package ragnarok_http

import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

// ────────────────────────────────────────────────────
// Accept callback
// ────────────────────────────────────────────────────

on_accept :: proc(op: ^nbio.Operation, server: ^Server) {
	if op.accept.err != nil {
		log.errorf("Accept error: %v", op.accept.err)
		nbio.accept_poly(op.accept.socket, server, on_accept)
		return
	}

	// Re-register accept for the next connection
	nbio.accept_poly(op.accept.socket, server, on_accept)

	// Acquire a slot from the connection pool
	ref := pool_acquire(&server.pool)
	if ref == nil {
		log.warnf("Connection pool full (%d), rejecting", server.config.max_connections)
		nbio.close(op.accept.client)
		return
	}

	s := ref.slot
	pool := ref.pool

	net.set_option(op.accept.client, .TCP_Nodelay, true)

	pool.conns[s].socket   = op.accept.client
	pool.conns[s].endpoint = op.accept.client_endpoint

	log.debugf("Accepted connection from %v (slot %d, active: %d)",
		pool.conns[s].endpoint, s, pool_active_count(pool))

	connection_start_recv(ref)
}

// ────────────────────────────────────────────────────
// Receive flow
// ────────────────────────────────────────────────────

connection_start_recv :: proc(ref: ^Conn_Ref) {
	s    := ref.slot
	pool := ref.pool

	buf := &pool.conns.recv_buf[s]
	remaining := buf[pool.conns[s].recv_len:]
	if len(remaining) == 0 {
		log.warn("Receive buffer full, closing connection")
		connection_close(ref)
		return
	}

	pool.conns[s].recv_start = time.now()
	bufs := [][]u8{remaining}
	recv_timeout := time.Duration(pool.server.config.idle_timeout_secs) * time.Second
	nbio.recv_poly(pool.conns[s].socket, bufs, ref, on_recv, timeout = recv_timeout)
}

on_recv :: proc(op: ^nbio.Operation, ref: ^Conn_Ref) {
	s    := ref.slot
	pool := ref.pool

	// Timeout
	recv_err, is_tcp_err := op.recv.err.(net.TCP_Recv_Error)
	if is_tcp_err && recv_err == .Timeout {
		log.debugf("Recv timeout from %v", pool.conns[s].endpoint)
		send_error_response(ref, .Request_Timeout)
		return
	}

	if op.recv.err != nil {
		log.debugf("Recv error from %v: %v", pool.conns[s].endpoint, op.recv.err)
		connection_close(ref)
		return
	}

	// Peer closed
	if op.recv.received == 0 {
		log.debugf("Connection closed by peer: %v", pool.conns[s].endpoint)
		connection_close(ref)
		return
	}

	pool.conns[s].recv_len += op.recv.received

	buf  := &pool.conns.recv_buf[s]
	data := buf[:pool.conns[s].recv_len]

	// Header size guard
	if pool.conns[s].recv_len > pool.server.config.max_header_size {
		if find_header_end(data) < 0 {
			send_error_response(ref, .Bad_Request)
			return
		}
	}

	// Look for end of headers (\r\n\r\n)
	header_end := find_header_end(data)
	if header_end < 0 {
		connection_start_recv(ref)
		return
	}

	// Body completeness check
	header_section := data[:header_end]
	body_start     := header_end + 4

	content_length := scan_content_length(header_section)
	if content_length > 0 {
		if content_length > pool.server.config.max_body_size {
			send_error_response(ref, .Payload_Too_Large)
			return
		}
		body_available := pool.conns[s].recv_len - body_start
		if body_available < content_length {
			if body_start + content_length > RECV_BUF_SIZE {
				send_error_response(ref, .Payload_Too_Large)
				return
			}
			connection_start_recv(ref)
			return
		}
	}

	// Full request — dispatch to a worker thread
	thread.pool_add_task(&pool.server.workers, context.allocator, process_request_task, ref)
}

