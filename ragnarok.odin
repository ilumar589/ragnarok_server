package main

import "core:fmt"
import "core:log"
import "core:mem"

main :: proc() {
	// Set up console logger
	context.logger = log.create_console_logger(.Debug)

	config := default_server_config()

	server: Server
	if !server_init(&server, config) {
		log.error("Failed to initialize server")
		return
	}

	// Register application routes
	router_add_route(&server.router, .GET, "/", index_handler)
	router_add_route(&server.router, .POST, "/echo", echo_handler)

	fmt.printfln("Starting Ragnarok HTTP server on :%d", config.port)
	server_start(&server)
}

// ────────────────────────────────────────────────────
// Application handlers
// ────────────────────────────────────────────────────

index_handler :: proc(request: ^Http_Request, response: ^Http_Response, allocator: mem.Allocator) {
	response.status = .OK
	response_set_body_string(response, "Welcome to Ragnarok", "text/plain", allocator)
}

echo_handler :: proc(request: ^Http_Request, response: ^Http_Response, allocator: mem.Allocator) {
	response.status = .OK
	if request.body != nil && len(request.body) > 0 {
		response_set_body(response, request.body, "application/octet-stream", allocator)
	} else {
		response_set_body_string(response, "", "text/plain", allocator)
	}
}