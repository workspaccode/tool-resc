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

// Scan is one scanned label, checked against one list of a project.
type Scan struct {
	ID           string     `json:"id"`
	ProjectID    string     `json:"projectId"`
	ListID       string     `json:"listId"`
	ListName     string     `json:"listName,omitempty"`
	DeviceID     string     `json:"deviceId"`
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
	s.ListID = strings.TrimSpace(s.ListID)
	s.ListName = strings.TrimSpace(s.ListName)
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
	case s.ProjectID == "" || s.ListID == "":
		return Invalid("scan %s: projectId and listId are required", s.ID)
	case s.MPNKey == "":
		return Invalid("scan %s: mpn has no letters or digits", s.ID)
	case s.ScannedAt.IsZero():
		return Invalid("scan %s: scannedAt is required", s.ID)
	}
	return nil
}

// Resolve checks the scan against the list's parts. A list with data is
// the authority on Found; otherwise the device's answer is kept.
func (s *Scan) Resolve(l *List) {
	if l == nil {
		return
	}
	s.ListName = l.Name
	if len(l.Parts) == 0 {
		return
	}
	part, ok := l.Parts[s.MPNKey]
	s.Found = ok
	if ok && part.MPN != "" {
		s.MPN = part.MPN // as stored, not as printed on the label
	}
}
