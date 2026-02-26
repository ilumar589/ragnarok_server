package ragnarok_http

import "core:fmt"
import "core:log"
import "core:mem"
import "core:strings"
import "core:testing"

// ────────────────────────────────────────────────────
// Tracking-allocator helpers
// ────────────────────────────────────────────────────

// Wraps a tracking allocator over the default heap allocator.
// Returns the allocator and a pointer to the tracking state for later inspection.
@(private = "file")
make_tracking_allocator :: proc() -> (mem.Allocator, ^mem.Tracking_Allocator) {
	ta := new(mem.Tracking_Allocator)
	mem.tracking_allocator_init(ta, context.allocator)
	return mem.tracking_allocator(ta), ta
}

// Asserts that the tracking allocator has no outstanding allocations (i.e. no leaks).
// Logs every leaked allocation on failure for easy debugging.
@(private = "file")
expect_no_leaks :: proc(t: ^testing.T, ta: ^mem.Tracking_Allocator, label: string) {
	leak_count := len(ta.allocation_map)
	if leak_count > 0 {
		for addr, entry in ta.allocation_map {
			fmt.eprintf("  LEAK [%s]: %p — %d bytes at %v\n", label, addr, entry.size, entry.location)
		}
			testing.expectf(t, false, "%s: %d allocation(s) leaked", label, leak_count)
	}
	bad_free_count := len(ta.bad_free_array)
	if bad_free_count > 0 {
		for entry in ta.bad_free_array {
			fmt.eprintf("  BAD FREE [%s]: %p at %v\n", label, entry.memory, entry.location)
		}
			testing.expectf(t, false, "%s: %d bad free(s) detected", label, bad_free_count)
	}

	// Clean up the tracking allocator itself
	mem.tracking_allocator_destroy(ta)
	free(ta)
}

// ────────────────────────────────────────────────────
// Test: Request_Arena init / destroy
// ────────────────────────────────────────────────────

@(test)
test_request_arena_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 4096, alloc)
	testing.expect(t, err == nil, "request_arena_init should succeed")
	testing.expect(t, ra.backing != nil, "backing buffer should be allocated")

	// Use the arena allocator for a few allocations
	arena_alloc := request_arena_allocator(&ra)
	_ = make([]u8, 128, arena_alloc)
	_ = make([]u8, 256, arena_alloc)

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "request_arena_init_destroy")
}

// ────────────────────────────────────────────────────
// Test: Request_Arena reset + reuse cycle
// ────────────────────────────────────────────────────

@(test)
test_request_arena_reset_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 4096, alloc)
	testing.expect(t, err == nil, "init should succeed")

	// Simulate multiple keep-alive requests reusing the arena
	for _ in 0 ..< 10 {
		arena_alloc := request_arena_allocator(&ra)
		_ = make([]u8, 100, arena_alloc)
		_ = make([]u8, 200, arena_alloc)
		request_arena_reset(&ra)
	}

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "request_arena_reset_reuse")
}

// ────────────────────────────────────────────────────
// Test: Request_Arena double destroy is safe
// ────────────────────────────────────────────────────

@(test)
test_request_arena_double_destroy_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 2048, alloc)
	testing.expect(t, err == nil, "init should succeed")

	request_arena_destroy(&ra, alloc)
	request_arena_destroy(&ra, alloc) // should be safe (nil guard)

	expect_no_leaks(t, ta, "request_arena_double_destroy")
}

// ────────────────────────────────────────────────────
// Test: Connection pool lifecycle
// ────────────────────────────────────────────────────

@(test)
test_pool_init_destroy_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	server: Server
	server.config = default_server_config()

	pool: Connection_Pool
	ok := pool_init(&pool, 64, &server, alloc)
	testing.expect(t, ok, "pool_init should succeed")
	testing.expect(t, pool.capacity == 64, "capacity should be 64")

	pool_destroy(&pool, alloc)

	expect_no_leaks(t, ta, "pool_init_destroy")
}

// ────────────────────────────────────────────────────
// Test: Pool acquire / release cycles
// ────────────────────────────────────────────────────

