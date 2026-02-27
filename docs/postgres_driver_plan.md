# Ragnarok PostgreSQL Driver — Implementation Plan

## Overview

Add a `ragnarok_pg` package that provides PostgreSQL support via FFI bindings to `libpq` (the official PostgreSQL C client library). The driver follows the same architectural patterns as the rest of Ragnarok: pre-allocated pools, arena-friendly memory, zero unnecessary heap allocations, and clear I/O thread vs worker thread boundaries.

---

## Package Structure

```
ragnarok_pg/
  ├── libpq.odin              ← Raw foreign bindings to libpq C API
  ├── types.odin               ← Odin-friendly type definitions (DB, Result, Row, etc.)
  ├── postgres.odin            ← High-level wrapper (connect, query, exec, close)
  ├── pool.odin                ← Connection pool (bounded, pre-allocated slots, LIFO free-stack)
  ├── params.odin              ← Parameterized query builder (safe escaping, type mapping)
  ├── error.odin               ← Error types and helpers
  └── pg_tests.odin            ← Memory leak tests using Tracking_Allocator (same pattern as ragnarok_http)
```

---

## Phase 1: libpq Foreign Bindings (`libpq.odin`)

**Goal:** Minimal, correct FFI surface over libpq.

### Tasks

1. **Set up `foreign import` block for libpq**
   - Windows: link `libpq.lib` + system libs (`Ws2_32.lib`, `Secur32.lib`, `Advapi32.lib`, `Shell32.lib`, `Crypt32.lib`)
   - Linux: link `system:pq`
   - Place `libpq.lib` and `libpq.dll` (Windows) in the `ragnarok_pg/lib/` directory, or accept a path via environment

2. **Define opaque handle types**
   ```
   PGconn     :: distinct rawptr
   PGresult   :: distinct rawptr
   PGcancel   :: distinct rawptr
   ```

3. **Define enums matching libpq constants**
   - `Conn_Status_Type` — `CONNECTION_OK`, `CONNECTION_BAD`, etc.
   - `Exec_Status_Type` — `PGRES_EMPTY_QUERY`, `PGRES_COMMAND_OK`, `PGRES_TUPLES_OK`, `PGRES_FATAL_ERROR`, etc.
   - `PG_Oid` — `u32` alias; define constants for common types (`BOOLOID`, `INT4OID`, `TEXTOID`, `FLOAT8OID`, `TIMESTAMPOID`, etc.)

4. **Bind the core libpq functions**

   | Category | Functions |
   |----------|-----------|
   | **Connection** | `PQconnectdb`, `PQconnectStart`, `PQconnectPoll`, `PQfinish`, `PQstatus`, `PQerrorMessage`, `PQreset` |
   | **Query** | `PQexec`, `PQexecParams`, `PQprepare`, `PQexecPrepared`, `PQdescribePrepared` |
   | **Result** | `PQresultStatus`, `PQresultErrorMessage`, `PQntuples`, `PQnfields`, `PQfname`, `PQftype`, `PQgetvalue`, `PQgetisnull`, `PQgetlength`, `PQclear`, `PQcmdTuples` |
   | **Escaping** | `PQescapeLiteral`, `PQescapeIdentifier`, `PQfreemem` |
   | **Cancel** | `PQgetCancel`, `PQcancel`, `PQfreeCancel` |
   | **Large Objects** | (defer to a later phase) |
   | **COPY** | (defer to a later phase) |
   | **Async** | `PQsendQuery`, `PQsendQueryParams`, `PQgetResult`, `PQconsumeInput`, `PQisBusy`, `PQsocket`, `PQsetnonblocking` |

### Acceptance Criteria
- Compiles on Windows and Linux
- Can call `PQconnectdb` / `PQfinish` from a test without crashing
- All bound functions match libpq 16.x headers exactly

---

## Phase 2: Odin-Friendly Types (`types.odin`, `error.odin`)

**Goal:** Provide safe, ergonomic Odin types that wrap the raw C handles.

### Types

```odin
PG_Error :: struct {
    message:  string,       // cloned from PQerrorMessage / PQresultErrorMessage
    status:   Exec_Status_Type,
}

DB :: struct {
    conn:     PGconn,
    connected: bool,
}

Query_Result :: struct {
    handle:   PGresult,     // raw handle, cleared on result_destroy
    rows:     int,
    cols:     int,
}

Row_Iterator :: struct {
    result:   ^Query_Result,
    current:  int,
}
```

### Error Handling Pattern
- Functions return `(T, PG_Error)` or `(T, bool)` — follows Odin's multi-return convention
- `PG_Error` with empty message = no error (check via `pg_ok(err)` helper)

---

## Phase 3: High-Level Wrapper (`postgres.odin`)

**Goal:** Provide a clean API for handlers to use.

### Core API Surface

