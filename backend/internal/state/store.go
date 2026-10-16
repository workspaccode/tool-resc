package state

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// EventLog persists events. Implementations live in the storage package.
type EventLog interface {
	Append(ctx context.Context, env Envelope) error
	// Replay calls fn for every stored event, oldest first.
	Replay(ctx context.Context, fn func(Envelope) error) error
	Close() error
}

// Result of dispatching one event.
type Result struct {
	// Duplicate is true when an event with the same id was applied before;
	// nothing changed and Value is nil.
	Duplicate bool
	// Value is what the event's Apply returned.
	Value any
}

// Store owns the State. Writers are serialized; readers share a read lock.
type Store struct {
	mu  sync.RWMutex
	st  *State
	log EventLog
	now func() time.Time
}

// Open rebuilds the state from the log.
func Open(ctx context.Context, log EventLog) (*Store, error) {
	st := New()
	err := log.Replay(ctx, func(env Envelope) error {
		e, err := Decode(env)
		if err != nil {
			return err
		}
		if env.Seq <= st.Seq {
			return fmt.Errorf("event %d: out of order after %d", env.Seq, st.Seq)
		}
		st.apply(env.Seq, e)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("replay: %w", err)
	}
	return &Store{st: st, log: log, now: time.Now}, nil
}

// Dispatch persists an event, then applies it. Events with an id that was
// seen before are skipped, which makes client retries safe.
func (s *Store) Dispatch(ctx context.Context, e Event) (Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if id := e.ID(); id != "" && s.st.Seen(id) {
		return Result{Duplicate: true}, nil
	}
	env, err := Encode(s.st.Seq+1, e, s.now())
	if err != nil {
		return Result{}, err
	}
	if err := s.log.Append(ctx, env); err != nil {
		return Result{}, fmt.Errorf("append %s: %w", e.Kind(), err)
	}
	return Result{Value: s.st.apply(env.Seq, e)}, nil
}

// View runs fn with read access to the state. fn must not keep or modify
// anything it reads.
func (s *Store) View(fn func(*State)) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	fn(s.st)
}

func (s *Store) Close() error { return s.log.Close() }

func (st *State) apply(seq uint64, e Event) any {
	st.Seq = seq
	if id := e.ID(); id != "" {
		st.seen[id] = struct{}{}
	}
	return e.Apply(st, seq)
}
