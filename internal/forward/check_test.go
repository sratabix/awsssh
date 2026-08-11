package forward

import (
	"errors"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"

	"github.com/sratabix/awsssh/internal/awsx"
	"github.com/sratabix/awsssh/internal/session"
)

func TestInstanceLabelPrefersTheNameAndKeepsTheID(t *testing.T) {
	cases := []struct {
		in   awsx.Instance
		want string
	}{
		{awsx.Instance{Name: "db-prod", InstanceID: "i-0abc"}, "db-prod (i-0abc)"},
		{awsx.Instance{InstanceID: "i-0abc"}, "i-0abc"},
		{awsx.Instance{Name: "i-0abc", InstanceID: "i-0abc"}, "i-0abc"},
	}
	for _, c := range cases {
		if got := instanceLabel(c.in); got != c.want {
			t.Errorf("instanceLabel(%+v) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestAgentFailureStopsAnUnregisteredInstance(t *testing.T) {
	target := awsx.Instance{Name: "db-prod", InstanceID: "i-0abc", State: "running"}

	err := agentFailure(target, "eu-central-1", session.Agent{}, true)
	if err == nil {
		t.Fatal("an unmanaged instance can never be forwarded to")
	}
	if !strings.Contains(err.Error(), "not registered with SSM") {
		t.Errorf("error = %q, want the cause", err)
	}
	if !strings.Contains(err.Error(), "instance profile") {
		t.Errorf("error = %q, want the fix as well as the cause", err)
	}
}

func TestAgentFailureStopsAnOfflineAgent(t *testing.T) {
	target := awsx.Instance{InstanceID: "i-0abc", State: "running"}

	err := agentFailure(target, "eu-west-1", session.Agent{Registered: true, Ping: "ConnectionLost"}, true)
	if err == nil {
		t.Fatal("a registered instance whose agent is gone must not pass")
	}
	if !strings.Contains(err.Error(), "ConnectionLost") {
		t.Errorf("error = %q, want the ping status AWS reported", err)
	}
}

func TestAgentFailureLetsAnUncheckableAgentThrough(t *testing.T) {
	target := awsx.Instance{InstanceID: "i-0abc", State: "running"}
	if err := agentFailure(target, "eu-west-1", session.Agent{}, false); err != nil {
		t.Errorf("a missing read permission is not proof of a broken forward: %v", err)
	}
}

func TestAgentFailurePassesAnOnlineAgent(t *testing.T) {
	target := awsx.Instance{InstanceID: "i-0abc", State: "running"}
	if err := agentFailure(target, "eu-west-1", session.Agent{Registered: true, Ping: "Online"}, true); err != nil {
		t.Errorf("want a pass, got %v", err)
	}
}

func TestTargetNameSaysWhatWasProbed(t *testing.T) {
	if got := targetName(Spec{Host: "db.internal", RemotePort: "5432"}); got != "db.internal:5432" {
		t.Errorf("targetName = %q", got)
	}
	if got := targetName(Spec{RemotePort: "22"}); !strings.Contains(got, "22") ||
		!strings.Contains(got, "instance") {
		t.Errorf("targetName = %q; with no host the target is the instance itself", got)
	}
}

func TestCheckDetailNamesTheTargetThatAnswered(t *testing.T) {
	target := awsx.Instance{Name: "db-prod", InstanceID: "i-0abc"}
	got := checkDetail(target, "eu-central-1", Spec{Host: "db.internal", RemotePort: "5432"})

	for _, want := range []string{"db-prod", "i-0abc", "eu-central-1", "db.internal:5432"} {
		if !strings.Contains(got, want) {
			t.Errorf("detail %q should mention %q", got, want)
		}
	}
}

func TestAnsweredTreatsAQuietOpenSocketAsAPass(t *testing.T) {
	if !answered(0, os.ErrDeadlineExceeded) {
		t.Error("postgres says nothing until spoken to; a quiet socket is still open")
	}
	if !answered(1, nil) {
		t.Error("a banner is an answer")
	}
	if answered(0, io.EOF) {
		t.Error("an immediate EOF is the signature of a target that refused")
	}
	if answered(0, errors.New("read: connection reset by peer")) {
		t.Error("a reset is not an answer")
	}
}

func TestRefusedPrefersWhatThePluginSaid(t *testing.T) {
	err := refused("db.internal:5432", "ERROR: cannot connect\nsecond line", "Port 1234 opened")
	if !strings.Contains(err.Error(), "ERROR: cannot connect") {
		t.Errorf("error = %q, want stderr's first line", err)
	}
	if strings.Contains(err.Error(), "second line") {
		t.Errorf("error = %q must stay one line", err)
	}

	err = refused("db.internal:5432", "", "Port 1234 opened\nConnection to destination port failed")
	if !strings.Contains(err.Error(), "Connection to destination port failed") {
		t.Errorf("error = %q, want stdout's last line when stderr is silent", err)
	}
}

func TestRefusedAlwaysExplainsItselfAndNamesTheTarget(t *testing.T) {
	for _, tail := range []string{"", "   ", "\n\n"} {
		err := refused("db.internal:5432", tail, tail)
		if err == nil {
			t.Fatal("a refusal must always carry a reason")
		}
		if !strings.Contains(err.Error(), "db.internal:5432") {
			t.Errorf("error = %q, want the target named", err)
		}
		if strings.Contains(err.Error(), "\n") {
			t.Errorf("error = %q spans lines", err)
		}
	}
}

func TestAFreeLocalPortIsFreeAndDifferentEachTime(t *testing.T) {
	first, err := freeLocalPort()
	if err != nil {
		t.Fatal(err)
	}
	l, err := net.Listen("tcp", "127.0.0.1:"+first)
	if err != nil {
		t.Fatalf("the port handed back must be bindable: %v", err)
	}
	defer l.Close()

	second, err := freeLocalPort()
	if err != nil {
		t.Fatal(err)
	}
	if second == first {
		t.Error("a port already taken must not be handed out again")
	}
}

func TestAReservedLocalPortIsRefusedBeforeAnythingElse(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root may bind a reserved port")
	}
	err := checkLocalPort("11")
	if err == nil {
		t.Fatal("port 11 needs root; a test that passes here is the bug this covers")
	}
	if !strings.Contains(err.Error(), "root") || !strings.Contains(err.Error(), "1023") {
		t.Errorf("error = %q, want the cause and the way out", err)
	}
}

func TestALocalPortHeldBySomethingElseIsRefused(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	addr, ok := l.Addr().(*net.TCPAddr)
	if !ok {
		t.Fatal("want a TCP listener")
	}

	err = checkLocalPort(strconv.Itoa(addr.Port))
	if err == nil {
		t.Fatal("a port already listening cannot be forwarded to")
	}
	if !strings.Contains(err.Error(), "already in use") {
		t.Errorf("error = %q", err)
	}
}

func TestAFreeLocalPortPassesAndIsGivenBack(t *testing.T) {
	port, err := freeLocalPort()
	if err != nil {
		t.Fatal(err)
	}
	if err := checkLocalPort(port); err != nil {
		t.Fatalf("a free port must pass: %v", err)
	}
	if err := checkLocalPort(port); err != nil {
		t.Fatalf("the check must not keep the port it just bound: %v", err)
	}
}

func TestNoLocalPortIsNotAFailure(t *testing.T) {
	if err := checkLocalPort(""); err != nil {
		t.Errorf("a test of a running forward sends no local port: %v", err)
	}
}

func TestLocalPortErrorNamesThePortWhateverWentWrong(t *testing.T) {
	cases := []error{syscall.EACCES, syscall.EADDRINUSE, errors.New("something else"), os.ErrPermission}
	for _, in := range cases {
		err := localPortError("15432", in)
		if !strings.Contains(err.Error(), "15432") {
			t.Errorf("localPortError(%v) = %q, want the port named", in, err)
		}
		if strings.Contains(err.Error(), "\n") {
			t.Errorf("localPortError(%v) = %q spans lines", in, err)
		}
	}
}

func TestCheckDetailMentionsTheLocalPortOnlyWhenItWasChecked(t *testing.T) {
	target := awsx.Instance{Name: "db-prod", InstanceID: "i-0abc"}

	with := checkDetail(target, "eu-central-1", Spec{Host: "db.internal", RemotePort: "5432", LocalPort: "15432"})
	if !strings.Contains(with, "15432") {
		t.Errorf("detail = %q, want the local port it proved free", with)
	}

	without := checkDetail(target, "eu-central-1", Spec{Host: "db.internal", RemotePort: "5432"})
	if strings.Contains(without, "local port") {
		t.Errorf("detail = %q must not claim a port it never bound", without)
	}
}

func TestAPluginLineDropsItsSessionID(t *testing.T) {
	const line = "SessionId: someone@example.com-0123456789abcdef : " +
		"lookup db.internal on 10.0.0.2:53: no such host"

	got := withoutSessionID(line)
	if got != "lookup db.internal on 10.0.0.2:53: no such host" {
		t.Errorf("got %q; the session id is noise, and it carries the user's name", got)
	}
	if withoutSessionID("Port 1234 opened") != "Port 1234 opened" {
		t.Error("a line with no session id must be left alone")
	}
	if withoutSessionID("SessionId: no-separator") != "SessionId: no-separator" {
		t.Error("without the separator there is nothing safe to cut")
	}
}

func TestNotOpenedAlwaysExplainsItself(t *testing.T) {
	cases := []struct {
		werr           error
		stderr, stdout string
		want           string
	}{
		{nil, "", "SessionId: x : no such host", "no such host"},
		{nil, "ERROR: cannot perform start session", "", "cannot perform start session"},
		{errors.New("exit status 254"), "", "", "exit status 254"},
		{nil, "", "", "said nothing"},
	}
	for _, c := range cases {
		err := notOpened(c.werr, c.stderr, c.stdout)
		if err == nil {
			t.Fatalf("notOpened(%v, %q, %q) returned nil", c.werr, c.stderr, c.stdout)
		}
		if !strings.Contains(err.Error(), c.want) {
			t.Errorf("error = %q, want it to mention %q", err, c.want)
		}
		if !strings.Contains(err.Error(), "did not open") {
			t.Errorf("error = %q, want it to say the tunnel never opened", err)
		}
		if strings.Contains(err.Error(), "\n") {
			t.Errorf("error = %q spans lines", err)
		}
	}
}

func TestConnectWhenOpenReportsAPluginThatDiedFirst(t *testing.T) {
	run := &pluginRun{done: make(chan struct{})}
	run.err = errors.New("exit status 254")
	close(run.done)

	out, errs := newTailBuffer(tailBytes), newTailBuffer(tailBytes)
	errs.Write([]byte("ERROR: cannot perform start session"))

	free, err := freeLocalPort()
	if err != nil {
		t.Fatal(err)
	}
	_, err = connectWhenOpen(t.Context(), free, run, out, errs)
	if err == nil {
		t.Fatal("a plugin that exited before opening the port cannot be waited on")
	}
	if !strings.Contains(err.Error(), "cannot perform start session") {
		t.Errorf("error = %q, want the plugin's own complaint", err)
	}
}

func TestConnectWhenOpenTakesTheFirstOpenPort(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	addr, ok := l.Addr().(*net.TCPAddr)
	if !ok {
		t.Fatal("want a TCP listener")
	}

	run := &pluginRun{done: make(chan struct{})}
	conn, err := connectWhenOpen(t.Context(), strconv.Itoa(addr.Port), run,
		newTailBuffer(tailBytes), newTailBuffer(tailBytes))
	if err != nil {
		t.Fatalf("a listening port must be connected to: %v", err)
	}
	conn.Close()
}
