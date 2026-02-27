package ragnarok_pg

import "core:fmt"
import "core:mem"
import "core:testing"

// ────────────────────────────────────────────────────
// Tracking-allocator helpers
// (Same pattern as ragnarok_http/memory_leak_tests.odin)
// ────────────────────────────────────────────────────

@(private = "file")
make_tracking_allocator :: proc() -> (mem.Allocator, ^mem.Tracking_Allocator) {
	ta := new(mem.Tracking_Allocator)
	mem.tracking_allocator_init(ta, context.allocator)
	return mem.tracking_allocator(ta), ta
}

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
	mem.tracking_allocator_destroy(ta)
	free(ta)
}

// ────────────────────────────────────────────────────
// Test: params_to_cstrings / params_free — no leaks
// ────────────────────────────────────────────────────

@(test)
test_params_int_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	vals: []any = {int(42), i32(-7), i64(9999999999)}
	cs, ok := params_to_cstrings(vals, alloc)
	testing.expect(t, ok, "params_to_cstrings should succeed for ints")
	testing.expect(t, len(cs) == 3, "should have 3 cstrings")

	// Verify values
	testing.expect(t, string(cs[0]) == "42", "int param should be '42'")
	testing.expect(t, string(cs[1]) == "-7", "i32 param should be '-7'")

	params_free(cs, alloc)
	expect_no_leaks(t, ta, "params_int")
}

@(test)
test_params_float_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	vals: []any = {f64(3.14), f32(2.5)}
	cs, ok := params_to_cstrings(vals, alloc)
	testing.expect(t, ok, "params_to_cstrings should succeed for floats")
	testing.expect(t, len(cs) == 2, "should have 2 cstrings")

	params_free(cs, alloc)
	expect_no_leaks(t, ta, "params_float")
}

@(test)
test_params_bool_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	vals: []any = {true, false}
	cs, ok := params_to_cstrings(vals, alloc)
	testing.expect(t, ok, "params_to_cstrings should succeed for bools")
	testing.expect(t, string(cs[0]) == "t", "true should be 't'")
	testing.expect(t, string(cs[1]) == "f", "false should be 'f'")

	params_free(cs, alloc)
	expect_no_leaks(t, ta, "params_bool")
}

@(test)
test_params_string_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	vals: []any = {string("hello"), string("world")}
	cs, ok := params_to_cstrings(vals, alloc)
	testing.expect(t, ok, "params_to_cstrings should succeed for strings")
	testing.expect(t, string(cs[0]) == "hello", "first param should be 'hello'")
	testing.expect(t, string(cs[1]) == "world", "second param should be 'world'")

	params_free(cs, alloc)
	expect_no_leaks(t, ta, "params_string")
}

@(test)
test_params_mixed_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	vals: []any = {int(1), string("test"), f64(2.5), true}
	cs, ok := params_to_cstrings(vals, alloc)
	testing.expect(t, ok, "params_to_cstrings should succeed for mixed types")
	testing.expect(t, len(cs) == 4, "should have 4 cstrings")

	params_free(cs, alloc)
	expect_no_leaks(t, ta, "params_mixed")
}

@(test)
test_params_empty_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	vals: []any = {}
	cs, ok := params_to_cstrings(vals, alloc)
	testing.expect(t, ok, "params_to_cstrings should succeed for empty params")
	testing.expect(t, cs == nil, "empty params should return nil")

	params_free(cs, alloc)
	expect_no_leaks(t, ta, "params_empty")
}

// ────────────────────────────────────────────────────
// Test: PG_Error lifecycle — no leaks
// ────────────────────────────────────────────────────

@(test)
test_error_static_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	err := pg_error_static("static error")
	testing.expect(t, !pg_ok(err), "static error should not be ok")
	testing.expect(t, err.message == "static error", "message should match")
	testing.expect(t, !err.owned, "static error should not be owned")

	pg_error_destroy(&err, alloc) // no-op for static
	expect_no_leaks(t, ta, "error_static")
}

@(test)
test_error_owned_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	err := pg_error_from_cstr("owned error message", alloc)
	testing.expect(t, !pg_ok(err), "owned error should not be ok")
	testing.expect(t, err.owned, "should be owned")

	pg_error_destroy(&err, alloc)
	expect_no_leaks(t, ta, "error_owned")
}

@(test)
test_error_nil_cstr_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	err := pg_error_from_cstr(nil, alloc)
	testing.expect(t, pg_ok(err), "nil cstring should produce ok error")

	pg_error_destroy(&err, alloc)
	expect_no_leaks(t, ta, "error_nil_cstr")
}

