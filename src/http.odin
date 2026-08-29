package spoticyclint

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import curl "vendor:curl"

g_ctx: runtime.Context

Response :: struct {
	status:      int,
	body:        string,
	retry_after: int, // seconds, from the Retry-After header
}

@(private = "file")
write_cb :: proc "c" (ptr: rawptr, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
	context = g_ctx
	buf := cast(^[dynamic]byte)userdata
	n := int(size) * int(nmemb)
	append(buf, ..(cast([^]byte)ptr)[:n])
	return size * nmemb
}

http_init :: proc() {
	g_ctx = context
	curl.global_init(3) // CURL_GLOBAL_ALL
}

// Performs one HTTP request. Retries a few times on 429/5xx.
http_request :: proc(
	method: string,
	url: string,
	headers: []string,
	body: string = "",
	retries := 5,
) -> (
	res: Response,
	ok: bool,
) {
	for attempt in 0 ..< max(retries, 1) {
		res, ok = http_once(method, url, headers, body)
		if !ok do return

		retryable := res.status == 429 || res.status >= 500
		if retryable && attempt < retries - 1 {
			// Drop the body and blank it: the caller owns whatever we finally
			// return, and handing back a freed slice is a double free.
			wait := res.retry_after > 0 ? res.retry_after : 2 + attempt * 3
			if res.status == 429 {
				fmt.eprintfln("Spotify rate limit; waiting %ds", min(wait, 60))
			}
			delete(res.body)
			res = {}
			time.sleep(time.Second * time.Duration(min(wait, 60)))
			continue
		}
		return
	}
	return
}

@(private = "file")
http_once :: proc(
	method: string,
	url: string,
	headers: []string,
	body: string,
) -> (
	res: Response,
	ok: bool,
) {
	h := curl.easy_init()
	if h == nil do return {}, false
	defer curl.easy_cleanup(h)

	buf: [dynamic]byte

	curl.easy_setopt(h, .URL, strings.clone_to_cstring(url, context.temp_allocator))
	curl.easy_setopt(h, .WRITEFUNCTION, write_cb)
	curl.easy_setopt(h, .WRITEDATA, &buf)
	curl.easy_setopt(h, .USERAGENT, cstring("spoticyclint/0.1"))
	curl.easy_setopt(h, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(h, .TIMEOUT, c.long(30))

	slist: ^curl.slist
	defer if slist != nil do curl.slist_free_all(slist)
	for hd in headers {
		slist = curl.slist_append(slist, strings.clone_to_cstring(hd, context.temp_allocator))
	}
	if slist != nil {
		curl.easy_setopt(h, .HTTPHEADER, slist)
	}

	switch method {
	case "GET":
	// default
	case "POST":
		curl.easy_setopt(h, .POST, c.long(1))
		curl.easy_setopt(h, .POSTFIELDS, strings.clone_to_cstring(body, context.temp_allocator))
		curl.easy_setopt(h, .POSTFIELDSIZE, c.long(len(body)))
	case:
		curl.easy_setopt(
			h,
			.CUSTOMREQUEST,
			strings.clone_to_cstring(method, context.temp_allocator),
		)
		curl.easy_setopt(h, .POSTFIELDS, strings.clone_to_cstring(body, context.temp_allocator))
		curl.easy_setopt(h, .POSTFIELDSIZE, c.long(len(body)))
	}

	if curl.easy_perform(h) != .E_OK {
		delete(buf)
		return {}, false
	}

	status: c.long
	curl.easy_getinfo(h, .RESPONSE_CODE, &status)

	// libcurl parses Retry-After for us; Spotify's 429s can ask for minutes.
	retry_after: curl.off_t
	curl.easy_getinfo(h, .RETRY_AFTER, &retry_after)

	return Response{status = int(status), body = string(buf[:]), retry_after = int(retry_after)}, true
}

// Percent-encodes a string for use in a query string or form body.
url_encode :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		ch := s[i]
		switch {
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z', ch >= '0' && ch <= '9':
			strings.write_byte(&b, ch)
		case ch == '-', ch == '_', ch == '.', ch == '~':
			strings.write_byte(&b, ch)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, HEX[ch >> 4])
			strings.write_byte(&b, HEX[ch & 0xF])
		}
	}
	return strings.to_string(b)
}
