package main

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:thread"

// ────────────────────────────────────────────────────
// Server configuration
// ────────────────────────────────────────────────────

Server_Config :: struct {
	host:               net.IP4_Address,
	port:               int,
	max_connections:     int,
	worker_count:        int,
	read_buffer_size:    int,
	request_arena_size:  int,
	max_headers:         int,
	max_header_size:     int,
	max_body_size:       int,
	max_requests_per_conn: int,
	idle_timeout_secs:   int,
}

default_server_config :: proc() -> Server_Config {
	return Server_Config{
		host               = nbio.IP4_Any,
		port               = 8080,
		max_connections     = 1024,
		worker_count        = 4,
		read_buffer_size    = 8192,
		request_arena_size  = 8192,
		max_headers         = 64,
		max_header_size     = 8192,
		max_body_size       = 1_048_576, // 1 MiB
		max_requests_per_conn = 100,
		idle_timeout_secs   = 30,
	}
}

// ────────────────────────────────────────────────────
// Server state
// ────────────────────────────────────────────────────

Server :: struct {
	config:  Server_Config,
	socket:  net.TCP_Socket,
	router:  Router,
	workers: thread.Pool,
	loop:    ^nbio.Event_Loop, // main thread event loop reference for worker→IO queuing
	running: bool,
}

// ────────────────────────────────────────────────────
// Server lifecycle
// ────────────────────────────────────────────────────

server_init :: proc(server: ^Server, config: Server_Config) -> bool {
	server.config = config
	router_init(&server.router)

	// Register default routes
	router_add_route(&server.router, .GET, "/health", health_handler)

	return true
}

server_start :: proc(server: ^Server) {
	// Acquire the thread-local event loop
	if err := nbio.acquire_thread_event_loop(); err != nil {
		log.errorf("Failed to acquire event loop: %v", err)
		return
	}
	defer nbio.release_thread_event_loop()

	// Store the event loop reference so worker threads can queue sends back
	server.loop = nbio.current_thread_event_loop()

	// Initialize thread pool for CPU-bound request processing
	thread.pool_init(&server.workers, context.allocator, server.config.worker_count)
	thread.pool_start(&server.workers)
	log.infof("Started %d worker threads", server.config.worker_count)

	// Bind and listen
	endpoint := net.Endpoint{
		address = server.config.host,
		port    = server.config.port,
	}
	socket, listen_err := nbio.listen_tcp(endpoint)
	if listen_err != nil {
		log.errorf("Failed to listen on port %d: %v", server.config.port, listen_err)
		return
	}
	server.socket = socket
	server.running = true

	log.infof("Ragnarok HTTP server listening on port %d", server.config.port)

	// Start accepting connections
	nbio.accept_poly(server.socket, server, on_accept)

	// Block on the event loop
	if err := nbio.run(); err != nil {
		log.errorf("Event loop error: %v", err)
	}

	server.running = false
	thread.pool_finish(&server.workers)
	thread.pool_destroy(&server.workers)
	log.info("Server shut down")
}

server_stop :: proc(server: ^Server) {
	if server.running {
		nbio.close(server.socket)
		server.running = false
	}
}
