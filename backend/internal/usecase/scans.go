package usecase

import (
	"context"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// MaxScanBatch is the most scans one Record call takes.
const MaxScanBatch = 1000

// Scans records scans and lists a project's scan history.
type Scans struct {
	store Store
	now   Clock
}

func NewScans(store Store, now Clock) *Scans { return &Scans{store: store, now: now} }

type RecordOutput struct {
	Accepted   int           `json:"accepted"`
	Duplicates int           `json:"duplicates"`
	Rejected   int           `json:"rejected"` // projects the device isn't a member of
	Scans      []domain.Scan `json:"scans"`    // as stored (checked against the list)
}

// Record stores a batch of scans made by the device. The whole batch is
// validated first. Scans for projects the device isn't (or is no longer) a
// member of are rejected without failing the batch, so they can't block
// the app's queue.
func (uc *Scans) Record(ctx context.Context, deviceID string, scans []domain.Scan) (RecordOutput, error) {
	if len(scans) == 0 {
		return RecordOutput{}, domain.Invalid("no scans")
	}
	if len(scans) > MaxScanBatch {
		return RecordOutput{}, domain.Invalid("at most %d scans per request", MaxScanBatch)
	}
	now := uc.now().UTC()
	for i := range scans {
		scans[i].Normalize()
		scans[i].DeviceID = deviceID
		if scans[i].ScannedAt.IsZero() || scans[i].ScannedAt.After(now.Add(time.Minute)) {
			scans[i].ScannedAt = now // missing, or a device with a wrong clock
		}
		if err := scans[i].Validate(); err != nil {
			return RecordOutput{}, err
		}
	}

	allowed := map[string]bool{}
	uc.store.View(func(s *state.State) {
		for _, sc := range scans {
			if _, done := allowed[sc.ProjectID]; !done {
				_, allowed[sc.ProjectID] = s.ProjectFor(sc.ProjectID, deviceID)
			}
		}
	})

	out := RecordOutput{Scans: make([]domain.Scan, 0, len(scans))}
	for _, sc := range scans {
		if !allowed[sc.ProjectID] {
			out.Rejected++
			continue
		}
		res, err := uc.store.Dispatch(ctx, state.ScanRecorded{Scan: sc})
		if err != nil {
			return out, err
		}
		if res.Duplicate {
			out.Duplicates++
			continue
		}
		out.Accepted++
		out.Scans = append(out.Scans, res.Value.(domain.Scan))
	}
	return out, nil
}

// History returns a project's matching scans, newest first.
func (uc *Scans) History(_ context.Context, deviceID string, f domain.ScanFilter, limit int) (scans []domain.Scan, total int, err error) {
	limit = clampLimit(limit, 100, 1000)
	scans = []domain.Scan{}
	err = member(uc.store, f.ProjectID, deviceID, func(s *state.State, _ *domain.Project) {
		all := s.Scans[f.ProjectID]
		for i := len(all) - 1; i >= 0; i-- {
			if !f.Match(all[i]) {
				continue
			}
			total++
			if len(scans) < limit {
				scans = append(scans, all[i])
			}
		}
	})
	return scans, total, err
}
