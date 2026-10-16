package state_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/state"
	"toolsresc/backend/internal/storage"
)

func TestStoreReplaysFileLog(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "events.jsonl")
	at := time.Date(2026, 5, 1, 9, 0, 0, 0, time.UTC)

	log, err := storage.OpenFile(path)
	if err != nil {
		t.Fatal(err)
	}
	store, err := state.Open(ctx, log)
	if err != nil {
		t.Fatal(err)
	}
	mustDispatch := func(e state.Event) state.Result {
		t.Helper()
		res, err := store.Dispatch(ctx, e)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	mustDispatch(state.DeviceRegistered{Device: domain.Device{ID: "dev1", Name: "Pixel"}, At: at})
	mustDispatch(state.ProjectCreated{ProjectID: "p1", Code: "AAAA-BBBB", Name: "Site A", DeviceID: "dev1", At: at})
	mustDispatch(state.ListImported{
		EventID: "imp1", ProjectID: "p1", ListID: "l1", Name: "BOM", DeviceID: "dev1", At: at,
		Data: domain.ImportData{Mode: domain.ImportReplace, Headers: []string{"MPN"}, Rows: [][]string{{"LM358DR"}}},
	})
	scan := func(id, mpn string) state.ScanRecorded {
		s := domain.Scan{ID: id, ProjectID: "p1", ListID: "l1", DeviceID: "dev1", MPN: mpn, Found: true, ScannedAt: at.Add(time.Minute)}
		s.Normalize()
		return state.ScanRecorded{Scan: s}
	}
	got := mustDispatch(scan("s1", "lm358-dr")).Value.(domain.Scan)
	if !got.Found || got.MPN != "LM358DR" || got.ListName != "BOM" || got.DeviceName != "Pixel" {
		t.Fatalf("scan not resolved against the list: %+v", got)
	}
	// The device says found, but the list doesn't have it.
	if got := mustDispatch(scan("s2", "NE555")).Value.(domain.Scan); got.Found {
		t.Fatal("server must decide Found when it has the list")
	}
	if !mustDispatch(scan("s1", "lm358-dr")).Duplicate {
		t.Fatal("retried scan must be a duplicate")
	}
	store.Close()

	// Simulate a crash in the middle of a write.
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(`{"seq":6,"kind":"scan.rec`)
	f.Close()

	log, err = storage.OpenFile(path)
	if err != nil {
		t.Fatal(err)
	}
	store, err = state.Open(ctx, log)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	store.View(func(s *state.State) {
		if s.Seq != 5 || len(s.Scans["p1"]) != 2 || s.ByCode["AAAA-BBBB"] != "p1" {
			t.Fatalf("replayed: seq=%d scans=%d", s.Seq, len(s.Scans["p1"]))
		}
		if l := s.Projects["p1"].Lists["l1"]; l == nil || l.Version != 3 {
			t.Fatalf("list version must be the import's seq: %+v", l)
		}
		if tally := s.PartTally["l1"]["LM358DR"]; tally == nil || tally.Scans != 1 {
			t.Fatalf("part tally: %+v", tally)
		}
		if !s.Seen("s1") || !s.Seen("imp1") {
			t.Fatal("seen ids must survive a restart")
		}
	})
	// The torn line was cut off, so new events append cleanly.
	if _, err := store.Dispatch(ctx, scan("s3", "LM358DR")); err != nil {
		t.Fatal(err)
	}
}
