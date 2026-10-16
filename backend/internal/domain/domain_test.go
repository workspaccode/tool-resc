package domain

import (
	"testing"
	"time"
)

func TestMPNKeyMatchesApp(t *testing.T) {
	if MPNKey("rc0805fr 07820kl") != MPNKey("RC0805FR-07820KL") {
		t.Fatal("case, spaces and dashes must be ignored")
	}
	if got := MPNKey(" -/ "); got != "" {
		t.Fatalf("got %q, want empty", got)
	}
}

func TestImportReplaceThenMerge(t *testing.T) {
	at := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	p := NewList("l1", "p1", "BOM", at)

	res := p.Import(ImportData{
		Mode:    ImportReplace,
		Headers: []string{"MPN", "Bin", "Qty"},
		Rows: [][]string{
			{"LM358DR", "A1", "10"},
			{"LM358DR", "A2", "5"},
			{"RC0805FR-07820KL", "B1", "100"},
			{"", "X", "1"},
		},
	}, 1, "dev", at)
	if res != (ImportResult{Inserted: 3, Skipped: 1}) {
		t.Fatalf("replace: %+v", res)
	}
	if p.RowCount != 3 || len(p.Parts) != 2 || p.MPNField != "MPN" {
		t.Fatalf("project: rows=%d parts=%d mpnField=%q", p.RowCount, len(p.Parts), p.MPNField)
	}

	// Merge: LM358DR gets one row (one updated, one removed), a new field
	// is added, "bin" reuses the existing "Bin" field and Qty is kept.
	res = p.Import(ImportData{
		Mode:     ImportMerge,
		Headers:  []string{"bin", "Mpn", "Note"},
		Rows:     [][]string{{"C9", "lm358dr", "new"}, {"D1", "NE555", ""}},
		MPNIndex: 1,
	}, 2, "dev", at.Add(time.Hour))
	if res != (ImportResult{Inserted: 1, Updated: 1, Removed: 1}) {
		t.Fatalf("merge: %+v", res)
	}
	lm, ok := p.Lookup("LM358-DR")
	if !ok || len(lm.Rows) != 1 {
		t.Fatalf("LM358DR rows: %+v", lm)
	}
	row := lm.Rows[0]
	if row["Bin"] != "C9" || row["Qty"] != "10" || row["Note"] != "new" {
		t.Fatalf("merged row: %v", row)
	}
	if want := []string{"MPN", "Bin", "Qty", "Note"}; len(p.Fields) != len(want) {
		t.Fatalf("fields: %v", p.Fields)
	}
	if p.RowCount != 3 || p.Imports != 2 || p.Version != 2 {
		t.Fatalf("rows=%d imports=%d version=%d", p.RowCount, p.Imports, p.Version)
	}

	// The table for download keeps import order and every field.
	table := p.Table()
	if table.Headers[table.MPNIndex] != "MPN" || len(table.Rows) != 3 || table.Rows[0][table.MPNIndex] != "lm358dr" {
		t.Fatalf("table: %+v", table)
	}
	if table.Rows[2][table.MPNIndex] != "NE555" {
		t.Fatalf("new parts go last: %+v", table.Rows)
	}
}

func TestProjectCodes(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		c := NewCode()
		if NormalizeCode(c) != c || len(c) != 9 || seen[c] {
			t.Fatalf("bad or repeated code %q", c)
		}
		seen[c] = true
	}
	if NormalizeCode("k7f2 qx9m") != "K7F2-QX9M" {
		t.Fatal("codes must accept any case and spaces")
	}
	if NormalizeCode("K7F2-QX9") != "" || NormalizeCode("K7F2-QX9O") != "" {
		t.Fatal("short codes and look-alike letters are rejected")
	}
}

func TestRenameIgnoresOlderNames(t *testing.T) {
	at := time.Now()
	p := NewList("l1", "p1", "New name", at)
	p.Rename("Old name", at.Add(-time.Minute))
	if p.Name != "New name" {
		t.Fatalf("name = %q", p.Name)
	}
}

func TestCountScans(t *testing.T) {
	day := time.Date(2026, 3, 1, 22, 30, 0, 0, time.UTC)
	scans := []Scan{
		{ListID: "a", MPNKey: "LM358DR", MPN: "LM358DR", DeviceID: "d1", Found: true, Quantity: 10, ScannedAt: day},
		{ListID: "a", MPNKey: "LM358DR", MPN: "LM358DR", DeviceID: "d2", Found: true, Quantity: 5, ScannedAt: day.Add(time.Hour)},
		{ListID: "b", MPNKey: "NE555", MPN: "NE555", DeviceID: "d1", ScannedAt: day.Add(2 * time.Hour)},
	}

	groups, matched := CountScans(scans, ByPart, ScanFilter{}, nil)
	if matched != 3 || len(groups) != 2 || groups[0].Key != "LM358DR" || groups[0].Scans != 2 || groups[0].Quantity != 15 {
		t.Fatalf("by part: %+v", groups)
	}

	groups, _ = CountScans(scans, ByDevice, ScanFilter{ListID: "a"}, nil)
	if len(groups) != 2 || groups[0].Scans != 1 {
		t.Fatalf("by device in list a: %+v", groups)
	}

	notFound := false
	groups, matched = CountScans(scans, ByList, ScanFilter{Found: &notFound}, nil)
	if matched != 1 || groups[0].Key != "b" || groups[0].NotFound != 1 {
		t.Fatalf("not found by list: %+v", groups)
	}

	// Riyadh is UTC+3, so the 22:30 UTC scan is already the next day there.
	riyadh := time.FixedZone("AST", 3*60*60)
	groups, _ = CountScans(scans, ByDay, ScanFilter{}, riyadh)
	if len(groups) != 1 || groups[0].Key != "2026-03-02" {
		t.Fatalf("by day: %+v", groups)
	}
}
