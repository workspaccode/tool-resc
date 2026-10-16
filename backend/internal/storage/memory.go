// Package storage implements state.EventLog.
package storage

import (
	"context"
	"sync"

	"toolsresc/backend/internal/state"
)

// Memory keeps events in memory only; for tests and throwaway servers.
type Memory struct {
	mu     sync.Mutex
	events []state.Envelope
}

func NewMemory() *Memory { return &Memory{} }

func (m *Memory) Append(_ context.Context, env state.Envelope) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.events = append(m.events, env)
	return nil
}

func (m *Memory) Replay(ctx context.Context, fn func(state.Envelope) error) error {
	m.mu.Lock()
	events := append([]state.Envelope(nil), m.events...)
	m.mu.Unlock()
	for _, env := range events {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := fn(env); err != nil {
			return err
		}
	}
	return nil
}

func (m *Memory) Close() error { return nil }
