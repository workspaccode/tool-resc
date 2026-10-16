package usecase

import (
	"context"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// Stats counts scans.
type Stats struct {
	store Store
}

func NewStats(store Store) *Stats { return &Stats{store: store} }

type CountQuery struct {
	By       domain.Dimension
	Filter   domain.ScanFilter
	Location *time.Location // for days; UTC if nil
	Limit    int
}

type CountOutput struct {
	By          domain.Dimension `json:"by"`
	Scans       int              `json:"scans"`       // matching scans
	TotalGroups int              `json:"totalGroups"` // before the limit
	Groups      []domain.Count   `json:"groups"`
}

// Count groups the matching scans by one dimension, e.g. how often each
// part was scanned in a project, or scans per device per day.
func (uc *Stats) Count(_ context.Context, q CountQuery) CountOutput {
	out := CountOutput{By: q.By}
	uc.store.View(func(s *state.State) {
		out.Groups, out.Scans = domain.CountScans(s.Scans, q.By, q.Filter, q.Location)
	})
	out.TotalGroups = len(out.Groups)
	if limit := clampLimit(q.Limit, 100, 10000); len(out.Groups) > limit {
		out.Groups = out.Groups[:limit]
	}
	if out.Groups == nil {
		out.Groups = []domain.Count{}
	}
	return out
}

type Summary struct {
	Projects   int        `json:"projects"`
	Parts      int        `json:"parts"`
	Rows       int        `json:"rows"`
	Scans      int        `json:"scans"`
	Found      int        `json:"found"`
	NotFound   int        `json:"notFound"`
	Devices    int        `json:"devices"`
	LastScanAt *time.Time `json:"lastScanAt,omitempty"`
}

// Summary is the totals across all projects.
func (uc *Stats) Summary(_ context.Context) Summary {
	var out Summary
	uc.store.View(func(s *state.State) {
		out.Projects = len(s.Projects)
		for _, p := range s.Projects {
			out.Parts += len(p.Parts)
			out.Rows += p.RowCount
		}
		devices := map[string]struct{}{}
		var last time.Time
		for _, sc := range s.Scans {
			if sc.Found {
				out.Found++
			}
			if sc.DeviceID != "" {
				devices[sc.DeviceID] = struct{}{}
			}
			if sc.ScannedAt.After(last) {
				last = sc.ScannedAt
			}
		}
		out.Scans, out.NotFound, out.Devices = len(s.Scans), len(s.Scans)-out.Found, len(devices)
		out.LastScanAt = timePtr(last)
	})
	return out
}
