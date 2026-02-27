package ragnarok_pg

import "core:log"
import "core:mem"
import "core:sync"
import "core:time"

// ────────────────────────────────────────────────────
// PostgreSQL Connection Pool
// ────────────────────────────────────────────────────
//
// Bounded, pre-allocated pool of DB connections shared by
// the HTTP worker thread pool.  Uses a LIFO free-stack
// (same pattern as ragnarok_http's Connection_Pool) with
// a mutex for thread safety — unlike the HTTP pool which
// only runs on the I/O thread.
//
// Usage:
//   pool: pg.PG_Pool
//   pg.pg_pool_init(&pool, config)
//   defer pg.pg_pool_destroy(&pool)
//
//   // In a handler (worker thread):
//   db := pg.pg_pool_acquire(&pool)
//   defer pg.pg_pool_release(&pool, db)
//   result, err := pg.db_query(db, "SELECT 1")
// ────────────────────────────────────────────────────

PG_Pool_Config :: struct {
	conninfo:       string,          // libpq connection string
	min_conns:      int,             // pre-opened on init (warm the pool)
	max_conns:      int,             // hard cap — pool capacity
	idle_timeout:   time.Duration,   // (reserved for future idle reaping)
	health_check:   bool,            // if true, verify connection on acquire
}

default_pg_pool_config :: proc(conninfo: string, worker_count: int) -> PG_Pool_Config {
	return PG_Pool_Config{
		conninfo     = conninfo,
		min_conns    = max(worker_count, 1),
		max_conns    = max(worker_count * 2, 4),
		idle_timeout = 5 * time.Minute,
		health_check = true,
	}
}

PG_Pool :: struct {
	conns:      []DB,         // pre-allocated DB slots
	free_stack: []int,        // LIFO stack of available slot indices
	free_count: int,
	capacity:   int,
	config:     PG_Pool_Config,
	mu:         sync.Mutex,   // protects free_stack / free_count
}

// ────────────────────────────────────────────────────
// Pool lifecycle
// ────────────────────────────────────────────────────

// Initialise the pool: allocate slots and open min_conns connections.
pg_pool_init :: proc(
	pool: ^PG_Pool,
	config: PG_Pool_Config,
	allocator := context.allocator,
) -> PG_Error {
	pool.config   = config
	pool.capacity = config.max_conns

	alloc_err: mem.Allocator_Error

	pool.conns, alloc_err = make([]DB, config.max_conns, allocator)
	if alloc_err != nil { return pg_error_static("pool: failed to allocate connection slots") }

	pool.free_stack, alloc_err = make([]int, config.max_conns, allocator)
	if alloc_err != nil {
		delete(pool.conns, allocator)
		return pg_error_static("pool: failed to allocate free stack")
	}

	// Fill free list (all slots available, top-of-stack = slot 0)
	for i in 0 ..< config.max_conns {
		pool.free_stack[i] = config.max_conns - 1 - i
	}
	pool.free_count = config.max_conns

	// Pre-open min_conns connections (warm start)
	opened := 0
	for _ in 0 ..< config.min_conns {
		idx := _pool_pop_slot(pool)
		if idx < 0 { break }

		db, err := db_connect(config.conninfo, allocator)
		if !pg_ok(err) {
			log.warnf("pool: failed to pre-open connection: %s", err.message)
			pg_error_destroy(&err, allocator)
			_pool_push_slot(pool, idx)
			continue
		}
		pool.conns[idx] = db
		_pool_push_slot(pool, idx)
		opened += 1
	}

	log.infof("PG pool initialized: %d/%d connections pre-opened, capacity=%d",
		opened, config.min_conns, config.max_conns)
	return {}
}

// Destroy the pool: close all connections and free memory.
pg_pool_destroy :: proc(pool: ^PG_Pool, allocator := context.allocator) {
	// Close every connection that was opened
	for i in 0 ..< pool.capacity {
		if pool.conns[i].conn != nil {
			db_close(&pool.conns[i])
		}
	}
	if pool.conns != nil      { delete(pool.conns, allocator) }
	if pool.free_stack != nil { delete(pool.free_stack, allocator) }
	pool.capacity   = 0
	pool.free_count = 0
	log.debug("PG pool destroyed")
}

