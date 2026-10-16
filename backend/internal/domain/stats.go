package domain

import (
	"sort"
	"strings"
	"time"
)

// Dimension is what scans are counted by.
type Dimension string

const (
	ByPart         Dimension = "part"          // MPN (name)
	BySupplierPart Dimension = "supplier_part" // supplier code, e.g. LCSC C141700 (id)
	ByProject      Dimension = "project"       // the app's list
	ByDevice       Dimension = "device"
	BySource       Dimension = "source"
	ByOrder        Dimension = "order"
	ByDay          Dimension = "day"
	ByResult       Dimension = "result" // found / not found
)

// Dimensions lists every supported dimension.
var Dimensions = []Dimension{ByPart, BySupplierPart, ByProject, ByDevice, BySource, ByOrder, ByDay, ByResult}

func ParseDimension(s string) (Dimension, error) {
	d := Dimension(strings.ToLower(strings.TrimSpace(s)))
	for _, known := range Dimensions {
		if d == known {
			return d, nil
		}
	}
	return "", Invalid("unknown dimension %q", s)
}

// groupKey is the strategy for each dimension: the key scans are grouped
// by, and a readable label for it.
func (d Dimension) groupKey(s Scan, loc *time.Location) (key, label string) {
	switch d {
	case ByPart:
		return s.MPNKey, s.MPN
	case BySupplierPart:
		return s.SupplierPart, s.SupplierPart
	case ByProject:
		return s.ProjectID, s.ProjectName
	case ByDevice:
		return s.DeviceID, s.DeviceName
	case BySource:
		return string(s.Source), string(s.Source)
	case ByOrder:
		return s.OrderNumber, s.OrderNumber
	case ByDay:
		day := s.ScannedAt.In(loc).Format(time.DateOnly)
		return day, day
	case ByResult:
		if s.Found {
			return "found", "Found"
		}
		return "not_found", "Not found"
	}
	return "", ""
}

// ScanFilter narrows the scans that are counted. Zero values match all.
type ScanFilter struct {
	ProjectID string
	DeviceID  string
	PartKey   string
	Source    ScanSource
	Found     *bool
	From, To  time.Time // [From, To)
}

func (f ScanFilter) Match(s Scan) bool {
	switch {
	case f.ProjectID != "" && s.ProjectID != f.ProjectID,
		f.DeviceID != "" && s.DeviceID != f.DeviceID,
		f.PartKey != "" && s.MPNKey != f.PartKey,
		f.Source != "" && s.Source != f.Source,
		f.Found != nil && s.Found != *f.Found,
		!f.From.IsZero() && s.ScannedAt.Before(f.From),
		!f.To.IsZero() && !s.ScannedAt.Before(f.To):
		return false
	}
	return true
}

// Count is one group of scans.
type Count struct {
	Key      string    `json:"key"`
	Label    string    `json:"label"`
	Scans    int       `json:"scans"`
	Found    int       `json:"found"`
	NotFound int       `json:"notFound"`
	Quantity int       `json:"quantity"`
	FirstAt  time.Time `json:"firstAt"`
	LastAt   time.Time `json:"lastAt"`
}

// Add counts one scan into the group. The newest scan's label wins, so a
// renamed project or device shows its current name.
func (c *Count) Add(s Scan, label string) {
	c.Scans++
	if s.Found {
		c.Found++
	} else {
		c.NotFound++
	}
	c.Quantity += s.Quantity
	if c.FirstAt.IsZero() || s.ScannedAt.Before(c.FirstAt) {
		c.FirstAt = s.ScannedAt
	}
	if !s.ScannedAt.Before(c.LastAt) {
		c.LastAt = s.ScannedAt
		if label != "" {
			c.Label = label
		}
	}
}

// CountScans groups matching scans by a dimension. Scans without a value
// for the dimension (e.g. no supplier code) are grouped under "". Sorted by
// most scans, then key; days are sorted by date instead.
func CountScans(scans []Scan, by Dimension, f ScanFilter, loc *time.Location) (groups []Count, matched int) {
	if loc == nil {
		loc = time.UTC
	}
	index := map[string]int{}
	for _, s := range scans {
		if !f.Match(s) {
			continue
		}
		matched++
		key, label := by.groupKey(s, loc)
		i, ok := index[key]
		if !ok {
			i = len(groups)
			index[key] = i
			groups = append(groups, Count{Key: key, Label: label})
		}
		groups[i].Add(s, label)
	}
	sort.Slice(groups, func(i, j int) bool {
		a, b := groups[i], groups[j]
		if by == ByDay {
			return a.Key < b.Key
		}
		if a.Scans != b.Scans {
			return a.Scans > b.Scans
		}
		return a.Key < b.Key
	})
	return groups, matched
}
