# Ragnarok — Architecture & Developer Guide

Welcome to the Ragnarok codebase. This document explains how the HTTP server works from the ground up, covering the threading model, how a request flows through the system, memory management, and how each source file fits together.

---

## Table of Contents

1. [Project Layout](#project-layout)
2. [High-Level Architecture](#high-level-architecture)
3. [Threading Model](#threading-model)
4. [Life of a Request](#life-of-a-request)
5. [The Connection Pool (`#soa`)](#the-connection-pool)
6. [Memory Management](#memory-management)
7. [Static File Serving (sendfile)](#static-file-serving)
8. [Router & Handlers](#router--handlers)
9. [File-by-File Reference](#file-by-file-reference)
10. [Building & Running](#building--running)
11. [Key Odin Concepts to Know](#key-odin-concepts-to-know)

---

## Project Layout

```
ragnarok.odin              ← Entry point (package main). Configures & starts the server.
ragnarok_http/             ← HTTP server library (package ragnarok_http)
  ├── server.odin          ← Server config, lifecycle (init / start / stop)
  ├── pool.odin            ← #soa connection pool + Conn_Ref handles
  ├── connection.odin      ← I/O callbacks (accept/recv/send), worker task, helpers
  ├── request.odin         ← HTTP request types + zero-copy parser
  ├── response.odin        ← HTTP response types + serializer
  ├── router.odin          ← Fixed-size route table + default handlers
  ├── static.odin          ← Static file serving via zero-copy sendfile
  └── allocators.odin      ← Per-request arena allocator helpers
static/                    ← Static files served by sendfile (when configured)
  ├── index.html
  └── style.css
docs/
  ├── architecture.md      ← You are here
  ├── http1_server_plan.md ← Original implementation plan & checklist
  └── ...
```

---

## High-Level Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                     Main Thread (I/O)                        │
│                                                              │
│  nbio Event Loop (IOCP on Windows / io_uring on Linux)       │
│    ├── accept  →  pool_acquire  →  recv                      │
│    ├── recv complete  →  dispatch to worker thread            │
│    ├── send complete  →  [sendfile chain]  →  keep-alive     │
│    └── close  →  pool_release                                │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│               Worker Thread Pool (N threads)                 │
│                                                              │
│    task:  parse request  →  route  →  handler  →             │
│           serialize response  →  queue send to I/O thread    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

There are exactly **two kinds of threads**:

| Thread | Count | Role |
|--------|-------|------|
| **I/O thread** | 1 (main thread) | Runs the `nbio` event loop. Handles all async I/O: accept, recv, send, sendfile, close. Never blocks. |
| **Worker threads** | N (cpu cores − 1) | Run CPU-bound work: parse HTTP, route, execute handler, serialize response. |

---

## Threading Model

### The I/O Thread (main)

The main thread calls `nbio.run()` which blocks in the OS completion port (IOCP / io_uring). When a network event completes, nbio calls our callback — `on_accept`, `on_recv`, `on_send`, `on_sendfile_complete`, etc. These callbacks run on the main thread and must **never block**.

All socket operations (`recv_poly`, `send_poly`, `sendfile_poly`, `close`) are initiated from callback code. The `_poly` suffix means "polymorphic" — it lets us pass a typed user-data pointer (our `^Conn_Ref`) that is returned in the callback.

### Worker Threads

When a complete HTTP request has been received (`on_recv` finds `\r\n\r\n` and verifies body length), the connection is handed to a worker via:

```odin
thread.pool_add_task(&server.workers, context.allocator, process_request_task, ref)
```

The worker parses, routes, runs the handler, serializes, then **queues the send back to the I/O thread** by passing `l = pool.server.loop` to `nbio.send_poly`. This cross-thread queuing is safe because nbio's event loop supports it natively.

### Thread Safety Rules

- **Pool acquire/release** — only called from the I/O thread. No locks needed.
- **`pool.conns[s]` fields** — written by the I/O thread (accept, recv callbacks) or by the owning worker task. There's no concurrent access because a slot is either being serviced by the I/O thread *or* dispatched to a single worker, never both simultaneously.
- **`pool.request_arenas[s]`** — allocated by the worker, freed by the I/O thread (in `on_send` or `connection_close`), but never touched concurrently.

---

## Life of a Request

Here's the complete journey of an HTTP request through the system:

```
1.  Client connects
        ↓
2.  on_accept (I/O thread)
      • Re-arm accept for next client
      • pool_acquire → get a free Conn_Ref (slot index)
      • Set TCP_NODELAY, store socket + endpoint in pool.conns[slot]
      • Call connection_start_recv
        ↓
3.  connection_start_recv (I/O thread)
      • Slice into pool.conns[slot].recv_buf at current recv_len offset
      • Call nbio.recv_poly with idle timeout
        ↓
4.  on_recv (I/O thread)
      • Handle errors, timeouts, peer close
      • Accumulate bytes in recv_buf, advance recv_len
      • Scan for \r\n\r\n (end of headers)
      • If headers incomplete → loop back to step 3
      • Quick-scan Content-Length; if body incomplete → loop back to step 3
      • Dispatch: thread.pool_add_task → process_request_task
        ↓
5.  process_request_task (worker thread)
      • Allocate a Request_Arena (8 KiB heap-backed arena)
      • Parse HTTP request (zero-copy slices into recv_buf)
      • Route: exact path match in router, or try static file
      • Execute handler (user code like index_handler, echo_handler)
      • Serialize response into arena-allocated buffer
      • Log access line: "127.0.0.1:54321 "GET /path" 200 1.2ms"
      • Queue: nbio.send_poly(socket, buf, ref, on_send, l = server.loop)
        ↓
6.  on_send (I/O thread)
      • If sendfile_pending → chain nbio.sendfile_poly (static files)
      • Otherwise: destroy request_arena, free all request memory
      • If keep_alive → reset recv_len, go back to step 3
      • If !keep_alive → connection_close → pool_release
        ↓
7.  (Optional) on_sendfile_complete (I/O thread)
      • Close file handle, destroy request arena
      • Keep-alive or close, same as step 6
```

---

## The Connection Pool

### Why SOA?

Traditional servers do `new(Connection)` on accept and `free(conn)` on close. That's a heap allocation per connection, and the fields are interleaved in memory (Array-of-Structs). When you need to sweep one field across all connections (e.g. checking timeouts), you touch scattered cache lines.

Ragnarok uses Odin's native `#soa` (Structure-of-Arrays) directive:

```odin
Connection_Pool :: struct {
    conns: #soa[]Connection,   // each field → its own contiguous array
    ...
}
```

The compiler transforms this so that `pool.conns.socket` is a contiguous `[]TCP_Socket`, `pool.conns.endpoint` is a contiguous `[]Endpoint`, etc. Sweeping one field now touches contiguous memory, and there are **zero** per-connection heap allocations.

### Conn_Ref — The Stable Handle

Every async callback needs a pointer that remains valid. We can't use `&pool.conns[s]` because SOA subscripts are temporary values. Instead, each slot has a `Conn_Ref`:

```odin
Conn_Ref :: struct {
    pool: ^Connection_Pool,
    slot: int,             // index into the pool arrays
}
```

These live in `pool.refs[]` (a regular slice allocated once at startup). `&pool.refs[slot]` is stable for the pool's lifetime, so it's safe to hand to overlapped I/O, thread pool tasks, or any deferred callback.

All field access goes through the slot index:

```odin
pool.conns[s].socket          // read/write a field
pool.conns[s].keep_alive      // another field
&pool.conns.recv_buf[s]       // pointer to the recv buffer (for slicing into it)
pool.request_arenas[s]        // arena is stored separately (see below)
```

### Free-Stack

Available slots are tracked with a LIFO stack (`free_stack[]` + `free_count`). Acquire pops, release pushes. Most-recently-released slots are reused first for better cache temporal locality.

### Why `request_arenas` Is Separate

`Request_Arena` contains a `mem.Arena` which has internal pointers. Due to a limitation in the Odin compiler's LLVM backend, taking `&pool.conns.request_arena[s]` on an `#soa` multi-pointer to a complex struct triggers a panic. Keeping it as a separate `[]Request_Arena` sidesteps this while preserving SOA layout for the hot connection fields.

---

## Memory Management

### The Request Arena Pattern

Every HTTP request gets a `Request_Arena` — a bump allocator backed by an 8 KiB heap buffer:

```
request_arena_init  → allocates 8 KiB backing buffer from heap
  ↓
arena_allocator     → returns mem.Allocator pointing into the arena
  ↓
(all per-request allocations: parsed headers, response builder, etc.)
  ↓
request_arena_destroy → frees the single 8 KiB buffer, releasing everything
```

This means the entire request lifecycle does exactly **one** heap allocation and **one** free. No individual string/header/buffer frees needed. Handlers receive this allocator and should use it for any temporary allocations.

### Allocation Rules

| Context | Allocator to use | Freed when |
|---------|-----------------|------------|
| Handler code | `allocator` parameter (the request arena) | Response sent |
| Per-request strings, headers | Arena allocator | Response sent |
| Error response buffers | `make([]u8, 256)` from heap | Stored on `request_arena.backing`, freed in `on_send` |
| Pool arrays | `context.allocator` at startup | Server shutdown |

---

## Static File Serving

When `config.static_root` is set (e.g. `"static"`), unmatched routes fall back to static file serving. The flow:

1. **Worker thread** (`try_serve_static_file`):
   - Validates path (rejects `..`, null bytes)
   - Opens file with `os.open` to get size via `os.file_size`
   - Closes the OS handle, reopens with `nbio.open_sync` (associates with IOCP)
   - Stores the nbio handle in `pool.conns[s].sendfile_handle`
   - Sets `pool.conns[s].sendfile_pending = true`
   - Populates `Content-Type` (MIME lookup) and `Content-Length` headers
   - The response body is **empty** — data will come from sendfile

2. **I/O thread** (`on_send`):
   - After headers are sent, sees `sendfile_pending == true`
   - Calls `nbio.sendfile_poly` — OS copies file data directly to the socket (zero-copy on Windows via TransmitFile, on Linux via sendfile(2))

3. **I/O thread** (`on_sendfile_complete`):
   - Closes file handle, frees arena, handles keep-alive/close

This avoids reading file contents into userspace entirely.

---

## Router & Handlers

### Route Registration

Routes are stored in a fixed-size array (`MAX_ROUTES = 128`). Registration happens in `ragnarok.odin` before the server starts:

```odin
http.router_add_route(&server.router, .GET, "/", index_handler)
http.router_add_route(&server.router, .POST, "/echo", echo_handler)
```

A `/health` endpoint is registered automatically in `server_init`.

### Route Matching

Matching is exact path comparison (no patterns/wildcards). If the path matches but the method doesn't, `method_not_allowed_handler` is returned (405). If nothing matches and `static_root` is configured, static file serving is attempted. Otherwise, `not_found_handler` returns 404.

### Writing a Handler

A handler has this signature:

```odin
my_handler :: proc(
    request:   ^Http_Request,   // parsed request (method, path, headers, body)
    response:  ^Http_Response,  // you fill this in
    allocator: mem.Allocator,   // per-request arena — use for any allocations
) {
    response.status = .OK
    response_set_body_string(response, "Hello!", "text/plain", allocator)
}
```

**Rules:**
- Always set `response.status`
- Use `response_set_body` / `response_set_body_string` to set the body and Content-Type
- Use `response_set_header` to add custom headers
- Use the provided `allocator` for any memory you need — it's freed automatically after the response is sent
- Don't hold references to request data beyond the handler call

---

## File-by-File Reference

### `ragnarok.odin`
Entry point. Creates a `Server_Config`, initializes the server, registers application routes, and calls `server_start` (which blocks on the event loop).

### `ragnarok_http/server.odin`
- **`Server_Config`** — All tunables: port, max connections, buffer sizes, timeouts, static root
- **`Server`** — Runtime state: config, listen socket, router, thread pool, event loop pointer, connection pool
- **`server_init`** — Stores config, initializes router, registers `/health`
- **`server_start`** — Acquires event loop, initializes pool, starts workers, binds socket, calls `nbio.run()` (blocks)
- **`server_stop`** — Closes listen socket

### `ragnarok_http/pool.odin`
- **`Connection`** — Per-connection fields: socket, endpoint, recv buffer, keep-alive flag, sendfile state, etc. Stored as `#soa` in the pool.
- **`Conn_Ref`** — Stable `{pool, slot}` handle for async callbacks
- **`Connection_Pool`** — `#soa[]Connection` + `[]Request_Arena` + `[]Conn_Ref` + LIFO free-stack
- **`pool_init` / `pool_destroy`** — Allocate/free all pool memory
- **`pool_acquire`** — Pop a free slot (O(1)), reset its state, return `^Conn_Ref`
- **`pool_release`** — Push slot back onto free stack (O(1))

### `ragnarok_http/connection.odin`
The heart of the server. Contains all the I/O callbacks and the worker task:

- **`on_accept`** — Accepts a client, acquires a pool slot, starts recv
- **`connection_start_recv`** — Initiates async recv into the slot's buffer
- **`on_recv`** — Handles recv completion, checks for complete request, dispatches to worker
- **`process_request_task`** — Worker thread entry: parse → route → handle → serialize → queue send
- **`on_send`** — Send complete: chain sendfile if pending, otherwise free arena + keep-alive/close
- **`send_error_response`** / **`queue_error_response`** — Send HTTP error responses from I/O or worker thread
- **`connection_close`** — Cleanup: destroy arena, close socket, release pool slot
- Helper functions: `find_header_end`, `scan_content_length`, `copy_to`, `write_int_to_buf`, `method_to_string`

### `ragnarok_http/request.odin`
- **`Http_Method`** — Enum: GET, POST, PUT, DELETE, etc.
- **`Http_Request`** — Parsed request: method, path, query string, headers, body, content length
- **`parse_request`** — Zero-copy HTTP/1.1 parser. Strings are slices into the recv buffer (no copies). Validates header count, size limits, URI length, content-length sign.

### `ragnarok_http/response.odin`
- **`Http_Status`** — Enum: 200, 400, 404, 408, 413, 500, etc.
- **`Http_Response`** — Status + dynamic header list + body bytes
- **`response_serialize`** — Builds the complete HTTP response as a byte buffer. Auto-adds Content-Length (unless already set for sendfile), Server, and Date headers.
- **`format_http_date`** — RFC 7231 date formatting

### `ragnarok_http/router.odin`
- **`Handler_Proc`** — The handler function signature
- **`Router`** — Fixed array of `Route` structs (method + path + handler)
- **`router_match`** — Exact path match, returns handler or 405/nil
- Built-in handlers: `health_handler`, `not_found_handler`, `method_not_allowed_handler`

### `ragnarok_http/static.odin`
- **`try_serve_static_file`** — Path validation, file open/stat, nbio handle setup, MIME + Content-Length headers
- **`on_sendfile_complete`** — Cleanup after zero-copy transfer
- **`mime_from_extension`** — Maps ~30 file extensions to MIME types
- **`build_file_path`** / **`path_extension`** — Path utilities

### `ragnarok_http/allocators.odin`
- **`Request_Arena`** — Arena + backing buffer wrapper
- **`request_arena_init`** / **`request_arena_allocator`** / **`request_arena_reset`** / **`request_arena_destroy`**

---

## Building & Running

### Debug Build
```
odin build . -out:ragnarok.exe -warnings-as-errors
```

### Optimized Build
```
odin build . -out:ragnarok.exe -o:speed -lto:thin
```

### Running
```
.\ragnarok.exe
```
The server starts on port 8080 by default. Test with:
```
curl http://localhost:8080/health       # → 200 "OK"
curl http://localhost:8080/             # → 200 "Welcome to Ragnarok"
curl -X POST -d "hello" http://localhost:8080/echo  # → 200 echoes body back
curl http://localhost:8080/index.html   # → 200 static HTML via sendfile
curl http://localhost:8080/style.css    # → 200 static CSS via sendfile
```

### Configuration
All tunables are in `Server_Config` (see `server.odin`). Override them in `ragnarok.odin` before calling `server_start`:
```odin
config := http.default_server_config()
config.port = 9090
config.max_connections = 4096
config.static_root = "public"  // or "" to disable static serving
```

---

## Key Odin Concepts to Know

If you're new to Odin, here are the language features used heavily in this codebase:

| Concept | Where Used | What It Does |
|---------|-----------|--------------|
| `#soa[]T` | `pool.odin` | Compiler splits struct fields into parallel arrays (Structure of Arrays) |
| `mem.Arena` | `allocators.odin` | Bump allocator — allocations just advance a pointer, free is a no-op, destroy frees the whole buffer |
| `context.allocator` | Everywhere | Odin's implicit allocator parameter — every proc inherits it |
| `nbio.*_poly` | `connection.odin` | Polymorphic async I/O — passes typed user data through to the completion callback |
| `thread.Pool` | `server.odin` | Thread pool — `pool_add_task` queues work, workers pick it up |
| `transmute([]u8)str` | `response.odin` | Reinterpret a `string` as `[]u8` without copying (same layout in memory) |
| `or_return` | `allocators.odin` | Early return on error — `make(...) or_return` returns the error if allocation fails |
| `l = server.loop` | `connection.odin` | Tells nbio to queue the operation on the main thread's event loop (cross-thread) |
