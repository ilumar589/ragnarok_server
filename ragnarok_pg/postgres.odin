package ragnarok_pg

import "core:c"
import "core:log"
import "core:strconv"
import "core:strings"

// ────────────────────────────────────────────────────
// Connection lifecycle
// ────────────────────────────────────────────────────

// Open a synchronous connection to PostgreSQL.
//
//   db, err := pg.db_connect("host=localhost dbname=test user=postgres")
//   defer pg.db_close(&db)
//
// The conninfo string follows the standard libpq format:
//   https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING
db_connect :: proc(conninfo: string, allocator := context.allocator) -> (DB, PG_Error) {
	cs := strings.clone_to_cstring(conninfo, allocator)
	defer delete(cs, allocator)

	conn := PQconnectdb(cs)
	if conn == nil {
		return {}, pg_error_static("PQconnectdb returned nil")
	}

	if PQstatus(conn) != .CONNECTION_OK {
		err := pg_error_from_cstr(PQerrorMessage(conn), allocator)
		PQfinish(conn)
		return {}, err
	}

	log.debugf("PG connected: %s", conninfo)
	return DB{conn = conn, connected = true}, {}
}

// Close a connection.  Safe to call on a zero-value or already-closed DB.
db_close :: proc(db: ^DB) {
	if db.conn != nil {
		PQfinish(db.conn)
		db.conn = nil
		db.connected = false
		log.debug("PG connection closed")
	}
}

// Check whether the connection is open and usable.
db_is_connected :: proc(db: ^DB) -> bool {
	return db.conn != nil && db.connected && PQstatus(db.conn) == .CONNECTION_OK
}

// Attempt to reset (reconnect) a dead connection in-place.
db_reset :: proc(db: ^DB) -> bool {
	if db.conn == nil { return false }
	PQreset(db.conn)
	ok := PQstatus(db.conn) == .CONNECTION_OK
	db.connected = ok
	if ok {
		log.debug("PG connection reset successfully")
	} else {
		log.warn("PG connection reset failed")
	}
	return ok
}

// ────────────────────────────────────────────────────
// Simple query (no parameters)
// ────────────────────────────────────────────────────

// Execute a SQL command that does not return rows (CREATE, INSERT without
// RETURNING, etc.).  For queries that return rows, use db_query.
db_exec :: proc(db: ^DB, sql: string, allocator := context.allocator) -> (Query_Result, PG_Error) {
	if !db_is_connected(db) {
		return {}, pg_error_static("not connected")
	}

	cs := strings.clone_to_cstring(sql, allocator)
	defer delete(cs, allocator)

	res := PQexec(db.conn, cs)
	if res == nil {
		return {}, pg_error_from_cstr(PQerrorMessage(db.conn), allocator)
	}

	status := PQresultStatus(res)
	#partial switch status {
	case .PGRES_COMMAND_OK, .PGRES_TUPLES_OK, .PGRES_SINGLE_TUPLE:
		return _wrap_result(res), {}
	case:
		err := pg_error_from_result(res, allocator)
		PQclear(res)
		return {}, err
	}
}

// ────────────────────────────────────────────────────
// Parameterised query
// ────────────────────────────────────────────────────

// Execute a parameterised SQL query.  Parameters are bound positionally
// as $1, $2, … in the SQL string.
//
//   result, err := pg.db_query(&db, "SELECT * FROM users WHERE id = $1", 42)
//   defer pg.result_destroy(&result)
//
// Supported Odin types: int, i32, i64, u32, u64, f32, f64, bool, string, nil.
// All temporary cstring conversions use `allocator` and are freed before return.
db_query :: proc(
	db: ^DB,
	sql: string,
	params: ..any,
	allocator := context.allocator,
) -> (Query_Result, PG_Error) {
	if !db_is_connected(db) {
		return {}, pg_error_static("not connected")
	}

	sql_cs := strings.clone_to_cstring(sql, allocator)
	defer delete(sql_cs, allocator)

	n := len(params)
	if n == 0 {
		// No params — use simple exec path
		res := PQexec(db.conn, sql_cs)
		if res == nil {
			return {}, pg_error_from_cstr(PQerrorMessage(db.conn), allocator)
		}
		status := PQresultStatus(res)
		#partial switch status {
		case .PGRES_COMMAND_OK, .PGRES_TUPLES_OK, .PGRES_SINGLE_TUPLE:
			return _wrap_result(res), {}
		case:
			err := pg_error_from_result(res, allocator)
			PQclear(res)
			return {}, err
		}
	}

	// Build param arrays
	param_values, param_ok := params_to_cstrings(params, allocator)
	if !param_ok {
		return {}, pg_error_static("failed to convert parameters")
	}
	defer params_free(param_values, allocator)

	res := PQexecParams(
		db.conn,
		sql_cs,
		c.int(n),
		nil,                                // let server infer types
		raw_data(param_values),             // [^]cstring
		nil,                                // lengths (text format ignores)
		nil,                                // formats (all text)
		FORMAT_TEXT,                         // result format
	)
	if res == nil {
		return {}, pg_error_from_cstr(PQerrorMessage(db.conn), allocator)
	}

	status := PQresultStatus(res)
	#partial switch status {
	case .PGRES_COMMAND_OK, .PGRES_TUPLES_OK, .PGRES_SINGLE_TUPLE:
		return _wrap_result(res), {}
	case:
		err := pg_error_from_result(res, allocator)
		PQclear(res)
		return {}, err
	}
}