@(test)
test_pool_acquire_release_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	server: Server
	server.config = default_server_config()

	pool: Connection_Pool
	ok := pool_init(&pool, 16, &server, alloc)
	testing.expect(t, ok, "pool_init should succeed")

	// Acquire all slots, then release them — repeated cycles
	for cycle in 0 ..< 5 {
		refs: [16]^Conn_Ref
		for i in 0 ..< 16 {
			refs[i] = pool_acquire(&pool)
			testing.expect(t, refs[i] != nil, "acquire should succeed")
		}
		// Pool should be full
		testing.expect(t, pool_acquire(&pool) == nil, "pool should be full")

		for i in 0 ..< 16 {
			pool_release(&pool, refs[i].slot)
		}
		testing.expect(t, pool_active_count(&pool) == 0, "all slots should be free")
	}

	pool_destroy(&pool, alloc)

	expect_no_leaks(t, ta, "pool_acquire_release_cycles")
}

// ────────────────────────────────────────────────────
// Test: Pool acquire with request arenas
// ────────────────────────────────────────────────────

@(test)
test_pool_acquire_with_arenas_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	server: Server
	server.config = default_server_config()

	pool: Connection_Pool
	ok := pool_init(&pool, 8, &server, alloc)
	testing.expect(t, ok, "pool_init should succeed")

	// Simulate connection lifecycle: acquire → arena init → arena destroy → release
	for _ in 0 ..< 10 {
		ref := pool_acquire(&pool)
		testing.expect(t, ref != nil, "acquire should succeed")

		s := ref.slot

		// Init request arena (as process_request_task does)
		arena_err := request_arena_init(&pool.request_arenas[s], 4096, alloc)
		testing.expect(t, arena_err == nil, "arena init should succeed")

		arena_alloc := request_arena_allocator(&pool.request_arenas[s])
		_ = make([]u8, 512, arena_alloc)

		// Destroy arena (as connection_close / on_send does)
		request_arena_destroy(&pool.request_arenas[s], alloc)

		pool_release(&pool, s)
	}

	pool_destroy(&pool, alloc)

	expect_no_leaks(t, ta, "pool_acquire_with_arenas")
}

// ────────────────────────────────────────────────────
// Test: parse_request allocations freed via arena
// ────────────────────────────────────────────────────

@(test)
test_parse_request_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 8192, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	// RFC-compliant GET request (note: no trailing \r\n\r\n — parse_request
	// receives the header section only, before the blank line separator)
	raw := "GET /hello?foo=bar HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\nConnection: keep-alive"

	config := default_server_config()
	request: Http_Request
	ok := parse_request(&request, transmute([]u8)raw, config, arena_alloc)
	testing.expect(t, ok, "parse should succeed")
	testing.expect(t, request.method == .GET, "method should be GET")
	testing.expect(t, request.path == "/hello", "path should be /hello")
	testing.expect(t, request.query_string == "foo=bar", "query should be foo=bar")
	testing.expect(t, request.keep_alive, "should be keep-alive")

	// Destroy the arena — all parse_request allocations go away
	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "parse_request")
}

// ────────────────────────────────────────────────────
// Test: parse_request POST with headers
// ────────────────────────────────────────────────────

@(test)
test_parse_request_post_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 8192, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	raw := "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 11\r\nContent-Type: text/plain\r\nConnection: close"

	config := default_server_config()
	request: Http_Request
	ok := parse_request(&request, transmute([]u8)raw, config, arena_alloc)
	testing.expect(t, ok, "parse should succeed")
	testing.expect(t, request.method == .POST, "method should be POST")
	testing.expect(t, request.content_length == 11, "content-length should be 11")
	testing.expect(t, !request.keep_alive, "should not be keep-alive")

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "parse_request_post")
}

// ────────────────────────────────────────────────────
// Test: parse_request failure paths don't leak
// ────────────────────────────────────────────────────

