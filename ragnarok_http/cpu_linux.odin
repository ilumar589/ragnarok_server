package ragnarok_http

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	@(link_name = "get_nprocs")
	_libc_get_nprocs :: proc() -> i32 ---
}

// Linux: use glibc get_nprocs() for online CPU count
_get_cpu_count :: proc() -> int {
	n := int(_libc_get_nprocs())
	return n if n > 0 else 4
}
