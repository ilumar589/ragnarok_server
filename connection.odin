package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

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
	recv_start:      time.Time, // when we started waiting for data (for access log timing)
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

	// Set TCP_NODELAY on the accepted socket to disable Nagle's algorithm
	net.set_option(op.accept.client, .TCP_Nodelay, true)

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
	conn.recv_start = time.now()
	bufs := [][]u8{remaining}
	// Apply idle timeout to recv so stalled connections get cleaned up
	recv_timeout := time.Duration(conn.server.config.idle_timeout_secs) * time.Second
	nbio.recv_poly(conn.socket, bufs, conn, on_recv, timeout = recv_timeout)
}

on_recv :: proc(op: ^nbio.Operation, conn: ^Connection) {
	// Check for timeout
	recv_err, is_tcp_err := op.recv.err.(net.TCP_Recv_Error)
	if is_tcp_err && recv_err == .Timeout {
		log.debugf("Recv timeout from %v", conn.remote_endpoint)
		send_error_response(conn, .Request_Timeout)
		return
	}

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

	// Check if body is complete before dispatching to worker
	header_section := data[:header_end]
	body_start := header_end + 4 // skip \r\n\r\n

	// Quick scan for Content-Length to check if we have the full body
	content_length := scan_content_length(header_section)
	if content_length > 0 {
		if content_length > conn.server.config.max_body_size {
			send_error_response(conn, .Payload_Too_Large)
			return
		}
		body_available := conn.recv_len - body_start
		if body_available < content_length {
			// Need more body data
			if body_start + content_length > RECV_BUF_SIZE {
				send_error_response(conn, .Payload_Too_Large)
				return
			}
			connection_start_recv(conn)
			return
		}
	}

	// Full request received — dispatch CPU work (parse/route/handle/serialize) to worker thread
	thread.pool_add_task(&conn.server.workers, context.allocator, process_request_task, conn)
}

// ────────────────────────────────────────────────────
// Worker thread task — CPU-bound request processing
// ────────────────────────────────────────────────────

// Runs on a worker thread. Parses the request, routes, runs the handler,
// serializes the response, then queues the send back to the main event loop.
process_request_task :: proc(task: thread.Task) {
	conn := (^Connection)(task.data)
	data := conn.recv_buf[:conn.recv_len]

	header_end := find_header_end(data)
	// header_end is guaranteed >= 0 since we checked before dispatching
	header_section := data[:header_end]
	body_start := header_end + 4

	// Initialize request arena (heap alloc on this worker thread)
	if err := request_arena_init(&conn.request_arena, conn.server.config.request_arena_size, context.allocator); err != nil {
		log.error("Failed to allocate request arena")
		// Queue error response send back to the I/O thread
		queue_error_response(conn, .Internal_Server_Error)
		return
	}

	arena_alloc := request_arena_allocator(&conn.request_arena)

	// Parse the request
	request: Http_Request
	parse_ok := parse_request(&request, header_section, conn.server.config, arena_alloc)
	if !parse_ok {
		queue_error_response(conn, .Bad_Request)
		return
	}

	// Attach body if present
	if request.content_length > 0 {
		request.body = data[body_start:body_start + request.content_length]
	}

	// Update connection state
	conn.keep_alive = request.keep_alive
	conn.request_count += 1

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
		not_found_handler(&request, &response, arena_alloc)
	}

	// Connection header
	if !conn.keep_alive {
		response_set_header(&response, "Connection", "close", arena_alloc)
	} else {
		response_set_header(&response, "Connection", "keep-alive", arena_alloc)
	}

	// Serialize response
	send_buf := response_serialize(&response, arena_alloc)
	if send_buf == nil {
		log.error("Failed to serialize response")
		request_arena_destroy(&conn.request_arena, context.allocator)
		// Queue close on I/O thread
		nbio.close(conn.socket, l = conn.server.loop)
		free(conn)
		return
	}

	// Access log: method, path, status, duration
	duration := time.since(conn.recv_start)
	duration_ms := time.duration_milliseconds(duration)
	log.infof("%v \"%s %s\" %d %.1fms",
		conn.remote_endpoint,
		method_to_string(request.method),
		request.path,
		int(response.status),
		duration_ms,
	)

	// Queue the send operation back to the main I/O event loop
	bufs := [][]u8{send_buf}
	send_timeout := time.Duration(conn.server.config.idle_timeout_secs) * time.Second
	nbio.send_poly(conn.socket, bufs, conn, on_send, all = true, timeout = send_timeout, l = conn.server.loop)
}

