package domain

import (
	"strings"
	"time"
)

// ScanSource is how a code reached the app.
type ScanSource string

const (
	SourceCamera  ScanSource = "camera"
	SourceScanner ScanSource = "scanner" // USB / Bluetooth scanner in keyboard mode
	SourceTyped   ScanSource = "typed"   // a full label code entered in the search field
	SourceUnknown ScanSource = "unknown"
)

// ParseSource maps any unknown value to SourceUnknown.
func ParseSource(s string) ScanSource {
	switch src := ScanSource(strings.ToLower(strings.TrimSpace(s))); src {
	case SourceCamera, SourceScanner, SourceTyped:
		return src
	default:
		return SourceUnknown
	}
}

// Scan is one scanned label, checked against one project.
type Scan struct {
	ID           string     `json:"id"`
	ProjectID    string     `json:"projectId"`
	ProjectName  string     `json:"projectName,omitempty"`
	DeviceID     string     `json:"deviceId,omitempty"`
	DeviceName   string     `json:"deviceName,omitempty"`
	Source       ScanSource `json:"source"`
	Raw          string     `json:"raw,omitempty"`
	MPN          string     `json:"mpn"`
	MPNKey       string     `json:"mpnKey"`
	SupplierPart string     `json:"supplierPart,omitempty"`
	OrderNumber  string     `json:"orderNumber,omitempty"`
	Quantity     int        `json:"quantity,omitempty"`
	Found        bool       `json:"found"`
	ScannedAt    time.Time  `json:"scannedAt"`
}

const maxRawLen = 4096

// Normalize fills derived fields and trims input.
func (s *Scan) Normalize() {
	s.ID = strings.TrimSpace(s.ID)
	s.ProjectID = strings.TrimSpace(s.ProjectID)
	s.ProjectName = strings.TrimSpace(s.ProjectName)
	s.DeviceID = strings.TrimSpace(s.DeviceID)
	s.DeviceName = strings.TrimSpace(s.DeviceName)
	s.MPN = strings.TrimSpace(s.MPN)
	s.MPNKey = MPNKey(s.MPN)
	s.SupplierPart = strings.TrimSpace(s.SupplierPart)
	s.OrderNumber = strings.TrimSpace(s.OrderNumber)
	s.Source = ParseSource(string(s.Source))
	if len(s.Raw) > maxRawLen {
		s.Raw = s.Raw[:maxRawLen]
	}
	if s.Quantity < 0 {
		s.Quantity = 0
	}
	s.ScannedAt = s.ScannedAt.UTC()
}

// Validate checks a normalized scan.
func (s Scan) Validate() error {
	switch {
	case s.ID == "":
		return Invalid("scan id is required")
	case s.ProjectID == "":
		return Invalid("scan %s: projectId is required", s.ID)
	case s.MPNKey == "":
		return Invalid("scan %s: mpn has no letters or digits", s.ID)
	case s.ScannedAt.IsZero():
		return Invalid("scan %s: scannedAt is required", s.ID)
	}
	return nil
}

// Resolve checks the scan against the project's imported parts. A project
// with data is the authority on Found; without data the device's answer is
// kept.
func (s *Scan) Resolve(p *Project) {
	if p == nil || len(p.Parts) == 0 {
		return
	}
	part, ok := p.Parts[s.MPNKey]
	s.Found = ok
	if ok && part.MPN != "" {
		s.MPN = part.MPN // as stored, not as printed on the label
	}
}
