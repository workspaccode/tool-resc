package usecase

import (
	"context"
	"sort"
	"strings"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// Projects manages the app's lists and their imported parts.
type Projects struct {
	store Store
	now   Clock
}

func NewProjects(store Store, now Clock) *Projects { return &Projects{store: store, now: now} }

type ImportInput struct {
	// EventID makes the import idempotent; the app sends its queue id.
	EventID   string
	ProjectID string
	Name      string
	DeviceID  string
	Data      domain.ImportData
}

type ImportOutput struct {
	Duplicate bool                `json:"duplicate"`
	Result    domain.ImportResult `json:"result"`
	Project   ProjectSummary      `json:"project"`
}

// ProjectSummary is a project with its scan counts.
type ProjectSummary struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Fields     []string   `json:"fields"`
	MPNField   string     `json:"mpnField"`
	Parts      int        `json:"parts"`
	Rows       int        `json:"rows"`
	Imports    int        `json:"imports"`
	Scans      int        `json:"scans"`
	Found      int        `json:"found"`
	NotFound   int        `json:"notFound"`
	Quantity   int        `json:"quantity"`
	LastScanAt *time.Time `json:"lastScanAt,omitempty"`
	CreatedAt  time.Time  `json:"createdAt"`
	UpdatedAt  time.Time  `json:"updatedAt"`
}

// PartCount is one imported part with how often it was scanned.
type PartCount struct {
	Key        string     `json:"key"`
	MPN        string     `json:"mpn"`
	Rows       int        `json:"rows"`
	Values     domain.Row `json:"values,omitempty"` // first row
	Scans      int        `json:"scans"`
	Quantity   int        `json:"quantity"`
	LastScanAt *time.Time `json:"lastScanAt,omitempty"`
}

func (uc *Projects) Import(ctx context.Context, in ImportInput) (ImportOutput, error) {
	in.ProjectID = strings.TrimSpace(in.ProjectID)
	if in.ProjectID == "" {
		return ImportOutput{}, domain.Invalid("project id is required")
	}
	if err := in.Data.Validate(); err != nil {
		return ImportOutput{}, err
	}
	res, err := uc.store.Dispatch(ctx, state.ProjectImported{
		EventID:   strings.TrimSpace(in.EventID),
		ProjectID: in.ProjectID,
		Name:      in.Name,
		DeviceID:  in.DeviceID,
		Data:      in.Data,
		At:        uc.now().UTC(),
	})
	if err != nil {
		return ImportOutput{}, err
	}
	out := ImportOutput{Duplicate: res.Duplicate}
	if r, ok := res.Value.(domain.ImportResult); ok {
		out.Result = r
	}
	out.Project, err = uc.Get(ctx, in.ProjectID)
	return out, err
}

// List returns every project, most recently scanned or updated first.
func (uc *Projects) List(_ context.Context) []ProjectSummary {
	var out []ProjectSummary
	uc.store.View(func(s *state.State) {
		out = make([]ProjectSummary, 0, len(s.Projects))
		for _, p := range s.Projects {
			out = append(out, summarize(s, p))
		}
	})
	recent := func(p ProjectSummary) time.Time {
		if p.LastScanAt != nil && p.LastScanAt.After(p.UpdatedAt) {
			return *p.LastScanAt
		}
		return p.UpdatedAt
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := recent(out[i]), recent(out[j])
		if !a.Equal(b) {
			return a.After(b)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func (uc *Projects) Get(_ context.Context, id string) (ProjectSummary, error) {
	var out ProjectSummary
	var ok bool
	uc.store.View(func(s *state.State) {
		var p *domain.Project
		if p, ok = s.Projects[id]; ok {
			out = summarize(s, p)
		}
	})
	if !ok {
		return ProjectSummary{}, domain.ErrNotFound
	}
	return out, nil
}

// PartsQuery selects parts of a project.
type PartsQuery struct {
	// Search matches MPNs containing it (normalized, like the app).
	Search string
	// Scanned: nil = all parts, true = only scanned, false = never scanned.
	Scanned *bool
	// Sort: "scans" (default, most first) or "mpn".
	Sort  string
	Limit int
}

// Parts lists a project's imported parts with their scan counts. total is
// the number of matches before the limit.
func (uc *Projects) Parts(_ context.Context, id string, q PartsQuery) (parts []PartCount, total int, err error) {
	key := domain.MPNKey(q.Search)
	limit := clampLimit(q.Limit, 100, 5000)
	found := false
	uc.store.View(func(s *state.State) {
		p, ok := s.Projects[id]
		if !ok {
			return
		}
		found = true
		tallies := s.PartTally[id]
		for _, part := range p.Parts {
			if key != "" && !strings.Contains(part.Key, key) {
				continue
			}
			pc := PartCount{Key: part.Key, MPN: part.MPN, Rows: len(part.Rows)}
			if len(part.Rows) > 0 {
				pc.Values = copyRow(part.Rows[0])
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
	if !found {
		return nil, 0, domain.ErrNotFound
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

func summarize(s *state.State, p *domain.Project) ProjectSummary {
	out := ProjectSummary{
		ID:        p.ID,
		Name:      p.Name,
		Fields:    append([]string{}, p.Fields...),
		MPNField:  p.MPNField,
		Parts:     len(p.Parts),
		Rows:      p.RowCount,
		Imports:   p.Imports,
		CreatedAt: p.CreatedAt,
		UpdatedAt: p.UpdatedAt,
	}
	if t := s.ProjectTally[p.ID]; t != nil {
		out.Scans, out.Found, out.NotFound = t.Scans, t.Found, t.Scans-t.Found
		out.Quantity, out.LastScanAt = t.Quantity, timePtr(t.LastAt)
	}
	return out
}

func copyRow(r domain.Row) domain.Row {
	out := make(domain.Row, len(r))
	for k, v := range r {
		out[k] = v
	}
	return out
}
