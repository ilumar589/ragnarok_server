package ragnarok_http

import "core:mem"
import "core:strconv"
import "core:strings"

// ────────────────────────────────────────────────────
// HTTP Method
// ────────────────────────────────────────────────────

Http_Method :: enum {
	GET,
	HEAD,
	POST,
	PUT,
	DELETE,
	PATCH,
	OPTIONS,
	TRACE,
	CONNECT,
}

method_from_string :: proc(s: string) -> (Http_Method, bool) {
	switch s {
	case "GET":     return .GET, true
	case "HEAD":    return .HEAD, true
	case "POST":    return .POST, true
	case "PUT":     return .PUT, true
	case "DELETE":  return .DELETE, true
	case "PATCH":   return .PATCH, true
	case "OPTIONS": return .OPTIONS, true
	case "TRACE":   return .TRACE, true
	case "CONNECT": return .CONNECT, true
	}
	return .GET, false
}

// ────────────────────────────────────────────────────
// HTTP Version
// ────────────────────────────────────────────────────

Http_Version :: enum {
	HTTP_1_0,
	HTTP_1_1,
}

// ────────────────────────────────────────────────────
// Header
// ────────────────────────────────────────────────────

Header :: struct {
	name:  string,
	value: string,
}

// ────────────────────────────────────────────────────
// HTTP Request
// ────────────────────────────────────────────────────

Http_Request :: struct {
	method:         Http_Method,
	uri:            string,       // raw request URI, e.g. "/path?query=1"
	path:           string,       // just the path portion
	query_string:   string,       // raw query string (after '?')
	version:        Http_Version,
	headers:        []Header,
	body:           []u8,
	content_length: int,
	keep_alive:     bool,
}

// ────────────────────────────────────────────────────
// Request parsing
// ────────────────────────────────────────────────────

// Parses a complete HTTP request from the header section bytes.
// All strings returned are slices into `data` (zero-copy) or allocated from `allocator`.
// Returns true on success.
parse_request :: proc(
	request: ^Http_Request,
	data: []u8,
	config: Server_Config,
	allocator: mem.Allocator,
) -> bool {
	text := string(data)

	// ── Parse request line: METHOD SP URI SP HTTP/Version CRLF ──
	request_line_end := strings.index(text, "\r\n")
	if request_line_end < 0 {
		return false
	}
	request_line := text[:request_line_end]

	// Parse method
	sp1 := strings.index(request_line, " ")
	if sp1 < 0 {
		return false
	}
	method_str := request_line[:sp1]
	method, method_ok := method_from_string(method_str)
	if !method_ok {
		return false
	}
	request.method = method

	// Parse URI and version
	rest := request_line[sp1 + 1:]
	sp2 := strings.index(rest, " ")
	if sp2 < 0 {
		return false
	}
	request.uri = rest[:sp2]
	version_str := rest[sp2 + 1:]

	switch version_str {
	case "HTTP/1.0":
		request.version = .HTTP_1_0
		request.keep_alive = false // Default for 1.0
	case "HTTP/1.1":
		request.version = .HTTP_1_1
		request.keep_alive = true // Default for 1.1
	case:
		return false
	}

	// Parse path and query string from URI
	qmark := strings.index(request.uri, "?")
	if qmark >= 0 {
		request.path = request.uri[:qmark]
		request.query_string = request.uri[qmark + 1:]
	} else {
		request.path = request.uri
		request.query_string = ""
	}

	// ── Parse headers ──
	headers_text := text[request_line_end + 2:] // skip past \r\n of request line
	parsed_headers := make([dynamic]Header, 0, 16, allocator)
	header_count := 0

	remaining := headers_text
	for len(remaining) > 0 {
		// Check header count limit
		if header_count >= config.max_headers {
			return false
		}

		// Find end of this header line
		line_end := strings.index(remaining, "\r\n")
		if line_end < 0 {
			// Last header without trailing CRLF (shouldn't happen with proper data)
			line_end = len(remaining)
		}

		if line_end == 0 {
			// Empty line = end of headers (shouldn't reach here since we split on \r\n\r\n)
			break
		}

		line := remaining[:line_end]

		// Find colon separator
		colon := strings.index(line, ":")
		if colon < 0 {
			return false // Malformed header
		}

		name := strings.trim_space(line[:colon])
		value := strings.trim_space(line[colon + 1:])

		append(&parsed_headers, Header{name = name, value = value})
		header_count += 1

		// Advance past this line and its CRLF
		if line_end + 2 <= len(remaining) {
			remaining = remaining[line_end + 2:]
		} else {
			break
		}
	}

	request.headers = parsed_headers[:]

	// ── Extract important headers ──
	request.content_length = 0
	for h in request.headers {
		lower_name := strings.to_lower(h.name, allocator)

		if lower_name == "content-length" {
			cl, ok := strconv.parse_int(h.value)
			if ok {
				request.content_length = cl
			}
		} else if lower_name == "connection" {
			lower_value := strings.to_lower(h.value, allocator)
			if lower_value == "close" {
				request.keep_alive = false
			} else if lower_value == "keep-alive" {
				request.keep_alive = true
			}
		}
	}

	return true
}