@(test)
test_parse_request_bad_input_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 4096, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)
	config := default_server_config()

	bad_inputs := []string{
		"",
		"GARBAGE",
		"FOO / HTTP/1.1",              // unknown method
		"GET /HTTP/1.1",               // missing space
		"GET / HTTP/2.0",              // unsupported version
		"GET / HTTP/1.1\r\nBadHeader", // missing colon
	}

	for input in bad_inputs {
		request: Http_Request
		_ = parse_request(&request, transmute([]u8)input, config, arena_alloc)
		request_arena_reset(&ra) // reset for next attempt
	}

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "parse_request_bad_input")
}

// ────────────────────────────────────────────────────
// Test: response_serialize no leak
// ────────────────────────────────────────────────────

@(test)
test_response_serialize_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 8192, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	response := Http_Response{}
	response.status = .OK
	response.headers = make([dynamic]Header, 0, 8, arena_alloc)
	response_set_body_string(&response, "Hello, World!", "text/plain", arena_alloc)

	buf := response_serialize(&response, arena_alloc)
	testing.expect(t, buf != nil, "serialize should produce output")
	testing.expect(t, len(buf) > 0, "output should be non-empty")

	// Verify it looks like HTTP
	output := string(buf)
	testing.expect(t, strings.has_prefix(output, "HTTP/1.1 200"), "should start with HTTP/1.1 200")
	testing.expect(t, strings.contains(output, "Hello, World!"), "body should be present")

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "response_serialize")
}

// ────────────────────────────────────────────────────
// Test: response with many headers no leak
// ────────────────────────────────────────────────────

@(test)
test_response_many_headers_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 16384, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	response := Http_Response{}
	response.status = .OK
	response.headers = make([dynamic]Header, 0, 32, arena_alloc)

	// Add many custom headers
	for i in 0 ..< 20 {
		hdr_buf := make([]u8, 32, arena_alloc)
		name := fmt.bprintf(hdr_buf, "X-Custom-%d", i)
		response_set_header(&response, name, "some-value", arena_alloc)
	}

	response_set_body_string(&response, "body", "text/plain", arena_alloc)

	buf := response_serialize(&response, arena_alloc)
	testing.expect(t, buf != nil, "serialize should succeed")

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "response_many_headers")
}

// ────────────────────────────────────────────────────
// Test: handler cycle (route → handler → serialize)
// ────────────────────────────────────────────────────

@(test)
test_handler_cycle_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 8192, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	// Build a request
	raw := "GET /health HTTP/1.1\r\nHost: localhost"
	config := default_server_config()
	request: Http_Request
	ok := parse_request(&request, transmute([]u8)raw, config, arena_alloc)
	testing.expect(t, ok, "parse should succeed")

	// Build a response via router
	router: Router
	router_init(&router)
	router_add_route(&router, .GET, "/health", health_handler)

	handler := router_match(&router, request.method, request.path)
	testing.expect(t, handler != nil, "handler should be found")

	response := Http_Response{}
	response.headers = make([dynamic]Header, 0, 16, arena_alloc)
	handler(&request, &response, arena_alloc)

	// Serialise
	buf := response_serialize(&response, arena_alloc)
	testing.expect(t, buf != nil, "serialize should succeed")
	testing.expect(t, strings.contains(string(buf), "OK"), "body should contain OK")

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "handler_cycle")
}

// ────────────────────────────────────────────────────
// Test: not-found handler no leak
// ────────────────────────────────────────────────────

@(test)
test_not_found_handler_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 4096, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	raw := "GET /nonexistent HTTP/1.1\r\nHost: localhost"
	config := default_server_config()
	request: Http_Request
	ok := parse_request(&request, transmute([]u8)raw, config, arena_alloc)
	testing.expect(t, ok, "parse should succeed")

	response := Http_Response{}
	response.headers = make([dynamic]Header, 0, 16, arena_alloc)
	not_found_handler(&request, &response, arena_alloc)

	buf := response_serialize(&response, arena_alloc)
	testing.expect(t, buf != nil, "serialize should succeed")
	testing.expect(t, strings.contains(string(buf), "404"), "should be 404")

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "not_found_handler")
}

// ────────────────────────────────────────────────────
// Test: method_not_allowed handler no leak
// ────────────────────────────────────────────────────

