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
	"time"

	"github.com/sratabix/awsssh/internal/awsx"
	"github.com/sratabix/awsssh/internal/forward"
)

type command struct {
	Cmd     string       `json:"cmd"`
	ID      int          `json:"id,omitempty"`
	Forward *forwardSpec `json:"forward,omitempty"`
	Login   string       `json:"login,omitempty"`
}

type forwardSpec struct {
	Profile    string `json:"profile"`
	Region     string `json:"region"`
	Instance   string `json:"instance"`
	LocalPort  string `json:"local"`
	Host       string `json:"host"`
	RemotePort string `json:"remote"`
}

type loginInfo struct {
	Label       string   `json:"label"`
	Profiles    []string `json:"profiles"`
	Expires     string   `json:"expires,omitempty"`
	Refreshable bool     `json:"refreshable,omitempty"`
}

type message struct {
	Event    string      `json:"event"`
	ID       int         `json:"id,omitempty"`
	Detail   string      `json:"detail,omitempty"`
	Error    string      `json:"error,omitempty"`
	Profiles []string    `json:"profiles,omitempty"`
	Logins   []loginInfo `json:"logins,omitempty"`
	State    string      `json:"state,omitempty"`
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
	serve(ctx, os.Stdin, os.Stdout, mgr)
}

func serve(ctx context.Context, in io.Reader, w io.Writer, mgr *forward.Manager) {
	out := &output{enc: json.NewEncoder(w)}
	var background sync.WaitGroup

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
		handle(ctx, c, mgr, out, &background)
	}

	background.Wait()
	mgr.Close()
	<-done
}

func handle(
	ctx context.Context,
	c command,
	mgr *forward.Manager,
	out *output,
	background *sync.WaitGroup,
) {
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
	case "logins":
		out.send(loginList())
	case "ssoLogin":
		background.Add(1)
		go func() {
			defer background.Done()
			signIn(ctx, c.Login, out)
		}()
	case "checkLogin":
		background.Add(1)
		go func() {
			defer background.Done()
			checkLogin(ctx, c.Login, out)
		}()
	default:
		out.send(message{Event: "error", Error: "unknown cmd: " + c.Cmd})
	}
}

var (
	listLogins   = awsx.Logins
	ssoLogin     = awsx.RunSSOLogin
	loginChecker = awsx.CheckLogin
)

func checkLogin(ctx context.Context, label string, out *output) {
	for _, login := range listLogins() {
		if login.Label() == label {
			out.send(message{
				Event:  "loginCheck",
				Detail: label,
				State:  string(loginChecker(ctx, login)),
			})
			return
		}
	}
	out.send(message{Event: "loginCheck", Detail: label, State: string(awsx.LoginUnknown)})
}

func loginList() message {
	found := listLogins()
	infos := make([]loginInfo, 0, len(found))
	for _, login := range found {
		info := loginInfo{
			Label:       login.Label(),
			Profiles:    login.Profiles,
			Refreshable: login.Refreshable,
		}
		if !login.Expires.IsZero() {
			info.Expires = login.Expires.Format(time.RFC3339)
		}
		infos = append(infos, info)
	}
	return message{Event: "logins", Logins: infos}
}

func signIn(ctx context.Context, label string, out *output) {
	for _, login := range listLogins() {
		if login.Label() != label {
			continue
		}
		if err := ssoLogin(ctx, login); err != nil {
			out.send(message{Event: "ssoLogin", Detail: label, Error: err.Error()})
			return
		}
		out.send(message{Event: "ssoLogin", Detail: label})
		out.send(loginList())
		return
	}
	out.send(message{Event: "ssoLogin", Detail: label, Error: "no SSO sign-in named " + label})
}
