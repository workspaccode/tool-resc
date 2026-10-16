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
	KindDeviceRegistered Kind = "device.registered"
	KindProjectCreated   Kind = "project.created"
	KindProjectJoined    Kind = "project.joined"
	KindProjectLeft      Kind = "project.left"
	KindListImported     Kind = "list.imported"
	KindListRenamed      Kind = "list.renamed"
	KindListDeleted      Kind = "list.deleted"
	KindScanRecorded     Kind = "scan.recorded"
)

// Event is a fact that changes the state. Apply is its reducer: it must be
// deterministic and must not fail, because it also runs when the log is
// replayed. Use cases validate (including membership) before dispatching.
type Event interface {
	// ID is unique per event; a second event with the same id is ignored.
	// Empty: never deduplicated.
	ID() string
	Kind() Kind
	Apply(s *State, seq uint64) any
}

// DeviceRegistered is a device saying hello (also when its name changes).
type DeviceRegistered struct {
	Device domain.Device `json:"device"`
	At     time.Time     `json:"at"`
}

func (DeviceRegistered) ID() string { return "" }
func (DeviceRegistered) Kind() Kind { return KindDeviceRegistered }
func (e DeviceRegistered) Apply(s *State, _ uint64) any {
	d, ok := s.Devices[e.Device.ID]
	if !ok {
		d = &domain.Device{ID: e.Device.ID, FirstSeen: e.At}
		s.Devices[d.ID] = d
	}
	d.Name, d.Platform, d.Model, d.LastSeen = e.Device.Name, e.Device.Platform, e.Device.Model, e.At
	return *d
}

type ProjectCreated struct {
	ProjectID string    `json:"projectId"`
	Code      string    `json:"code"`
	Name      string    `json:"name"`
	DeviceID  string    `json:"deviceId"`
	At        time.Time `json:"at"`
}

func (ProjectCreated) ID() string { return "" }
func (ProjectCreated) Kind() Kind { return KindProjectCreated }
func (e ProjectCreated) Apply(s *State, _ uint64) any {
	p := domain.NewProject(e.ProjectID, e.Code, e.Name, e.DeviceID, e.At)
	s.Projects[p.ID] = p
	s.ByCode[p.Code] = p.ID
	return p
}

type ProjectJoined struct {
	ProjectID string    `json:"projectId"`
	DeviceID  string    `json:"deviceId"`
	At        time.Time `json:"at"`
}

func (ProjectJoined) ID() string { return "" }
func (ProjectJoined) Kind() Kind { return KindProjectJoined }
func (e ProjectJoined) Apply(s *State, _ uint64) any {
	if p, ok := s.Projects[e.ProjectID]; ok && !p.IsMember(e.DeviceID) {
		p.Members[e.DeviceID] = e.At
	}
	return nil
}

type ProjectLeft struct {
	ProjectID string    `json:"projectId"`
	DeviceID  string    `json:"deviceId"`
	At        time.Time `json:"at"`
}

func (ProjectLeft) ID() string { return "" }
func (ProjectLeft) Kind() Kind { return KindProjectLeft }
func (e ProjectLeft) Apply(s *State, _ uint64) any {
	if p, ok := s.Projects[e.ProjectID]; ok {
		delete(p.Members, e.DeviceID)
	}
	return nil
}

// ListImported is an Excel sheet imported into a list of a project. The
// list is created on its first import.
type ListImported struct {
	EventID   string            `json:"eventId"`
	ProjectID string            `json:"projectId"`
	ListID    string            `json:"listId"`
	Name      string            `json:"name"`
	DeviceID  string            `json:"deviceId"`
	Data      domain.ImportData `json:"data"`
	At        time.Time         `json:"at"`
}

func (e ListImported) ID() string { return e.EventID }
func (ListImported) Kind() Kind   { return KindListImported }

// Apply returns the updated *domain.List and the domain.ImportResult.
func (e ListImported) Apply(s *State, seq uint64) any {
	p, ok := s.Projects[e.ProjectID]
	if !ok {
		return nil
	}
	l, ok := p.Lists[e.ListID]
	if !ok {
		l = domain.NewList(e.ListID, p.ID, e.Name, e.At)
		p.Lists[l.ID] = l
	}
	l.Rename(e.Name, e.At)
	s.touchDevice(e.DeviceID, e.At)
	return ImportApplied{List: l, Result: l.Import(e.Data, seq, e.DeviceID, e.At)}
}

// ImportApplied is what ListImported.Apply returns.
type ImportApplied struct {
	List   *domain.List
	Result domain.ImportResult
}

type ListRenamed struct {
	EventID   string    `json:"eventId"`
	ProjectID string    `json:"projectId"`
	ListID    string    `json:"listId"`
	Name      string    `json:"name"`
	At        time.Time `json:"at"`
}

func (e ListRenamed) ID() string { return e.EventID }
func (ListRenamed) Kind() Kind   { return KindListRenamed }
func (e ListRenamed) Apply(s *State, _ uint64) any {
	if p, ok := s.Projects[e.ProjectID]; ok {
		if l, ok := p.Lists[e.ListID]; ok {
			l.Rename(e.Name, e.At)
		}
	}
	return nil
}

// ListDeleted removes a list from the project; its scans stay in the
// history.
type ListDeleted struct {
	EventID   string    `json:"eventId"`
	ProjectID string    `json:"projectId"`
	ListID    string    `json:"listId"`
	At        time.Time `json:"at"`
}

func (e ListDeleted) ID() string { return e.EventID }
func (ListDeleted) Kind() Kind   { return KindListDeleted }
func (e ListDeleted) Apply(s *State, _ uint64) any {
	if p, ok := s.Projects[e.ProjectID]; ok {
		delete(p.Lists, e.ListID)
	}
	return nil
}

// ScanRecorded is one scan, as the device sent it.
type ScanRecorded struct {
	Scan domain.Scan `json:"scan"`
}

func (e ScanRecorded) ID() string { return e.Scan.ID }
func (ScanRecorded) Kind() Kind   { return KindScanRecorded }

// Apply checks the scan against its list and returns the stored domain.Scan.
func (e ScanRecorded) Apply(s *State, _ uint64) any {
	sc := e.Scan
	if p, ok := s.Projects[sc.ProjectID]; ok {
		sc.Resolve(p.Lists[sc.ListID])
	}
	if d, ok := s.Devices[sc.DeviceID]; ok {
		sc.DeviceName = d.Name
	}
	s.touchDevice(sc.DeviceID, sc.ScannedAt)
	s.Scans[sc.ProjectID] = append(s.Scans[sc.ProjectID], sc)
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
	KindDeviceRegistered: decodeAs[DeviceRegistered],
	KindProjectCreated:   decodeAs[ProjectCreated],
	KindProjectJoined:    decodeAs[ProjectJoined],
	KindProjectLeft:      decodeAs[ProjectLeft],
	KindListImported:     decodeAs[ListImported],
	KindListRenamed:      decodeAs[ListRenamed],
	KindListDeleted:      decodeAs[ListDeleted],
	KindScanRecorded:     decodeAs[ScanRecorded],
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
