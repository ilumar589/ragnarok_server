package ragnarok_pg

// ────────────────────────────────────────────────────
// libpq Foreign Bindings
// ────────────────────────────────────────────────────
//
// Minimal FFI surface over PostgreSQL's official C client library (libpq).
// Covers connection management, query execution, result inspection,
// parameterised queries, prepared statements, and escaping.
//
// Windows: place libpq.lib in ragnarok_pg/lib/ and ensure libpq.dll
//          (plus OpenSSL/intl DLLs) is on PATH or next to the executable.
// Linux:   install libpq-dev; the "system:pq" link handles the rest.
// ────────────────────────────────────────────────────

import "core:c"

// ────────────────────────────────────────────────────
// Platform-specific linking
// ────────────────────────────────────────────────────

when ODIN_OS == .Windows {
	@(extra_linker_flags = "/NODEFAULTLIB:msvcrt")
	foreign import libpq {
		"lib/libpq.lib",
		"system:Ws2_32.lib",
		"system:Secur32.lib",
		"system:Advapi32.lib",
		"system:Shell32.lib",
		"system:Crypt32.lib",
	}
} else {
	foreign import libpq {
		"system:pq",
	}
}

// ────────────────────────────────────────────────────
// Opaque handle types
// ────────────────────────────────────────────────────

PGconn   :: distinct rawptr   // libpq connection handle
PGresult :: distinct rawptr   // libpq result handle
PGcancel :: distinct rawptr   // libpq cancel handle

// ────────────────────────────────────────────────────
// Oid type
// ────────────────────────────────────────────────────

Oid :: c.uint   // PostgreSQL object identifier

// Common type OIDs (from pg_type_d.h)
BOOLOID        : Oid : 16
BYTEAOID       : Oid : 17
CHAROID        : Oid : 18
INT8OID        : Oid : 20
INT2OID        : Oid : 21
INT4OID        : Oid : 23
TEXTOID        : Oid : 25
OIDOID         : Oid : 26
FLOAT4OID      : Oid : 700
FLOAT8OID      : Oid : 701
VARCHAROID     : Oid : 1043
DATEOID        : Oid : 1082
TIMEOID        : Oid : 1083
TIMESTAMPOID   : Oid : 1114
TIMESTAMPTZOID : Oid : 1184
NUMERICOID     : Oid : 1700
JSONOID        : Oid : 114
JSONBOID       : Oid : 3802
UUIDOID        : Oid : 2950

// ────────────────────────────────────────────────────
// Connection status
// ────────────────────────────────────────────────────

ConnStatusType :: enum c.int {
	CONNECTION_OK                = 0,
	CONNECTION_BAD               = 1,
	CONNECTION_STARTED           = 2,
	CONNECTION_MADE              = 3,
	CONNECTION_AWAITING_RESPONSE = 4,
	CONNECTION_AUTH_OK           = 5,
	CONNECTION_SETENV            = 6,
	CONNECTION_SSL_STARTUP       = 7,
	CONNECTION_NEEDED            = 8,
	CONNECTION_CHECK_WRITABLE    = 9,
	CONNECTION_CONSUME           = 10,
	CONNECTION_GSS_STARTUP       = 11,
	CONNECTION_CHECK_TARGET      = 12,
	CONNECTION_CHECK_STANDBY     = 13,
}

// ────────────────────────────────────────────────────
// Execution status (result of a query)
// ────────────────────────────────────────────────────

ExecStatusType :: enum c.int {
	PGRES_EMPTY_QUERY    = 0,
	PGRES_COMMAND_OK     = 1,   // command that doesn't return rows
	PGRES_TUPLES_OK      = 2,   // query returned rows
	PGRES_COPY_OUT       = 3,
	PGRES_COPY_IN        = 4,
	PGRES_BAD_RESPONSE   = 5,
	PGRES_NONFATAL_ERROR = 6,
	PGRES_FATAL_ERROR    = 7,
	PGRES_COPY_BOTH      = 8,
	PGRES_SINGLE_TUPLE   = 9,
	PGRES_PIPELINE_SYNC  = 10,
	PGRES_PIPELINE_ABORTED = 11,
}

// ────────────────────────────────────────────────────
// Polling status (async connection)
// ────────────────────────────────────────────────────

PostgresPollingStatusType :: enum c.int {
	PGRES_POLLING_FAILED  = 0,
	PGRES_POLLING_READING = 1,
	PGRES_POLLING_WRITING = 2,
	PGRES_POLLING_OK      = 3,
	PGRES_POLLING_ACTIVE  = 4,  // unused, kept for compatibility
}

// ────────────────────────────────────────────────────
// Format codes for PQexecParams
// ────────────────────────────────────────────────────

FORMAT_TEXT   :: 0
FORMAT_BINARY :: 1

// ────────────────────────────────────────────────────
// Foreign function declarations
// ────────────────────────────────────────────────────

