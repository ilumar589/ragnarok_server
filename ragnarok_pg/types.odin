package ragnarok_pg

import "core:mem"
import "core:strings"

// ────────────────────────────────────────────────────
// Error type
// ────────────────────────────────────────────────────
//
// All fallible procedures return (T, PG_Error).
// A zero-value PG_Error (empty message) means success.
// ────────────────────────────────────────────────────

PG_Error :: struct {
	message: string,           // human-readable error (owned copy or static)
	status:  ExecStatusType,   // PGRES_* code when the error came from a query result
	owned:   bool,             // true if `message` was heap-allocated and must be freed
}

// Returns true when there is no error.
pg_ok :: proc(err: PG_Error) -> bool {
	return len(err.message) == 0
}

// Construct an error from a static (compile-time) string — no allocation.
pg_error_static :: proc(msg: string) -> PG_Error {
	return PG_Error{message = msg}
}

// Construct an error from a libpq cstring, cloning it into `allocator`.
pg_error_from_cstr :: proc(cs: cstring, allocator: mem.Allocator) -> PG_Error {
	if cs == nil { return {} }
	s := string(cs)
	if len(s) == 0 { return {} }
	cloned := strings.clone(s, allocator)
	return PG_Error{message = cloned, owned = true}
}

// Construct an error from a PGresult, extracting its error message.
pg_error_from_result :: proc(res: PGresult, allocator: mem.Allocator) -> PG_Error {
	status := PQresultStatus(res)
	msg_cs := PQresultErrorMessage(res)
	err := pg_error_from_cstr(msg_cs, allocator)
	err.status = status
	return err
}

// Free an owned error message.  Safe to call on any PG_Error.
pg_error_destroy :: proc(err: ^PG_Error, allocator: mem.Allocator) {
	if err.owned && len(err.message) > 0 {
		delete(transmute([]u8)err.message, allocator)
		err.message = ""
		err.owned = false
	}
}

// ────────────────────────────────────────────────────
// Database handle
// ────────────────────────────────────────────────────
//
// Wraps a PGconn with a connected flag for quick checks.
// ────────────────────────────────────────────────────

DB :: struct {
	conn:      PGconn,
	connected: bool,
}

// ────────────────────────────────────────────────────
// Query result
// ────────────────────────────────────────────────────
//
// Thin wrapper over PGresult.  Field values are read lazily
// via result_get_* — libpq stores them internally so we never
// allocate a [][]string.  Call result_destroy when done.
// ────────────────────────────────────────────────────

Query_Result :: struct {
	handle: PGresult,   // raw libpq result; nil after destroy
	rows:   int,        // cached PQntuples
	cols:   int,        // cached PQnfields
}

// ────────────────────────────────────────────────────
// Row iterator
// ────────────────────────────────────────────────────
//
// Lightweight cursor for stepping through query results
// without allocating.
//
// Usage:
//   it := result_iter(&result)
//   for row in iter_next(&it) {
//       name := result_get_string(&result, row, 0)
//       ...
//   }
// ────────────────────────────────────────────────────

Row_Iterator :: struct {
	result:  ^Query_Result,
	current: int,
}
