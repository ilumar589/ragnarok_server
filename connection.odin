package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"

// ────────────────────────────────────────────────────
// Connection state
// ────────────────────────────────────────────────────

RECV_BUF_SIZE :: 8192

Connection :: struct {
	socket:          net.TCP_Socket,
	remote_endpoint: net.Endpoint,
	recv_buf:        [RECV_BUF_SIZE]u8,
	recv_len:        int,
	keep_alive:      bool,
	request_count:   int,
	server:          ^Server,
	request_arena:   Request_Arena,
}

// ────────────────────────────────────────────────────
// Accept callback
// ────────────────────────────────────────────────────

on_accept :: proc(op: ^nbio.Operation, server: ^Server) {
	if op.accept.err != nil {
		log.errorf("Accept error: %v", op.accept.err)
		// Re-register accept to keep the server running
		nbio.accept_poly(op.accept.socket, server, on_accept)
		return
	}

	// Re-register accept for the next connection
	nbio.accept_poly(op.accept.socket, server, on_accept)

	// Create a new connection
	conn := new(Connection)
	if conn == nil {
		log.error("Failed to allocate connection")
		nbio.close(op.accept.client)
		return
	}
	conn.socket = op.accept.client
	conn.remote_endpoint = op.accept.client_endpoint
	conn.server = server
	conn.keep_alive = true // HTTP/1.1 default
	conn.recv_len = 0
	conn.request_count = 0

	log.debugf("Accepted connection from %v", conn.remote_endpoint)

	// Start receiving data
	connection_start_recv(conn)
}

// ────────────────────────────────────────────────────
// Receive flow
// ────────────────────────────────────────────────────

connection_start_recv :: proc(conn: ^Connection) {
	remaining := conn.recv_buf[conn.recv_len:]
	if len(remaining) == 0 {
		// Buffer full, can't read more
		log.warn("Receive buffer full, closing connection")
		connection_close(conn)
		return
	}
	bufs := [][]u8{remaining}
	nbio.recv_poly(conn.socket, bufs, conn, on_recv)
}

on_recv :: proc(op: ^nbio.Operation, conn: ^Connection) {
	if op.recv.err != nil {
		log.debugf("Recv error from %v: %v", conn.remote_endpoint, op.recv.err)
		connection_close(conn)
		return
	}

	// Connection closed by peer
	if op.recv.received == 0 {
		log.debugf("Connection closed by peer: %v", conn.remote_endpoint)
		connection_close(conn)
		return
	}

	conn.recv_len += op.recv.received

	// Try to parse the request
	data := conn.recv_buf[:conn.recv_len]

	// Look for end of headers (\r\n\r\n)
	header_end := find_header_end(data)
	if header_end < 0 {
		// Headers incomplete, keep reading
		connection_start_recv(conn)
		return
	}

	header_section := data[:header_end]
	body_start := header_end + 4 // skip \r\n\r\n

	// Initialize request arena
	if err := request_arena_init(&conn.request_arena, conn.server.config.request_arena_size, context.allocator); err != nil {
		log.error("Failed to allocate request arena")
		send_error_response(conn, .Internal_Server_Error)
		return
	}

	arena_alloc := request_arena_allocator(&conn.request_arena)

	// Parse the request
	request: Http_Request
	parse_ok := parse_request(&request, header_section, conn.server.config, arena_alloc)
	if !parse_ok {
		send_error_response(conn, .Bad_Request)
		return
	}

	// Check Content-Length for body
	body_available := conn.recv_len - body_start
	if request.content_length > 0 {
		if request.content_length > conn.server.config.max_body_size {
			send_error_response(conn, .Payload_Too_Large)
			return
		}

		if body_available < request.content_length {
			// Need more body data — continue receiving
			// For MVP, we only support bodies that fit in the recv buffer
			if body_start + request.content_length > RECV_BUF_SIZE {
				send_error_response(conn, .Payload_Too_Large)
				return
			}
			connection_start_recv(conn)
			return
		}

		request.body = data[body_start:body_start + request.content_length]
	}

	// Update connection state
	conn.keep_alive = request.keep_alive
	conn.request_count += 1

	// Check max requests per connection
	if conn.request_count >= conn.server.config.max_requests_per_conn {
		conn.keep_alive = false
	}

	// Route and handle
	response := Http_Response{}
	response.headers = make([dynamic]Header, 0, 16, arena_alloc)

	handler := router_match(&conn.server.router, request.method, request.path)
	if handler != nil {
		handler(&request, &response, arena_alloc)
	} else {
		// 404 Not Found
		not_found_handler(&request, &response, arena_alloc)
	}

	// Ensure Connection header reflects keep-alive state
	if !conn.keep_alive {
		response_set_header(&response, "Connection", "close", arena_alloc)
	} else {
		response_set_header(&response, "Connection", "keep-alive", arena_alloc)
	}

	// Serialize and send
	send_buf := response_serialize(&response, arena_alloc)
	if send_buf == nil {
		log.error("Failed to serialize response")
		connection_close(conn)
		return
	}

	bufs := [][]u8{send_buf}
	nbio.send_poly(conn.socket, bufs, conn, on_send, all = true)
}

