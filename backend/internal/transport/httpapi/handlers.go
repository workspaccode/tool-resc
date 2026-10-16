package httpapi

import (
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"toolsresc/backend/internal/domain"
	"toolsresc/backend/internal/usecase"
)

type handlers struct {
	svc Services
}

func (h *handlers) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// --- device ---

func (h *handlers) registerDevice(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name     string `json:"name"`
		Platform string `json:"platform"`
		Model    string `json:"model"`
	}
	if err := decode(r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	d, err := h.svc.Devices.Register(r.Context(), domain.Device{
		ID: deviceID(r), Name: req.Name, Platform: req.Platform, Model: req.Model,
	})
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

// --- projects ---

func (h *handlers) myProjects(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"projects": h.svc.Projects.Mine(r.Context(), deviceID(r))})
}

func (h *handlers) createProject(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := decode(r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	p, err := h.svc.Projects.Create(r.Context(), deviceID(r), req.Name)
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, p)
}

func (h *handlers) joinProject(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	if err := decode(r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	p, err := h.svc.Projects.Join(r.Context(), deviceID(r), req.Code)
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (h *handlers) getProject(w http.ResponseWriter, r *http.Request) {
	p, err := h.svc.Projects.Get(r.Context(), deviceID(r), r.PathValue("pid"), atoi(r.URL.Query().Get("recent")))
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (h *handlers) leaveProject(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Projects.Leave(r.Context(), deviceID(r), r.PathValue("pid")); err != nil {
		writeError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// --- lists ---

func (h *handlers) lists(w http.ResponseWriter, r *http.Request) {
	lists, err := h.svc.Lists.All(r.Context(), deviceID(r), r.PathValue("pid"))
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"lists": lists})
}

func (h *handlers) listTable(w http.ResponseWriter, r *http.Request) {
	sum, table, err := h.svc.Lists.Table(r.Context(), deviceID(r), r.PathValue("pid"), r.PathValue("lid"))
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"list": sum, "headers": table.Headers, "rows": table.Rows, "mpnIndex": table.MPNIndex,
	})
}

func (h *handlers) importList(w http.ResponseWriter, r *http.Request) {
	var req struct {
		EventID  string     `json:"eventId"`
		Name     string     `json:"name"`
		Mode     string     `json:"mode"`
		Headers  []string   `json:"headers"`
		Rows     [][]string `json:"rows"`
		MPNIndex int        `json:"mpnIndex"`
	}
	if err := decode(r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	out, err := h.svc.Lists.Import(r.Context(), usecase.ImportInput{
		EventID: req.EventID, DeviceID: deviceID(r),
		ProjectID: r.PathValue("pid"), ListID: r.PathValue("lid"), Name: req.Name,
		Data: domain.ImportData{
			Mode: domain.ImportMode(strings.ToLower(req.Mode)), Headers: req.Headers, Rows: req.Rows, MPNIndex: req.MPNIndex,
		},
	})
	if err != nil {
		writeError(w, r, err)
		return
	}
	status := http.StatusCreated
	if out.Duplicate {
		status = http.StatusOK
	}
	writeJSON(w, status, out)
}

func (h *handlers) renameList(w http.ResponseWriter, r *http.Request) {
	var req struct {
		EventID string `json:"eventId"`
		Name    string `json:"name"`
	}
	if err := decode(r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	if err := h.svc.Lists.Rename(r.Context(), deviceID(r), r.PathValue("pid"), r.PathValue("lid"), req.EventID, req.Name); err != nil {
		writeError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) deleteList(w http.ResponseWriter, r *http.Request) {
	err := h.svc.Lists.Delete(r.Context(), deviceID(r), r.PathValue("pid"), r.PathValue("lid"), r.URL.Query().Get("eventId"))
	if err != nil {
		writeError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handlers) parts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	scanned, err := optBool(q, "scanned")
	if err != nil {
		writeError(w, r, err)
		return
	}
	parts, total, err := h.svc.Lists.Parts(r.Context(), deviceID(r), r.PathValue("pid"), r.PathValue("lid"), usecase.PartsQuery{
		Search: q.Get("q"), Scanned: scanned, Sort: q.Get("sort"), Limit: atoi(q.Get("limit")),
	})
	if err != nil {
		writeError(w, r, err)
		return
	}
	if parts == nil {
		parts = []usecase.PartCount{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "parts": parts})
}

// --- scans ---

// scanRequest is a scan as the app sends it; quantity comes from the label
// text, so it may be a string or a number.
type scanRequest struct {
	ID           string    `json:"id"`
	ProjectID    string    `json:"projectId"`
	ListID       string    `json:"listId"`
	ListName     string    `json:"listName"`
	DeviceName   string    `json:"deviceName"`
	Source       string    `json:"source"`
	Raw          string    `json:"raw"`
	MPN          string    `json:"mpn"`
	SupplierPart string    `json:"supplierPart"`
	OrderNumber  string    `json:"orderNumber"`
	Quantity     flexInt   `json:"quantity"`
	Found        bool      `json:"found"`
	ScannedAt    time.Time `json:"scannedAt"`
}

func (h *handlers) recordScans(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Scans []scanRequest `json:"scans"`
	}
	if err := decode(r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	scans := make([]domain.Scan, len(req.Scans))
	for i, s := range req.Scans {
		scans[i] = domain.Scan{
			ID: s.ID, ProjectID: s.ProjectID, ListID: s.ListID, ListName: s.ListName, DeviceName: s.DeviceName,
			Source: domain.ScanSource(s.Source), Raw: s.Raw, MPN: s.MPN, SupplierPart: s.SupplierPart,
			OrderNumber: s.OrderNumber, Quantity: int(s.Quantity), Found: s.Found, ScannedAt: s.ScannedAt,
		}
	}
	out, err := h.svc.Scans.Record(r.Context(), deviceID(r), scans)
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (h *handlers) history(w http.ResponseWriter, r *http.Request) {
	f, _, err := parseFilter(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	scans, total, err := h.svc.Scans.History(r.Context(), deviceID(r), f, atoi(r.URL.Query().Get("limit")))
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "scans": scans})
}

func (h *handlers) stats(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	by := domain.ByPart
	if v := q.Get("by"); v != "" {
		var err error
		if by, err = domain.ParseDimension(v); err != nil {
			writeError(w, r, err)
			return
		}
	}
	f, loc, err := parseFilter(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	out, err := h.svc.Stats.Count(r.Context(), deviceID(r), usecase.CountQuery{
		By: by, Filter: f, Location: loc, Limit: atoi(q.Get("limit")),
	})
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// parseFilter reads the project from the path and list, device ("me" for
// the caller), part, source, found, from, to and tz from the query. from/to
// take RFC 3339 or a date (YYYY-MM-DD, in tz); a date "to" is inclusive.
func parseFilter(r *http.Request) (domain.ScanFilter, *time.Location, error) {
	q := r.URL.Query()
	loc := time.UTC
	if tz := q.Get("tz"); tz != "" {
		l, err := time.LoadLocation(tz)
		if err != nil {
			return domain.ScanFilter{}, nil, domain.Invalid("unknown tz %q", tz)
		}
		loc = l
	}
	f := domain.ScanFilter{
		ProjectID: r.PathValue("pid"),
		ListID:    q.Get("list"),
		DeviceID:  q.Get("device"),
		PartKey:   domain.MPNKey(q.Get("part")),
	}
	if f.DeviceID == "me" {
		f.DeviceID = deviceID(r)
	}
	if s := q.Get("source"); s != "" {
		f.Source = domain.ParseSource(s)
	}
	var err error
	if f.Found, err = optBool(q, "found"); err != nil {
		return f, nil, err
	}
	if f.From, err = parseTime(q.Get("from"), loc, false); err != nil {
		return f, nil, err
	}
	if f.To, err = parseTime(q.Get("to"), loc, true); err != nil {
		return f, nil, err
	}
	return f, loc, nil
}

func parseTime(s string, loc *time.Location, endOfDay bool) (time.Time, error) {
	if s == "" {
		return time.Time{}, nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, nil
	}
	d, err := time.ParseInLocation(time.DateOnly, s, loc)
	if err != nil {
		return time.Time{}, domain.Invalid("bad time %q: use RFC 3339 or YYYY-MM-DD", s)
	}
	if endOfDay {
		d = d.AddDate(0, 0, 1)
	}
	return d, nil
}

func optBool(q url.Values, key string) (*bool, error) {
	v := q.Get(key)
	if v == "" {
		return nil, nil
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return nil, domain.Invalid("%s must be true or false", key)
	}
	return &b, nil
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

// flexInt accepts 100, "100" or "" (and ignores anything unparsable).
type flexInt int

func (n *flexInt) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(strings.Trim(strings.TrimSpace(string(b)), `"`))
	*n = 0
	if v, err := strconv.Atoi(s); err == nil {
		*n = flexInt(v)
	} else if f, err := strconv.ParseFloat(s, 64); err == nil {
		*n = flexInt(f)
	}
	return nil
}
