package main

import "core:fmt"
import "core:log"
import "core:mem"

import http "ragnarok_http"

main :: proc() {
	// Set up console logger
	context.logger = log.create_console_logger(.Debug)

	config := http.default_server_config()

	server: http.Server
	if !http.server_init(&server, config) {
		log.error("Failed to initialize server")
		return
	}

	// Register application routes
	http.router_add_route(&server.router, .GET, "/", index_handler)
	http.router_add_route(&server.router, .POST, "/echo", echo_handler)

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