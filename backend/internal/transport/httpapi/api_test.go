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

const (
	phone   = "android-0123456789abcdef"
	desktop = "windows-fedcba9876543210"
	other   = "ios-aaaaaaaaaaaaaaaaaaaa"
)

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	store, err := state.Open(context.Background(), storage.NewMemory())
	if err != nil {
		t.Fatal(err)
	}
	now := func() time.Time { return time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC) }
	srv := httptest.NewServer(httpapi.NewRouter(httpapi.Services{
		Devices:  usecase.NewDevices(store, now),
		Projects: usecase.NewProjects(store, now),
		Lists:    usecase.NewLists(store, now),
		Scans:    usecase.NewScans(store, now),
		Stats:    usecase.NewStats(store),
	}, httpapi.Options{}))
	t.Cleanup(srv.Close)
	return srv
}

// call sends a request as a device and decodes the JSON answer into out.
func call(t *testing.T, srv *httptest.Server, device, method, path string, body, out any) int {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, srv.URL+path, &buf)
	if device != "" {
		req.Header.Set("X-Device-Id", device)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if out != nil && res.StatusCode < 300 {
		if err := json.NewDecoder(res.Body).Decode(out); err != nil {
			t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
	return res.StatusCode
}

func TestProjectsByCodeListsAndHistory(t *testing.T) {
	srv := newServer(t)
	call(t, srv, phone, "PUT", "/v1/device", map[string]string{"name": "Ahmed's phone", "platform": "android", "model": "Pixel 8"}, nil)
	call(t, srv, desktop, "PUT", "/v1/device", map[string]string{"name": "Store PC", "platform": "windows"}, nil)

	// The phone creates a project and gets a code.
	var proj usecase.ProjectSummary
	if code := call(t, srv, phone, "POST", "/v1/projects", map[string]string{"name": "Site A"}, &proj); code != http.StatusCreated || len(proj.Code) != 9 {
		t.Fatalf("create: %d %+v", code, proj)
	}
	base := "/v1/projects/" + proj.ID

	// Another device can't see it without the code.
	if code := call(t, srv, desktop, "GET", base, nil, nil); code != http.StatusNotFound {
		t.Fatalf("non-member: %d", code)
	}
	if code := call(t, srv, desktop, "POST", "/v1/projects/join", map[string]string{"code": "WRONG-CODE"}, nil); code != http.StatusNotFound {
		t.Fatalf("wrong code: %d", code)
	}

	// The phone adds a list (an Excel sheet).
	imp := map[string]any{
		"eventId": "e1", "name": "BOM 1", "mode": "replace", "mpnIndex": 0,
		"headers": []string{"MPN", "Bin"},
		"rows":    [][]string{{"LM358DR", "A1"}, {"NE555", "A2"}, {"RC0805FR-07820KL", "B1"}},
	}
	var impOut usecase.ImportOutput
	if code := call(t, srv, phone, "POST", base+"/lists/L1/imports", imp, &impOut); code != http.StatusCreated || impOut.List.Parts != 3 || impOut.List.Version == 0 {
		t.Fatalf("import: %d %+v", code, impOut)
	}

	// The desktop joins with the code (any case/spacing) and downloads the list.
	var joined usecase.ProjectSummary
	lower := []byte(proj.Code)
	for i := range lower {
		if lower[i] >= 'A' && lower[i] <= 'Z' {
			lower[i] += 'a' - 'A'
		}
	}
	if code := call(t, srv, desktop, "POST", "/v1/projects/join", map[string]string{"code": string(lower)}, &joined); code != http.StatusOK || joined.ID != proj.ID || joined.Members != 2 {
		t.Fatalf("join: %d %+v", code, joined)
	}
	var table struct {
		List     usecase.ListSummary `json:"list"`
		Headers  []string            `json:"headers"`
		Rows     [][]string          `json:"rows"`
		MPNIndex int                 `json:"mpnIndex"`
	}
	call(t, srv, desktop, "GET", base+"/lists/L1", nil, &table)
	if len(table.Rows) != 3 || table.Headers[table.MPNIndex] != "MPN" || table.List.Name != "BOM 1" {
		t.Fatalf("table: %+v", table)
	}

	// Both devices scan.
	scans := func(id, mpn, qty, at string) map[string]any {
		return map[string]any{"scans": []map[string]any{{
			"id": id, "projectId": proj.ID, "listId": "L1", "source": "camera",
			"mpn": mpn, "quantity": qty, "scannedAt": at,
		}}}
	}
	var rec usecase.RecordOutput
	call(t, srv, phone, "POST", "/v1/scans", scans("s1", "lm358dr", "100", "2026-10-16T08:00:00Z"), &rec)
	call(t, srv, desktop, "POST", "/v1/scans", scans("s2", "LM358DR", "50", "2026-10-16T09:00:00Z"), &rec)
	call(t, srv, phone, "POST", "/v1/scans", scans("s3", "UNKNOWN-1", "", "2026-10-16T10:00:00Z"), &rec)
	if rec.Accepted != 1 {
		t.Fatalf("scan: %+v", rec)
	}
	// A device outside the project can't add scans to it.
	call(t, srv, other, "POST", "/v1/scans", scans("s4", "NE555", "", "2026-10-16T10:00:00Z"), &rec)
	if rec.Rejected != 1 || rec.Accepted != 0 {
		t.Fatalf("outsider scan: %+v", rec)
	}

	// Opening the project shows members, lists and the last scans, newest first.
	var detail usecase.ProjectDetail
	call(t, srv, desktop, "GET", base+"?recent=2", nil, &detail)
	if len(detail.MemberList) != 2 || len(detail.ListInfo) != 1 || detail.ListInfo[0].Scans != 3 {
		t.Fatalf("detail: %+v", detail)
	}
	if len(detail.Recent) != 2 || detail.Recent[0].ID != "s3" || detail.Recent[1].DeviceName != "Store PC" {
		t.Fatalf("recent: %+v", detail.Recent)
	}

	// My scans only.
	var hist struct {
		Total int `json:"total"`
	}
	call(t, srv, phone, "GET", base+"/scans?device=me", nil, &hist)
	if hist.Total != 2 {
		t.Fatalf("my history: %+v", hist)
	}

	var byPart usecase.CountOutput
	call(t, srv, phone, "GET", base+"/stats?by=part&list=L1", nil, &byPart)
	if byPart.Scans != 3 || byPart.Groups[0].Key != "LM358DR" || byPart.Groups[0].Scans != 2 || byPart.Groups[0].Quantity != 150 {
		t.Fatalf("by part: %+v", byPart)
	}
	var byDevice usecase.CountOutput
	call(t, srv, phone, "GET", base+"/stats?by=device", nil, &byDevice)
	if len(byDevice.Groups) != 2 || byDevice.Groups[0].Label != "Ahmed's phone" {
		t.Fatalf("by device: %+v", byDevice)
	}

	var parts struct {
		Total int `json:"total"`
	}
	call(t, srv, phone, "GET", base+"/lists/L1/parts?scanned=false", nil, &parts)
	if parts.Total != 2 {
		t.Fatalf("never scanned parts: %+v", parts)
	}

	// Rename and delete reach every member.
	call(t, srv, desktop, "PATCH", base+"/lists/L1", map[string]string{"eventId": "r1", "name": "BOM One"}, nil)
	var lists struct {
		Lists []usecase.ListSummary `json:"lists"`
	}
	call(t, srv, phone, "GET", base+"/lists", nil, &lists)
	if len(lists.Lists) != 1 || lists.Lists[0].Name != "BOM One" || lists.Lists[0].Version != impOut.List.Version {
		t.Fatalf("rename must not change the data version: %+v", lists)
	}
	call(t, srv, phone, "DELETE", base+"/lists/L1?eventId=d1", nil, nil)
	call(t, srv, desktop, "GET", base+"/lists", nil, &lists)
	if len(lists.Lists) != 0 {
		t.Fatalf("deleted: %+v", lists)
	}

	// Leaving hides the project again.
	if code := call(t, srv, desktop, "POST", base+"/leave", nil, nil); code != http.StatusNoContent {
		t.Fatalf("leave: %d", code)
	}
	if code := call(t, srv, desktop, "GET", base, nil, nil); code != http.StatusNotFound {
		t.Fatalf("after leave: %d", code)
	}
}

func TestDeviceIDAndCodeAttempts(t *testing.T) {
	srv := newServer(t)
	if code := call(t, srv, "", "GET", "/v1/projects", nil, nil); code != http.StatusBadRequest {
		t.Fatalf("missing device id: %d", code)
	}
	if code := call(t, srv, "short", "GET", "/v1/projects", nil, nil); code != http.StatusBadRequest {
		t.Fatalf("short device id: %d", code)
	}
	for i := 0; i < 10; i++ {
		call(t, srv, phone, "POST", "/v1/projects/join", map[string]string{"code": "AAAA-BBBB"}, nil)
	}
	if code := call(t, srv, phone, "POST", "/v1/projects/join", map[string]string{"code": "AAAA-BBBB"}, nil); code != http.StatusTooManyRequests {
		t.Fatalf("guessing codes must be limited: %d", code)
	}
	if code := call(t, srv, phone, "POST", "/v1/projects/p/lists/l/imports", map[string]any{"mode": "nope", "headers": []string{"MPN"}}, nil); code != http.StatusBadRequest {
		t.Fatalf("bad mode: %d", code)
	}
	if code := call(t, srv, phone, "GET", "/v1/projects/nope/stats?by=color", nil, nil); code != http.StatusBadRequest {
		t.Fatalf("bad dimension: %d", code)
	}
	res, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("healthz: %d", res.StatusCode)
	}
}