@(default_calling_convention = "c")
foreign libpq {

	// ── Connection management ──────────────────────

	// Open a new connection using a conninfo string.
	// Returns a PGconn even on failure — call PQstatus to check.
	PQconnectdb :: proc(conninfo: cstring) -> PGconn ---

	// Async connection start — returns immediately.
	PQconnectStart :: proc(conninfo: cstring) -> PGconn ---

	// Poll async connection for progress.
	PQconnectPoll :: proc(conn: PGconn) -> PostgresPollingStatusType ---

	// Close the connection and free the PGconn.
	PQfinish :: proc(conn: PGconn) ---

	// Reset (reconnect) an existing connection.
	PQreset :: proc(conn: PGconn) ---

	// Get connection status.
	PQstatus :: proc(conn: PGconn) -> ConnStatusType ---

	// Get last error message for this connection.
	PQerrorMessage :: proc(conn: PGconn) -> cstring ---

	// Get the underlying socket fd (for event loop integration).
	PQsocket :: proc(conn: PGconn) -> c.int ---

	// Set blocking/non-blocking mode (1 = nonblocking).
	PQsetnonblocking :: proc(conn: PGconn, arg: c.int) -> c.int ---

	// Check if connection is non-blocking.
	PQisnonblocking :: proc(conn: PGconn) -> c.int ---

	// ── Simple query ───────────────────────────────

	// Execute a simple SQL command (may contain multiple statements).
	PQexec :: proc(conn: PGconn, query: cstring) -> PGresult ---

	// ── Parameterised query ────────────────────────

	// Execute a parameterised SQL command.
	PQexecParams :: proc(
		conn:          PGconn,
		command:       cstring,
		nParams:       c.int,
		paramTypes:    [^]Oid,       // may be nil (server infers types)
		paramValues:   [^]cstring,
		paramLengths:  [^]c.int,     // ignored for text format
		paramFormats:  [^]c.int,     // 0 = text per param
		resultFormat:  c.int,        // 0 = text results
	) -> PGresult ---

	// ── Prepared statements ────────────────────────

	// Create a prepared statement.
	PQprepare :: proc(
		conn:       PGconn,
		stmtName:   cstring,
		query:      cstring,
		nParams:    c.int,
		paramTypes: [^]Oid,
	) -> PGresult ---

	// Execute a previously prepared statement.
	PQexecPrepared :: proc(
		conn:         PGconn,
		stmtName:     cstring,
		nParams:      c.int,
		paramValues:  [^]cstring,
		paramLengths: [^]c.int,
		paramFormats: [^]c.int,
		resultFormat: c.int,
	) -> PGresult ---

	// Describe a prepared statement (returns param types).
	PQdescribePrepared :: proc(conn: PGconn, stmtName: cstring) -> PGresult ---

	// ── Async query ────────────────────────────────

	// Send a query without waiting for the result.
	PQsendQuery :: proc(conn: PGconn, query: cstring) -> c.int ---

	// Send a parameterised query asynchronously.
	PQsendQueryParams :: proc(
		conn:          PGconn,
		command:       cstring,
		nParams:       c.int,
		paramTypes:    [^]Oid,
		paramValues:   [^]cstring,
		paramLengths:  [^]c.int,
		paramFormats:  [^]c.int,
		resultFormat:  c.int,
	) -> c.int ---

	// Get the next result from an async query.
	// Returns nil when no more results.
	PQgetResult :: proc(conn: PGconn) -> PGresult ---

	// Consume input from the server (for async operations).
	PQconsumeInput :: proc(conn: PGconn) -> c.int ---

	// Check if PQgetResult would block.
	PQisBusy :: proc(conn: PGconn) -> c.int ---

	// ── Result inspection ──────────────────────────

	// Get the status of a result.
	PQresultStatus :: proc(res: PGresult) -> ExecStatusType ---

	// Get the error message from a result.
	PQresultErrorMessage :: proc(res: PGresult) -> cstring ---

	// Number of rows in the result.
	PQntuples :: proc(res: PGresult) -> c.int ---

	// Number of columns in the result.
	PQnfields :: proc(res: PGresult) -> c.int ---

	// Get column name by index (0-based).
	PQfname :: proc(res: PGresult, field_num: c.int) -> cstring ---

	// Get column type OID by index (0-based).
	PQftype :: proc(res: PGresult, field_num: c.int) -> Oid ---

	// Get a field value as a C string (row, col are 0-based).
	PQgetvalue :: proc(res: PGresult, tup_num: c.int, field_num: c.int) -> cstring ---

	// Check if a field is NULL (returns 1 if NULL).
	PQgetisnull :: proc(res: PGresult, tup_num: c.int, field_num: c.int) -> c.int ---

	// Get field length in bytes.
	PQgetlength :: proc(res: PGresult, tup_num: c.int, field_num: c.int) -> c.int ---

	// Free a PGresult.
	PQclear :: proc(res: PGresult) ---

	// Get the number of rows affected by an INSERT/UPDATE/DELETE.
	// Returns a string like "5".
	PQcmdTuples :: proc(res: PGresult) -> cstring ---

	// ── Escaping ───────────────────────────────────

	// Escape a string literal for use in SQL. Returns malloc'd string.
	PQescapeLiteral :: proc(conn: PGconn, str: cstring, len: c.size_t) -> cstring ---

	// Escape an identifier (table/column name). Returns malloc'd string.
	PQescapeIdentifier :: proc(conn: PGconn, str: cstring, len: c.size_t) -> cstring ---

	// Free memory allocated by libpq (PQescapeLiteral, etc.).
	PQfreemem :: proc(ptr: rawptr) ---

	// ── Cancel ─────────────────────────────────────

	// Get a cancel object for the current query.
	PQgetCancel :: proc(conn: PGconn) -> PGcancel ---

	// Request cancellation of the current query.
	// errbuf/errbufsize receive an error message on failure.
	PQcancel :: proc(cancel: PGcancel, errbuf: [^]u8, errbufsize: c.int) -> c.int ---

	// Free a cancel object.
	PQfreeCancel :: proc(cancel: PGcancel) ---
}