// ────────────────────────────────────────────────────
// Acquire / Release
// ────────────────────────────────────────────────────

// Acquire a connection from the pool.
// Returns a pointer to a DB slot.  The caller MUST call pg_pool_release
// when done (use `defer`).
//
// If the pool is exhausted, returns (nil, error).
// If the slot has no open connection, one is opened on demand.
// If health_check is enabled and the connection is dead, it is reset.
pg_pool_acquire :: proc(pool: ^PG_Pool, allocator := context.allocator) -> (^DB, PG_Error) {
	sync.mutex_lock(&pool.mu)
	idx := _pool_pop_slot_unlocked(pool)
	sync.mutex_unlock(&pool.mu)

	if idx < 0 {
		return nil, pg_error_static("pool exhausted: no available connections")
	}

	db := &pool.conns[idx]

	// Lazy connect: slot may not have been pre-opened
	if db.conn == nil {
		new_db, err := db_connect(pool.config.conninfo, allocator)
		if !pg_ok(err) {
			// Return slot to pool
			sync.mutex_lock(&pool.mu)
			_pool_push_slot_unlocked(pool, idx)
			sync.mutex_unlock(&pool.mu)
			return nil, err
		}
		db^ = new_db
		return db, {}
	}

	// Health check: verify the connection is alive
	if pool.config.health_check && !db_is_connected(db) {
		log.debug("pool: stale connection detected, resetting")
		if !db_reset(db) {
			// Reset failed — close and try to reconnect
			db_close(db)
			new_db, err := db_connect(pool.config.conninfo, allocator)
			if !pg_ok(err) {
				sync.mutex_lock(&pool.mu)
				_pool_push_slot_unlocked(pool, idx)
				sync.mutex_unlock(&pool.mu)
				return nil, err
			}
			db^ = new_db
		}
	}

	return db, {}
}

// Release a connection back to the pool.
// The `db` pointer must have been obtained from pg_pool_acquire.
pg_pool_release :: proc(pool: ^PG_Pool, db: ^DB) {
	if db == nil { return }

	// Find the slot index from the pointer offset
	base := raw_data(pool.conns)
	idx := int(uintptr(db) - uintptr(base)) / size_of(DB)

	if idx < 0 || idx >= pool.capacity {
		log.errorf("pool: invalid release — pointer outside pool bounds (idx=%d)", idx)
		return
	}

	sync.mutex_lock(&pool.mu)
	_pool_push_slot_unlocked(pool, idx)
	sync.mutex_unlock(&pool.mu)
}

// ────────────────────────────────────────────────────
// Pool stats
// ────────────────────────────────────────────────────

// Returns (active, idle, total) connection counts.
pg_pool_stats :: proc(pool: ^PG_Pool) -> (active, idle, total: int) {
	sync.mutex_lock(&pool.mu)
	idle = pool.free_count
	sync.mutex_unlock(&pool.mu)
	total = pool.capacity
	active = total - idle
	return
}

// ────────────────────────────────────────────────────
// Internal: LIFO free-stack operations
// ────────────────────────────────────────────────────

// Pop a slot index. Returns -1 if stack is empty.
// Acquires the mutex internally.
@(private = "file")
_pool_pop_slot :: proc(pool: ^PG_Pool) -> int {
	sync.mutex_lock(&pool.mu)
	defer sync.mutex_unlock(&pool.mu)
	return _pool_pop_slot_unlocked(pool)
}

// Pop without locking — caller must hold the mutex.
@(private = "file")
_pool_pop_slot_unlocked :: proc(pool: ^PG_Pool) -> int {
	if pool.free_count == 0 { return -1 }
	pool.free_count -= 1
	return pool.free_stack[pool.free_count]
}

// Push a slot back. Acquires the mutex internally.
@(private = "file")
_pool_push_slot :: proc(pool: ^PG_Pool, idx: int) {
	sync.mutex_lock(&pool.mu)
	defer sync.mutex_unlock(&pool.mu)
	_pool_push_slot_unlocked(pool, idx)
}

// Push without locking — caller must hold the mutex.
@(private = "file")
_pool_push_slot_unlocked :: proc(pool: ^PG_Pool, idx: int) {
	pool.free_stack[pool.free_count] = idx
	pool.free_count += 1
}
