// Package httpapi is the HTTP/JSON transport over the use cases.
package httpapi

import (
	"net/http"

	"toolsresc/backend/internal/usecase"
)

// Services are the use cases the API exposes.
type Services struct {
	Projects *usecase.Projects
	Scans    *usecase.Scans
	Stats    *usecase.Stats
}

type Options struct {
	// APIKey protects /v1; empty means open.
	APIKey string
	// MaxBodyBytes limits request bodies (imports can be large).
	MaxBodyBytes int64
	// AllowOrigin enables CORS for one origin ("*" for any); empty: off.
	AllowOrigin string
}

// NewRouter builds the API:
//
//	GET  /healthz
//	GET  /v1/summary
//	GET  /v1/projects
//	GET  /v1/projects/{id}
//	GET  /v1/projects/{id}/parts   ?q= &scanned=true|false &sort=scans|mpn &limit=
//	POST /v1/projects/{id}/imports
//	POST /v1/scans
//	GET  /v1/scans                 ?project= &device= &part= &source= &found= &from= &to= &limit=
//	GET  /v1/stats/scans           ?by=part|supplier_part|project|device|source|order|day|result + filters &tz= &limit=
func NewRouter(svc Services, opt Options) http.Handler {
	h := &handlers{svc: svc}
	if opt.MaxBodyBytes <= 0 {
		opt.MaxBodyBytes = 64 << 20
	}
	auth := APIKey(opt.APIKey)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", h.health)

	v1 := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, auth(fn)) }
	v1("GET /v1/summary", h.summary)
	v1("GET /v1/projects", h.listProjects)
	v1("GET /v1/projects/{id}", h.getProject)
	v1("GET /v1/projects/{id}/parts", h.listParts)
	v1("POST /v1/projects/{id}/imports", h.importProject)
	v1("POST /v1/scans", h.recordScans)
	v1("GET /v1/scans", h.listScans)
	v1("GET /v1/stats/scans", h.countScans)

	return Chain(mux, Recover, Log, CORS(opt.AllowOrigin), MaxBody(opt.MaxBodyBytes))
}