// ────────────────────────────────────────────────────
// Worker thread — parse / route / handle / serialise
// ────────────────────────────────────────────────────

process_request_task :: proc(task: thread.Task) {
	ref  := (^Conn_Ref)(task.data)
	s    := ref.slot
	pool := ref.pool

	buf  := &pool.conns.recv_buf[s]
	data := buf[:pool.conns[s].recv_len]

	header_end     := find_header_end(data)
	header_section := data[:header_end]
	body_start     := header_end + 4

	// Allocate per-request arena
	if err := request_arena_init(
		&pool.request_arenas[s],
		pool.server.config.request_arena_size,
		context.allocator,
	); err != nil {
		log.error("Failed to allocate request arena")
		queue_error_response(ref, .Internal_Server_Error)
		return
	}

	arena_alloc := request_arena_allocator(&pool.request_arenas[s])

	// Parse
	request: Http_Request
	if !parse_request(&request, header_section, pool.server.config, arena_alloc) {
		queue_error_response(ref, .Bad_Request)
		return
	}

	if request.content_length > 0 {
		request.body = data[body_start:body_start + request.content_length]
	}

	// Update connection state
	pool.conns[s].keep_alive     = request.keep_alive
	pool.conns[s].request_count += 1
	if pool.conns[s].request_count >= pool.server.config.max_requests_per_conn {
		pool.conns[s].keep_alive = false
	}

	// Route → handle
	response := Http_Response{}
	response.headers = make([dynamic]Header, 0, 16, arena_alloc)

	handler := router_match(&pool.server.router, request.method, request.path)
	if handler != nil {
		handler(&request, &response, arena_alloc)
	} else if len(pool.server.config.static_root) > 0 {
		if !try_serve_static_file(ref, &request, &response, arena_alloc) {
			not_found_handler(&request, &response, arena_alloc)
		}
	} else {
		not_found_handler(&request, &response, arena_alloc)
	}

	// Connection header
	if pool.conns[s].keep_alive {
		response_set_header(&response, "Connection", "keep-alive", arena_alloc)
	} else {
		response_set_header(&response, "Connection", "close", arena_alloc)
	}

	// Serialise (headers-only for sendfile, headers+body otherwise)
	send_buf := response_serialize(&response, arena_alloc)
	if send_buf == nil {
		log.error("Failed to serialize response")
		queue_error_response(ref, .Internal_Server_Error)
		return
	}

	// Access log
	duration_ms := time.duration_milliseconds(time.since(pool.conns[s].recv_start))
	log.infof("%v \"%s %s\" %d %.1fms",
		pool.conns[s].endpoint,
		method_to_string(request.method),
		request.path,
		int(response.status),
		duration_ms,
	)

	// Queue send back to the I/O event loop
	bufs := [][]u8{send_buf}
	send_timeout := time.Duration(pool.server.config.idle_timeout_secs) * time.Second
	nbio.send_poly(
		pool.conns[s].socket, bufs, ref, on_send,
		all = true, timeout = send_timeout, l = pool.server.loop,
	)
}

// ────────────────────────────────────────────────────
// Error response helpers  (worker → I/O thread)
// ────────────────────────────────────────────────────

queue_error_response :: proc(ref: ^Conn_Ref, status: Http_Status) {
	s    := ref.slot
	pool := ref.pool

	request_arena_destroy(&pool.request_arenas[s], context.allocator)

	error_body := status_reason(status)
	error_resp_buf := make([]u8, 256)
	if error_resp_buf == nil {
		nbio.close(pool.conns[s].socket, l = pool.server.loop)
		pool_release(pool, s)
		return
	}

	// Stash the heap buffer so on_send → connection_close frees it
	pool.request_arenas[s].backing = error_resp_buf

	n := format_error_response(error_resp_buf, status, error_body)
	pool.conns[s].keep_alive = false

	bufs := [][]u8{error_resp_buf[:n]}
	nbio.send_poly(pool.conns[s].socket, bufs, ref, on_send, all = true, l = pool.server.loop)
}