// ────────────────────────────────────────────────────
// Prepared statements
// ────────────────────────────────────────────────────

// Create a named prepared statement.
//
//   err := pg.db_prepare(&db, "get_user", "SELECT * FROM users WHERE id = $1")
//
db_prepare :: proc(
	db: ^DB,
	name: string,
	sql: string,
	param_types: []Oid = nil,
	allocator := context.allocator,
) -> PG_Error {
	if !db_is_connected(db) {
		return pg_error_static("not connected")
	}

	name_cs := strings.clone_to_cstring(name, allocator)
	defer delete(name_cs, allocator)
	sql_cs := strings.clone_to_cstring(sql, allocator)
	defer delete(sql_cs, allocator)

	n_params := c.int(len(param_types)) if param_types != nil else 0
	types_ptr: [^]Oid = raw_data(param_types) if param_types != nil else nil

	res := PQprepare(db.conn, name_cs, sql_cs, n_params, types_ptr)
	if res == nil {
		return pg_error_from_cstr(PQerrorMessage(db.conn), allocator)
	}
	defer PQclear(res)

	if PQresultStatus(res) != .PGRES_COMMAND_OK {
		return pg_error_from_result(res, allocator)
	}
	return {}
}

// Execute a previously prepared statement.
//
//   result, err := pg.db_exec_prepared(&db, "get_user", 42)
//   defer pg.result_destroy(&result)
//
db_exec_prepared :: proc(
	db: ^DB,
	name: string,
	params: ..any,
	allocator := context.allocator,
) -> (Query_Result, PG_Error) {
	if !db_is_connected(db) {
		return {}, pg_error_static("not connected")
	}

	name_cs := strings.clone_to_cstring(name, allocator)
	defer delete(name_cs, allocator)

	n := len(params)
	param_values: []cstring
	param_ok: bool

	if n > 0 {
		param_values, param_ok = params_to_cstrings(params, allocator)
		if !param_ok {
			return {}, pg_error_static("failed to convert parameters")
		}
	}
	defer if n > 0 { params_free(param_values, allocator) }

	res := PQexecPrepared(
		db.conn,
		name_cs,
		c.int(n),
		raw_data(param_values) if n > 0 else nil,
		nil,           // lengths
		nil,           // formats
		FORMAT_TEXT,   // result format
	)
	if res == nil {
		return {}, pg_error_from_cstr(PQerrorMessage(db.conn), allocator)
	}

	status := PQresultStatus(res)
	#partial switch status {
	case .PGRES_COMMAND_OK, .PGRES_TUPLES_OK, .PGRES_SINGLE_TUPLE:
		return _wrap_result(res), {}
	case:
		err := pg_error_from_result(res, allocator)
		PQclear(res)
		return {}, err
	}
}

// ────────────────────────────────────────────────────
// Result inspection
// ────────────────────────────────────────────────────

// Number of rows in the result.
result_row_count :: proc(r: ^Query_Result) -> int {
	return r.rows
}

// Number of columns in the result.
result_col_count :: proc(r: ^Query_Result) -> int {
	return r.cols
}

// Get column name by 0-based index.
// Returns a view into libpq's internal memory (valid until result_destroy).
result_col_name :: proc(r: ^Query_Result, col: int) -> string {
	if r.handle == nil || col < 0 || col >= r.cols { return "" }
	cs := PQfname(r.handle, c.int(col))
	if cs == nil { return "" }
	return string(cs)
}

// Get column type OID by 0-based index.
result_col_type :: proc(r: ^Query_Result, col: int) -> Oid {
	if r.handle == nil || col < 0 || col >= r.cols { return 0 }
	return PQftype(r.handle, c.int(col))
}

