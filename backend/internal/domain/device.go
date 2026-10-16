package domain

import (
	"strings"
	"time"
)

// Device is a phone or desktop running the app. There are no accounts: the
// app derives a stable id from the device's hardware id and sends it with
// every request.
type Device struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Platform  string    `json:"platform,omitempty"` // android, ios, windows, macos, linux
	Model     string    `json:"model,omitempty"`
	FirstSeen time.Time `json:"firstSeen"`
	LastSeen  time.Time `json:"lastSeen"`
}

// ValidDeviceID: 16 to 128 letters, digits, '-' or '_'.
func ValidDeviceID(id string) error {
	if len(id) < 16 || len(id) > 128 {
		return Invalid("device id must be 16 to 128 characters")
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_') {
			return Invalid("device id has invalid characters")
		}
	}
	return nil
}

// Normalize trims and limits the descriptive fields.
func (d *Device) Normalize() {
	d.Name = limit(strings.TrimSpace(d.Name), 80)
	d.Platform = limit(strings.ToLower(strings.TrimSpace(d.Platform)), 20)
	d.Model = limit(strings.TrimSpace(d.Model), 80)
	if d.Name == "" {
		d.Name = d.Model
	}
	if d.Name == "" {
		d.Name = "Device"
	}
}

func limit(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
