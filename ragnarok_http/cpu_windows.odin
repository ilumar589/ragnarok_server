package ragnarok_http

import "core:os"

// Windows: use the OS-provided API for CPU core count
_get_cpu_count :: proc() -> int {
	return os.get_processor_core_count()
}
