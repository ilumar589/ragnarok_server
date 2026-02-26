package benchmarks

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import http "../ragnarok_http"

// ────────────────────────────────────────────────────
// Benchmark result
// ────────────────────────────────────────────────────

Bench_Result :: struct {
	name:            string,
	category:        string,
	iterations:      int,
	total_ns:        i64,
	avg_ns:          f64,
	min_ns:          i64,
	max_ns:          i64,
	ops_per_sec:     f64,
	total_allocs:    int,
	total_bytes:     int,
	allocs_per_op:   f64,
	bytes_per_op:    f64,
	alloc_rate:        f64,
	throughput_mb_s:   f64,
	p50_ns:            i64,
	p99_ns:            i64,
	peak_ops_per_sec:  f64,
}

// Fill derived fields from raw timing + tracking data.
finish_result :: proc(r: ^Bench_Result, ta: ^mem.Tracking_Allocator, throughput_bytes: int = 0) {
	r.avg_ns      = f64(r.total_ns) / f64(r.iterations)
	r.ops_per_sec = f64(r.iterations) / (f64(r.total_ns) / 1e9) if r.total_ns > 0 else 0

	r.total_allocs  = int(ta.total_allocation_count)
	r.total_bytes   = int(ta.total_memory_allocated)
	r.allocs_per_op = f64(r.total_allocs) / f64(r.iterations)
	r.bytes_per_op  = f64(r.total_bytes) / f64(r.iterations)
	r.alloc_rate    = f64(r.total_allocs) / (f64(r.total_ns) / 1e9) if r.total_ns > 0 else 0

	if throughput_bytes > 0 {
		total_data := f64(throughput_bytes) * f64(r.iterations)
		r.throughput_mb_s = (total_data / (1024 * 1024)) / (f64(r.total_ns) / 1e9)
	}
}

is_request_category :: proc(cat: string) -> bool {
	return cat == "Requests/sec" || cat == "Concurrent Requests" || cat == "Throughput"
}

print_result :: proc(r: ^Bench_Result) {
	rate_label := "req/s" if is_request_category(r.category) else "ops/s"
	fmt.printf("  %-40s %s ops  %s ns/op  %s %s",
		r.name,
		format_int_comma(r.iterations),
		format_number(r.avg_ns, 1),
		format_int_comma(int(r.ops_per_sec)),
		rate_label,
	)
	if r.allocs_per_op > 0 {
		fmt.printf("  %.1f allocs/op  %.0f B/op", r.allocs_per_op, r.bytes_per_op)
	}
	if r.throughput_mb_s > 0 {
		fmt.printf("  %.1f MB/s", r.throughput_mb_s)
	}
	if r.p99_ns > 0 {
		fmt.printf("  p99=%s ns", format_int_comma(int(r.p99_ns)))
	}
	if r.peak_ops_per_sec > 0 {
		peak_label := "req/s" if is_request_category(r.category) else "ops/s"
		fmt.printf("  peak=%s %s", format_int_comma(int(r.peak_ops_per_sec)), peak_label)
	}
	fmt.println()
}

// ────────────────────────────────────────────────────
// Common request data
// ────────────────────────────────────────────────────

GET_REQUEST_RAW  :: "GET /hello?foo=bar&baz=42 HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: benchmark/1.0\r\nAccept: text/html,application/json\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive"
POST_REQUEST_RAW :: "POST /api/data HTTP/1.1\r\nHost: localhost:8080\r\nContent-Type: application/json\r\nContent-Length: 45\r\nAccept: application/json\r\nConnection: keep-alive"
MANY_HEADERS_RAW :: "GET / HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\nAccept-Language: en-US\r\nAccept-Encoding: gzip\r\nCache-Control: no-cache\r\nPragma: no-cache\r\nUser-Agent: bench/1.0\r\nReferer: http://localhost/\r\nX-Request-ID: abc123\r\nX-Forwarded-For: 127.0.0.1\r\nX-Forwarded-Proto: https\r\nX-Custom-1: value1\r\nX-Custom-2: value2\r\nX-Custom-3: value3\r\nX-Custom-4: value4\r\nConnection: keep-alive"

// ────────────────────────────────────────────────────
// Individual benchmarks
// ────────────────────────────────────────────────────

