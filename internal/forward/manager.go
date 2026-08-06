package forward

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"

	"github.com/sratabix/awsssh/internal/session"
)

type Spec struct {
	Profile    string
	Region     string
	Instance   string
	LocalPort  string
	Host       string
	RemotePort string
}

type EventKind string

const (
	Started EventKind = "started"
	Exited  EventKind = "exited"
)

type Event struct {
	ID     int
	Kind   EventKind
	Detail string
	Err    string
}

type Manager struct {
	ctx      context.Context
	provider *Provider
	events   chan Event

	mu        sync.Mutex
	cancels   map[int]context.CancelFunc
	wg        sync.WaitGroup
	closeOnce sync.Once
}

func NewManager(ctx context.Context, provider *Provider) *Manager {
	return &Manager{
		ctx:      ctx,
		provider: provider,
		events:   make(chan Event, 64),
		cancels:  map[int]context.CancelFunc{},
	}
}

func (m *Manager) Events() <-chan Event { return m.events }

func (m *Manager) Start(id int, s Spec) {
	m.mu.Lock()
	if _, running := m.cancels[id]; running {
		m.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(m.ctx)
	m.cancels[id] = cancel
	m.mu.Unlock()

	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		defer cancel()

		ev := m.run(ctx, id, s)

		m.mu.Lock()
		delete(m.cancels, id)
		m.mu.Unlock()

		m.emit(ev)
	}()
}

func (m *Manager) run(ctx context.Context, id int, s Spec) Event {
	b, err := m.provider.Get(s.Profile, s.Region)
	if err != nil {
		return exitEvent(id, err)
	}
	target, err := b.Client.LookupRunning(ctx, s.Instance)
	if err != nil {
		return exitEvent(id, err)
	}
	cmd, err := b.Starter.ForwardCommand(ctx, target.InstanceID, session.Forward{
		LocalPort:  s.LocalPort,
		Host:       s.Host,
		RemotePort: s.RemotePort,
	})
	if err != nil {
		return exitEvent(id, err)
	}

	out, errs := newTailBuffer(tailBytes), newTailBuffer(tailBytes)
	cmd.Stdout = out
	cmd.Stderr = errs
	if err := cmd.Start(); err != nil {
		return exitEvent(id, err)
	}
	m.emit(Event{ID: id, Kind: Started, Detail: "localhost:" + s.LocalPort})

	werr := cmd.Wait()
	if ctx.Err() != nil {
		return Event{ID: id, Kind: Exited}
	}
	return exitEvent(id, endedReason(werr, errs.String(), out.String()))
}

func (m *Manager) Stop(id int) {
	m.mu.Lock()
	cancel := m.cancels[id]
	m.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (m *Manager) StopAll() {
	m.mu.Lock()
	for _, cancel := range m.cancels {
		cancel()
	}
	m.mu.Unlock()
	m.wg.Wait()
}

func (m *Manager) Close() {
	m.StopAll()
	m.closeOnce.Do(func() { close(m.events) })
}

func exitEvent(id int, err error) Event {
	ev := Event{ID: id, Kind: Exited}
	if err != nil && !errors.Is(err, context.Canceled) {
		ev.Err = err.Error()
	}
	return ev
}

func (m *Manager) emit(e Event) {
	select {
	case m.events <- e:
	case <-m.ctx.Done():
	}
}

func endedReason(werr error, stderrTail, stdoutTail string) error {
	if msg := firstLine(strings.TrimSpace(stderrTail)); msg != "" {
		return errors.New(msg)
	}
	last := lastLine(strings.TrimSpace(stdoutTail))
	switch {
	case werr != nil && last != "":
		return fmt.Errorf("%s (%w)", last, werr)
	case werr != nil:
		return werr
	case last != "":
		return fmt.Errorf(
			"the session ended on its own; last message from session-manager-plugin: %s", last)
	default:
		return errors.New("the session ended on its own, with no message from session-manager-plugin")
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func lastLine(s string) string {
	if i := strings.LastIndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[i+1:])
	}
	return s
}