@(test)
test_method_not_allowed_handler_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 4096, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	raw := "POST /health HTTP/1.1\r\nHost: localhost"
	config := default_server_config()
	request: Http_Request
	ok := parse_request(&request, transmute([]u8)raw, config, arena_alloc)
	testing.expect(t, ok, "parse should succeed")

	// Router has only GET /health -> POST should yield method_not_allowed
	router: Router
	router_init(&router)
	router_add_route(&router, .GET, "/health", health_handler)

	handler := router_match(&router, request.method, request.path)
	testing.expect(t, handler != nil, "handler should be returned (method_not_allowed)")

	response := Http_Response{}
	response.headers = make([dynamic]Header, 0, 16, arena_alloc)
	handler(&request, &response, arena_alloc)

	buf := response_serialize(&response, arena_alloc)
	testing.expect(t, buf != nil, "serialize should succeed")
	testing.expect(t, strings.contains(string(buf), "405"), "should be 405")

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "method_not_allowed_handler")
}

// ────────────────────────────────────────────────────
// Test: format_error_response (stack buffer, no alloc)
// ────────────────────────────────────────────────────

@(test)
test_format_error_response_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	// format_error_response writes into an existing buffer — should make zero heap allocations
	buf: [256]u8
	n := format_error_response(buf[:], .Bad_Request, "Bad Request")
	testing.expect(t, n > 0, "should produce output")

	output := string(buf[:n])
	testing.expect(t, strings.has_prefix(output, "HTTP/1.1 400"), "should start with 400")
	testing.expect(t, strings.contains(output, "Bad Request"), "body should be present")

	expect_no_leaks(t, ta, "format_error_response")
}

// ────────────────────────────────────────────────────
// Test: build_file_path no leak
// ────────────────────────────────────────────────────

@(test)
test_build_file_path_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	path := build_file_path("static", "index.html", alloc)
	testing.expect(t, len(path) > 0, "path should be non-empty")

	path2 := build_file_path("static/", "css/style.css", alloc)
	testing.expect(t, len(path2) > 0, "path2 should be non-empty")

	// Free everything via tracking allocator awareness — these are plain heap allocs
	// In production, these are arena-allocated and freed with the arena.
	// For this test we manually free to verify no extra hidden allocs.
	delete(path, alloc)
	delete(path2, alloc)

	// build_file_path on Windows also allocates for replace_all
	// Those intermediate strings may be leaked — that's what this test catches.
	expect_no_leaks(t, ta, "build_file_path")
}

// ────────────────────────────────────────────────────
// Test: repeated full request cycle (parse→route→respond→serialize→destroy)
// ────────────────────────────────────────────────────

@(test)
test_repeated_request_cycle_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	router: Router
	router_init(&router)
	router_add_route(&router, .GET, "/health", health_handler)
	router_add_route(&router, .GET, "/", not_found_handler)

	config := default_server_config()

	// Simulate 50 request–response cycles, each with its own arena
	for _ in 0 ..< 50 {
		ra: Request_Arena
		err := request_arena_init(&ra, 4096, alloc)
		testing.expect(t, err == nil, "arena init should succeed")

		arena_alloc := request_arena_allocator(&ra)

		raw := "GET /health HTTP/1.1\r\nHost: localhost\r\nAccept: */*"
		request: Http_Request
		ok := parse_request(&request, transmute([]u8)raw, config, arena_alloc)
		testing.expect(t, ok, "parse should succeed")

		handler := router_match(&router, request.method, request.path)
		testing.expect(t, handler != nil, "handler should be found")

		response := Http_Response{}
		response.headers = make([dynamic]Header, 0, 16, arena_alloc)
		handler(&request, &response, arena_alloc)

		response_set_header(&response, "Connection", "keep-alive", arena_alloc)

		buf := response_serialize(&response, arena_alloc)
		testing.expect(t, buf != nil, "serialize should succeed")

		request_arena_destroy(&ra, alloc)
	}

	expect_no_leaks(t, ta, "repeated_request_cycle")
}

// ────────────────────────────────────────────────────
// Test: pool with simulated connection lifecycle burst
// ────────────────────────────────────────────────────

