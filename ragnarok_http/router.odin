package ragnarok_http

import "core:mem"

// ────────────────────────────────────────────────────
// Handler type
// ────────────────────────────────────────────────────

Handler_Proc :: proc(request: ^Http_Request, response: ^Http_Response, allocator: mem.Allocator)

// ────────────────────────────────────────────────────
// Route
// ────────────────────────────────────────────────────

MAX_ROUTES :: 128

Route :: struct {
	method:  Http_Method,
	path:    string,
	handler: Handler_Proc,
}

// ────────────────────────────────────────────────────
// Router
// ────────────────────────────────────────────────────

Router :: struct {
	routes: [MAX_ROUTES]Route,
	count:  int,
}

router_init :: proc(router: ^Router) {
	router.count = 0
}

router_add_route :: proc(router: ^Router, method: Http_Method, path: string, handler: Handler_Proc) -> bool {
	if router.count >= MAX_ROUTES {
		return false
	}
	router.routes[router.count] = Route{
		method  = method,
		path    = path,
		handler = handler,
	}
	router.count += 1
	return true
}

// Matches an incoming request to a registered route.
// Returns the handler proc, or nil if no match.
// On method mismatch for a known path, sets method_not_allowed^ to true.
router_match :: proc(router: ^Router, method: Http_Method, path: string) -> Handler_Proc {
	path_found := false

	for i in 0 ..< router.count {
		route := &router.routes[i]
		if route.path == path {
			path_found = true
			if route.method == method {
				return route.handler
			}
		}
	}

	if path_found {
		return method_not_allowed_handler
	}

	return nil
}

// ────────────────────────────────────────────────────
// Default handlers
// ────────────────────────────────────────────────────

health_handler :: proc(request: ^Http_Request, response: ^Http_Response, allocator: mem.Allocator) {
	response.status = .OK
	response_set_body_string(response, "OK", "text/plain", allocator)
}

not_found_handler :: proc(request: ^Http_Request, response: ^Http_Response, allocator: mem.Allocator) {
	response.status = .Not_Found
	response_set_body_string(response, "Not Found", "text/plain", allocator)
}

method_not_allowed_handler :: proc(request: ^Http_Request, response: ^Http_Response, allocator: mem.Allocator) {
	response.status = .Method_Not_Allowed
	response_set_body_string(response, "Method Not Allowed", "text/plain", allocator)
}

internal_error_handler :: proc(request: ^Http_Request, response: ^Http_Response, allocator: mem.Allocator) {
	response.status = .Internal_Server_Error
	response_set_body_string(response, "Internal Server Error", "text/plain", allocator)
}
