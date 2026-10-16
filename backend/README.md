# ToolsResc Server (Go)

Optional sync backend for the ToolsResc app. When **Settings › Server Sync** is on, the app sends:

- every **imported list** (Excel sheet) — so the server knows each list's parts, and
- every **scan** (camera, USB scanner, or a label code typed into search).

The server checks each scan against the list it was made in, and counts scans by **part (MPN)**, **supplier part id** (e.g. LCSC `C141700`), **project/list** (id and name), **device**, **source**, **order number**, **day**, and **found / not found**.

When sync is off (the default), the app works exactly as before and nothing leaves the device.

## Run

```sh
cd backend
go run ./cmd/server                       # http://localhost:8080, data in data/events.jsonl
TOOLSRESC_API_KEY=secret go run ./cmd/server
go test ./...
go build -o toolsresc-server ./cmd/server
```

In the app: Settings › Server Sync › on, Server `192.168.1.20:8080`, and the API key if you set one.

| Variable | Default | |
|---|---|---|
| `TOOLSRESC_ADDR` | `:8080` | Listen address |
| `TOOLSRESC_DATA` | `data/events.jsonl` | Event log file; `memory` = nothing saved |
| `TOOLSRESC_API_KEY` | none | Required as `Authorization: Bearer <key>` or `X-API-Key` |
| `TOOLSRESC_MAX_BODY_MB` | `64` | Largest request (big imports) |
| `TOOLSRESC_CORS_ORIGIN` | off | Allow a browser dashboard on this origin (`*` for any) |

Over the internet, put the server behind HTTPS (e.g. Caddy or nginx). Plain HTTP is meant for a local network only; the API key is sent in clear text over it.

## Architecture

Clean architecture; dependencies point inward only.

```
cmd/server            composition root: config -> storage -> state -> use cases -> HTTP
internal/
  domain/             entities and rules, no dependencies
                      Project (a list) + Import (replace/merge, same rules as the app)
                      Scan (normalize, validate, resolve against the list)
                      CountScans (strategy per Dimension) + ScanFilter
  state/              state management (event sourcing / reducer)
                      Event = a fact; Event.Apply = reducer; Store = single owner of State
                      Dispatch: dedupe by event id -> append to log -> apply   (write-ahead)
                      Open: replay the log to rebuild State and its projections (tallies)
  storage/            EventLog adapters: File (JSON Lines, fsync) and Memory (tests)
  usecase/            application services: Projects, Scans, Stats (validate, dispatch, query)
  transport/httpapi/  handlers, DTOs, router, middleware chain (recover, log, CORS, body limit, API key)
```

Patterns used: repository/port-adapter (`state.EventLog`), event sourcing + reducer (`state`), command (`Event`), strategy (`Dimension.groupKey`), decorator/middleware chain (`httpapi.Chain`), dependency injection via constructors, idempotency keys.

**Idempotent by design.** Every import and scan carries an id made on the device. The app keeps unsent items in a local queue and retries with backoff; if a request is repeated, the server answers `duplicate` and nothing is counted twice.

**Crash safety.** Each event is synced to disk before it is applied. A line cut short by a crash is dropped on the next start; any other damaged line stops startup, so data is never silently lost.

## API

All `/v1` routes need the API key when one is set. Times are RFC 3339 (UTC).

### `POST /v1/projects/{id}/imports`

```json
{ "eventId": "a1b2…", "name": "Order 42", "mode": "replace",
  "headers": ["MPN", "Bin"], "rows": [["LM358DR", "A1"]], "mpnIndex": 0 }
```

`mode`: `replace` or `merge`. Returns `{duplicate, result: {inserted, updated, removed, skipped}, project}`.

### `POST /v1/scans`

```json
{ "scans": [{ "id": "c3d4…", "projectId": "default", "projectName": "Main List",
  "deviceId": "…", "deviceName": "Pixel 8", "source": "camera",
  "raw": "{pbn:…,pc:C7950,pm:LM358DR,qty:100}", "mpn": "LM358DR",
  "supplierPart": "C7950", "orderNumber": "WM2609230751", "quantity": "100",
  "found": true, "scannedAt": "2026-10-16T08:00:00Z" }] }
```

Up to 1000 per request. `found` from the device is kept only when the server has no data for that list. Returns `{accepted, duplicates, scans}`.

### Counting

`GET /v1/stats/scans?by=<dimension>&<filters>&limit=`

- `by`: `part` (default), `supplier_part`, `project`, `device`, `source`, `order`, `day`, `result`
- filters: `project`, `device`, `part` (any spelling of the MPN), `source`, `found=true|false`, `from`, `to` (RFC 3339 or `YYYY-MM-DD`; a date `to` includes that day), `tz` (e.g. `Asia/Riyadh`, for `day` and dates)

```json
{ "by": "part", "scans": 3, "totalGroups": 2, "groups": [
  { "key": "LM358DR", "label": "LM358DR", "scans": 2, "found": 2, "notFound": 0,
    "quantity": 150, "firstAt": "…", "lastAt": "…" } ] }
```

Examples: most-scanned parts in a list `?by=part&project=default`; scans per device today `?by=device&from=2026-10-16&to=2026-10-16&tz=Asia/Riyadh`; parts scanned but not in the list `?by=part&found=false`.

### Other

| | |
|---|---|
| `GET /healthz` | Always open |
| `GET /v1/summary` | Totals: projects, parts, rows, scans, found, devices |
| `GET /v1/projects` | Every list with scan counts, most recent first |
| `GET /v1/projects/{id}` | One list |
| `GET /v1/projects/{id}/parts?q=&scanned=true\|false&sort=scans\|mpn&limit=` | Parts with how often each was scanned; `scanned=false` = never scanned |
| `GET /v1/scans?<filters>&limit=` | Newest scans first |

Errors are `{"error": "…"}` with 400 (invalid), 401 (API key), 404, 413 (too large) or 500.
