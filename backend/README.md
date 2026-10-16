# ToolsResc Server (Go)

Optional sync backend for the ToolsResc app. **No accounts.** Each phone or computer is recognized automatically by an id the app makes from its hardware id (Android ID, Windows MachineGuid, macOS hardware UUID, iOS identifierForVendor, Linux machine-id — hashed, never sent raw) and sends in `X-Device-Id`.

- **Projects** are shared by **code** (`K7F2-QX9M`). Any device creates a project and gets the code; other devices enter it to join.
- A project holds **lists**; each list is an imported **Excel** sheet. Lists sync both ways: every member device gets new, changed, renamed and removed lists.
- Every **scan** in a project's list is recorded. Opening a project shows its devices, lists and **last scans** (all devices, or only this one) — what was taken, when, and by which device.
- Scans are counted by **part (MPN)**, **supplier part id** (e.g. LCSC `C141700`), **list**, **device**, **source**, **order number**, **day**, and **found / not found**.

Lists outside a project, and everything when sync is off (the default), never leave the device.

## Run

```sh
cd backend
go run ./cmd/server                       # http://localhost:8080, data in data/events.jsonl
TOOLSRESC_API_KEY=secret go run ./cmd/server
go test ./...
go build -o toolsresc-server ./cmd/server
```

In the app: Settings › Server Sync › on, Server `192.168.1.20:8080` (and the API key if you set one), then Projects › New Project, or Join with Code.

| Variable | Default | |
|---|---|---|
| `TOOLSRESC_ADDR` | `:8080` | Listen address |
| `TOOLSRESC_DATA` | `data/events.jsonl` | Event log file; `memory` = nothing saved |
| `TOOLSRESC_API_KEY` | none | Optional server-wide key, as `Authorization: Bearer <key>` or `X-API-Key` |
| `TOOLSRESC_MAX_BODY_MB` | `64` | Largest request (big imports) |
| `TOOLSRESC_CORS_ORIGIN` | off | Allow a browser dashboard on this origin (`*` for any) |

Over the internet, put the server behind HTTPS (e.g. Caddy or nginx). Plain HTTP is meant for a local network only; the API key is sent in clear text over it.

## Architecture

Clean architecture; dependencies point inward only.

```
cmd/server            composition root: config -> storage -> state -> use cases -> HTTP
internal/
  domain/             entities and rules, no dependencies
                      Device, Project (code, members), List (Import replace/merge like the app, Table, Version)
                      Scan (normalize, validate, resolve against its list)
                      CountScans (strategy per Dimension) + ScanFilter
  state/              state management (event sourcing / reducer)
                      Event = a fact; Event.Apply = reducer; Store = single owner of State
                      Dispatch: dedupe by event id -> append to log -> apply   (write-ahead)
                      Open: replay the log to rebuild State and its projections (tallies)
  storage/            EventLog adapters: File (JSON Lines, fsync) and Memory (tests)
  usecase/            application services: Devices, Projects, Lists, Scans, Stats
                      (validate, check membership, dispatch, query)
  transport/httpapi/  handlers, DTOs, router, middleware chain (recover, log, CORS, body limit, API key, device id)
```

Patterns used: repository/port-adapter (`state.EventLog`), event sourcing + reducer (`state`), command (`Event`), strategy (`Dimension.groupKey`), decorator/middleware chain (`httpapi.Chain`), dependency injection via constructors, idempotency keys.

**Idempotent by design.** Every import and scan carries an id made on the device. The app keeps unsent items in a local queue and retries with backoff; if a request is repeated, the server answers `duplicate` and nothing is counted twice.

**Crash safety.** Each event is synced to disk before it is applied. A line cut short by a crash is dropped on the next start; any other damaged line stops startup, so data is never silently lost.

## API

Every `/v1` request needs `X-Device-Id` (16–128 of `A-Z a-z 0-9 - _`), plus the API key when one is set. A device only sees projects it created or joined; anything else answers 404. Times are RFC 3339 (UTC). Errors are `{"error": "…"}` with 400, 401, 404, 413, 429 or 500.

| | |
|---|---|
| `GET /healthz` | Always open |
| `PUT /v1/device` | Register / rename this device `{name, platform, model}` |
| `GET /v1/projects` | My projects |
| `POST /v1/projects` | Create `{name}` → `{id, code, …}` |
| `POST /v1/projects/join` | Join `{code}` (any case, spaces ok). 10 wrong codes per 10 min per device, then 429 |
| `GET /v1/projects/{pid}?recent=20` | Detail: `memberList`, `listInfo` (with scan counts), `recent` scans |
| `POST /v1/projects/{pid}/leave` | Leave |
| `GET /v1/projects/{pid}/lists` | Lists with `version` (changes when the data changes) |
| `GET /v1/projects/{pid}/lists/{lid}` | Whole list to download: `{list, headers, rows, mpnIndex}` |
| `POST /v1/projects/{pid}/lists/{lid}/imports` | `{eventId, name, mode: replace\|merge, headers, rows, mpnIndex}`; creates the list on first import |
| `PATCH /v1/projects/{pid}/lists/{lid}` | Rename `{eventId, name}` |
| `DELETE /v1/projects/{pid}/lists/{lid}?eventId=` | Remove from the project (its scans stay in history) |
| `GET /v1/projects/{pid}/lists/{lid}/parts?q=&scanned=true\|false&sort=scans\|mpn` | Parts with scan counts; `scanned=false` = never scanned |
| `GET /v1/projects/{pid}/scans?<filters>&limit=` | History, newest first |
| `GET /v1/projects/{pid}/stats?by=<dimension>&<filters>` | Counts |
| `POST /v1/scans` | `{scans: [{id, projectId, listId, listName, source, raw, mpn, supplierPart, orderNumber, quantity, found, scannedAt}]}`, up to 1000. Scans for projects the device isn't in are `rejected` |

**Filters:** `list`, `device` (`me` = the caller), `part` (any spelling of the MPN), `source`, `found=true|false`, `from`, `to` (RFC 3339 or `YYYY-MM-DD`; a date `to` includes that day), `tz` (e.g. `Asia/Riyadh`).

**Dimensions:** `part` (default), `supplier_part`, `list`, `device`, `source`, `order`, `day`, `result`.

Examples: what this device scanned today `GET /v1/projects/{pid}/scans?device=me&from=2026-10-16&tz=Asia/Riyadh`; most-scanned parts of a list `…/stats?by=part&list={lid}`; scans per device `…/stats?by=device`; scanned but not in the list `…/stats?by=part&found=false`.

### How the app syncs

1. On start (and every 2 minutes) it registers the device, then sends its queue in order: imports, renames, deletes, scans. Each has an id, so a retry is never counted twice.
2. When the queue is empty it reloads its projects and, per project, compares each list's `version` with the one it has; changed or new lists are downloaded, lists gone from the project are deleted on the device too.
3. An import's response carries the new version, so a device never re-downloads its own upload.
4. Offline, everything waits in the queue and is retried with backoff (15 s up to 10 min).

Security notes: the project code (≈40 bits, rate-limited) is what grants access, so share it only with your devices. Leaving a project keeps its lists on the device as local lists.
