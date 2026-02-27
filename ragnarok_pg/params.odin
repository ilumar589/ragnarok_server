package ragnarok_pg

import "core:fmt"
import "core:mem"
import "core:strings"

// ────────────────────────────────────────────────────
// Parameter conversion
// ────────────────────────────────────────────────────
//
// Converts a variadic list of Odin `any` values into a []cstring
// suitable for PQexecParams / PQexecPrepared.  All temporary
// cstrings are allocated from `allocator` so the caller can free
// them in one shot (e.g. via a request arena).
//
// Supported types:
//   int, i8, i16, i32, i64          → decimal text
//   uint, u8, u16, u32, u64         → decimal text
//   f32, f64                         → decimal text
//   bool                             → "t" / "f"
//   string                           → as-is
//   cstring                          → as-is (no clone)
//   nil  (any with nil data ptr)     → NULL (nil cstring)
// ────────────────────────────────────────────────────

// Convert a slice of `any` params into a []cstring for libpq.
// Returns the cstring slice and true on success.
// On failure returns nil, false — the caller should report an error.
params_to_cstrings :: proc(params: []any, allocator: mem.Allocator) -> ([]cstring, bool) {
	n := len(params)
	if n == 0 { return nil, true }

	values, alloc_err := make([]cstring, n, allocator)
	if alloc_err != nil { return nil, false }

	for i in 0 ..< n {
		p := params[i]

		// nil any → SQL NULL
		if p.id == nil {
			values[i] = nil
			continue
		}

		cs, ok := _any_to_cstring(p, allocator)
		if !ok {
			// Clean up already-converted values
			for j in 0 ..< i {
				if values[j] != nil { delete(values[j], allocator) }
			}
			delete(values, allocator)
			return nil, false
		}
		values[i] = cs
	}

	return values, true
}

// Free a param cstring slice produced by params_to_cstrings.
params_free :: proc(values: []cstring, allocator: mem.Allocator) {
	if values == nil { return }
	for v in values {
		if v != nil { delete(v, allocator) }
	}
	delete(values, allocator)
}

// ────────────────────────────────────────────────────
// Internal: convert a single `any` to cstring
// ────────────────────────────────────────────────────

@(private = "file")
_any_to_cstring :: proc(val: any, allocator: mem.Allocator) -> (cstring, bool) {
	// Signed integers
	switch v in val {
	case int:
		return _i64_to_cstring(i64(v), allocator)
	case i8:
		return _i64_to_cstring(i64(v), allocator)
	case i16:
		return _i64_to_cstring(i64(v), allocator)
	case i32:
		return _i64_to_cstring(i64(v), allocator)
	case i64:
		return _i64_to_cstring(v, allocator)

	// Unsigned integers
	case uint:
		return _u64_to_cstring(u64(v), allocator)
	case u8:
		return _u64_to_cstring(u64(v), allocator)
	case u16:
		return _u64_to_cstring(u64(v), allocator)
	case u32:
		return _u64_to_cstring(u64(v), allocator)
	case u64:
		return _u64_to_cstring(v, allocator)

	// Floats
	case f32:
		return _f64_to_cstring(f64(v), allocator)
	case f64:
		return _f64_to_cstring(v, allocator)

	// Bool
	case bool:
		if v {
			return strings.clone_to_cstring("t", allocator), true
		} else {
			return strings.clone_to_cstring("f", allocator), true
		}

	// Strings
	case string:
		return strings.clone_to_cstring(v, allocator), true
	case cstring:
		return v, true  // caller-owned — do not clone
	}

	return nil, false
}

// ────────────────────────────────────────────────────
// Number → cstring helpers  (stack buffer, then clone)
// ────────────────────────────────────────────────────

@(private = "file")
_i64_to_cstring :: proc(v: i64, allocator: mem.Allocator) -> (cstring, bool) {
	buf: [32]u8
	s := fmt.bprintf(buf[:], "%d", v)
	return strings.clone_to_cstring(s, allocator), true
}

@(private = "file")
_u64_to_cstring :: proc(v: u64, allocator: mem.Allocator) -> (cstring, bool) {
	buf: [32]u8
	s := fmt.bprintf(buf[:], "%d", v)
	return strings.clone_to_cstring(s, allocator), true
}

@(private = "file")
_f64_to_cstring :: proc(v: f64, allocator: mem.Allocator) -> (cstring, bool) {
	buf: [64]u8
	s := fmt.bprintf(buf[:], "%g", v)
	return strings.clone_to_cstring(s, allocator), true
}