// ────────────────────────────────────────────────────
// Test: PG_Pool init / destroy — no leaks
// (Does NOT require a running PostgreSQL instance)
// ────────────────────────────────────────────────────

@(test)
test_pool_init_destroy_no_leak :: proc(t: ^testing.T) {
	alloc, ta := make_tracking_allocator()

	pool: PG_Pool
	config := PG_Pool_Config{
		conninfo   = "host=localhost dbname=nonexistent",
		min_conns  = 0,   // don't try to actually connect
		max_conns  = 4,
		health_check = false,
	}
	err := pg_pool_init(&pool, config, alloc)
	testing.expect(t, pg_ok(err), "pool init should succeed with min_conns=0")

	// Verify capacity
	active, idle, total := pg_pool_stats(&pool)
	testing.expect(t, total == 4, "total should be 4")
	testing.expect(t, idle == 4, "all should be idle")
	testing.expect(t, active == 0, "none should be active")

	pg_pool_destroy(&pool, alloc)
	expect_no_leaks(t, ta, "pool_init_destroy")
}

@(test)
test_pool_acquire_release_no_real_db :: proc(t: ^testing.T) {
	// This test verifies the pool slot management without a real database.
	// Acquire will try to connect and fail — we just verify the slot
	// is properly returned on failure.
	alloc, ta := make_tracking_allocator()

	pool: PG_Pool
	config := PG_Pool_Config{
		conninfo     = "host=127.0.0.1 port=1 dbname=none connect_timeout=1",
		min_conns    = 0,
		max_conns    = 2,
		health_check = false,
	}
	err := pg_pool_init(&pool, config, alloc)
	testing.expect(t, pg_ok(err), "pool init should succeed")

	// Acquire will fail because there's no database
	db, acq_err := pg_pool_acquire(&pool, alloc)
	if db != nil {
		// Unexpected success (maybe PG is running on port 1?) — release it
		pg_pool_release(&pool, db)
	} else {
		// Expected: connection failed, slot should be returned
		testing.expect(t, !pg_ok(acq_err), "acquire should fail without a database")
		pg_error_destroy(&acq_err, alloc)
	}

	// Pool should still have all slots available
	_, idle, _ := pg_pool_stats(&pool)
	testing.expect(t, idle == 2, "all slots should be idle after failed acquire")

	pg_pool_destroy(&pool, alloc)
	expect_no_leaks(t, ta, "pool_acquire_release_no_db")
}

// ────────────────────────────────────────────────────
// Test: Query_Result zero-value destroy — no crash
// ────────────────────────────────────────────────────

@(test)
test_result_destroy_zero_value :: proc(t: ^testing.T) {
	r := Query_Result{}
	result_destroy(&r) // should not crash
	testing.expect(t, r.handle == nil, "handle should remain nil")
}

@(test)
test_result_double_destroy :: proc(t: ^testing.T) {
	r := Query_Result{}
	result_destroy(&r)
	result_destroy(&r) // double destroy should be safe
	testing.expect(t, r.handle == nil, "handle should remain nil")
}

// ────────────────────────────────────────────────────
// Test: result_get_* with nil handle — safe defaults
// ────────────────────────────────────────────────────

@(test)
test_result_get_nil_handle :: proc(t: ^testing.T) {
	r := Query_Result{}

	{
		_, ok := result_get_string(&r, 0, 0)
		testing.expect(t, !ok, "get_string on nil result should return false")
	}
	{
		_, ok := result_get_int(&r, 0, 0)
		testing.expect(t, !ok, "get_int on nil result should return false")
	}
	{
		_, ok := result_get_f64(&r, 0, 0)
		testing.expect(t, !ok, "get_f64 on nil result should return false")
	}
	{
		_, ok := result_get_bool(&r, 0, 0)
		testing.expect(t, !ok, "get_bool on nil result should return false")
	}

	testing.expect(t, result_is_null(&r, 0, 0), "is_null on nil result should return true")
	testing.expect(t, result_affected(&r) == 0, "affected on nil result should return 0")
	testing.expect(t, result_col_name(&r, 0) == "", "col_name on nil result should return empty")
}

// ────────────────────────────────────────────────────
// Test: Row_Iterator on empty result
// ────────────────────────────────────────────────────

@(test)
test_iter_empty_result :: proc(t: ^testing.T) {
	r := Query_Result{}
	it := result_iter(&r)
	_, ok := iter_next(&it)
	testing.expect(t, !ok, "iter_next on empty result should return false")
}