// Queue an error response send from a worker thread back to the I/O event loop.
queue_error_response :: proc(conn: ^Connection, status: Http_Status) {
	// Free any in-progress request arena
	request_arena_destroy(&conn.request_arena, context.allocator)

	// Allocate a small buffer for the error response that outlives this proc.
	// We use heap because the send is async on the I/O thread.
	error_body := status_reason(status)

	// Build a minimal error response
	error_resp_buf := make([]u8, 256)
	if error_resp_buf == nil {
		nbio.close(conn.socket, l = conn.server.loop)
		free(conn)
		return
	}

	// Store the error response buffer on the connection's request_arena backing
	// so it gets freed in on_send → connection_close
	conn.request_arena.backing = error_resp_buf

	n := format_error_response(error_resp_buf, status, error_body)
	conn.keep_alive = false

	bufs := [][]u8{error_resp_buf[:n]}
	nbio.send_poly(conn.socket, bufs, conn, on_send, all = true, l = conn.server.loop)
}

// Format a minimal HTTP error response into a buffer. Returns bytes written.
format_error_response :: proc(buf: []u8, status: Http_Status, body: string) -> int {
	// Build: "HTTP/1.1 STATUS REASON\r\nContent-Length: N\r\nContent-Type: text/plain\r\nConnection: close\r\nServer: Ragnarok\r\n\r\nbody"
	i := 0
	i += copy_to(buf[i:], "HTTP/1.1 ")
	i += write_int_to_buf(buf[i:], int(status))
	i += copy_to(buf[i:], " ")
	i += copy_to(buf[i:], status_reason(status))
	i += copy_to(buf[i:], "\r\n")
	i += copy_to(buf[i:], "Content-Length: ")
	i += write_int_to_buf(buf[i:], len(body))
	i += copy_to(buf[i:], "\r\n")
	i += copy_to(buf[i:], "Content-Type: text/plain\r\n")
	i += copy_to(buf[i:], "Connection: close\r\n")
	i += copy_to(buf[i:], "Server: Ragnarok\r\n")
	i += copy_to(buf[i:], "\r\n")
	i += copy_to(buf[i:], body)
	return i
}

// ────────────────────────────────────────────────────
// Send flow (runs on main I/O thread via callback)
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
// Error response helper (I/O thread context)
// ────────────────────────────────────────────────────

// Sends an error response from the I/O thread (e.g. recv timeout, body too large).
// Uses a heap-allocated buffer since nbio.send is async.
send_error_response :: proc(conn: ^Connection, status: Http_Status) {
	// Free any request arena that might have been initialized
	request_arena_destroy(&conn.request_arena, context.allocator)

	error_body := status_reason(status)

	error_resp_buf := make([]u8, 256)
	if error_resp_buf == nil {
		connection_close(conn)
		return
	}

	// Store the buffer on the request_arena backing so it gets freed in on_send
	conn.request_arena.backing = error_resp_buf

	n := format_error_response(error_resp_buf, status, error_body)
	conn.keep_alive = false

	bufs := [][]u8{error_resp_buf[:n]}
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

// Quick scan for Content-Length value in raw header bytes without full parsing.
// Returns 0 if not found or invalid.
scan_content_length :: proc(header_data: []u8) -> int {
	text := string(header_data)
	// Search for Content-Length header (case-insensitive search for common casing)
	for line in strings.split_lines_iterator(&text) {
		if len(line) > 16 && (line[0] == 'C' || line[0] == 'c') {
			lower := strings.to_lower(line[:16], context.temp_allocator)
			if strings.has_prefix(lower, "content-length:") {
				val_str := strings.trim_space(line[15:])
				cl, ok := strconv.parse_int(val_str)
				if ok {
					return cl
				}
			}
		}
	}
	return 0
}

// Copy a string into a byte buffer. Returns number of bytes written.
copy_to :: proc(dst: []u8, src: string) -> int {
	n := min(len(dst), len(src))
	copy(dst[:n], transmute([]u8)src[:n])
	return n
}

// Write an integer into a byte buffer as decimal text. Returns number of bytes written.
write_int_to_buf :: proc(dst: []u8, value: int) -> int {
	tmp: [20]u8
	s := strconv.write_int(tmp[:], i64(value), 10)
	return copy_to(dst, s)
}

// Convert an Http_Method enum to its string representation.
method_to_string :: proc(method: Http_Method) -> string {
	switch method {
	case .GET:     return "GET"
	case .HEAD:    return "HEAD"
	case .POST:    return "POST"
	case .PUT:     return "PUT"
	case .DELETE:  return "DELETE"
	case .PATCH:   return "PATCH"
	case .OPTIONS: return "OPTIONS"
	case .TRACE:   return "TRACE"
	case .CONNECT: return "CONNECT"
	}
	return "UNKNOWN"
}
