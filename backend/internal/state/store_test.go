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
	mustDispatch(state.ProjectImported{
		EventID: "imp1", ProjectID: "l1", Name: "BOM", At: at,
		Data: domain.ImportData{Mode: domain.ImportReplace, Headers: []string{"MPN"}, Rows: [][]string{{"LM358DR"}}},
	})
	scan := func(id, mpn string) state.ScanRecorded {
		s := domain.Scan{ID: id, ProjectID: "l1", MPN: mpn, Found: true, ScannedAt: at.Add(time.Minute)}
		s.Normalize()
		return state.ScanRecorded{Scan: s}
	}
	if got := mustDispatch(scan("s1", "lm358-dr")).Value.(domain.Scan); !got.Found || got.MPN != "LM358DR" {
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
	f.WriteString(`{"seq":4,"kind":"scan.rec`)
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
		if s.Seq != 3 || len(s.Scans) != 2 || s.Projects["l1"].Name != "BOM" {
			t.Fatalf("replayed: seq=%d scans=%d", s.Seq, len(s.Scans))
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
