package main

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"github.com/sratabix/awsssh/internal/awsx"
	"github.com/sratabix/awsssh/internal/forward"
)

type command struct {
	Cmd     string       `json:"cmd"`
	ID      int          `json:"id,omitempty"`
	Forward *forwardSpec `json:"forward,omitempty"`
}

type forwardSpec struct {
	Profile    string `json:"profile"`
	Region     string `json:"region"`
	Instance   string `json:"instance"`
	LocalPort  string `json:"local"`
	Host       string `json:"host"`
	RemotePort string `json:"remote"`
}

type message struct {
	Event    string   `json:"event"`
	ID       int      `json:"id,omitempty"`
	Detail   string   `json:"detail,omitempty"`
	Error    string   `json:"error,omitempty"`
	Profiles []string `json:"profiles,omitempty"`
}

type output struct {
	mu  sync.Mutex
	enc *json.Encoder
}

func (o *output) send(m message) {
	o.mu.Lock()
	defer o.mu.Unlock()
	_ = o.enc.Encode(m)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	provider := forward.NewProvider(ctx)
	mgr := forward.NewManager(ctx, provider)
	serve(os.Stdin, os.Stdout, mgr)
}

func serve(in io.Reader, w io.Writer, mgr *forward.Manager) {
	out := &output{enc: json.NewEncoder(w)}

	done := make(chan struct{})
	go func() {
		defer close(done)
		for ev := range mgr.Events() {
			out.send(message{
				Event:  string(ev.Kind),
				ID:     ev.ID,
				Detail: ev.Detail,
				Error:  ev.Err,
			})
		}
	}()

	out.send(message{Event: "ready"})

	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var c command
		if err := json.Unmarshal(line, &c); err != nil {
			out.send(message{Event: "error", Error: "bad command: " + err.Error()})
			continue
		}
		handle(c, mgr, out)
	}

	mgr.Close()
	<-done
}

func handle(c command, mgr *forward.Manager, out *output) {
	switch c.Cmd {
	case "start":
		if c.Forward == nil {
			out.send(message{Event: string(forward.Exited), ID: c.ID, Error: "missing forward spec"})
			return
		}
		mgr.Start(c.ID, forward.Spec{
			Profile:    c.Forward.Profile,
			Region:     c.Forward.Region,
			Instance:   c.Forward.Instance,
			LocalPort:  c.Forward.LocalPort,
			Host:       c.Forward.Host,
			RemotePort: c.Forward.RemotePort,
		})
	case "stop":
		mgr.Stop(c.ID)
	case "stopAll":
		mgr.StopAll()
	case "profiles":
		out.send(message{Event: "profiles", Profiles: awsx.Profiles()})
	default:
		out.send(message{Event: "error", Error: "unknown cmd: " + c.Cmd})
	}
}
