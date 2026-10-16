package httpapi_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"toolsresc/backend/internal/state"
	"toolsresc/backend/internal/storage"
	"toolsresc/backend/internal/transport/httpapi"
	"toolsresc/backend/internal/usecase"
)

func newServer(t *testing.T, apiKey string) *httptest.Server {
	t.Helper()
	store, err := state.Open(context.Background(), storage.NewMemory())
	if err != nil {
		t.Fatal(err)
	}
	now := func() time.Time { return time.Date(2026, 6, 1, 12, 0, 0, 0, time.UTC) }
	srv := httptest.NewServer(httpapi.NewRouter(httpapi.Services{
		Projects: usecase.NewProjects(store, now),
		Scans:    usecase.NewScans(store, now),
		Stats:    usecase.NewStats(store),
	}, httpapi.Options{APIKey: apiKey}))
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, method, path string, body any, out any) int {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, srv.URL+path, &buf)
	req.Header.Set("X-API-Key", "secret")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if out != nil {
		if err := json.NewDecoder(res.Body).Decode(out); err != nil {
			t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
	return res.StatusCode
}

func TestImportScanAndCount(t *testing.T) {
	srv := newServer(t, "secret")

	imp := map[string]any{
		"eventId": "e1", "name": "Order 42", "mode": "replace", "mpnIndex": 0,
		"headers": []string{"MPN", "Bin"},
		"rows":    [][]string{{"LM358DR", "A1"}, {"NE555", "A2"}, {"RC0805FR-07820KL", "B1"}},
	}
	var impOut usecase.ImportOutput
	if code := call(t, srv, "POST", "/v1/projects/l1/imports", imp, &impOut); code != http.StatusCreated {
		t.Fatalf("import: %d", code)
	}
	if impOut.Result.Inserted != 3 || impOut.Project.Parts != 3 {
		t.Fatalf("import result: %+v", impOut)
	}
	if code := call(t, srv, "POST", "/v1/projects/l1/imports", imp, &impOut); code != http.StatusOK || !impOut.Duplicate {
		t.Fatalf("retried import: %d %+v", code, impOut)
	}

	scans := map[string]any{"scans": []map[string]any{
		{"id": "s1", "projectId": "l1", "projectName": "Order 42", "deviceId": "d1", "source": "camera",
			"mpn": "lm358dr", "supplierPart": "C7950", "quantity": "100", "scannedAt": "2026-06-01T08:00:00Z"},
		{"id": "s2", "projectId": "l1", "deviceId": "d2", "source": "scanner",
			"mpn": "LM358DR", "quantity": 50, "scannedAt": "2026-06-01T09:00:00Z"},
		{"id": "s3", "projectId": "l1", "deviceId": "d1", "mpn": "UNKNOWN-1", "scannedAt": "2026-06-01T10:00:00Z"},
	}}
	var rec usecase.RecordOutput
	if code := call(t, srv, "POST", "/v1/scans", scans, &rec); code != http.StatusOK || rec.Accepted != 3 {
		t.Fatalf("scans: %d %+v", code, rec)
	}
	if call(t, srv, "POST", "/v1/scans", scans, &rec); rec.Duplicates != 3 {
		t.Fatalf("retried scans: %+v", rec)
	}

	var byPart usecase.CountOutput
	call(t, srv, "GET", "/v1/stats/scans?by=part&project=l1", nil, &byPart)
	if byPart.Scans != 3 || byPart.Groups[0].Key != "LM358DR" || byPart.Groups[0].Scans != 2 || byPart.Groups[0].Quantity != 150 {
		t.Fatalf("by part: %+v", byPart)
	}

	var byResult usecase.CountOutput
	call(t, srv, "GET", "/v1/stats/scans?by=result", nil, &byResult)
	if len(byResult.Groups) != 2 || byResult.Groups[0].Key != "found" || byResult.Groups[0].Scans != 2 {
		t.Fatalf("by result: %+v", byResult)
	}

	var parts struct {
		Total int                 `json:"total"`
		Parts []usecase.PartCount `json:"parts"`
	}
	call(t, srv, "GET", "/v1/projects/l1/parts?scanned=false", nil, &parts)
	if parts.Total != 2 {
		t.Fatalf("never scanned parts: %+v", parts)
	}

	var projects struct {
		Projects []usecase.ProjectSummary `json:"projects"`
	}
	call(t, srv, "GET", "/v1/projects", nil, &projects)
	if p := projects.Projects[0]; p.Name != "Order 42" || p.Scans != 3 || p.Found != 2 || p.NotFound != 1 {
		t.Fatalf("project summary: %+v", p)
	}

	var summary usecase.Summary
	call(t, srv, "GET", "/v1/summary", nil, &summary)
	if summary.Devices != 2 || summary.Scans != 3 {
		t.Fatalf("summary: %+v", summary)
	}
}

func TestValidationAndAuth(t *testing.T) {
	srv := newServer(t, "secret")

	if code := call(t, srv, "POST", "/v1/projects/l1/imports", map[string]any{"mode": "nope", "headers": []string{"MPN"}}, nil); code != http.StatusBadRequest {
		t.Fatalf("bad mode: %d", code)
	}
	if code := call(t, srv, "GET", "/v1/projects/missing", nil, nil); code != http.StatusNotFound {
		t.Fatalf("missing project: %d", code)
	}
	if code := call(t, srv, "GET", "/v1/stats/scans?by=color", nil, nil); code != http.StatusBadRequest {
		t.Fatalf("bad dimension: %d", code)
	}

	res, err := http.Get(srv.URL + "/v1/summary")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no key: %d", res.StatusCode)
	}
	res, err = http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("healthz must stay open: %d", res.StatusCode)
	}
}
