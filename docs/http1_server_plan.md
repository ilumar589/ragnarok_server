# Ragnarok HTTP/1.1 Server — Implementation Plan

## Overview

A high-performance HTTP/1.1 server written in Odin, built on top of `core:nbio` (non-blocking I/O with IOCP on Windows, io_uring on Linux, kQueue on macOS) and `core:thread` for worker pools. The design follows data-oriented principles with explicit allocators, arena-per-request lifetime management, and structure-of-arrays layouts where applicable.

---

## Architecture Summary

```
Main Thread (Event Loop)
  │
  ├── nbio.listen_tcp → accept loop
  │
  └── on accept → dispatch to Thread Pool
                      │
                      ├── Worker Thread 1 (own event loop)
                      ├── Worker Thread 2 (own event loop)
                      ├── ...
                      └── Worker Thread N (own event loop)
                            │
                            └── Per-request arena allocator
                                  ├── recv raw bytes
                                  ├── parse HTTP request
                                  ├── route → handler
                                  ├── build HTTP response
                                  ├── send response
                                  └── free arena (all request memory gone)
```

---

## Packages / Imports Used

| Package | Purpose |
|---|---|
| `core:nbio` | Non-blocking I/O event loop, TCP listen/accept/recv/send |
| `core:net` | TCP socket types, endpoint types, address constants |
| `core:thread` | Thread pool for worker threads |
| `core:mem` | Arena allocator, allocator interface |
| `core:fmt` | Logging / debug output |
| `core:strings` | String building for responses |
| `core:bytes` | Byte buffer utilities |
| `core:strconv` | Number ↔ string conversions (Content-Length, status codes) |
| `core:time` | Timestamps for Date header, timeouts |
| `core:log` | Structured logging |

---

## Implementation Steps

### Phase 1: Project Skeleton & TCP Accept Loop

- [ ] **1.1 — Project structure setup**
  - Create the following source files:
    - `ragnarok.odin` — entry point, server bootstrap
    - `server.odin` — server config, lifecycle (init, start, shutdown)
    - `connection.odin` — per-connection state and management
    - `request.odin` — HTTP request parsing types and procedures
    - `response.odin` — HTTP response building and sending
    - `router.odin` — route registration and dispatch
    - `allocators.odin` — arena and fixed-buffer allocator helpers
  - All files in `package main`

- [ ] **1.2 — Server config struct**
  - Define `Server_Config` with: host, port, max_connections, worker_count, read_buffer_size, request_arena_size
  - All sizes should have sensible defaults

- [ ] **1.3 — Event loop bootstrap**
  - In `main`, call `nbio.acquire_thread_event_loop()`
  - Call `nbio.listen_tcp({nbio.IP4_Any, port})` to bind and listen
  - Call `nbio.accept_poly(server_socket, &workers, on_accept)` to start accepting
  - Call `nbio.run()` to block the main thread on the event loop

- [ ] **1.4 — Thread pool initialization**
  - Use `thread.Pool` with configurable worker count (default: number of CPU cores)
  - Initialize before starting the event loop
  - Each worker task gets the accepted client socket + server context

- [ ] **1.5 — Accept callback and connection dispatch**
  - In `on_accept`: re-register accept for next connection, dispatch work to thread pool
  - Pass `Connection` struct (client socket, remote endpoint, event loop ref) to worker

### Phase 2: Memory Management

- [ ] **2.1 — Explicit allocator parameter convention**
  - Every procedure that allocates takes an `allocator: mem.Allocator` as its last parameter
  - No reliance on implicit `context.allocator` — always explicit for visibility

- [ ] **2.2 — Request arena allocator**
  - Each request gets its own `mem.Arena` backed by a chunk from the general-purpose allocator
  - Default chunk size: 8 KiB (configurable via `Server_Config.request_arena_size`)
  - Arena is initialized at the start of request handling and freed entirely when the response is sent
  - Pattern:
    ```odin
    arena: mem.Arena
    mem.arena_init(&arena, chunk_from_gpa)
    defer mem.arena_destroy(&arena)
    request_allocator := mem.arena_allocator(&arena)
    // ... all request parsing and response building uses request_allocator ...
    ```

- [ ] **2.3 — Fixed-buffer allocators for hot paths**
  - Use `mem.Arena` initialized with a stack-local fixed buffer (`[4096]u8`) for small, bounded allocations (e.g., header name/value scratch space, small string building)
  - Falls back to arena if fixed buffer is exhausted (arena supports this with `mem.arena_init` on a fixed `[]u8`)

### Phase 3: HTTP/1.1 Request Parsing

- [ ] **3.1 — Request types**
  ```odin
  Http_Method :: enum {
      GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS, TRACE, CONNECT,
  }

  Http_Version :: enum {
      HTTP_1_0,
      HTTP_1_1,
  }

  Header :: struct {
      name:  string,
      value: string,
  }

  Http_Request :: struct {
      method:         Http_Method,
      uri:            string,         // raw request URI e.g. "/path?query=1"
      path:           string,         // just the path portion
      query_string:   string,         // raw query string (after '?')
      version:        Http_Version,
      headers:        []Header,       // SOA candidate if count is high
      body:           []u8,
      content_length: int,
      keep_alive:     bool,
  }
  ```

