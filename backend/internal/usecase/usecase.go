// Package usecase is the application layer: it validates input, checks
// that the device may act on the project, turns commands into state events,
// and answers queries. Transports (HTTP) call it; it knows nothing about
// them.
package usecase

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// Store is the state the use cases work on (implemented by *state.Store).
type Store interface {
	Dispatch(ctx context.Context, e state.Event) (state.Result, error)
	View(fn func(*state.State))
}

// Clock returns the current time; replaced in tests.
type Clock func() time.Time

// member runs fn with the project if the device is a member; otherwise the
// project is reported as not found, so ids can't be probed.
func member(store Store, projectID, deviceID string, fn func(*state.State, *domain.Project)) error {
	found := false
	store.View(func(s *state.State) {
		if p, ok := s.ProjectFor(projectID, deviceID); ok {
			found = true
			fn(s, p)
		}
	})
	if !found {
		return domain.ErrNotFound
	}
	return nil
}

func newID() string {
	b := make([]byte, 12)
	rand.Read(b)
	return hex.EncodeToString(b)
}

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
