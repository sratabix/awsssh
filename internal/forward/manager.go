package forward

import (
	"bytes"
	"context"
	"fmt"
	"io"
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
		defer func() {
			m.mu.Lock()
			delete(m.cancels, id)
			m.mu.Unlock()
		}()

		b, err := m.provider.Get(s.Profile, s.Region)
		if err != nil {
			m.emit(Event{ID: id, Kind: Exited, Err: err.Error()})
			return
		}
		target, err := b.Client.LookupRunning(ctx, s.Instance)
		if err != nil {
			m.emit(Event{ID: id, Kind: Exited, Err: err.Error()})
			return
		}
		cmd, err := b.Starter.ForwardCommand(ctx, target.InstanceID, session.Forward{
			LocalPort:  s.LocalPort,
			Host:       s.Host,
			RemotePort: s.RemotePort,
		})
		if err != nil {
			m.emit(Event{ID: id, Kind: Exited, Err: err.Error()})
			return
		}

		var errbuf bytes.Buffer
		cmd.Stdout = io.Discard
		cmd.Stderr = &errbuf
		if err := cmd.Start(); err != nil {
			m.emit(Event{ID: id, Kind: Exited, Err: err.Error()})
			return
		}
		m.emit(Event{ID: id, Kind: Started, Detail: "localhost:" + s.LocalPort})

		werr := cmd.Wait()
		switch {
		case ctx.Err() != nil:
			werr = nil
		case werr != nil:
			if msg := strings.TrimSpace(errbuf.String()); msg != "" {
				werr = fmt.Errorf("%s", firstLine(msg))
			}
		}
		ev := Event{ID: id, Kind: Exited}
		if werr != nil {
			ev.Err = werr.Error()
		}
		m.emit(ev)
	}()
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

func (m *Manager) emit(e Event) {
	select {
	case m.events <- e:
	case <-m.ctx.Done():
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
