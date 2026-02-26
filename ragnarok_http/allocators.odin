package ragnarok_http

import "core:mem"

// Request_Arena wraps a mem.Arena with its own heap-allocated backing buffer.
// Each HTTP request gets one of these; it is freed entirely when the response is sent.
Request_Arena :: struct {
	arena:   mem.Arena,
	backing: []u8,
}

// Initializes a request arena by allocating a backing buffer of `size` bytes from `allocator`.
request_arena_init :: proc(ra: ^Request_Arena, size: int, allocator: mem.Allocator) -> mem.Allocator_Error {
	ra.backing = make([]u8, size, allocator) or_return
	mem.arena_init(&ra.arena, ra.backing)
	return nil
}

// Returns the arena-based allocator for use during request processing.
request_arena_allocator :: proc(ra: ^Request_Arena) -> mem.Allocator {
	return mem.arena_allocator(&ra.arena)
}

// Resets the arena offset so the backing buffer can be reused (e.g. for keep-alive).
request_arena_reset :: proc(ra: ^Request_Arena) {
	mem.arena_free_all(&ra.arena)
}

// Frees the backing buffer, releasing all memory back to the parent allocator.
request_arena_destroy :: proc(ra: ^Request_Arena, allocator: mem.Allocator) {
	if ra.backing != nil {
		delete(ra.backing, allocator)
		ra.backing = nil
	}
}

// Creates a scratch allocator from a stack-local fixed buffer.
// Use for small, bounded temporary allocations (header parsing scratch, etc.).
// Example:
//   scratch_buf: [4096]u8
//   scratch_arena: mem.Arena
//   mem.arena_init(&scratch_arena, scratch_buf[:])
//   scratch := mem.arena_allocator(&scratch_arena)
