package ragnarok_http

import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

// ────────────────────────────────────────────────────
// Per-connection state
// ────────────────────────────────────────────────────

RECV_BUF_SIZE :: 8192

// Connection holds every mutable field for one client connection.
// The pool stores these in Odin's native #soa layout — the compiler
// splits each field into its own contiguous array so sweeping a single
// field across all slots (timeout checks, active scans) is cache-friendly.
Connection :: struct {
	socket:          net.TCP_Socket,
	endpoint:        net.Endpoint,
	recv_buf:        [RECV_BUF_SIZE]u8,
	recv_len:        int,
	keep_alive:      bool,
	request_count:   int,
	recv_start:      time.Time,
	active:          bool,
	sendfile_handle: nbio.Handle,
	sendfile_pending: bool,
}

// ────────────────────────────────────────────────────
// SOA Connection Pool
// ────────────────────────────────────────────────────

// Conn_Ref is a lightweight, stable handle passed to every async I/O
// callback (nbio poly ops) and thread-pool task.  It lives inside the
// pool's refs[] array so &refs[slot] is valid for the entire pool
// lifetime — safe to hand to any overlapped / deferred callback.
Conn_Ref :: struct {
	pool: ^Connection_Pool,
	slot: int,
}

// Connection_Pool stores connections in Odin's native #soa layout.
//
// Benefits over heap-allocated AOS:
//   - Pre-allocated: zero heap alloc/free on accept/close
//   - Bounded: exactly `capacity` connections worth of memory
//   - Cache-friendly: one-field sweeps touch contiguous memory
//   - O(1) acquire/release via LIFO free-stack
Connection_Pool :: struct {
	conns:          #soa[]Connection,  // Odin-native SOA — each field → contiguous array
	request_arenas: []Request_Arena,   // separate from #soa (avoids LLVM GEP limitation)
	refs:           []Conn_Ref,        // one per slot; &refs[slot] handed to callbacks
	free_stack:     []int,             // LIFO stack of available slot indices
	free_count:     int,
	capacity:       int,
	server:         ^Server,
}

// ────────────────────────────────────────────────────
// Pool lifecycle
// ────────────────────────────────────────────────────

// Allocate and initialise the pool.  Returns false on allocation failure.
pool_init :: proc(
	pool: ^Connection_Pool,
	capacity: int,
	server: ^Server,
	allocator := context.allocator,
) -> bool {
	pool.capacity = capacity
	pool.server   = server

	alloc_err: mem.Allocator_Error

	pool.conns, alloc_err = make(#soa[]Connection, capacity, allocator)
	if alloc_err != nil { return false }

	pool.request_arenas, alloc_err = make([]Request_Arena, capacity, allocator)
	if alloc_err != nil { pool_destroy(pool, allocator); return false }

	pool.refs, alloc_err = make([]Conn_Ref, capacity, allocator)
	if alloc_err != nil { pool_destroy(pool, allocator); return false }

	pool.free_stack, alloc_err = make([]int, capacity, allocator)
	if alloc_err != nil { pool_destroy(pool, allocator); return false }

	// Initialise stable refs and fill the free list
	for i in 0 ..< capacity {
		pool.refs[i]       = Conn_Ref{ pool = pool, slot = i }
		pool.free_stack[i] = capacity - 1 - i  // top-of-stack → slot 0
	}
	pool.free_count = capacity
	return true
}

// Tear down every pool allocation.
pool_destroy :: proc(pool: ^Connection_Pool, allocator := context.allocator) {
	// Clean up any live request arenas
	for i in 0 ..< len(pool.conns) {
		if pool.conns[i].active {
			request_arena_destroy(&pool.request_arenas[i], allocator)
		}
	}
	if len(pool.conns) > 0        { delete_soa_slice(pool.conns, allocator) }
	if pool.request_arenas != nil { delete(pool.request_arenas, allocator) }
	if pool.refs != nil           { delete(pool.refs, allocator) }
	if pool.free_stack != nil { delete(pool.free_stack, allocator) }
}

// ────────────────────────────────────────────────────
// Slot acquire / release  (I/O thread only — no sync)
// ────────────────────────────────────────────────────

// Pop a free slot.  Returns nil when the pool is full.
pool_acquire :: proc(pool: ^Connection_Pool) -> ^Conn_Ref {
	if pool.free_count == 0 { return nil }
	pool.free_count -= 1
	slot := pool.free_stack[pool.free_count]

	// Reset slot for the new connection
	pool.conns[slot].active           = true
	pool.conns[slot].recv_len         = 0
	pool.conns[slot].keep_alive       = true  // HTTP/1.1 default
	pool.conns[slot].request_count    = 0
	pool.conns[slot].sendfile_pending = false

	return &pool.refs[slot]
}

// Push a slot back onto the free list.
pool_release :: proc(pool: ^Connection_Pool, slot: int) {
	if slot < 0 || slot >= pool.capacity || !pool.conns[slot].active {
		return  // double-release / invalid guard
	}
	pool.conns[slot].active = false
	pool.free_stack[pool.free_count] = slot
	pool.free_count += 1
}

// Number of connections currently in flight.
pool_active_count :: proc(pool: ^Connection_Pool) -> int {
	return pool.capacity - pool.free_count
}
