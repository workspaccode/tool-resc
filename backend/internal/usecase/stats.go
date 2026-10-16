package usecase

import (
	"context"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// Stats counts a project's scans.
type Stats struct {
	store Store
}

func NewStats(store Store) *Stats { return &Stats{store: store} }

type CountQuery struct {
	By       domain.Dimension
	Filter   domain.ScanFilter // Filter.ProjectID is required
	Location *time.Location    // for days; UTC if nil
	Limit    int
}

type CountOutput struct {
	By          domain.Dimension `json:"by"`
	Scans       int              `json:"scans"`       // matching scans
	TotalGroups int              `json:"totalGroups"` // before the limit
	Groups      []domain.Count   `json:"groups"`
}

// Count groups the matching scans by one dimension, e.g. how often each
// part was scanned in a list, or scans per device per day.
func (uc *Stats) Count(_ context.Context, deviceID string, q CountQuery) (CountOutput, error) {
	out := CountOutput{By: q.By, Groups: []domain.Count{}}
	err := member(uc.store, q.Filter.ProjectID, deviceID, func(s *state.State, _ *domain.Project) {
		if groups, n := domain.CountScans(s.Scans[q.Filter.ProjectID], q.By, q.Filter, q.Location); n > 0 {
			out.Groups, out.Scans = groups, n
		}
	})
	out.TotalGroups = len(out.Groups)
	if limit := clampLimit(q.Limit, 100, 10000); len(out.Groups) > limit {
		out.Groups = out.Groups[:limit]
	}
	return out, err
}