- [ ] **3.2 — Request-line parser**
  - Parse: `METHOD SP Request-URI SP HTTP-Version CRLF`
  - Validate method, extract URI, parse version
  - All strings are slices into the receive buffer (zero-copy where possible)

- [ ] **3.3 — Header parser**
  - Parse: `Field-Name ":" OWS Field-Value OWS CRLF` repeated until empty line `CRLF`
  - Limit max headers (default: 64)
  - Limit max header size (default: 8 KiB)
  - Extract `Content-Length`, `Connection` (keep-alive / close), `Host`, `Transfer-Encoding`

- [ ] **3.4 — Body reading**
  - If `Content-Length` present: read exactly that many bytes
  - If `Transfer-Encoding: chunked`: implement chunked decoding (stretch goal — skip for MVP)
  - For MVP: support `Content-Length`-based body reading only

- [ ] **3.5 — Incremental receive buffer**
  - Recv into a fixed buffer (default: 8 KiB)
  - If request is incomplete, continue receiving
  - Detect end of headers (`\r\n\r\n`) then read body based on Content-Length
  - Handle partial reads correctly (TCP framing)

### Phase 4: HTTP/1.1 Response Building & Sending

- [ ] **4.1 — Response types**
  ```odin
  Http_Status :: enum u16 {
      OK                    = 200,
      Created               = 201,
      No_Content            = 204,
      Bad_Request           = 400,
      Not_Found             = 404,
      Method_Not_Allowed    = 405,
      Request_Timeout       = 408,
      Internal_Server_Error = 500,
      Not_Implemented       = 501,
  }

  Http_Response :: struct {
      status:       Http_Status,
      headers:      [dynamic]Header,
      body:         []u8,
  }
  ```

- [ ] **4.2 — Response serialization**
  - Build status line: `HTTP/1.1 STATUS_CODE REASON_PHRASE\r\n`
  - Append headers: auto-add `Content-Length`, `Date`, `Connection`, `Server: Ragnarok`
  - Append `\r\n` separator, then body
  - Serialize into a contiguous `[]u8` buffer from the request arena

- [ ] **4.3 — Send response via nbio**
  - Use `nbio.send` with the serialized buffer
  - On completion callback: if keep-alive, re-register recv for next request; otherwise close socket
  - Use `nbio.close` to clean up the socket when done

### Phase 5: Router & Handler System

- [ ] **5.1 — Route registration**
  ```odin
  Handler_Proc :: proc(request: ^Http_Request, response: ^Http_Response, allocator: mem.Allocator)

  Route :: struct {
      method:  Http_Method,
      path:    string,
      handler: Handler_Proc,
  }
  ```
  - Store routes in a fixed-size or dynamic array
  - Support exact path matching for MVP
  - Prefix/pattern matching as stretch goal

- [ ] **5.2 — Route dispatch**
  - Match incoming request method + path against registered routes
  - If no match: 404 Not Found
  - If method mismatch on known path: 405 Method Not Allowed

- [ ] **5.3 — Default handlers**
  - 404 handler (plain text "Not Found")
  - 500 handler (plain text "Internal Server Error")
  - Health check endpoint: `GET /health` → 200 "OK"

### Phase 6: Connection Lifecycle & Keep-Alive

- [ ] **6.1 — Connection struct**
  ```odin
  Connection :: struct {
      socket:          net.TCP_Socket,
      remote_endpoint: net.Endpoint,
      recv_buf:        [8192]u8,        // fixed receive buffer
      recv_len:        int,             // bytes currently in buffer
      keep_alive:      bool,
      request_count:   int,             // requests served on this connection
  }
  ```

- [ ] **6.2 — Keep-alive support**
  - Default: keep-alive for HTTP/1.1, close for HTTP/1.0
  - Respect `Connection: close` / `Connection: keep-alive` headers
  - After sending response, if keep-alive: reset recv buffer, re-register recv
  - Max requests per connection (configurable, default: 100)
  - Idle timeout per connection (configurable, default: 30s)

- [ ] **6.3 — Graceful connection close**
  - On error or connection close: free connection resources
  - Use `nbio.close` to close the socket asynchronously

### Phase 7: Error Handling & Robustness

- [ ] **7.1 — Malformed request handling**
  - If request line is invalid → 400 Bad Request, close connection
  - If headers exceed limits → 400 Bad Request
  - If body exceeds max body size (configurable) → 413 Payload Too Large

- [ ] **7.2 — Timeout handling**
  - Use `nbio` timeout parameters on recv/send operations
  - Read timeout: if headers not received within N seconds → 408 Request Timeout
  - Write timeout: if response send stalls → close connection

