package main

import "core:fmt"
import "core:log"
import "core:mem"

import http "ragnarok_http"
// import pg "ragnarok_pg"   // uncomment once libpq.lib is in ragnarok_pg/lib/

// ────────────────────────────────────────────────────
// Module-level PG pool (accessible from all handlers)
// ────────────────────────────────────────────────────
// pg_pool: pg.PG_Pool

main :: proc() {
	// Set up console logger
	context.logger = log.create_console_logger(.Debug)

	config := http.default_server_config()
	config.static_root = "static" // serve files from ./static/ directory

	server: http.Server
	if !http.server_init(&server, config) {
		log.error("Failed to initialize server")
		return
	}

	// ── PostgreSQL pool (uncomment when libpq is available) ──
	// pg_config := pg.default_pg_pool_config(
	// 	"host=localhost dbname=mydb user=postgres password=secret",
	// 	config.worker_count,
	// )
	// pg_err := pg.pg_pool_init(&pg_pool, pg_config)
	// if !pg.pg_ok(pg_err) {
	// 	log.errorf("Failed to init PG pool: %s", pg_err.message)
	// 	return
	// }
	// defer pg.pg_pool_destroy(&pg_pool)

	// Register application routes
	http.router_add_route(&server.router, .GET, "/", index_handler)
	http.router_add_route(&server.router, .POST, "/echo", echo_handler)

	// TechEmpower-style benchmark routes
	http.router_add_route(&server.router, .GET, "/plaintext", http.plaintext_handler)
	http.router_add_route(&server.router, .GET, "/json", http.json_handler)

	// Database routes (uncomment when PG pool is enabled)
	// http.router_add_route(&server.router, .GET, "/db", db_handler)

	fmt.printfln("Starting Ragnarok HTTP server on :%d", config.port)
	http.server_start(&server)
}

// ────────────────────────────────────────────────────
// Application handlers
// ────────────────────────────────────────────────────

index_handler :: proc(request: ^http.Http_Request, response: ^http.Http_Response, allocator: mem.Allocator) {
	response.status = .OK
	http.response_set_body_string(response, "Welcome to Ragnarok", "text/plain", allocator)
}

echo_handler :: proc(request: ^http.Http_Request, response: ^http.Http_Response, allocator: mem.Allocator) {
	response.status = .OK
	if request.body != nil && len(request.body) > 0 {
		http.response_set_body(response, request.body, "application/octet-stream", allocator)
	} else {
		http.response_set_body_string(response, "", "text/plain", allocator)
	}
}

// ────────────────────────────────────────────────────
// Database handler example (uncomment when PG pool is enabled)
// ────────────────────────────────────────────────────
//
// TechEmpower "db" test — single random row as JSON.
//
// db_handler :: proc(request: ^http.Http_Request, response: ^http.Http_Response, allocator: mem.Allocator) {
// 	db, err := pg.pg_pool_acquire(&pg_pool, allocator)
// 	if !pg.pg_ok(err) {
// 		response.status = .Internal_Server_Error
// 		http.response_set_body_string(response, "Database unavailable", "text/plain", allocator)
// 		return
// 	}
// 	defer pg.pg_pool_release(&pg_pool, db)
//
// 	result, qerr := pg.db_query(db, "SELECT id, randomNumber FROM World WHERE id = $1", rand.int_max(10000) + 1, allocator = allocator)
// 	if !pg.pg_ok(qerr) {
// 		response.status = .Internal_Server_Error
// 		http.response_set_body_string(response, "Query failed", "text/plain", allocator)
// 		return
// 	}
// 	defer pg.result_destroy(&result)
//
// 	if result.rows > 0 {
// 		id_str, _    := pg.result_get_string(&result, 0, 0)
// 		rand_str, _  := pg.result_get_string(&result, 0, 1)
// 		body := fmt.aprintf("{\"id\":%s,\"randomNumber\":%s}", id_str, rand_str, allocator = allocator)
// 		http.response_set_body_string(response, body, "application/json; charset=UTF-8", allocator)
// 		response.status = .OK
// 	} else {
// 		response.status = .Not_Found
// 		http.response_set_body_string(response, "Not found", "text/plain", allocator)
// 	}
// }