@(test)
test_pool_connection_burst_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	server: Server
	server.config = default_server_config()

	pool: Connection_Pool
	ok := pool_init(&pool, 32, &server, alloc)
	testing.expect(t, ok, "pool_init should succeed")

	config := default_server_config()

	// Simulate burst: acquire slot → init arena → parse → serialize → destroy arena → release
	for _ in 0 ..< 100 {
		ref := pool_acquire(&pool)
		testing.expect(t, ref != nil, "acquire should succeed")
		s := ref.slot

		arena_err := request_arena_init(&pool.request_arenas[s], 4096, alloc)
		testing.expect(t, arena_err == nil, "arena init should succeed")

		arena_alloc := request_arena_allocator(&pool.request_arenas[s])

		raw := "GET / HTTP/1.1\r\nHost: localhost"
		request: Http_Request
		_ = parse_request(&request, transmute([]u8)raw, config, arena_alloc)

		response := Http_Response{}
		response.headers = make([dynamic]Header, 0, 8, arena_alloc)
		health_handler(&request, &response, arena_alloc)
		_ = response_serialize(&response, arena_alloc)

		request_arena_destroy(&pool.request_arenas[s], alloc)
		pool_release(&pool, s)
	}

	pool_destroy(&pool, alloc)

	expect_no_leaks(t, ta, "pool_connection_burst")
}

// ────────────────────────────────────────────────────
// Test: concurrent-style arena isolation (no cross-contamination)
// ────────────────────────────────────────────────────

@(test)
test_arena_isolation_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	// Allocate multiple arenas simultaneously (simulates concurrent connections)
	ARENA_COUNT :: 8
	arenas: [ARENA_COUNT]Request_Arena

	for i in 0 ..< ARENA_COUNT {
		err := request_arena_init(&arenas[i], 2048, alloc)
		testing.expect(t, err == nil, "arena init should succeed")
	}

	// Each arena gets independent allocations
	for i in 0 ..< ARENA_COUNT {
		a := request_arena_allocator(&arenas[i])
		_ = make([]u8, 256, a)
		_ = make([]u8, 512, a)
	}

	// Destroy in reverse order — should not affect others
	for i := ARENA_COUNT - 1; i >= 0; i -= 1 {
		request_arena_destroy(&arenas[i], alloc)
	}

	expect_no_leaks(t, ta, "arena_isolation")
}

// ────────────────────────────────────────────────────
// Test: arena stress — many small allocations
// ────────────────────────────────────────────────────

@(test)
test_arena_stress_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 65536, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	// Lots of small allocations
	for _ in 0 ..< 200 {
		_ = make([]u8, 64, arena_alloc)
	}

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "arena_stress")
}

// ────────────────────────────────────────────────────
// Test: pool double release is safe
// ────────────────────────────────────────────────────

@(test)
test_pool_double_release_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	server: Server
	server.config = default_server_config()

	pool: Connection_Pool
	ok := pool_init(&pool, 4, &server, alloc)
	testing.expect(t, ok, "pool_init should succeed")

	ref := pool_acquire(&pool)
	testing.expect(t, ref != nil, "acquire should succeed")

	pool_release(&pool, ref.slot)
	pool_release(&pool, ref.slot) // double release — should be guarded

	pool_destroy(&pool, alloc)

	expect_no_leaks(t, ta, "pool_double_release")
}

// ────────────────────────────────────────────────────
// Test: empty response serialization no leak
// ────────────────────────────────────────────────────

@(test)
test_empty_response_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	ra: Request_Arena
	err := request_arena_init(&ra, 4096, alloc)
	testing.expect(t, err == nil, "arena init should succeed")

	arena_alloc := request_arena_allocator(&ra)

	response := Http_Response{}
	response.status = .No_Content
	response.headers = make([dynamic]Header, 0, 8, arena_alloc)
	// No body

	buf := response_serialize(&response, arena_alloc)
	testing.expect(t, buf != nil, "serialize should succeed")
	testing.expect(t, strings.contains(string(buf), "204"), "should be 204")

	request_arena_destroy(&ra, alloc)

	expect_no_leaks(t, ta, "empty_response")
}
