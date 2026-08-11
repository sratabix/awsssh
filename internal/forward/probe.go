package forward

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/sratabix/awsssh/internal/session"
)

const (
	probeOpenWait = 15 * time.Second
	probeQuiet    = 2 * time.Second
	probeRetry    = 250 * time.Millisecond
	probeReap     = 6 * time.Second
)

type pluginRun struct {
	done chan struct{}
	err  error
}

func startPlugin(cmd *exec.Cmd) *pluginRun {
	run := &pluginRun{done: make(chan struct{})}
	go func() {
		run.err = cmd.Wait()
		close(run.done)
	}()
	return run
}

func freeLocalPort() (string, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", fmt.Errorf("no local port is free for the test: %w", err)
	}
	defer func() { _ = l.Close() }()
	addr, ok := l.Addr().(*net.TCPAddr)
	if !ok {
		return "", errors.New("no local port is free for the test")
	}
	return strconv.Itoa(addr.Port), nil
}

func targetName(s Spec) string {
	if s.Host == "" {
		return "port " + s.RemotePort + " on the instance"
	}
	return s.Host + ":" + s.RemotePort
}

func answered(n int, err error) bool {
	return n > 0 || errors.Is(err, os.ErrDeadlineExceeded)
}

func withoutSessionID(s string) string {
	if !strings.HasPrefix(s, "SessionId: ") {
		return s
	}
	if i := strings.Index(s, " : "); i >= 0 {
		return strings.TrimSpace(s[i+len(" : "):])
	}
	return s
}

func pluginSaid(stderrTail, stdoutTail string) string {
	said := firstLine(strings.TrimSpace(stderrTail))
	if said == "" {
		said = lastLine(strings.TrimSpace(stdoutTail))
	}
	return withoutSessionID(said)
}

func refused(target, stderrTail, stdoutTail string) error {
	if said := pluginSaid(stderrTail, stdoutTail); said != "" {
		return fmt.Errorf("the tunnel opened but %s did not answer: %s", target, said)
	}
	return fmt.Errorf(
		"the tunnel opened but %s closed the connection at once; "+
			"check the host, the port and the security group in front of it", target)
}

func notOpened(werr error, stderrTail, stdoutTail string) error {
	said := pluginSaid(stderrTail, stdoutTail)
	switch {
	case said != "":
		return fmt.Errorf("the tunnel did not open: %s", said)
	case werr != nil:
		return fmt.Errorf("the tunnel did not open: %w", werr)
	default:
		return errors.New("the tunnel did not open, and session-manager-plugin said nothing")
	}
}

func (m *Manager) probe(ctx context.Context, b Bundle, instanceID string, s Spec) error {
	local, err := freeLocalPort()
	if err != nil {
		return err
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	cmd, err := b.Starter.ForwardCommand(ctx, instanceID, session.Forward{
		LocalPort:  local,
		Host:       s.Host,
		RemotePort: s.RemotePort,
	})
	if err != nil {
		return err
	}

	out, errs := newTailBuffer(tailBytes), newTailBuffer(tailBytes)
	cmd.Stdout, cmd.Stderr = out, errs
	if err := cmd.Start(); err != nil {
		return err
	}

	run := startPlugin(cmd)
	defer func() {
		cancel()
		select {
		case <-run.done:
		case <-time.After(probeReap):
		}
	}()

	conn, err := connectWhenOpen(ctx, local, run, out, errs)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()

	_ = conn.SetReadDeadline(time.Now().Add(probeQuiet))
	n, rerr := conn.Read(make([]byte, 1))
	if answered(n, rerr) {
		return nil
	}
	return refused(targetName(s), errs.String(), out.String())
}

func connectWhenOpen(
	ctx context.Context,
	local string,
	run *pluginRun,
	out, errs *tailBuffer,
) (net.Conn, error) {
	deadline := time.Now().Add(probeOpenWait)
	for {
		conn, err := net.DialTimeout("tcp", "127.0.0.1:"+local, probeRetry)
		if err == nil {
			return conn, nil
		}
		select {
		case <-run.done:
			return nil, notOpened(run.err, errs.String(), out.String())
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(probeRetry):
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("the tunnel did not open within %s", probeOpenWait)
		}
	}
}