```odin
// Connect / disconnect
db_connect      :: proc(conninfo: string, allocator: mem.Allocator) -> (DB, PG_Error)
db_close        :: proc(db: ^DB)
db_is_connected :: proc(db: ^DB) -> bool

// Simple query (no params, returns full result)
db_exec         :: proc(db: ^DB, sql: string) -> (Query_Result, PG_Error)

// Parameterized query (SQL injection safe)
db_query        :: proc(db: ^DB, sql: string, params: ..any) -> (Query_Result, PG_Error)

// Prepared statements
db_prepare      :: proc(db: ^DB, name: string, sql: string, param_types: []PG_Oid) -> PG_Error
db_exec_prepared :: proc(db: ^DB, name: string, params: ..any) -> (Query_Result, PG_Error)

// Result navigation
result_row_count   :: proc(r: ^Query_Result) -> int
result_col_count   :: proc(r: ^Query_Result) -> int
result_col_name    :: proc(r: ^Query_Result, col: int) -> string
result_get_string  :: proc(r: ^Query_Result, row, col: int) -> (string, bool)
result_get_int     :: proc(r: ^Query_Result, row, col: int) -> (int, bool)
result_get_f64     :: proc(r: ^Query_Result, row, col: int) -> (f64, bool)
result_get_bool    :: proc(r: ^Query_Result, row, col: int) -> (bool, bool)
result_is_null     :: proc(r: ^Query_Result, row, col: int) -> bool
result_destroy     :: proc(r: ^Query_Result)

// Iterator (avoids allocating a full [][]string)
result_iter        :: proc(r: ^Query_Result) -> Row_Iterator
iter_next          :: proc(it: ^Row_Iterator) -> (row: int, ok: bool)

// Affected rows for INSERT/UPDATE/DELETE
result_affected    :: proc(r: ^Query_Result) -> int
```

### Key Decisions
- **String conversion:** `cstring` ↔ `string` conversion uses the caller's allocator (or the request arena in handler context) so memory is automatically freed at end-of-request
- **Param binding:** `db_query` accepts `..any` and internally converts Odin types to C param arrays. Supports `int`, `f64`, `bool`, `string`, and `nil` (SQL NULL)
- **No hidden allocations:** `Query_Result` holds the raw `PGresult` handle. Column values are read lazily via `result_get_*` (libpq stores them internally). Call `result_destroy` when done.

---

## Phase 4: Connection Pool (`pool.odin`)

**Goal:** Bounded, pre-allocated pool of PostgreSQL connections for the worker thread pool to share.

### Design

```odin
PG_Pool_Config :: struct {
    conninfo:     string,
    min_conns:    int,      // pre-opened on init (e.g. worker_count)
    max_conns:    int,      // hard cap
    idle_timeout: time.Duration,
}

PG_Pool :: struct {
    conns:       []DB,
    free_stack:  []int,     // LIFO (mirrors ragnarok_http Connection_Pool pattern)
    free_count:  int,
    capacity:    int,
    config:      PG_Pool_Config,
    mu:          sync.Mutex, // needed: workers are multi-threaded (unlike HTTP pool)
}
```

### API

```odin
pg_pool_init    :: proc(pool: ^PG_Pool, config: PG_Pool_Config) -> PG_Error
pg_pool_destroy :: proc(pool: ^PG_Pool)
pg_pool_acquire :: proc(pool: ^PG_Pool) -> (^DB, PG_Error)   // blocks or returns error if full
pg_pool_release :: proc(pool: ^PG_Pool, db: ^DB)
pg_pool_stats   :: proc(pool: ^PG_Pool) -> (active, idle, total: int)
```

### Thread Safety
- The HTTP connection pool doesn't need locking (only the I/O thread touches it). The PG pool **does** need a mutex because multiple worker threads acquire/release connections concurrently.
- Use `sync.Mutex` from `core:sync` — lightweight, no heap allocation.

### Health Checks
- On `pg_pool_acquire`, check `PQstatus(conn) == .OK`. If the connection is dead, attempt `PQreset`. If reset fails, discard and open a new one (up to `max_conns`).

---

## Phase 5: Parameterized Queries (`params.odin`)

**Goal:** Safe, ergonomic parameter binding that prevents SQL injection.

### Approach
- Accept Odin `any` values and convert to `cstring` + `Oid` arrays for `PQexecParams`
- Support common types:

  | Odin Type | PG Oid | Format |
  |-----------|--------|--------|
  | `int`, `i32`, `i64` | `INT4OID` / `INT8OID` | text (`fmt.tprintf`) |
  | `f32`, `f64` | `FLOAT4OID` / `FLOAT8OID` | text |
  | `bool` | `BOOLOID` | `"t"` / `"f"` |
  | `string` | `TEXTOID` | as-is |
  | `nil` | 0 | NULL (nil pointer in paramValues) |
  | `time.Time` | `TIMESTAMPOID` | ISO 8601 format |
  | `[]u8` | `BYTEAOID` | binary format |

- Allocations for temp cstrings use the caller's allocator (request arena) — zero leaks

---

## Phase 6: Integration with Ragnarok HTTP

### Server-Level Pool

Add PG pool to `Server` or pass it as user context:

```odin
// In ragnarok.odin
pg_pool: pg.PG_Pool
pg.pg_pool_init(&pg_pool, pg.PG_Pool_Config{
    conninfo  = "host=localhost dbname=mydb user=postgres password=secret",
    min_conns = server.config.worker_count,
    max_conns = server.config.worker_count * 2,
})
defer pg.pg_pool_destroy(&pg_pool)
```

