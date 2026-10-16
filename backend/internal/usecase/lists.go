package usecase

import (
	"context"
	"sort"
	"strings"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// Lists manages a project's lists (imported Excel sheets).
type Lists struct {
	store Store
	now   Clock
}

func NewLists(store Store, now Clock) *Lists { return &Lists{store: store, now: now} }

// ListSummary is a list with its scan counts; Version tells devices when
// to download the data again.
type ListSummary struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Fields     []string   `json:"fields"`
	MPNField   string     `json:"mpnField"`
	Parts      int        `json:"parts"`
	Rows       int        `json:"rows"`
	Version    uint64     `json:"version"`
	UpdatedBy  string     `json:"updatedBy,omitempty"`
	UpdatedAt  time.Time  `json:"updatedAt"`
	Scans      int        `json:"scans"`
	Found      int        `json:"found"`
	NotFound   int        `json:"notFound"`
	Quantity   int        `json:"quantity"`
	LastScanAt *time.Time `json:"lastScanAt,omitempty"`
}

type ImportInput struct {
	// EventID makes the import idempotent; the app sends its queue id.
	EventID   string
	DeviceID  string
	ProjectID string
	ListID    string
	Name      string
	Data      domain.ImportData
}

type ImportOutput struct {
	Duplicate bool                `json:"duplicate"`
	Result    domain.ImportResult `json:"result"`
	List      ListSummary         `json:"list"`
}

func (uc *Lists) Import(ctx context.Context, in ImportInput) (ImportOutput, error) {
	in.ListID = strings.TrimSpace(in.ListID)
	if in.ListID == "" {
		return ImportOutput{}, domain.Invalid("list id is required")
	}
	if err := in.Data.Validate(); err != nil {
		return ImportOutput{}, err
	}
	if err := member(uc.store, in.ProjectID, in.DeviceID, func(*state.State, *domain.Project) {}); err != nil {
		return ImportOutput{}, err
	}
	res, err := uc.store.Dispatch(ctx, state.ListImported{
		EventID: strings.TrimSpace(in.EventID), ProjectID: in.ProjectID, ListID: in.ListID,
		Name: in.Name, DeviceID: in.DeviceID, Data: in.Data, At: uc.now().UTC(),
	})
	if err != nil {
		return ImportOutput{}, err
	}
	out := ImportOutput{Duplicate: res.Duplicate}
	if a, ok := res.Value.(state.ImportApplied); ok {
		out.Result = a.Result
	}
	// Read the list back under the lock (a deleted list reports not found).
	err = member(uc.store, in.ProjectID, in.DeviceID, func(s *state.State, p *domain.Project) {
		if l, ok := p.Lists[in.ListID]; ok {
			out.List = listSummary(s, l)
		}
	})
	return out, err
}

func (uc *Lists) Rename(ctx context.Context, deviceID, projectID, listID, eventID, name string) error {
	name, err := domain.ValidName(name)
	if err != nil {
		return err
	}
	if err := uc.requireList(projectID, listID, deviceID); err != nil {
		return err
	}
	_, err = uc.store.Dispatch(ctx, state.ListRenamed{
		EventID: eventID, ProjectID: projectID, ListID: listID, Name: name, At: uc.now().UTC(),
	})
	return err
}

// Delete removes a list; deleting one that is already gone is fine.
func (uc *Lists) Delete(ctx context.Context, deviceID, projectID, listID, eventID string) error {
	if err := member(uc.store, projectID, deviceID, func(*state.State, *domain.Project) {}); err != nil {
		return err
	}
	_, err := uc.store.Dispatch(ctx, state.ListDeleted{EventID: eventID, ProjectID: projectID, ListID: listID, At: uc.now().UTC()})
	return err
}

func (uc *Lists) All(_ context.Context, deviceID, projectID string) ([]ListSummary, error) {
	var out []ListSummary
	err := member(uc.store, projectID, deviceID, func(s *state.State, p *domain.Project) { out = listSummaries(s, p) })
	return out, err
}