- [ ] **7.3 — Logging**
  - Log accepted connections, request method/path, response status, timing
  - Use `core:log` with context-based logger
  - Access log format: `[timestamp] remote_ip "METHOD /path" status_code duration_ms`

### Phase 8: Performance Optimizations

- [ ] **8.1 — Structure of Arrays (SOA) for connection pool**
  - If managing many concurrent connections, use SOA layout:
    ```odin
    Connection_Pool :: struct {
        sockets:    [MAX_CONNECTIONS]net.TCP_Socket,
        endpoints:  [MAX_CONNECTIONS]net.Endpoint,
        recv_bufs:  [MAX_CONNECTIONS][8192]u8,
        recv_lens:  [MAX_CONNECTIONS]int,
        alive:      [MAX_CONNECTIONS]bool,
        count:      int,
    }
    ```
  - Better cache behavior when iterating over one field across all connections

- [ ] **8.2 — sendfile for static files**
  - Use `nbio.sendfile` for zero-copy file serving (stretch goal)
  - Opens file with `nbio.open_sync`, then sends via `nbio.sendfile` to the TCP socket

- [ ] **8.3 — Compile with LTO**
  - Build with `-lto:thin` for cross-package inlining and dead code elimination
  - Build command: `odin build . -opt:speed -lto:thin`

- [ ] **8.4 — TCP_NODELAY**
  - Ensure TCP_NODELAY is set on accepted sockets (Odin defaults to true via `ODIN_NET_TCP_NODELAY_DEFAULT`)
  - Confirm via `net.set_option(socket, .TCP_Nodelay, true)`

### Phase 9: Testing & Validation

- [ ] **9.1 — Manual smoke tests**
  - Start server, curl basic endpoints
  - `curl http://localhost:8080/health`
  - `curl -X POST -d "hello" http://localhost:8080/echo`

- [ ] **9.2 — Keep-alive test**
  - Use `curl --keepalive` or a persistent HTTP client
  - Verify multiple requests on the same TCP connection

- [ ] **9.3 — Load testing**
  - Use `wrk` or `hey` to benchmark: `wrk -t4 -c100 -d10s http://localhost:8080/health`
  - Measure: requests/sec, latency p50/p99, memory usage

- [ ] **9.4 — Edge cases**
  - Partial sends/receives
  - Malformed requests (incomplete headers, wrong Content-Length)
  - Connection reset by client mid-request
  - Concurrent connections at max capacity

---

## File Layout (Target)

```
ragnarok/
├── ragnarok.odin       # entry point: main proc, server bootstrap
├── server.odin         # Server_Config, server init/start/shutdown
├── connection.odin     # Connection struct, lifecycle, pool
├── request.odin        # Http_Request, parsing logic
├── response.odin       # Http_Response, serialization, sending
├── router.odin         # Route registration, dispatch, Handler_Proc
├── allocators.odin     # Arena helpers, fixed-buffer helpers
├── ols.json            # Odin Language Server config
├── docs/
│   ├── performance.md
│   ├── odin_highlights.md
│   └── http1_server_plan.md  ← this file
└── README.md
```

---

## Key API Reference (Quick Look)

### core:nbio essentials
- `nbio.acquire_thread_event_loop()` / `nbio.release_thread_event_loop()` — manage per-thread event loop
- `nbio.listen_tcp(endpoint, backlog)` → `TCP_Socket` — bind + listen
- `nbio.accept_poly(socket, user_data, callback)` — async accept
- `nbio.recv_poly(socket, bufs, user_data, callback)` — async receive
- `nbio.send_poly(socket, bufs, user_data, callback)` — async send
- `nbio.close_poly(socket, user_data, callback)` — async close
- `nbio.run()` — block on event loop until no operations remain
- `nbio.sendfile(socket, file_handle, callback)` — zero-copy file send

### core:mem arena allocator
- `mem.Arena` — arena allocator struct
- `mem.arena_init(&arena, backing_buffer)` — init with fixed buffer
- `mem.arena_allocator(&arena)` — get `Allocator` interface from arena
- `mem.arena_destroy(&arena)` — free arena (if it allocated from a backing allocator)

---

## Build & Run

```sh
# Debug build
odin build . -out:ragnarok.exe

# Optimized build
odin build . -opt:speed -out:ragnarok.exe

# Optimized build with LTO
odin build . -opt:speed -lto:thin -out:ragnarok.exe

# Run
./ragnarok.exe
```

---

## Milestones

| Milestone | Phases | Goal |
|---|---|---|
| **M1 — Echo Server** | 1, 2, 3, 4 | Accept TCP, parse HTTP request, return hardcoded 200 response |
| **M2 — Routing** | 5 | Register routes, dispatch to handlers, 404/405 |
| **M3 — Keep-Alive** | 6 | Persistent connections, idle timeout |
| **M4 — Robust** | 7 | Error handling, timeouts, malformed request protection |
| **M5 — Fast** | 8 | SOA, sendfile, LTO, benchmarks |
| **M6 — Validated** | 9 | Load tested, edge cases handled |