### Handler Pattern

```odin
db_handler :: proc(req: ^http.Http_Request, resp: ^http.Http_Response, alloc: mem.Allocator) {
    // acquire from pool (pointer passed via closure or server user_data)
    db, err := pg.pg_pool_acquire(&pg_pool)
    if !pg.pg_ok(err) {
        resp.status = .Internal_Server_Error
        return
    }
    defer pg.pg_pool_release(&pg_pool, db)

    result, qerr := pg.db_query(db, "SELECT id, name FROM users WHERE active = $1", true)
    if !pg.pg_ok(qerr) {
        resp.status = .Internal_Server_Error
        return
    }
    defer pg.result_destroy(&result)

    // Build JSON response using request arena allocator
    // ...
}
```

### TechEmpower DB Benchmark Route

Add `/db` route returning a single random row as JSON (TechEmpower "db" test):

```odin
http.router_add_route(&server.router, .GET, "/db", techempower_db_handler)
```

---

## Phase 7: Tests (`pg_tests.odin`)

Follow the exact same pattern as `ragnarok_http/memory_leak_tests.odin`:

| Test | What it verifies |
|------|------------------|
| `test_pg_connect_disconnect` | Connect + close leaks no memory |
| `test_pg_query_simple` | Simple SELECT, iterate results, destroy — zero leaks |
| `test_pg_query_params` | Parameterized query with various types — zero leaks |
| `test_pg_pool_init_destroy` | Pool lifecycle — zero leaks |
| `test_pg_pool_acquire_release` | Acquire/release cycles — zero leaks |
| `test_pg_pool_concurrent` | N goroutine-style workers hitting pool — no double-acquire, no leaks |
| `test_pg_prepared_stmt` | Prepare + execute + destroy — zero leaks |
| `test_pg_error_handling` | Bad conninfo, bad SQL — errors returned cleanly, no leaks |
| `test_pg_null_handling` | NULL values round-trip correctly |
| `test_pg_reconnect` | Simulate dead connection, verify pool auto-reconnects |

All tests use `mem.Tracking_Allocator` and assert empty `allocation_map` + empty `bad_free_array`.

---

## Phase 8: Documentation

- Update [docs/architecture.md](docs/architecture.md) with a new "Database Layer" section
- Add `ragnarok_pg/` to the project layout diagram
- Document the connection pool threading model (mutex-protected, unlike the HTTP pool)
- Add build instructions for obtaining/linking libpq

---

## Dependency: Obtaining libpq

### Windows
1. Install PostgreSQL (full or client-only) from https://www.postgresql.org/download/windows/
2. Copy from the PG install directory:
   - `lib/libpq.lib` → `ragnarok_pg/lib/libpq.lib`
   - `bin/libpq.dll` → project root (or add PG `bin/` to PATH)
   - Also need: `libssl-3-x64.dll`, `libcrypto-3-x64.dll`, `libintl-9.dll`, `libiconv-2.dll` (from PG `bin/`)
3. Alternative: use `vcpkg install libpq:x64-windows` for a standalone build

### Linux
```sh
# Debian/Ubuntu
sudo apt install libpq-dev

# Fedora/RHEL
sudo dnf install libpq-devel
```
The `system:pq` foreign import handles the rest.

---

## Implementation Order

| Step | Phase | Estimated Effort | Dependency |
|------|-------|-----------------|------------|
| 1 | Phase 1 — libpq bindings | 1–2 days | libpq installed |
| 2 | Phase 2 — Types & errors | 0.5 day | Phase 1 |
| 3 | Phase 3 — High-level wrapper | 1–2 days | Phase 2 |
| 4 | Phase 5 — Param builder | 0.5–1 day | Phase 3 |
| 5 | Phase 4 — Connection pool | 1 day | Phase 3 |
| 6 | Phase 7 — Tests | 1–2 days | Phases 3–5, running PG instance |
| 7 | Phase 6 — HTTP integration | 0.5–1 day | Phases 4–5 |
| 8 | Phase 8 — Docs | 0.5 day | All above |

**Total estimated effort: 6–10 days**

---

## Open Questions

1. **Async queries?** libpq supports non-blocking queries (`PQsendQuery` + `PQgetResult`). We could integrate these with `nbio` by registering the PG socket fd with the event loop. This would be ideal for maximum throughput but adds complexity. **Recommendation:** Start synchronous (Phase 3), add async as a follow-up.

2. **JSON serialization?** Handlers returning query results as JSON will need a serializer. Options:
   - Manual string building (fast, no deps)
   - A small `ragnarok_json` package
   - Use `core:encoding/json` (available in Odin's core library)

3. **Connection string vs structured config?** libpq accepts both `"host=... dbname=..."` and `PQconnectdbParams` with key/value arrays. **Recommendation:** Accept string for simplicity, add structured config helper later.

4. **TLS/SSL support?** libpq handles TLS internally if compiled with OpenSSL/Schannel support. No extra work needed on our side — just pass `sslmode=require` in the conninfo string.