// Table returns the whole list for a device to download.
func (uc *Lists) Table(_ context.Context, deviceID, projectID, listID string) (ListSummary, domain.ImportData, error) {
	var sum ListSummary
	var table domain.ImportData
	found := false
	err := member(uc.store, projectID, deviceID, func(s *state.State, p *domain.Project) {
		if l, ok := p.Lists[listID]; ok {
			found, sum, table = true, listSummary(s, l), l.Table()
		}
	})
	if err == nil && !found {
		err = domain.ErrNotFound
	}
	return sum, table, err
}

// PartCount is one part of a list with how often it was scanned.
type PartCount struct {
	Key        string     `json:"key"`
	MPN        string     `json:"mpn"`
	Rows       int        `json:"rows"`
	Values     domain.Row `json:"values,omitempty"` // first row
	Scans      int        `json:"scans"`
	Quantity   int        `json:"quantity"`
	LastScanAt *time.Time `json:"lastScanAt,omitempty"`
}

// PartsQuery selects parts of a list.
type PartsQuery struct {
	Search  string // MPNs containing it (normalized, like the app)
	Scanned *bool  // nil = all, true = only scanned, false = never scanned
	Sort    string // "scans" (default) or "mpn"
	Limit   int
}

func (uc *Lists) Parts(_ context.Context, deviceID, projectID, listID string, q PartsQuery) (parts []PartCount, total int, err error) {
	key := domain.MPNKey(q.Search)
	limit := clampLimit(q.Limit, 100, 5000)
	found := false
	err = member(uc.store, projectID, deviceID, func(s *state.State, p *domain.Project) {
		l, ok := p.Lists[listID]
		if !ok {
			return
		}
		found = true
		tallies := s.PartTally[listID]
		for _, part := range l.Parts {
			if key != "" && !strings.Contains(part.Key, key) {
				continue
			}
			pc := PartCount{Key: part.Key, MPN: part.MPN, Rows: len(part.Rows)}
			if len(part.Rows) > 0 {
				pc.Values = make(domain.Row, len(part.Rows[0]))
				for k, v := range part.Rows[0] {
					pc.Values[k] = v
				}
			}
			if t := tallies[part.Key]; t != nil {
				pc.Scans, pc.Quantity, pc.LastScanAt = t.Scans, t.Quantity, timePtr(t.LastAt)
			}
			if q.Scanned != nil && (pc.Scans > 0) != *q.Scanned {
				continue
			}
			parts = append(parts, pc)
		}
	})
	if err == nil && !found {
		err = domain.ErrNotFound
	}
	if err != nil {
		return nil, 0, err
	}
	sort.Slice(parts, func(i, j int) bool {
		a, b := parts[i], parts[j]
		if q.Sort != "mpn" && a.Scans != b.Scans {
			return a.Scans > b.Scans
		}
		return a.Key < b.Key
	})
	total = len(parts)
	if len(parts) > limit {
		parts = parts[:limit]
	}
	return parts, total, nil
}

func (uc *Lists) requireList(projectID, listID, deviceID string) error {
	found := false
	err := member(uc.store, projectID, deviceID, func(_ *state.State, p *domain.Project) { _, found = p.Lists[listID] })
	if err == nil && !found {
		err = domain.ErrNotFound
	}
	return err
}

func listSummaries(s *state.State, p *domain.Project) []ListSummary {
	out := make([]ListSummary, 0, len(p.Lists))
	for _, l := range p.Lists {
		out = append(out, listSummary(s, l))
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

func listSummary(s *state.State, l *domain.List) ListSummary {
	out := ListSummary{
		ID: l.ID, Name: l.Name, Fields: append([]string{}, l.Fields...), MPNField: l.MPNField,
		Parts: len(l.Parts), Rows: l.RowCount, Version: l.Version, UpdatedBy: l.UpdatedBy, UpdatedAt: l.UpdatedAt,
	}
	if t := s.ListTally[l.ID]; t != nil {
		out.Scans, out.Found, out.NotFound = t.Scans, t.Found, t.Scans-t.Found
		out.Quantity, out.LastScanAt = t.Quantity, timePtr(t.LastAt)
	}
	return out
}