format_error_response :: proc(buf: []u8, status: Http_Status, body: string) -> int {
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
// Send flow  (I/O thread)
// ────────────────────────────────────────────────────

on_send :: proc(op: ^nbio.Operation, ref: ^Conn_Ref) {
	s    := ref.slot
	pool := ref.pool

	if op.send.err != nil {
		log.debugf("Send error to %v: %v", pool.conns[s].endpoint, op.send.err)
		if pool.conns[s].sendfile_pending {
			pool.conns[s].sendfile_pending = false
			nbio.close(pool.conns[s].sendfile_handle)
		}
		connection_close(ref)
		return
	}

	// Chain sendfile after headers if a static file is pending
	if pool.conns[s].sendfile_pending {
		pool.conns[s].sendfile_pending = false
		send_timeout := time.Duration(pool.server.config.idle_timeout_secs) * time.Second
		nbio.sendfile_poly(
			pool.conns[s].socket,
			pool.conns[s].sendfile_handle,
			ref,
			on_sendfile_complete,
			timeout = send_timeout,
		)
		return
	}

	// Normal completion
	request_arena_destroy(&pool.request_arenas[s], context.allocator)

	if pool.conns[s].keep_alive {
		pool.conns[s].recv_len = 0
		connection_start_recv(ref)
	} else {
		connection_close(ref)
	}
}

// I/O-thread error response (recv timeout, body too large, etc.)
send_error_response :: proc(ref: ^Conn_Ref, status: Http_Status) {
	s    := ref.slot
	pool := ref.pool

	request_arena_destroy(&pool.request_arenas[s], context.allocator)

	error_body := status_reason(status)
	error_resp_buf := make([]u8, 256)
	if error_resp_buf == nil {
		connection_close(ref)
		return
	}

	pool.request_arenas[s].backing = error_resp_buf

	n := format_error_response(error_resp_buf, status, error_body)
	pool.conns[s].keep_alive = false

	bufs := [][]u8{error_resp_buf[:n]}
	nbio.send_poly(pool.conns[s].socket, bufs, ref, on_send, all = true)
}

// ────────────────────────────────────────────────────
// Connection close / cleanup
// ────────────────────────────────────────────────────

connection_close :: proc(ref: ^Conn_Ref) {
	if ref == nil { return }
	s    := ref.slot
	pool := ref.pool
	if !pool.conns[s].active { return }

	log.debugf("Closing connection to %v (slot %d, served %d requests)",
		pool.conns[s].endpoint, s, pool.conns[s].request_count)

	request_arena_destroy(&pool.request_arenas[s], context.allocator)
	nbio.close(pool.conns[s].socket)
	pool_release(pool, s)
}

// ────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────

find_header_end :: proc(data: []u8) -> int {
	if len(data) < 4 { return -1 }
	for i in 0 ..< len(data) - 3 {
		if data[i] == '\r' && data[i+1] == '\n' && data[i+2] == '\r' && data[i+3] == '\n' {
			return i
		}
	}
	return -1
}

scan_content_length :: proc(header_data: []u8) -> int {
	text := string(header_data)
	for line in strings.split_lines_iterator(&text) {
		if len(line) > 16 && (line[0] == 'C' || line[0] == 'c') {
			lower := strings.to_lower(line[:16], context.temp_allocator)
			if strings.has_prefix(lower, "content-length:") {
				val_str := strings.trim_space(line[15:])
				cl, ok := strconv.parse_int(val_str)
				if ok { return cl }
			}
		}
	}
	return 0
}

copy_to :: proc(dst: []u8, src: string) -> int {
	n := min(len(dst), len(src))
	copy(dst[:n], transmute([]u8)src[:n])
	return n
}

write_int_to_buf :: proc(dst: []u8, value: int) -> int {
	tmp: [20]u8
	s := strconv.write_int(tmp[:], i64(value), 10)
	return copy_to(dst, s)
}

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
