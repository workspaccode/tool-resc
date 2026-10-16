package usecase

import (
	"context"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
)

// Devices registers devices. No accounts: a device is known by its id.
type Devices struct {
	store Store
	now   Clock
}

func NewDevices(store Store, now Clock) *Devices { return &Devices{store: store, now: now} }

// Register adds or updates a device. Nothing is written when nothing
// changed, so the app can call it on every start.
func (uc *Devices) Register(ctx context.Context, d domain.Device) (domain.Device, error) {
	if err := domain.ValidDeviceID(d.ID); err != nil {
		return domain.Device{}, err
	}
	d.Normalize()
	var current *domain.Device
	uc.store.View(func(s *state.State) {
		if c, ok := s.Devices[d.ID]; ok {
			cp := *c
			current = &cp
		}
	})
	if current != nil && current.Name == d.Name && current.Platform == d.Platform && current.Model == d.Model {
		return *current, nil
	}
	res, err := uc.store.Dispatch(ctx, state.DeviceRegistered{Device: d, At: uc.now().UTC()})
	if err != nil {
		return domain.Device{}, err
	}
	return res.Value.(domain.Device), nil
}

// Known reports whether the device registered.
func (uc *Devices) Known(id string) bool {
	ok := false
	uc.store.View(func(s *state.State) { _, ok = s.Devices[id] })
	return ok
}
