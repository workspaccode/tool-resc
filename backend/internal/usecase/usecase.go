// Package usecase is the application layer: it validates input, turns
// commands into state events, and answers queries. Transports (HTTP) call
// it; it knows nothing about them.
package usecase

import (
	"context"
	"time"

	"toolsresc/backend/internal/state"
)

// Store is the state the use cases work on (implemented by *state.Store).
type Store interface {
	Dispatch(ctx context.Context, e state.Event) (state.Result, error)
	View(fn func(*state.State))
}

// Clock returns the current time; replaced in tests.
type Clock func() time.Time

func timePtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func clampLimit(limit, def, max int) int {
	switch {
	case limit <= 0:
		return def
	case limit > max:
		return max
	}
	return limit
}
