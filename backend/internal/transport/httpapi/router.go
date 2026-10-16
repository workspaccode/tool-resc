// Package httpapi is the HTTP/JSON transport over the use cases.
package httpapi

import (
	"net/http"

	"toolsresc/backend/internal/usecase"
)

// Services are the use cases the API exposes.
type Services struct {
	Devices  *usecase.Devices
	Projects *usecase.Projects
	Lists    *usecase.Lists
	Scans    *usecase.Scans
	Stats    *usecase.Stats
}

type Options struct {
	// APIKey protects /v1 as a whole (optional, e.g. for a public server).
	APIKey string
	// MaxBodyBytes limits request bodies (imports can be large).
	MaxBodyBytes int64
	// AllowOrigin enables CORS for one origin ("*" for any); empty: off.
	AllowOrigin string
}

// NewRouter builds the API. Every /v1 request carries the device id in
// X-Device-Id; there are no accounts. A device sees only the projects it
// created or joined with the code.
//
//	GET    /healthz
//	PUT    /v1/device                                    register / rename this device
//	GET    /v1/projects                                  my projects
//	POST   /v1/projects                                  create  {name} -> code
//	POST   /v1/projects/join                             join    {code}
//	GET    /v1/projects/{pid}                            detail: members, lists, last scans  ?recent=
//	POST   /v1/projects/{pid}/leave
//	GET    /v1/projects/{pid}/lists
//	GET    /v1/projects/{pid}/lists/{lid}                whole list (to download)
//	POST   /v1/projects/{pid}/lists/{lid}/imports        Excel sheet (replace/merge)
//	PATCH  /v1/projects/{pid}/lists/{lid}                rename  {name, eventId}
//	DELETE /v1/projects/{pid}/lists/{lid}                ?eventId=
//	GET    /v1/projects/{pid}/lists/{lid}/parts          ?q= &scanned= &sort= &limit=
//	GET    /v1/projects/{pid}/scans                      history, newest first  + filters
//	GET    /v1/projects/{pid}/stats                      ?by= + filters
//	POST   /v1/scans                                     {scans: [...]}
func NewRouter(svc Services, opt Options) http.Handler {
	h := &handlers{svc: svc}
	if opt.MaxBodyBytes <= 0 {
		opt.MaxBodyBytes = 64 << 20
	}
	v1mw := []Middleware{APIKey(opt.APIKey), RequireDevice}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", h.health)
	v1 := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, Chain(fn, v1mw...)) }

	v1("PUT /v1/device", h.registerDevice)
	v1("GET /v1/projects", h.myProjects)
	v1("POST /v1/projects", h.createProject)
	v1("POST /v1/projects/join", h.joinProject)
	v1("GET /v1/projects/{pid}", h.getProject)
	v1("POST /v1/projects/{pid}/leave", h.leaveProject)
	v1("GET /v1/projects/{pid}/lists", h.lists)
	v1("GET /v1/projects/{pid}/lists/{lid}", h.listTable)
	v1("POST /v1/projects/{pid}/lists/{lid}/imports", h.importList)
	v1("PATCH /v1/projects/{pid}/lists/{lid}", h.renameList)
	v1("DELETE /v1/projects/{pid}/lists/{lid}", h.deleteList)
	v1("GET /v1/projects/{pid}/lists/{lid}/parts", h.parts)
	v1("GET /v1/projects/{pid}/scans", h.history)
	v1("GET /v1/projects/{pid}/stats", h.stats)
	v1("POST /v1/scans", h.recordScans)

	return Chain(mux, Recover, Log, CORS(opt.AllowOrigin), MaxBody(opt.MaxBodyBytes))
}