// Get a field value as a string.
// Returns a view into libpq's internal memory (valid until result_destroy).
// The bool indicates whether the field is non-NULL.
result_get_string :: proc(r: ^Query_Result, row, col: int) -> (string, bool) {
	if r.handle == nil { return "", false }
	if row < 0 || row >= r.rows || col < 0 || col >= r.cols { return "", false }
	if PQgetisnull(r.handle, c.int(row), c.int(col)) == 1 { return "", false }
	cs := PQgetvalue(r.handle, c.int(row), c.int(col))
	if cs == nil { return "", false }
	return string(cs), true
}

// Get a field value as an int.
result_get_int :: proc(r: ^Query_Result, row, col: int) -> (int, bool) {
	s, ok := result_get_string(r, row, col)
	if !ok { return 0, false }
	val, parse_ok := strconv.parse_int(s)
	return val, parse_ok
}

// Get a field value as an f64.
result_get_f64 :: proc(r: ^Query_Result, row, col: int) -> (f64, bool) {
	s, ok := result_get_string(r, row, col)
	if !ok { return 0, false }
	val, parse_ok := strconv.parse_f64(s)
	return val, parse_ok
}

// Get a field value as a bool.
result_get_bool :: proc(r: ^Query_Result, row, col: int) -> (bool, bool) {
	s, ok := result_get_string(r, row, col)
	if !ok { return false, false }
	switch s {
	case "t", "true", "1", "yes", "on":
		return true, true
	case "f", "false", "0", "no", "off":
		return false, true
	}
	return false, false
}

// Check if a field is NULL.
result_is_null :: proc(r: ^Query_Result, row, col: int) -> bool {
	if r.handle == nil { return true }
	if row < 0 || row >= r.rows || col < 0 || col >= r.cols { return true }
	return PQgetisnull(r.handle, c.int(row), c.int(col)) == 1
}

// Number of rows affected by INSERT/UPDATE/DELETE.
result_affected :: proc(r: ^Query_Result) -> int {
	if r.handle == nil { return 0 }
	cs := PQcmdTuples(r.handle)
	if cs == nil { return 0 }
	s := string(cs)
	if len(s) == 0 { return 0 }
	val, ok := strconv.parse_int(s)
	if !ok { return 0 }
	return val
}

// Free the underlying PGresult.  Safe to call multiple times.
result_destroy :: proc(r: ^Query_Result) {
	if r.handle != nil {
		PQclear(r.handle)
		r.handle = nil
		r.rows = 0
		r.cols = 0
	}
}

// ────────────────────────────────────────────────────
// Row iterator
// ────────────────────────────────────────────────────

// Create an iterator over query result rows.
result_iter :: proc(r: ^Query_Result) -> Row_Iterator {
	return Row_Iterator{result = r, current = 0}
}

// Advance the iterator.  Returns the current row index and true,
// or (0, false) when exhausted.
iter_next :: proc(it: ^Row_Iterator) -> (row: int, ok: bool) {
	if it.current >= it.result.rows {
		return 0, false
	}
	row = it.current
	it.current += 1
	return row, true
}

// ────────────────────────────────────────────────────
// Escaping helpers
// ────────────────────────────────────────────────────

// Escape a string literal for safe inclusion in SQL.
// The returned string is allocated from `allocator` — caller owns it.
escape_literal :: proc(db: ^DB, s: string, allocator := context.allocator) -> (string, bool) {
	if db.conn == nil { return "", false }
	cs := strings.clone_to_cstring(s, allocator)
	defer delete(cs, allocator)
	escaped := PQescapeLiteral(db.conn, cs, c.size_t(len(s)))
	if escaped == nil { return "", false }
	defer PQfreemem(rawptr(escaped))
	return strings.clone(string(escaped), allocator), true
}

// Escape an identifier (table/column name) for safe inclusion in SQL.
// The returned string is allocated from `allocator` — caller owns it.
escape_identifier :: proc(db: ^DB, s: string, allocator := context.allocator) -> (string, bool) {
	if db.conn == nil { return "", false }
	cs := strings.clone_to_cstring(s, allocator)
	defer delete(cs, allocator)
	escaped := PQescapeIdentifier(db.conn, cs, c.size_t(len(s)))
	if escaped == nil { return "", false }
	defer PQfreemem(rawptr(escaped))
	return strings.clone(string(escaped), allocator), true
}

// ────────────────────────────────────────────────────
// Internal helpers
// ────────────────────────────────────────────────────

// Wrap a raw PGresult into a Query_Result, caching row/col counts.
@(private = "file")
_wrap_result :: proc(res: PGresult) -> Query_Result {
	return Query_Result{
		handle = res,
		rows   = int(PQntuples(res)),
		cols   = int(PQnfields(res)),
	}
}
