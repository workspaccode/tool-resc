package domain

import (
	"fmt"
	"strings"
	"time"
)

// ImportMode mirrors the app: replace a project's data, or merge into it.
type ImportMode string

const (
	ImportReplace ImportMode = "replace"
	ImportMerge   ImportMode = "merge"
)

func (m ImportMode) Valid() bool { return m == ImportReplace || m == ImportMerge }

// Row is one imported Excel row: field label -> value, empty values omitted.
type Row map[string]string

// Part is every row of one MPN in a project.
type Part struct {
	Key  string `json:"key"`
	MPN  string `json:"mpn"`
	Rows []Row  `json:"rows"`
}

// ImportData is one Excel sheet as the app sends it.
type ImportData struct {
	Mode     ImportMode `json:"mode"`
	Headers  []string   `json:"headers"`
	Rows     [][]string `json:"rows"`
	MPNIndex int        `json:"mpnIndex"`
}

// Validate checks the sheet can be imported.
func (d ImportData) Validate() error {
	if !d.Mode.Valid() {
		return Invalid("mode must be %q or %q", ImportReplace, ImportMerge)
	}
	if len(d.Headers) == 0 {
		return Invalid("headers are required")
	}
	if d.MPNIndex < 0 || d.MPNIndex >= len(d.Headers) {
		return Invalid("mpnIndex %d is out of range", d.MPNIndex)
	}
	return nil
}

// ImportResult says what an import changed.
type ImportResult struct {
	Inserted int `json:"inserted"`
	Updated  int `json:"updated"`
	Removed  int `json:"removed"`
	Skipped  int `json:"skipped"`
}

// Project is one component list of the app (an order, BOM or customer).
type Project struct {
	ID        string           `json:"id"`
	Name      string           `json:"name"`
	Fields    []string         `json:"fields"`
	MPNField  string           `json:"mpnField"`
	Parts     map[string]*Part `json:"-"`
	RowCount  int              `json:"rows"`
	Imports   int              `json:"imports"`
	CreatedAt time.Time        `json:"createdAt"`
	UpdatedAt time.Time        `json:"updatedAt"`

	// namedAt is when Name was last set, so a late, queued event carrying
	// an older name doesn't undo a rename.
	namedAt time.Time
}

func NewProject(id, name string, at time.Time) *Project {
	p := &Project{ID: id, Parts: map[string]*Part{}, CreatedAt: at, UpdatedAt: at}
	p.Rename(name, at)
	return p
}

// Rename sets the name if it is newer than the current one.
func (p *Project) Rename(name string, at time.Time) {
	name = strings.TrimSpace(name)
	if name == "" || at.Before(p.namedAt) {
		return
	}
	p.Name, p.namedAt = name, at
}

// Lookup finds the part a scanned MPN belongs to.
func (p *Project) Lookup(mpn string) (*Part, bool) {
	key := MPNKey(mpn)
	if key == "" {
		return nil, false
	}
	part, ok := p.Parts[key]
	return part, ok
}

// Import applies a sheet with the app's rules: headers become fields
// (case-insensitive reuse), rows are grouped by MPN, and in merge mode an
// MPN's existing rows are paired with the file's rows in order — paired rows
// are updated (fields missing from the file are kept), extra file rows are
// added and extra existing rows are removed. The data must be validated.
func (p *Project) Import(d ImportData, at time.Time) ImportResult {
	if d.Mode == ImportReplace {
		p.Parts, p.Fields, p.MPNField = map[string]*Part{}, nil, ""
	}

	known := make(map[string]string, len(p.Fields))
	for _, f := range p.Fields {
		known[strings.ToLower(f)] = f
	}
	labels := make([]string, len(d.Headers))
	for i, h := range d.Headers {
		h = strings.TrimSpace(h)
		if h == "" {
			h = fmt.Sprintf("Column %d", i+1)
		}
		if f, ok := known[strings.ToLower(h)]; ok {
			labels[i] = f
			continue
		}
		known[strings.ToLower(h)] = h
		p.Fields = append(p.Fields, h)
		labels[i] = h
	}

	// Group the file's rows by MPN, keeping file order.
	var res ImportResult
	var order []string
	groups := map[string][][]string{}
	for _, row := range d.Rows {
		key := MPNKey(cell(row, d.MPNIndex))
		if key == "" {
			res.Skipped++
			continue
		}
		if _, ok := groups[key]; !ok {
			order = append(order, key)
		}
		groups[key] = append(groups[key], row)
	}

	for _, key := range order {
		fileRows := groups[key]
		var old []Row
		if part, ok := p.Parts[key]; ok {
			old = part.Rows
		}
		rows := make([]Row, len(fileRows))
		for i, fr := range fileRows {
			values := Row{}
			if i < len(old) {
				values = old[i]
				res.Updated++
			} else {
				res.Inserted++
			}
			// The file's columns overwrite; an empty cell clears that field.
			for c, label := range labels {
				if v := strings.TrimSpace(cell(fr, c)); v == "" {
					delete(values, label)
				} else {
					values[label] = v
				}
			}
			rows[i] = values
		}
		if len(old) > len(fileRows) {
			res.Removed += len(old) - len(fileRows)
		}
		p.Parts[key] = &Part{Key: key, MPN: strings.TrimSpace(cell(fileRows[0], d.MPNIndex)), Rows: rows}
	}

	p.MPNField = labels[d.MPNIndex]
	p.RowCount = 0
	for _, part := range p.Parts {
		p.RowCount += len(part.Rows)
	}
	p.Imports++
	p.UpdatedAt = at
	return res
}

func cell(row []string, i int) string {
	if i < len(row) {
		return row[i]
	}
	return ""
}
