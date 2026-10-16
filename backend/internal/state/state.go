// Package state is the server's state management: one in-memory State that
// changes only by applying Events (the reducer). Every event is written to
// an EventLog before it is applied, so the state can be rebuilt on startup
// by replaying the log.
package state

import (
	"time"

	"toolsresc/backend/internal/domain"
)

// Tally is a running scan count, kept per project and per part so lists
// don't need to walk every scan.
type Tally struct {
	Scans    int       `json:"scans"`
	Found    int       `json:"found"`
	Quantity int       `json:"quantity"`
	LastAt   time.Time `json:"lastAt"`
}

func (t *Tally) add(s domain.Scan) {
	t.Scans++
	if s.Found {
		t.Found++
	}
	t.Quantity += s.Quantity
	if s.ScannedAt.After(t.LastAt) {
		t.LastAt = s.ScannedAt
	}
}

// State is everything the server knows. Read it only through Store.View.
type State struct {
	// Seq is the sequence number of the last applied event.
	Seq uint64

	Projects map[string]*domain.Project

	// Scans in the order they were received.
	Scans []domain.Scan

	// ProjectTally and PartTally are projections of Scans.
	ProjectTally map[string]*Tally            // project id -> tally
	PartTally    map[string]map[string]*Tally // project id -> mpn key -> tally

	// seen holds the ids of applied events, so a retried request is a no-op.
	seen map[string]struct{}
}

func New() *State {
	return &State{
		Projects:     map[string]*domain.Project{},
		ProjectTally: map[string]*Tally{},
		PartTally:    map[string]map[string]*Tally{},
		seen:         map[string]struct{}{},
	}
}

// Seen reports whether an event with this id was already applied.
func (s *State) Seen(id string) bool {
	_, ok := s.seen[id]
	return ok
}

// project returns a project, creating it if needed, and keeps its name current.
func (s *State) project(id, name string, at time.Time) *domain.Project {
	p, ok := s.Projects[id]
	if !ok {
		p = domain.NewProject(id, name, at)
		s.Projects[id] = p
		return p
	}
	p.Rename(name, at)
	return p
}

func (s *State) tallyScan(sc domain.Scan) {
	pt, ok := s.ProjectTally[sc.ProjectID]
	if !ok {
		pt = &Tally{}
		s.ProjectTally[sc.ProjectID] = pt
	}
	pt.add(sc)

	parts, ok := s.PartTally[sc.ProjectID]
	if !ok {
		parts = map[string]*Tally{}
		s.PartTally[sc.ProjectID] = parts
	}
	t, ok := parts[sc.MPNKey]
	if !ok {
		t = &Tally{}
		parts[sc.MPNKey] = t
	}
	t.add(sc)
}
