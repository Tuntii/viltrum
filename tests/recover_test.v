module main

import os
import viltrum
import viltrum.http

fn test_recover_status_zero_is_500_close() {
	h := viltrum.recover(fn (_ viltrum.Request) viltrum.Response {
		return viltrum.Response{}
	})
	resp := h(viltrum.Request{})
	assert resp.status == 500
	cl := resp.headers.get_lowered('connection') or { '' }
	assert cl == 'close'
}

fn test_recover_fills_missing_content_length() {
	h := viltrum.recover(fn (_ viltrum.Request) viltrum.Response {
		return viltrum.Response{
			status:  200
			body:    'ab'.bytes()
			headers: http.HeaderMap.new()
		}
	})
	resp := h(viltrum.Request{})
	assert resp.status == 200
	got := resp.headers.get_lowered('content-length') or { '' }
	assert got == '2'
}

fn test_recover_keeps_existing_content_length() {
	h := viltrum.recover(fn (_ viltrum.Request) viltrum.Response {
		mut r := viltrum.Response{
			status:  200
			body:    'abcd'.bytes()
			headers: http.HeaderMap.new()
		}
		r.headers.set('Content-Length', '4')
		return r
	})
	resp := h(viltrum.Request{})
	assert resp.status == 200
	got := resp.headers.get_lowered('content-length') or { '' }
	assert got == '4'
	assert resp.body.bytestr() == 'abcd'
}

fn test_recover_success_lookup_does_not_casefold() {
	src := os.read_file(os.dir(os.dir(@FILE)) + '/viltrum.v') or {
		assert false, 'read viltrum.v: ${err}'
		return
	}
	start := src.index('pub fn recover(') or {
		assert false, 'recover missing'
		return
	}
	rest := src[start..]
	end := rest.index('\npub fn ') or { rest.len }
	body := rest[..end]
	assert body.contains("get_or_lowered('content-length'")
	assert !body.contains('get_or(')
	assert !body.contains('.to_lower(')
}
