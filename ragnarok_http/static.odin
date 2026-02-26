package ragnarok_http

import "core:log"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// ────────────────────────────────────────────────────
// Static file serving with zero-copy sendfile
// ────────────────────────────────────────────────────

// Attempt to serve a request as a static file.
//
// Returns true when the file will be served (sendfile flow), in which case
// response headers are populated and pool.conns[slot].sendfile_pending is
// set.  Returns false when the path doesn't resolve to a file.
//
// Called from a worker thread.  File I/O (open, stat) is synchronous;
// the actual data transfer uses nbio.sendfile on the I/O thread.
try_serve_static_file :: proc(
	ref: ^Conn_Ref,
	request: ^Http_Request,
	response: ^Http_Response,
	allocator: mem.Allocator,
) -> bool {
	s      := ref.slot
	pool   := ref.pool
	config := pool.server.config

	// Only GET / HEAD
	if request.method != .GET && request.method != .HEAD { return false }

	// Reject directory traversal
	if strings.contains(request.path, "..") { return false }
	if strings.contains_any(request.path, "\x00") { return false }

	// Strip leading /
	req_path := request.path
	if len(req_path) > 0 && req_path[0] == '/' { req_path = req_path[1:] }
	if len(req_path) == 0 { req_path = "index.html" }

	full_path := build_file_path(config.static_root, req_path, allocator)

	// ── Step 1: open with core:os to get file size ──────────────
	os_file, open_err := os.open(full_path)
	if open_err != nil {
		// Try index.html for extensionless paths
		if !strings.contains(req_path, ".") {
			idx_path := build_file_path(
				config.static_root,
				strings.concatenate({req_path, "/index.html"}, allocator),
				allocator,
			)
			f2, e2 := os.open(idx_path)
			if e2 != nil { return false }
			os_file    = f2
			full_path  = idx_path
		} else {
			return false
		}
	}
	fsize, size_err := os.file_size(os_file)
	os.close(os_file)  // close handle — reopened below via nbio
	if size_err != nil { return false }

	// ── Step 2: open via nbio for zero-copy sendfile ────────────
	nbio_handle, nbio_err := nbio.open_sync(full_path, l = pool.server.loop)
	if nbio_err != nil {
		log.debugf("nbio open_sync failed for %s: %v", full_path, nbio_err)
		return false
	}

	pool.conns[s].sendfile_handle  = nbio_handle
	pool.conns[s].sendfile_pending = true

	// ── Step 3: populate response headers ───────────────────────
	response.status = .OK
	response_set_header(response, "Content-Type", mime_from_extension(path_extension(request.path)), allocator)

	// Content-Length must be arena-allocated so it survives until serialisation
	cl_buf := make([]u8, 20, allocator)
	cl_str := strconv.write_int(cl_buf, fsize, 10)
	response_set_header(response, "Content-Length", cl_str, allocator)

	// HEAD → don't actually sendfile
	if request.method == .HEAD {
		pool.conns[s].sendfile_pending = false
		nbio.close(nbio_handle)
	}

	return true
}

// ────────────────────────────────────────────────────
// Sendfile completion  (I/O thread)
// ────────────────────────────────────────────────────

on_sendfile_complete :: proc(op: ^nbio.Operation, ref: ^Conn_Ref) {
	s    := ref.slot
	pool := ref.pool

	nbio.close(pool.conns[s].sendfile_handle)
	request_arena_destroy(&pool.request_arenas[s], context.allocator)

	if op.sendfile.err != nil {
		log.debugf("Sendfile error to %v: %v", pool.conns[s].endpoint, op.sendfile.err)
		connection_close(ref)
		return
	}

	log.infof("%v \"sendfile\" %d bytes", pool.conns[s].endpoint, op.sendfile.sent)

	if pool.conns[s].keep_alive {
		pool.conns[s].recv_len = 0
		connection_start_recv(ref)
	} else {
		connection_close(ref)
	}
}

// ────────────────────────────────────────────────────
// Path utilities
// ────────────────────────────────────────────────────

build_file_path :: proc(root, relative: string, allocator: mem.Allocator) -> string {
	clean_root := root
	if len(clean_root) > 0 &&
	   (clean_root[len(clean_root)-1] == '/' || clean_root[len(clean_root)-1] == '\\') {
		clean_root = clean_root[:len(clean_root)-1]
	}
	when ODIN_OS == .Windows {
		rel, was_alloc := strings.replace_all(relative, "/", "\\", allocator)
		result := strings.concatenate({clean_root, "\\", rel}, allocator)
		if was_alloc { delete(rel, allocator) }
		return result
	} else {
		return strings.concatenate({clean_root, "/", relative}, allocator)
	}
}

path_extension :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '.' { return path[i:] }
		if path[i] == '/' || path[i] == '\\' { break }
	}
	return ""
}

// ────────────────────────────────────────────────────
// MIME types
// ────────────────────────────────────────────────────

mime_from_extension :: proc(ext: string) -> string {
	switch ext {
	case ".html", ".htm": return "text/html; charset=utf-8"
	case ".css":          return "text/css; charset=utf-8"
	case ".js", ".mjs":   return "application/javascript; charset=utf-8"
	case ".json":         return "application/json; charset=utf-8"
	case ".xml":          return "application/xml; charset=utf-8"
	case ".txt":          return "text/plain; charset=utf-8"
	case ".csv":          return "text/csv; charset=utf-8"
	case ".md":           return "text/markdown; charset=utf-8"
	case ".png":          return "image/png"
	case ".jpg", ".jpeg": return "image/jpeg"
	case ".gif":          return "image/gif"
	case ".svg":          return "image/svg+xml"
	case ".ico":          return "image/x-icon"
	case ".webp":         return "image/webp"
	case ".avif":         return "image/avif"
	case ".woff":         return "font/woff"
	case ".woff2":        return "font/woff2"
	case ".ttf":          return "font/ttf"
	case ".otf":          return "font/otf"
	case ".pdf":          return "application/pdf"
	case ".wasm":         return "application/wasm"
	case ".zip":          return "application/zip"
	case ".gz":           return "application/gzip"
	case ".tar":          return "application/x-tar"
	case ".mp3":          return "audio/mpeg"
	case ".mp4":          return "video/mp4"
	case ".webm":         return "video/webm"
	case ".ogg":          return "audio/ogg"
	}
	return "application/octet-stream"
}
