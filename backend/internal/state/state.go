// Package state is the server's state management: one in-memory State that
// changes only by applying Events (the reducer). Every event is written to
// an EventLog before it is applied, so the state can be rebuilt on startup
// by replaying the log.
package state

import (
	"time"

	"toolsresc/backend/internal/domain"
)

// Tally is a running scan count, kept per list and per part so screens
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

	Devices  map[string]*domain.Device
	Projects map[string]*domain.Project
	ByCode   map[string]string // project code -> project id

	// Scans per project, in the order they were received.
	Scans map[string][]domain.Scan

	// Projections of Scans.
	ListTally map[string]*Tally            // list id -> tally
	PartTally map[string]map[string]*Tally // list id -> mpn key -> tally

	// seen holds the ids of applied events, so a retried request is a no-op.
	seen map[string]struct{}
}

func New() *State {
	return &State{
		Devices:   map[string]*domain.Device{},
		Projects:  map[string]*domain.Project{},
		ByCode:    map[string]string{},
		Scans:     map[string][]domain.Scan{},
		ListTally: map[string]*Tally{},
		PartTally: map[string]map[string]*Tally{},
		seen:      map[string]struct{}{},
	}
}

// Seen reports whether an event with this id was already applied.
func (s *State) Seen(id string) bool {
	_, ok := s.seen[id]
	return ok
}

// ProjectFor returns a project only if the device is a member.
func (s *State) ProjectFor(projectID, deviceID string) (*domain.Project, bool) {
	p, ok := s.Projects[projectID]
	if !ok || !p.IsMember(deviceID) {
		return nil, false
	}
	return p, true
}

func (s *State) touchDevice(id string, at time.Time) {
	if d, ok := s.Devices[id]; ok && at.After(d.LastSeen) {
		d.LastSeen = at
	}
}

func (s *State) tallyScan(sc domain.Scan) {
	lt, ok := s.ListTally[sc.ListID]
	if !ok {
		lt = &Tally{}
		s.ListTally[sc.ListID] = lt
	}
	lt.add(sc)

	parts, ok := s.PartTally[sc.ListID]
	if !ok {
		parts = map[string]*Tally{}
		s.PartTally[sc.ListID] = parts
	}
	t, ok := parts[sc.MPNKey]
	if !ok {
		t = &Tally{}
		parts[sc.MPNKey] = t
	}
	t.add(sc)
}
