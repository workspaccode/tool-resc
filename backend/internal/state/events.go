package state

import (
	"encoding/json"
	"fmt"
	"time"

	"toolsresc/backend/internal/domain"
)

// Kind names an event type in the log.
type Kind string

const (
	KindProjectImported Kind = "project.imported"
	KindScanRecorded    Kind = "scan.recorded"
)

// Event is a fact that changes the state. Apply is its reducer: it must be
// deterministic and must not fail, because it also runs when the log is
// replayed. Validate the input before dispatching.
type Event interface {
	// ID is unique per event; a second event with the same id is ignored.
	ID() string
	Kind() Kind
	Apply(s *State) any
}

// ProjectImported is an Excel sheet imported into a project (list).
type ProjectImported struct {
	EventID   string            `json:"eventId"`
	ProjectID string            `json:"projectId"`
	Name      string            `json:"name"`
	DeviceID  string            `json:"deviceId,omitempty"`
	Data      domain.ImportData `json:"data"`
	At        time.Time         `json:"at"`
}

func (e ProjectImported) ID() string { return e.EventID }
func (ProjectImported) Kind() Kind   { return KindProjectImported }

// Apply returns the domain.ImportResult.
func (e ProjectImported) Apply(s *State) any {
	return s.project(e.ProjectID, e.Name, e.At).Import(e.Data, e.At)
}

// ScanRecorded is one scan, as the device sent it.
type ScanRecorded struct {
	Scan domain.Scan `json:"scan"`
}

func (e ScanRecorded) ID() string { return e.Scan.ID }
func (ScanRecorded) Kind() Kind   { return KindScanRecorded }

// Apply checks the scan against the project's parts and returns the stored
// domain.Scan.
func (e ScanRecorded) Apply(s *State) any {
	sc := e.Scan
	p := s.project(sc.ProjectID, sc.ProjectName, sc.ScannedAt)
	sc.Resolve(p)
	sc.ProjectName = p.Name
	s.Scans = append(s.Scans, sc)
	s.tallyScan(sc)
	return sc
}

// Envelope is how an event is stored in the log.
type Envelope struct {
	Seq  uint64          `json:"seq"`
	Kind Kind            `json:"kind"`
	At   time.Time       `json:"at"`
	Data json.RawMessage `json:"data"`
}

var decoders = map[Kind]func([]byte) (Event, error){
	KindProjectImported: decodeAs[ProjectImported],
	KindScanRecorded:    decodeAs[ScanRecorded],
}

func decodeAs[T Event](data []byte) (Event, error) {
	var e T
	err := json.Unmarshal(data, &e)
	return e, err
}

func Encode(seq uint64, e Event, at time.Time) (Envelope, error) {
	data, err := json.Marshal(e)
	if err != nil {
		return Envelope{}, fmt.Errorf("encode %s: %w", e.Kind(), err)
	}
	return Envelope{Seq: seq, Kind: e.Kind(), At: at.UTC(), Data: data}, nil
}

func Decode(env Envelope) (Event, error) {
	decode, ok := decoders[env.Kind]
	if !ok {
		return nil, fmt.Errorf("event %d: unknown kind %q", env.Seq, env.Kind)
	}
	e, err := decode(env.Data)
	if err != nil {
		return nil, fmt.Errorf("event %d (%s): %w", env.Seq, env.Kind, err)
	}
	return e, nil
}
