package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"

// ────────────────────────────────────────────────────
// HTTP Status
// ────────────────────────────────────────────────────

Http_Status :: enum u16 {
	OK                    = 200,
	Created               = 201,
	No_Content            = 204,
	Bad_Request           = 400,
	Not_Found             = 404,
	Method_Not_Allowed    = 405,
	Request_Timeout       = 408,
	Payload_Too_Large     = 413,
	Internal_Server_Error = 500,
	Not_Implemented       = 501,
}

status_reason :: proc(status: Http_Status) -> string {
	switch status {
	case .OK:                    return "OK"
	case .Created:               return "Created"
	case .No_Content:            return "No Content"
	case .Bad_Request:           return "Bad Request"
	case .Not_Found:             return "Not Found"
	case .Method_Not_Allowed:    return "Method Not Allowed"
	case .Request_Timeout:       return "Request Timeout"
	case .Payload_Too_Large:     return "Payload Too Large"
	case .Internal_Server_Error: return "Internal Server Error"
	case .Not_Implemented:       return "Not Implemented"
	}
	return "Unknown"
}

// ────────────────────────────────────────────────────
// HTTP Response
// ────────────────────────────────────────────────────

Http_Response :: struct {
	status:  Http_Status,
	headers: [dynamic]Header,
	body:    []u8,
}

// ────────────────────────────────────────────────────
// Response helpers
// ────────────────────────────────────────────────────

response_set_header :: proc(
	response: ^Http_Response,
	name: string,
	value: string,
	allocator: mem.Allocator,
) {
	// Check if header already exists, update it
	for &h in response.headers {
		if strings.equal_fold(h.name, name) {
			h.value = value
			return
		}
	}
	append(&response.headers, Header{name = name, value = value})
}

response_set_body :: proc(
	response: ^Http_Response,
	body: []u8,
	content_type: string,
	allocator: mem.Allocator,
) {
	response.body = body
	response_set_header(response, "Content-Type", content_type, allocator)
}

response_set_body_string :: proc(
	response: ^Http_Response,
	body: string,
	content_type: string,
	allocator: mem.Allocator,
) {
	response.body = transmute([]u8)body
	response_set_header(response, "Content-Type", content_type, allocator)
}

// ────────────────────────────────────────────────────
// Response serialization
// ────────────────────────────────────────────────────

// Serializes the HTTP response into a contiguous byte buffer using the given allocator.
// Auto-adds Content-Length, Date, and Server headers.
// Returns nil on allocation failure.
response_serialize :: proc(response: ^Http_Response, allocator: mem.Allocator) -> []u8 {
	b, alloc_err := strings.builder_make(0, 512, allocator)
	if alloc_err != nil {
		return nil
	}

	// Status line: HTTP/1.1 STATUS_CODE REASON_PHRASE\r\n
	strings.write_string(&b, "HTTP/1.1 ")
	write_int(&b, int(response.status))
	strings.write_byte(&b, ' ')
	strings.write_string(&b, status_reason(response.status))
	strings.write_string(&b, "\r\n")

	// Auto-add Content-Length
	body_len := len(response.body) if response.body != nil else 0
	content_length_buf: [20]u8
	cl_str := strconv.write_int(content_length_buf[:], i64(body_len), 10)
	response_set_header(response, "Content-Length", cl_str, allocator)

	// Auto-add Server header
	response_set_header(response, "Server", "Ragnarok", allocator)

	// Auto-add Date header
	date_str := format_http_date(allocator)
	if date_str != "" {
		response_set_header(response, "Date", date_str, allocator)
	}

	// Write headers
	for h in response.headers {
		strings.write_string(&b, h.name)
		strings.write_string(&b, ": ")
		strings.write_string(&b, h.value)
		strings.write_string(&b, "\r\n")
	}

	// Empty line separating headers from body
	strings.write_string(&b, "\r\n")

	// Write body
	if body_len > 0 {
		strings.write_bytes(&b, response.body)
	}

	return transmute([]u8)strings.to_string(b)
}

// ────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────

// Write an integer to a strings.Builder
write_int :: proc(b: ^strings.Builder, value: int) {
	buf: [20]u8
	s := strconv.write_int(buf[:], i64(value), 10)
	strings.write_string(b, s)
}

// Format current time as HTTP date: "Thu, 26 Feb 2026 12:34:56 GMT"
format_http_date :: proc(allocator: mem.Allocator) -> string {
	t := time.now()
	year, month, day := time.date(t)
	hour, min, sec := time.clock(t)

	day_names := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	month_names := [12]string{
		"Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
	}

	weekday := int(time.weekday(t))

	b, alloc_err := strings.builder_make(0, 30, allocator)
	if alloc_err != nil {
		return ""
	}
	strings.write_string(&b, day_names[weekday])
	strings.write_string(&b, ", ")
	if day < 10 { strings.write_byte(&b, '0') }
	write_int(&b, day)
	strings.write_byte(&b, ' ')
	strings.write_string(&b, month_names[int(month) - 1])
	strings.write_byte(&b, ' ')
	write_int(&b, year)
	strings.write_byte(&b, ' ')
	if hour < 10 { strings.write_byte(&b, '0') }
	write_int(&b, hour)
	strings.write_byte(&b, ':')
	if min < 10 { strings.write_byte(&b, '0') }
	write_int(&b, min)
	strings.write_byte(&b, ':')
	if sec < 10 { strings.write_byte(&b, '0') }
	write_int(&b, sec)
	strings.write_string(&b, " GMT")

	return strings.to_string(b)
}