bench_arena_init_destroy :: proc() -> Bench_Result {
	N :: 100_000
	r := Bench_Result{ name = "Arena init+destroy", category = "Memory", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 8192, alloc)
		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, 8192)
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_arena_allocations :: proc() -> Bench_Result {
	N :: 100_000
	r := Bench_Result{ name = "Arena 20 allocs + reset", category = "Memory", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 16384, alloc)
		arena_alloc := http.request_arena_allocator(&ra)
		for _ in 0 ..< 20 {
			_ = make([]u8, 128, arena_alloc)
		}
		http.request_arena_reset(&ra)
		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, 20 * 128)
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_arena_reset_reuse :: proc() -> Bench_Result {
	N :: 500_000
	r := Bench_Result{ name = "Arena reset+reuse (keep-alive)", category = "Memory", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	ra: http.Request_Arena
	http.request_arena_init(&ra, 8192, alloc)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		arena_alloc := http.request_arena_allocator(&ra)
		_ = make([]u8, 256, arena_alloc)
		_ = make([]u8, 512, arena_alloc)
		http.request_arena_reset(&ra)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	http.request_arena_destroy(&ra, alloc)
	finish_result(&r, &ta, 256 + 512)
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_pool_acquire_release :: proc() -> Bench_Result {
	N :: 500_000
	r := Bench_Result{ name = "Pool acquire+release", category = "Memory", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	server: http.Server
	server.config = http.default_server_config()
	pool: http.Connection_Pool
	http.pool_init(&pool, 64, &server, alloc)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ref := http.pool_acquire(&pool)
		if ref != nil { http.pool_release(&pool, ref.slot) }

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	http.pool_destroy(&pool, alloc)
	finish_result(&r, &ta, size_of(http.Conn_Ref))
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_alloc_rate_small :: proc() -> Bench_Result {
	N :: 200_000
	r := Bench_Result{ name = "Arena alloc rate (50x64B)", category = "Allocation Rate", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 8192, alloc)
		arena_alloc := http.request_arena_allocator(&ra)
		for _ in 0 ..< 50 {
			_ = make([]u8, 64, arena_alloc)
		}
		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, 50 * 64)
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_alloc_rate_mixed :: proc() -> Bench_Result {
	N :: 200_000
	r := Bench_Result{ name = "Arena alloc rate (mixed sizes)", category = "Allocation Rate", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	sizes := [8]int{32, 64, 128, 256, 512, 1024, 64, 128}

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 16384, alloc)
		arena_alloc := http.request_arena_allocator(&ra)
		for sz in sizes {
			_ = make([]u8, sz, arena_alloc)
		}
		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, 32 + 64 + 128 + 256 + 512 + 1024 + 64 + 128)
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_parse_get :: proc() -> Bench_Result {
	N :: 200_000
	r := Bench_Result{ name = "Parse GET request", category = "CPU / Parsing", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	config := http.default_server_config()

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 4096, alloc)
		arena_alloc := http.request_arena_allocator(&ra)

		request: http.Http_Request
		http.parse_request(&request, transmute([]u8)string(GET_REQUEST_RAW), config, arena_alloc)

		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, len(GET_REQUEST_RAW))
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_parse_post :: proc() -> Bench_Result {
	N :: 200_000
	r := Bench_Result{ name = "Parse POST request", category = "CPU / Parsing", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	config := http.default_server_config()

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 4096, alloc)
		arena_alloc := http.request_arena_allocator(&ra)

		request: http.Http_Request
		http.parse_request(&request, transmute([]u8)string(POST_REQUEST_RAW), config, arena_alloc)

		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, len(POST_REQUEST_RAW))
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_parse_many_headers :: proc() -> Bench_Result {
	N :: 100_000
	r := Bench_Result{ name = "Parse request (16 headers)", category = "CPU / Parsing", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	config := http.default_server_config()

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 8192, alloc)
		arena_alloc := http.request_arena_allocator(&ra)

		request: http.Http_Request
		http.parse_request(&request, transmute([]u8)string(MANY_HEADERS_RAW), config, arena_alloc)

		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, len(MANY_HEADERS_RAW))
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_router_match :: proc() -> Bench_Result {
	N :: 1_000_000
	r := Bench_Result{ name = "Router match (10 routes)", category = "CPU / Routing", iterations = N, min_ns = max(i64) }

	router: http.Router
	http.router_init(&router)
	dummy :: proc(rq: ^http.Http_Request, rs: ^http.Http_Response, a: mem.Allocator) {}
	http.router_add_route(&router, .GET, "/", dummy)
	http.router_add_route(&router, .GET, "/health", dummy)
	http.router_add_route(&router, .GET, "/api/users", dummy)
	http.router_add_route(&router, .POST, "/api/users", dummy)
	http.router_add_route(&router, .GET, "/api/posts", dummy)
	http.router_add_route(&router, .POST, "/api/posts", dummy)
	http.router_add_route(&router, .GET, "/api/comments", dummy)
	http.router_add_route(&router, .DELETE, "/api/users", dummy)
	http.router_add_route(&router, .PUT, "/api/users", dummy)
	http.router_add_route(&router, .GET, "/about", dummy)

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()
		_ = http.router_match(&router, .GET, "/about")
		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, len("/about"))
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_router_miss :: proc() -> Bench_Result {
	N :: 1_000_000
	r := Bench_Result{ name = "Router miss (10 routes)", category = "CPU / Routing", iterations = N, min_ns = max(i64) }

	router: http.Router
	http.router_init(&router)
	dummy :: proc(rq: ^http.Http_Request, rs: ^http.Http_Response, a: mem.Allocator) {}
	http.router_add_route(&router, .GET, "/", dummy)
	http.router_add_route(&router, .GET, "/health", dummy)
	http.router_add_route(&router, .GET, "/api/users", dummy)
	http.router_add_route(&router, .POST, "/api/users", dummy)
	http.router_add_route(&router, .GET, "/api/posts", dummy)
	http.router_add_route(&router, .POST, "/api/posts", dummy)
	http.router_add_route(&router, .GET, "/api/comments", dummy)
	http.router_add_route(&router, .DELETE, "/api/users", dummy)
	http.router_add_route(&router, .PUT, "/api/users", dummy)
	http.router_add_route(&router, .GET, "/about", dummy)

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()
		_ = http.router_match(&router, .GET, "/nonexistent")
		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, len("/nonexistent"))
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_response_serialize_small :: proc() -> Bench_Result {
	N :: 200_000
	r := Bench_Result{ name = "Serialize response (small body)", category = "CPU / Serialization", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 4096, alloc)
		arena_alloc := http.request_arena_allocator(&ra)

		response := http.Http_Response{}
		response.status = .OK
		response.headers = make([dynamic]http.Header, 0, 8, arena_alloc)
		http.response_set_body_string(&response, "Hello, World!", "text/plain", arena_alloc)
		http.response_set_header(&response, "Connection", "keep-alive", arena_alloc)
		_ = http.response_serialize(&response, arena_alloc)

		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, len("Hello, World!"))
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_response_serialize_large :: proc() -> Bench_Result {
	N :: 50_000
	BODY_SIZE :: 16384
	r := Bench_Result{ name = "Serialize response (16KB body)", category = "CPU / Serialization", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 32768, alloc)
		arena_alloc := http.request_arena_allocator(&ra)

		body := make([]u8, BODY_SIZE, arena_alloc)
		for j in 0 ..< BODY_SIZE { body[j] = 'X' }

		response := http.Http_Response{}
		response.status = .OK
		response.headers = make([dynamic]http.Header, 0, 8, arena_alloc)
		http.response_set_body(&response, body, "application/octet-stream", arena_alloc)
		http.response_set_header(&response, "Connection", "keep-alive", arena_alloc)
		_ = http.response_serialize(&response, arena_alloc)

		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, BODY_SIZE)
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_format_error_response :: proc() -> Bench_Result {
	N :: 1_000_000
	r := Bench_Result{ name = "format_error_response (stack)", category = "CPU / Serialization", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		buf: [256]u8
		_ = http.format_error_response(buf[:], .Bad_Request, "Bad Request")

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, len("Bad Request"))
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_full_request_cycle :: proc() -> Bench_Result {
	N :: 200_000
	WINDOW :: 2_000
	r := Bench_Result{ name = "Full request cycle", category = "Requests/sec", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	router: http.Router
	http.router_init(&router)
	http.router_add_route(&router, .GET, "/health", http.health_handler)

	config := http.default_server_config()

	latencies := make([]i64, N)
	defer delete(latencies)
	peak_rps: f64 = 0
	window_start := time.tick_now()

	start := time.tick_now()
	for i in 0 ..< N {
		iter_start := time.tick_now()

		ra: http.Request_Arena
		http.request_arena_init(&ra, 8192, alloc)
		arena_alloc := http.request_arena_allocator(&ra)

		request: http.Http_Request
		http.parse_request(&request, transmute([]u8)string(GET_REQUEST_RAW), config, arena_alloc)

		handler := http.router_match(&router, request.method, request.path)
		if handler == nil { handler = http.not_found_handler }

		response := http.Http_Response{}
		response.headers = make([dynamic]http.Header, 0, 16, arena_alloc)
		handler(&request, &response, arena_alloc)
		http.response_set_header(&response, "Connection", "keep-alive", arena_alloc)
		_ = http.response_serialize(&response, arena_alloc)

		http.request_arena_destroy(&ra, alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		latencies[i] = ns
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }

		if (i + 1) % WINDOW == 0 {
			wnd_ns := time.duration_nanoseconds(time.tick_diff(window_start, time.tick_now()))
			if wnd_ns > 0 {
				wnd_rps := f64(WINDOW) / (f64(wnd_ns) / 1e9)
				if wnd_rps > peak_rps { peak_rps = wnd_rps }
			}
			window_start = time.tick_now()
		}
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	finish_result(&r, &ta, len(GET_REQUEST_RAW))
	r.peak_ops_per_sec = peak_rps
	slice.sort(latencies)
	r.p50_ns = latencies[(N - 1) * 50 / 100]
	r.p99_ns = latencies[(N - 1) * 99 / 100]
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_concurrent_connections :: proc() -> Bench_Result {
	N :: 100_000
	WINDOW :: 1_000
	r := Bench_Result{ name = "Concurrent conn simulation (32 slots)", category = "Concurrent Requests", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	server: http.Server
	server.config = http.default_server_config()
	pool: http.Connection_Pool
	http.pool_init(&pool, 32, &server, alloc)

	router: http.Router
	http.router_init(&router)
	http.router_add_route(&router, .GET, "/health", http.health_handler)

	config := http.default_server_config()

	latencies := make([]i64, N)
	defer delete(latencies)
	peak_rps: f64 = 0
	window_start := time.tick_now()

	start := time.tick_now()
	for i in 0 ..< N {
		iter_start := time.tick_now()

		ref := http.pool_acquire(&pool)
		if ref == nil { continue }
		s := ref.slot

		http.request_arena_init(&pool.request_arenas[s], 4096, alloc)
		arena_alloc := http.request_arena_allocator(&pool.request_arenas[s])

		request: http.Http_Request
		http.parse_request(&request, transmute([]u8)string(GET_REQUEST_RAW), config, arena_alloc)

		handler := http.router_match(&router, request.method, request.path)
		if handler == nil { handler = http.not_found_handler }

		response := http.Http_Response{}
		response.headers = make([dynamic]http.Header, 0, 8, arena_alloc)
		handler(&request, &response, arena_alloc)
		_ = http.response_serialize(&response, arena_alloc)

		http.request_arena_destroy(&pool.request_arenas[s], alloc)
		http.pool_release(&pool, s)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		latencies[i] = ns
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }

		if (i + 1) % WINDOW == 0 {
			wnd_ns := time.duration_nanoseconds(time.tick_diff(window_start, time.tick_now()))
			if wnd_ns > 0 {
				wnd_rps := f64(WINDOW) / (f64(wnd_ns) / 1e9)
				if wnd_rps > peak_rps { peak_rps = wnd_rps }
			}
			window_start = time.tick_now()
		}
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	http.pool_destroy(&pool, alloc)
	finish_result(&r, &ta, len(GET_REQUEST_RAW))
	r.peak_ops_per_sec = peak_rps
	slice.sort(latencies)
	r.p50_ns = latencies[(N - 1) * 50 / 100]
	r.p99_ns = latencies[(N - 1) * 99 / 100]
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_pool_burst :: proc() -> Bench_Result {
	POOL_CAP :: 64
	N :: 50_000
	r := Bench_Result{ name = "Pool burst (64 acquire+release)", category = "Concurrent Requests", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	server: http.Server
	server.config = http.default_server_config()
	pool: http.Connection_Pool
	http.pool_init(&pool, POOL_CAP, &server, alloc)

	start := time.tick_now()
	for _ in 0 ..< N {
		iter_start := time.tick_now()

		refs: [POOL_CAP]^http.Conn_Ref
		for j in 0 ..< POOL_CAP {
			refs[j] = http.pool_acquire(&pool)
		}
		for j in 0 ..< POOL_CAP {
			if refs[j] != nil {
				http.pool_release(&pool, refs[j].slot)
			}
		}

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	http.pool_destroy(&pool, alloc)
	finish_result(&r, &ta, POOL_CAP * size_of(http.Conn_Ref))
	mem.tracking_allocator_destroy(&ta)
	return r
}

// ────────────────────────────────────────────────────
// Throughput benchmarks (avg/peak req/s, p99 latency)
// ────────────────────────────────────────────────────

bench_throughput_n :: proc(concurrency: int, n_batches: int, label: string) -> Bench_Result {
	WINDOW :: 100
	total_reqs := n_batches * concurrency

	r := Bench_Result{
		name       = label,
		category   = "Throughput",
		iterations = total_reqs,
		min_ns     = max(i64),
	}

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	server: http.Server
	server.config = http.default_server_config()
	pool: http.Connection_Pool
	http.pool_init(&pool, concurrency, &server, alloc)

	router: http.Router
	http.router_init(&router)
	http.router_add_route(&router, .GET, "/health", http.health_handler)
	config := http.default_server_config()

	latencies := make([]i64, total_reqs)
	defer delete(latencies)
	lat_idx := 0
	peak_rps: f64 = 0
	window_reqs := 0
	window_start := time.tick_now()

	start := time.tick_now()
	for _ in 0 ..< n_batches {
		refs: [128]^http.Conn_Ref
		acquired := 0
		for c in 0 ..< concurrency {
			ref := http.pool_acquire(&pool)
			if ref != nil {
				refs[acquired] = ref
				acquired += 1
			}
		}

		for c in 0 ..< acquired {
			s := refs[c].slot
			req_start := time.tick_now()

			http.request_arena_init(&pool.request_arenas[s], 4096, alloc)
			arena_alloc := http.request_arena_allocator(&pool.request_arenas[s])

			request: http.Http_Request
			http.parse_request(&request, transmute([]u8)string(GET_REQUEST_RAW), config, arena_alloc)

			handler := http.router_match(&router, request.method, request.path)
			if handler == nil { handler = http.not_found_handler }

			response := http.Http_Response{}
			response.headers = make([dynamic]http.Header, 0, 8, arena_alloc)
			handler(&request, &response, arena_alloc)
			_ = http.response_serialize(&response, arena_alloc)

			http.request_arena_destroy(&pool.request_arenas[s], alloc)

			ns := time.duration_nanoseconds(time.tick_diff(req_start, time.tick_now()))
			if lat_idx < total_reqs {
				latencies[lat_idx] = ns
				lat_idx += 1
			}
			if ns < r.min_ns { r.min_ns = ns }
			if ns > r.max_ns { r.max_ns = ns }
		}

		for c in 0 ..< acquired {
			http.pool_release(&pool, refs[c].slot)
		}

		window_reqs += acquired
		if window_reqs >= WINDOW * concurrency {
			wnd_ns := time.duration_nanoseconds(time.tick_diff(window_start, time.tick_now()))
			if wnd_ns > 0 {
				wnd_rps := f64(window_reqs) / (f64(wnd_ns) / 1e9)
				if wnd_rps > peak_rps { peak_rps = wnd_rps }
			}
			window_reqs = 0
			window_start = time.tick_now()
		}
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	r.avg_ns = f64(r.total_ns) / f64(r.iterations) if r.iterations > 0 else 0
	r.ops_per_sec = f64(r.iterations) / (f64(r.total_ns) / 1e9) if r.total_ns > 0 else 0
	r.peak_ops_per_sec = peak_rps

	actual := latencies[:lat_idx]
	slice.sort(actual)
	if lat_idx > 0 {
		r.p50_ns = actual[int(f64(lat_idx - 1) * 0.50)]
		r.p99_ns = actual[int(f64(lat_idx - 1) * 0.99)]
	}

	r.total_allocs  = int(ta.total_allocation_count)
	r.total_bytes   = int(ta.total_memory_allocated)
	r.allocs_per_op = f64(r.total_allocs) / f64(r.iterations) if r.iterations > 0 else 0
	r.bytes_per_op  = f64(r.total_bytes) / f64(r.iterations) if r.iterations > 0 else 0
	r.alloc_rate    = f64(r.total_allocs) / (f64(r.total_ns) / 1e9) if r.total_ns > 0 else 0
	r.throughput_mb_s = (f64(len(GET_REQUEST_RAW)) * f64(r.iterations) / (1024 * 1024)) / (f64(r.total_ns) / 1e9) if r.total_ns > 0 else 0

	http.pool_destroy(&pool, alloc)
	mem.tracking_allocator_destroy(&ta)
	return r
}

bench_throughput_1   :: proc() -> Bench_Result { return bench_throughput_n(1,   100_000, "1 connection (sequential)") }
bench_throughput_8   :: proc() -> Bench_Result { return bench_throughput_n(8,    25_000, "8 connections (batch)") }
bench_throughput_32  :: proc() -> Bench_Result { return bench_throughput_n(32,   10_000, "32 connections (batch)") }
bench_throughput_64  :: proc() -> Bench_Result { return bench_throughput_n(64,    5_000, "64 connections (batch)") }
bench_throughput_128 :: proc() -> Bench_Result { return bench_throughput_n(128,   2_500, "128 connections (batch)") }

bench_throughput_keepalive :: proc() -> Bench_Result {
	N :: 500_000
	WINDOW :: 5_000
	r := Bench_Result{ name = "Keep-alive pipeline", category = "Throughput", iterations = N, min_ns = max(i64) }

	ta: mem.Tracking_Allocator
	mem.tracking_allocator_init(&ta, context.allocator)
	alloc := mem.tracking_allocator(&ta)

	router: http.Router
	http.router_init(&router)
	http.router_add_route(&router, .GET, "/health", http.health_handler)
	config := http.default_server_config()

	ra: http.Request_Arena
	http.request_arena_init(&ra, 8192, alloc)

	latencies := make([]i64, N)
	defer delete(latencies)
	peak_rps: f64 = 0
	window_start := time.tick_now()

	start := time.tick_now()
	for i in 0 ..< N {
		iter_start := time.tick_now()

		http.request_arena_reset(&ra)
		arena_alloc := http.request_arena_allocator(&ra)

		request: http.Http_Request
		http.parse_request(&request, transmute([]u8)string(GET_REQUEST_RAW), config, arena_alloc)

		handler := http.router_match(&router, request.method, request.path)
		if handler == nil { handler = http.not_found_handler }

		response := http.Http_Response{}
		response.headers = make([dynamic]http.Header, 0, 16, arena_alloc)
		handler(&request, &response, arena_alloc)
		http.response_set_header(&response, "Connection", "keep-alive", arena_alloc)
		_ = http.response_serialize(&response, arena_alloc)

		ns := time.duration_nanoseconds(time.tick_diff(iter_start, time.tick_now()))
		latencies[i] = ns
		if ns < r.min_ns { r.min_ns = ns }
		if ns > r.max_ns { r.max_ns = ns }

		if (i + 1) % WINDOW == 0 {
			wnd_ns := time.duration_nanoseconds(time.tick_diff(window_start, time.tick_now()))
			if wnd_ns > 0 {
				wnd_rps := f64(WINDOW) / (f64(wnd_ns) / 1e9)
				if wnd_rps > peak_rps { peak_rps = wnd_rps }
			}
			window_start = time.tick_now()
		}
	}
	r.total_ns = time.duration_nanoseconds(time.tick_diff(start, time.tick_now()))

	http.request_arena_destroy(&ra, alloc)
	finish_result(&r, &ta, len(GET_REQUEST_RAW))
	r.peak_ops_per_sec = peak_rps
	slice.sort(latencies)
	r.p50_ns = latencies[(N - 1) * 50 / 100]
	r.p99_ns = latencies[(N - 1) * 99 / 100]
	mem.tracking_allocator_destroy(&ta)
	return r
}

// ────────────────────────────────────────────────────
// HTML Report generation
// ────────────────────────────────────────────────────

generate_html_report :: proc(results: []Bench_Result) {
	b, _ := strings.builder_make(0, 65536)

	strings.write_string(&b, `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Ragnarok HTTP - Benchmark Report</title>
<style>
  :root {
    --bg: #0d1117; --surface: #161b22; --border: #30363d;
    --text: #e6edf3; --muted: #8b949e; --accent: #58a6ff;
    --green: #3fb950; --orange: #d29922; --red: #f85149;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); padding: 2rem; line-height: 1.5;
  }
  h1 { font-size: 1.75rem; margin-bottom: 0.25rem; }
  .subtitle { color: var(--muted); margin-bottom: 2rem; font-size: 0.9rem; }
  .category { margin-bottom: 2.5rem; }
  .category h2 {
    font-size: 1.1rem; color: var(--accent); border-bottom: 1px solid var(--border);
    padding-bottom: 0.5rem; margin-bottom: 1rem;
  }
  table {
    width: 100%; border-collapse: collapse; font-size: 0.85rem;
    background: var(--surface); border-radius: 8px; overflow: hidden;
  }
  th {
    text-align: left; padding: 0.6rem 1rem; background: var(--border);
    color: var(--muted); font-weight: 600; font-size: 0.75rem;
    text-transform: uppercase; letter-spacing: 0.05em;
  }
  td { padding: 0.6rem 1rem; border-top: 1px solid var(--border); }
  tr:hover td { background: rgba(88,166,255,0.04); }
  .num { text-align: right; font-variant-numeric: tabular-nums; font-family: 'SF Mono', 'Cascadia Code', Consolas, monospace; }
  .bar-cell { width: 120px; }
  .bar-bg { background: var(--border); border-radius: 4px; height: 8px; }
  .bar-fill { height: 8px; border-radius: 4px; background: var(--green); }
  .summary-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 1rem; margin-bottom: 2rem;
  }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 1rem;
  }
  .card .label { font-size: 0.75rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
  .card .value { font-size: 1.5rem; font-weight: 700; margin-top: 0.25rem; font-family: 'SF Mono', 'Cascadia Code', Consolas, monospace; }
  .card .unit  { font-size: 0.8rem; color: var(--muted); }
  footer { margin-top: 3rem; color: var(--muted); font-size: 0.75rem; text-align: center; }
</style>
</head>
<body>
<h1>Ragnarok HTTP - Benchmark Report</h1>
<p class="subtitle">Generated by ragnarok benchmark suite</p>
`)

	// Summary cards
	total_ops := 0
	fastest_ns: f64 = 1e18
	total_allocs := 0
	cycle_ops_sec: f64 = 0
	peak_rps: f64 = 0
	best_p99: i64 = 0
	for &r in results {
		total_ops += r.iterations
		if r.avg_ns < fastest_ns { fastest_ns = r.avg_ns }
		total_allocs += r.total_allocs
		if r.name == "Full request cycle" { cycle_ops_sec = r.ops_per_sec }
		if r.peak_ops_per_sec > peak_rps { peak_rps = r.peak_ops_per_sec }
		if r.p99_ns > 0 && (best_p99 == 0 || r.p99_ns < best_p99) { best_p99 = r.p99_ns }
	}

	strings.write_string(&b, `<div class="summary-grid">`)
	write_card(&b, "Total Benchmarks", fmt.tprintf("%d", len(results)), "")
	write_card(&b, "Total Operations", format_int_comma(total_ops), "")
	write_card(&b, "Req/sec (full cycle)", format_number(cycle_ops_sec, 0), "req/s")
	write_card(&b, "Peak Req/sec", format_number(peak_rps, 0), "req/s")
	write_card(&b, "Best P99 Latency", format_int_comma(int(best_p99)), "ns")
	write_card(&b, "Fastest Avg", format_number(fastest_ns, 1), "ns/op")
	strings.write_string(&b, `</div>`)

	categories := [?]string{
		"Memory",
		"Allocation Rate",
		"CPU / Parsing",
		"CPU / Routing",
		"CPU / Serialization",
		"Requests/sec",
		"Concurrent Requests",
		"Throughput",
	}

	for cat in categories {
		cat_results: [dynamic]^Bench_Result
		defer delete(cat_results)
		for &r in results {
			if r.category == cat { append(&cat_results, &r) }
		}
		if len(cat_results) == 0 { continue }

		max_ops: f64 = 0
		for r in cat_results {
			if r.ops_per_sec > max_ops { max_ops = r.ops_per_sec }
		}

		has_latency := false
		for r in cat_results {
			if r.p99_ns > 0 { has_latency = true; break }
		}

		strings.write_string(&b, `<div class="category"><h2>`)
		strings.write_string(&b, cat)
		strings.write_string(&b, `</h2><table><thead><tr>`)
		strings.write_string(&b, `<th>Benchmark</th>`)
		strings.write_string(&b, `<th class="num">Iterations</th>`)
		strings.write_string(&b, `<th class="num">Avg (ns/op)</th>`)
		strings.write_string(&b, `<th class="num">Min (ns)</th>`)
		strings.write_string(&b, `<th class="num">Max (ns)</th>`)
		if has_latency {
			strings.write_string(&b, `<th class="num">Req/sec</th>`)
			strings.write_string(&b, `<th class="num">P50 (ns)</th>`)
			strings.write_string(&b, `<th class="num">P99 (ns)</th>`)
			strings.write_string(&b, `<th class="num">Peak Req/sec</th>`)
		} else {
			strings.write_string(&b, `<th class="num">Ops/sec</th>`)
		}
		strings.write_string(&b, `<th class="num">Allocs/op</th>`)
		strings.write_string(&b, `<th class="num">Bytes/op</th>`)
		strings.write_string(&b, `<th class="num">MB/s</th>`)
		strings.write_string(&b, `<th class="bar-cell">Relative</th>`)
		strings.write_string(&b, `</tr></thead><tbody>`)

		for r in cat_results {
			strings.write_string(&b, `<tr>`)
			write_td(&b, r.name, false)
			write_td(&b, format_int_comma(r.iterations), true)
			write_td(&b, format_number(r.avg_ns, 1), true)
			write_td(&b, format_int_comma(int(r.min_ns)), true)
			write_td(&b, format_int_comma(int(r.max_ns)), true)
			write_td(&b, format_number(r.ops_per_sec, 0), true)
			if has_latency {
				if r.p50_ns > 0 {
					write_td(&b, format_int_comma(int(r.p50_ns)), true)
				} else {
					write_td(&b, "-", true)
				}
				if r.p99_ns > 0 {
					write_td(&b, format_int_comma(int(r.p99_ns)), true)
				} else {
					write_td(&b, "-", true)
				}
				if r.peak_ops_per_sec > 0 {
					write_td(&b, format_number(r.peak_ops_per_sec, 0), true)
				} else {
					write_td(&b, "-", true)
				}
			}
			write_td(&b, format_number(r.allocs_per_op, 1), true)
			write_td(&b, format_number(r.bytes_per_op, 0), true)
			if r.throughput_mb_s > 0 {
				write_td(&b, format_number(r.throughput_mb_s, 1), true)
			} else {
				write_td(&b, "-", true)
			}
			pct := (r.ops_per_sec / max_ops * 100) if max_ops > 0 else 0
			write_bar(&b, pct)
			strings.write_string(&b, `</tr>`)
		}

		strings.write_string(&b, `</tbody></table></div>`)
	}

	strings.write_string(&b, `<footer>Ragnarok HTTP Server - Benchmark Suite</footer>`)
	strings.write_string(&b, `</body></html>`)

	report := strings.to_string(b)
	write_err := os.write_entire_file("benchmark_report.html", transmute([]u8)report)
	if write_err == nil {
		fmt.println("  Report written to benchmark_report.html")
	} else {
		fmt.printf("  ERROR: Failed to write benchmark_report.html: %v\n", write_err)
	}
}

// HTML helpers

write_card :: proc(b: ^strings.Builder, label, value, unit: string) {
	strings.write_string(b, `<div class="card"><div class="label">`)
	strings.write_string(b, label)
	strings.write_string(b, `</div><div class="value">`)
	strings.write_string(b, value)
	if len(unit) > 0 {
		strings.write_string(b, ` <span class="unit">`)
		strings.write_string(b, unit)
		strings.write_string(b, `</span>`)
	}
	strings.write_string(b, `</div></div>`)
}

write_td :: proc(b: ^strings.Builder, content: string, is_num: bool) {
	if is_num {
		strings.write_string(b, `<td class="num">`)
	} else {
		strings.write_string(b, `<td>`)
	}
	strings.write_string(b, content)
	strings.write_string(b, `</td>`)
}

write_bar :: proc(b: ^strings.Builder, pct: f64) {
	strings.write_string(b, `<td class="bar-cell"><div class="bar-bg"><div class="bar-fill" style="width:`)
	strings.write_string(b, format_number(pct, 0))
	strings.write_string(b, `%"></div></div></td>`)
}

format_number :: proc(n: f64, decimals: int) -> string {
	if decimals == 0 {
		return fmt.tprintf("%.0f", n)
	} else {
		return fmt.tprintf("%.1f", n)
	}
}

format_int_comma :: proc(n: int) -> string {
	raw := fmt.tprintf("%d", n)
	if len(raw) <= 3 { return raw }

	result: [64]u8
	ri := 0
	digits := 0
	start_idx := 0
	if raw[0] == '-' {
		result[0] = '-'
		ri = 1
		start_idx = 1
	}
	total_digits := len(raw) - start_idx
	for i in start_idx ..< len(raw) {
		remaining := total_digits - digits
		if digits > 0 && remaining % 3 == 0 {
			result[ri] = ','
			ri += 1
		}
		result[ri] = raw[i]
		ri += 1
		digits += 1
	}
	return fmt.tprintf("%s", string(result[:ri]))
}

// ────────────────────────────────────────────────────
// Main
// ────────────────────────────────────────────────────

main :: proc() {
	fmt.println("=========================================================")
	fmt.println("  Ragnarok HTTP - Benchmark Suite")
	fmt.println("=========================================================")
	fmt.println()

	results: [dynamic]Bench_Result
	defer delete(results)

	run_one :: proc(results: ^[dynamic]Bench_Result, bench: proc() -> Bench_Result) {
		r := bench()
		print_result(&r)
		append(results, r)
	}

	// Memory
	run_one(&results, bench_arena_init_destroy)
	run_one(&results, bench_arena_allocations)
	run_one(&results, bench_arena_reset_reuse)
	run_one(&results, bench_pool_acquire_release)

	// Allocation Rate
	run_one(&results, bench_alloc_rate_small)
	run_one(&results, bench_alloc_rate_mixed)

	// CPU / Parsing
	run_one(&results, bench_parse_get)
	run_one(&results, bench_parse_post)
	run_one(&results, bench_parse_many_headers)

	// CPU / Routing
	run_one(&results, bench_router_match)
	run_one(&results, bench_router_miss)

	// CPU / Serialization
	run_one(&results, bench_response_serialize_small)
	run_one(&results, bench_response_serialize_large)
	run_one(&results, bench_format_error_response)

	// Requests/sec
	run_one(&results, bench_full_request_cycle)

	// Concurrent Requests
	run_one(&results, bench_concurrent_connections)
	run_one(&results, bench_pool_burst)

	// Throughput (avg/peak req/s, p99 latency)
	run_one(&results, bench_throughput_1)
	run_one(&results, bench_throughput_8)
	run_one(&results, bench_throughput_32)
	run_one(&results, bench_throughput_64)
	run_one(&results, bench_throughput_128)
	run_one(&results, bench_throughput_keepalive)

	fmt.println()
	fmt.println("=========================================================")
	fmt.println("  Generating HTML report...")
	generate_html_report(results[:])
	fmt.println("=========================================================")
}
