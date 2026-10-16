package usecase

import (
	"context"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// MaxScanBatch is the most scans one Record call takes.
const MaxScanBatch = 1000

// Scans records scans and lists them.
type Scans struct {
	store Store
	now   Clock
}

func NewScans(store Store, now Clock) *Scans { return &Scans{store: store, now: now} }

type RecordOutput struct {
	Accepted   int           `json:"accepted"`
	Duplicates int           `json:"duplicates"`
	Scans      []domain.Scan `json:"scans"` // as stored (checked against the project)
}

// Record stores a batch of scans. The whole batch is validated first, so a
// bad scan rejects the batch before anything is stored. Scans already
// stored (same id) are counted as duplicates.
func (uc *Scans) Record(ctx context.Context, scans []domain.Scan) (RecordOutput, error) {
	if len(scans) == 0 {
		return RecordOutput{}, domain.Invalid("no scans")
	}
	if len(scans) > MaxScanBatch {
		return RecordOutput{}, domain.Invalid("at most %d scans per request", MaxScanBatch)
	}
	now := uc.now().UTC()
	for i := range scans {
		scans[i].Normalize()
		if scans[i].ScannedAt.IsZero() || scans[i].ScannedAt.After(now.Add(time.Minute)) {
			scans[i].ScannedAt = now // missing or from a device with a wrong clock
		}
		if err := scans[i].Validate(); err != nil {
			return RecordOutput{}, err
		}
	}

	out := RecordOutput{Scans: make([]domain.Scan, 0, len(scans))}
	for _, sc := range scans {
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

// Recent returns the newest matching scans first.
func (uc *Scans) Recent(_ context.Context, f domain.ScanFilter, limit int) (scans []domain.Scan, total int) {
	limit = clampLimit(limit, 100, 1000)
	uc.store.View(func(s *state.State) {
		for i := len(s.Scans) - 1; i >= 0; i-- {
			if !f.Match(s.Scans[i]) {
				continue
			}
			total++
			if len(scans) < limit {
				scans = append(scans, s.Scans[i])
			}
		}
	})
	return scans, total
}
