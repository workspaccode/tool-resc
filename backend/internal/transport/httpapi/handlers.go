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

func (h *handlers) summary(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.svc.Stats.Summary(r.Context()))
}

func (h *handlers) listProjects(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"projects": h.svc.Projects.List(r.Context())})
}

func (h *handlers) getProject(w http.ResponseWriter, r *http.Request) {
	p, err := h.svc.Projects.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (h *handlers) listParts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	scanned, err := optBool(q, "scanned")
	if err != nil {
		writeError(w, r, err)
		return
	}
	parts, total, err := h.svc.Projects.Parts(r.Context(), r.PathValue("id"), usecase.PartsQuery{
		Search:  q.Get("q"),
		Scanned: scanned,
		Sort:    q.Get("sort"),
		Limit:   atoi(q.Get("limit")),
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

type importRequest struct {
	EventID  string     `json:"eventId"`
	Name     string     `json:"name"`
	DeviceID string     `json:"deviceId"`
	Mode     string     `json:"mode"`
	Headers  []string   `json:"headers"`
	Rows     [][]string `json:"rows"`
	MPNIndex int        `json:"mpnIndex"`
}

func (h *handlers) importProject(w http.ResponseWriter, r *http.Request) {
	var req importRequest
	if err := decode(r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	out, err := h.svc.Projects.Import(r.Context(), usecase.ImportInput{
		EventID:   req.EventID,
		ProjectID: r.PathValue("id"),
		Name:      req.Name,
		DeviceID:  req.DeviceID,
		Data: domain.ImportData{
			Mode:     domain.ImportMode(strings.ToLower(req.Mode)),
			Headers:  req.Headers,
			Rows:     req.Rows,
			MPNIndex: req.MPNIndex,
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

// scanRequest is a scan as the app sends it; quantity comes from the label
// text, so it may be a string or a number.
type scanRequest struct {
	ID           string    `json:"id"`
	ProjectID    string    `json:"projectId"`
	ProjectName  string    `json:"projectName"`
	DeviceID     string    `json:"deviceId"`
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

func (s scanRequest) toDomain() domain.Scan {
	return domain.Scan{
		ID: s.ID, ProjectID: s.ProjectID, ProjectName: s.ProjectName,
		DeviceID: s.DeviceID, DeviceName: s.DeviceName, Source: domain.ScanSource(s.Source),
		Raw: s.Raw, MPN: s.MPN, SupplierPart: s.SupplierPart, OrderNumber: s.OrderNumber,
		Quantity: int(s.Quantity), Found: s.Found, ScannedAt: s.ScannedAt,
	}
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
		scans[i] = s.toDomain()
	}
	out, err := h.svc.Scans.Record(r.Context(), scans)
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (h *handlers) listScans(w http.ResponseWriter, r *http.Request) {
	f, _, err := parseFilter(r.URL.Query())
	if err != nil {
		writeError(w, r, err)
		return
	}
	scans, total := h.svc.Scans.Recent(r.Context(), f, atoi(r.URL.Query().Get("limit")))
	if scans == nil {
		scans = []domain.Scan{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "scans": scans})
}

func (h *handlers) countScans(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	by := domain.ByPart
	if v := q.Get("by"); v != "" {
		var err error
		if by, err = domain.ParseDimension(v); err != nil {
			writeError(w, r, err)
			return
		}
	}
	f, loc, err := parseFilter(q)
	if err != nil {
		writeError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, h.svc.Stats.Count(r.Context(), usecase.CountQuery{
		By: by, Filter: f, Location: loc, Limit: atoi(q.Get("limit")),
	}))
}

// parseFilter reads project, device, part, source, found, from, to and tz.
// from/to take RFC 3339 or a date (YYYY-MM-DD, in tz); a date "to" is
// inclusive.
func parseFilter(q url.Values) (domain.ScanFilter, *time.Location, error) {
	loc := time.UTC
	if tz := q.Get("tz"); tz != "" {
		l, err := time.LoadLocation(tz)
		if err != nil {
			return domain.ScanFilter{}, nil, domain.Invalid("unknown tz %q", tz)
		}
		loc = l
	}
	f := domain.ScanFilter{
		ProjectID: q.Get("project"),
		DeviceID:  q.Get("device"),
		PartKey:   domain.MPNKey(q.Get("part")),
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
	s := strings.Trim(strings.TrimSpace(string(b)), `"`)
	if s == "" || s == "null" {
		*n = 0
		return nil
	}
	if v, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
		*n = flexInt(v)
		return nil
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		*n = flexInt(f)
		return nil
	}
	*n = 0
	return nil
}