// ────────────────────────────────────────────────────
// Send flow
// ────────────────────────────────────────────────────

on_send :: proc(op: ^nbio.Operation, conn: ^Connection) {
	// Free the request arena now that the response has been sent
	request_arena_destroy(&conn.request_arena, context.allocator)

	if op.send.err != nil {
		log.debugf("Send error to %v: %v", conn.remote_endpoint, op.send.err)
		connection_close(conn)
		return
	}

	if conn.keep_alive {
		// Reset receive buffer for next request
		conn.recv_len = 0
		connection_start_recv(conn)
	} else {
		connection_close(conn)
	}
}

// ────────────────────────────────────────────────────
// Error response helper
// ────────────────────────────────────────────────────

send_error_response :: proc(conn: ^Connection, status: Http_Status) {
	// Use a small stack-local arena for error responses
	scratch_buf: [2048]u8
	scratch_arena: mem.Arena
	mem.arena_init(&scratch_arena, scratch_buf[:])
	scratch := mem.arena_allocator(&scratch_arena)

	response := Http_Response{}
	response.headers = make([dynamic]Header, 0, 8, scratch)
	response.status = status
	response.body = transmute([]u8)status_reason(status)
	response_set_header(&response, "Content-Type", "text/plain", scratch)
	response_set_header(&response, "Connection", "close", scratch)

	send_buf := response_serialize(&response, scratch)
	if send_buf == nil {
		connection_close(conn)
		return
	}

	conn.keep_alive = false

	// Free any request arena that might have been initialized
	request_arena_destroy(&conn.request_arena, context.allocator)

	bufs := [][]u8{send_buf}
	nbio.send_poly(conn.socket, bufs, conn, on_send, all = true)
}

// ────────────────────────────────────────────────────
// Connection close / cleanup
// ────────────────────────────────────────────────────

connection_close :: proc(conn: ^Connection) {
	if conn == nil {
		return
	}
	log.debugf("Closing connection to %v (served %d requests)", conn.remote_endpoint, conn.request_count)
	request_arena_destroy(&conn.request_arena, context.allocator)
	nbio.close(conn.socket)
	free(conn)
}

// ────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────

// Searches for \r\n\r\n in data, returns index of first \r or -1 if not found.
find_header_end :: proc(data: []u8) -> int {
	if len(data) < 4 {
		return -1
	}
	for i in 0 ..< len(data) - 3 {
		if data[i] == '\r' && data[i + 1] == '\n' && data[i + 2] == '\r' && data[i + 3] == '\n' {
			return i
		}
	}
	return -1
}
