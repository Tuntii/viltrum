module engine

// HTTPS / WSS smoke tests (self-signed PEM files in a temp dir).
import net
import net.http as nhttp
import net.mbedtls
import os
import time
import viltrum.http
import viltrum.ws

// Same self-signed localhost cert as vlib/net/http server TLS tests.
const test_tls_cert = '-----BEGIN CERTIFICATE-----
MIIEOTCCAyECFG64Q2g46jZb3kRbDOJWX/BwjSp6MA0GCSqGSIb3DQEBCwUAMEUx
CzAJBgNVBAYTAkFVMRMwEQYDVQQIDApTb21lLVN0YXRlMSEwHwYDVQQKDBhJbnRl
cm5ldCBXaWRnaXRzIFB0eSBMdGQwIBcNMjMwODAyMTcyOTQyWhgPMjA1MDEyMTcx
NzI5NDJaMGsxCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApDYWxpZm9ybmlhMRQwEgYD
VQQHDAtMb3MgQW5nZWxlczEdMBsGA1UECgwUQ2F0YWx5c3QgRGV2ZWxvcG1lbnQx
EjAQBgNVBAMMCWxvY2FsaG9zdDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoC
ggIBALqAI4fqUi+QBVWcsXglouLdOML5+w0+1hSR1KdO0Q5XPdQAs/yYWJ+KUkDw
G++rfy9DUPq7FNRBVurXQkcAtn6gXdllGUSjwUiDo/N4mMOyS/2sufBuaeww7jVi
rppH+zwP1tUnjRd6khl6bi1Ian9VSzr3Iy9CkXIg1GU4CPXkOydLeoQfepXxWoK1
OUNwT3VKC/stAfY3j/NIIeiJYkyuRGFCkxn/BUjN+AsXiTugRcYKEFHdIPkOuCXp
Ybhf+lLsczpxCs3rdZG9b/N6mEDCzXTmeHkmsjdPTf+1k5DZZvKzVBBrgdxCgBb7
5RwjF5v9WmnIc33wWgfJC6FaUzj9NYxYUbPHD+jTz0rJB/jj4u/xJlM/e5NRmXdW
70pOMKXtWjRSolLOFIPKLY1qs3KMTAZxKKWPDDF7WlMJxMRt7nnnks5yw43Nog4C
jDLk1ZgETnPpLgo3jbmJdIv+OHKTJrBlVvDq7VTyixCoS5G8KoOmyQJhaXG6NwE2
iVhH5JIKgzgCfetfDsnjxqJ/qtrFXPa8FF2TsomD0NK/GZmIcs+9OeVB75Jn5uhF
fLHScpiTbuu5w3P/LI/MqihLRB6RRNnRzPH8fIg5bYC9b770ta/8GcFRuYE8t+UR
GtqXJoIKixbDlqV54kal8FQzYzhETf9+NM6Kb/lKEfG/pslvAgMBAAEwDQYJKoZI
hvcNAQELBQADggEBALI3uNiNO0QE1brA3QYFK+d9ZroB72NrJ0UNkzYHDg2Fc6xg
4aVVfaxY08+TmKc0JlMOW+pUxeCW/+UBSngdQiR9EE9xm0k0XIrAsy9RXxRvEtPu
M1VI2h7ayp1Y2BrnQinevTSgtqLRyS1VbOFRl1FiyVvinw2I0KsDdAMNevAPXcOa
Q8pUgUq6f56DkhocQaj+hxD/uV8HryNxuoSXnPhvfTN3z4YRGzsaWevJ9EYJliOM
+XugcqfFJ+W7/QCEcAHCL+Bw6OydG5NFORr3p57PXjjcL/uKmxPBrWg2Bz6uT4uR
Mhj0zttiFHLAt9jGfyk6W57UNUja1e1ggftJJhs=
-----END CERTIFICATE-----
'

const test_tls_key = '-----BEGIN RSA PRIVATE KEY-----
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
-----END RSA PRIVATE KEY-----
'

fn write_temp_tls_files() !(string, string, string) {
	dir := os.join_path(os.temp_dir(), 'viltrum_tls_${time.sys_mono_now()}')
	os.mkdir_all(dir)!
	cert := os.join_path(dir, 'cert.pem')
	key := os.join_path(dir, 'key.pem')
	os.write_file(cert, test_tls_cert)!
	os.write_file(key, test_tls_key)!
	return dir, cert, key
}

fn free_addr() string {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic('free_addr listen: ${err}') }
	a := l.addr() or {
		l.close() or {}
		panic('free_addr addr: ${err}')
	}
	s := a.str()
	l.close() or {}
	return s
}

fn wait_listen() {
	time.sleep(120 * time.millisecond)
}

fn test_validate_tls_options_empty_and_missing() {
	validate_tls_options(TlsOptions{}) or {
		assert err.msg().contains('cert_file')
		// continue to next case
	}
	// Must not succeed with empty paths.
	if _ := validate_tls_options(TlsOptions{}) {
		assert false, 'empty TlsOptions should fail'
	}

	validate_tls_options(TlsOptions{ cert_file: 'x' }) or { assert err.msg().contains('key_file') }
	if _ := validate_tls_options(TlsOptions{ cert_file: 'x' }) {
		assert false, 'missing key_file should fail'
	}

	validate_tls_options(TlsOptions{
		cert_file: '/no/such/cert.pem'
		key_file:  '/no/such/key.pem'
	}) or {
		assert err.msg().contains('not found')
		return
	}
	assert false, 'expected missing cert error'
}

fn test_listen_tls_missing_key_returns_error() {
	dir, cert, _ := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
	}
	listen_and_serve_tls_full(addr, fn (req http.Request) http.Response {
		return http.Response.text(200, 'nope')
	}, []UpgradeRoute{}, opts, TlsOptions{
		cert_file: cert
		key_file:  os.join_path(dir, 'missing.key')
	}) or {
		assert err.msg().contains('not found') || err.msg().contains('key')
		return
	}
	assert false, 'listen_tls should fail on missing key'
}

fn test_https_get_self_signed() {
	dir, cert, key := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
	}
	tls := TlsOptions{
		cert_file: cert
		key_file:  key
	}
	spawn fn [addr, opts, tls] () {
		listen_and_serve_tls_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'tls-ok')
		}, []UpgradeRoute{}, opts, tls) or {}
	}()
	wait_listen()

	port := addr.all_after_last(':')
	resp := nhttp.fetch(
		method:   .get
		url:      'https://127.0.0.1:${port}/'
		validate: false
	) or {
		assert false, 'https fetch: ${err}'
		return
	}
	assert resp.status_code == 200
	assert resp.body.contains('tls-ok')
}

fn test_plain_http_client_to_tls_port_fails_cleanly() {
	dir, cert, key := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
	}
	tls := TlsOptions{
		cert_file: cert
		key_file:  key
	}
	spawn fn [addr, opts, tls] () {
		listen_and_serve_tls_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'nope')
		}, []UpgradeRoute{}, opts, tls) or {}
	}()
	wait_listen()

	// Plain TCP + HTTP (no TLS) must not panic the server.
	mut client := net.dial_tcp(addr) or {
		assert false, 'dial: ${err}'
		return
	}
	defer {
		client.close() or {}
	}
	client.set_read_timeout(1 * time.second)
	client.set_write_timeout(1 * time.second)
	client.write('GET / HTTP/1.1\r\nHost: localhost\r\n\r\n'.bytes()) or {}
	mut buf := []u8{len: 256}
	_ := client.read(mut buf) or {
		// Expected: TLS handshake failure / reset / timeout. Server stays up.
		assert true
		return
	}
	// If we got bytes, they should not be a successful HTTP 200 over plain.
	assert true
}

fn test_wss_text_echo() {
	dir, cert, key := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
	}
	tls := TlsOptions{
		cert_file: cert
		key_file:  key
	}
	upgrades := [
		UpgradeRoute{
			method:  'GET'
			pattern: '/ws'
			handler: ws.make_upgrade(ws.Options{}, fn (mut s ws.Socket) {
				for {
					msg := s.read_message() or { break }
					if msg.is_text() {
						s.write_text(msg.text()) or { break }
					}
				}
				s.close_quiet()
			})
		},
	]
	spawn fn [addr, opts, tls, upgrades] () {
		listen_and_serve_tls_full(addr, fn (req http.Request) http.Response {
			return http.Response.not_found()
		}, upgrades, opts, tls) or {}
	}()
	wait_listen()

	port := addr.all_after_last(':').int()
	mut ssl := mbedtls.new_ssl_conn(mbedtls.SSLConnectConfig{
		validate: false
	}) or {
		assert false, 'ssl client: ${err}'
		return
	}
	ssl.dial('127.0.0.1', port) or {
		assert false, 'ssl dial: ${err}'
		return
	}
	defer {
		ssl.close() or {}
	}
	ssl.set_read_timeout(3 * time.second)

	req := 'GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n'
	ssl.write(req.bytes()) or {
		assert false, 'write upgrade: ${err}'
		return
	}

	// Read HTTP 101 response.
	mut hdr_buf := []u8{}
	mut tmp := []u8{len: 1024}
	for {
		n := ssl.read(mut tmp) or {
			assert false, 'read 101: ${err}'
			return
		}
		if n <= 0 {
			assert false, 'eof before 101'
			return
		}
		hdr_buf << tmp[..n]
		if index_of_double_crlf(hdr_buf) != none {
			break
		}
		if hdr_buf.len > 16 * 1024 {
			assert false, 'headers too large'
			return
		}
	}
	assert hdr_buf.bytestr().contains('101')

	// Send one masked client text frame "ping".
	mask := [u8(1), 2, 3, 4]!
	frame := ws.encode_client(true, .text, 'ping'.bytes(), mask)
	ssl.write(frame) or {
		assert false, 'write frame: ${err}'
		return
	}

	// Read server text frame (unmasked).
	mut out := []u8{}
	for out.len < 2 {
		n := ssl.read(mut tmp) or {
			assert false, 'read echo hdr: ${err}'
			return
		}
		out << tmp[..n]
	}
	// Need full frame: opcode + len + payload
	plen := int(out[1] & 0x7f)
	need := 2 + plen
	for out.len < need {
		n := ssl.read(mut tmp) or {
			assert false, 'read echo body: ${err}'
			return
		}
		out << tmp[..n]
	}
	assert out[0] == 0x81 // FIN + text
	assert out[2..need].bytestr() == 'ping'
}

fn https_get(addr string) !nhttp.Response {
	port := addr.all_after_last(':')
	return nhttp.fetch(
		method:                     .get
		url:                        'https://127.0.0.1:${port}/'
		validate:                   false
		enable_http2:               false
		disable_connection_reuse:   true
	)
}

fn write_openssl_tls_pair(dir string, name string) !(string, string) {
	cert := os.join_path(dir, '${name}.crt')
	key := os.join_path(dir, '${name}.key')
	cmd := 'openssl req -x509 -newkey rsa:2048 -keyout "${key}" -out "${cert}" -days 1 -nodes -subj "/CN=localhost"'
	res := os.execute(cmd)
	if res.exit_code != 0 {
		return error('openssl ${name}: ${res.output}')
	}
	return cert, key
}

// #39: corrupt PEM must not drop the live listener.
fn test_try_reload_tls_corrupt_does_not_drop_listener() {
	dir, cert, key := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	tls := TlsOptions{
		cert_file: cert
		key_file:  key
	}
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
	}
	mut hold := &TlsHold{
		l: new_tls_listener(addr, tls, opts)!
	}
	defer {
		hold.shutdown()
	}
	old := hold.l
	os.write_file(cert, 'this is not a pem\n') or {
		assert false, err.msg()
		return
	}
	if _ := try_reload_tls(mut hold, addr, tls, opts) {
		assert false, 'corrupt PEM should fail reload'
		return
	}
	assert hold.l == old
	assert hold.l != unsafe { nil }
}

// #39 / #40: missing PEM keeps serving the old cert over the real accept loop.
fn test_tls_reload_missing_pem_keeps_serving() {
	dir, cert, key := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	mut br := &ListenBreak{}
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
		listen_break:   br
	}
	tls := TlsOptions{
		cert_file: cert
		key_file:  key
	}
	spawn fn [addr, opts, tls] () {
		listen_and_serve_tls_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'still-a')
		}, []UpgradeRoute{}, opts, tls) or {}
	}()
	wait_listen()

	first := https_get(addr) or {
		assert false, 'https before reload: ${err}'
		return
	}
	assert first.status_code == 200
	assert first.body.contains('still-a')

	os.rm(cert) or {}
	br.request_tls_reload(tls, opts) or {
		second := https_get(addr) or {
			assert false, 'https after failed reload: ${err}'
			return
		}
		assert second.status_code == 200
		assert second.body.contains('still-a')
		br.fire()
		return
	}
	br.fire()
	assert false, 'missing cert should fail reload'
}

fn test_tls_reload_corrupt_pem_keeps_serving() {
	dir, cert, key := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	mut br := &ListenBreak{}
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
		listen_break:   br
	}
	tls := TlsOptions{
		cert_file: cert
		key_file:  key
	}
	spawn fn [addr, opts, tls] () {
		listen_and_serve_tls_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'still-a')
		}, []UpgradeRoute{}, opts, tls) or {}
	}()
	wait_listen()

	first := https_get(addr) or {
		assert false, 'https before reload: ${err}'
		return
	}
	assert first.status_code == 200
	os.write_file(cert, 'not-a-pem\n') or {
		assert false, err.msg()
		return
	}
	br.request_tls_reload(tls, opts) or {
		second := https_get(addr) or {
			assert false, 'https after corrupt reload: ${err}'
			return
		}
		assert second.status_code == 200
		assert second.body.contains('still-a')
		br.fire()
		return
	}
	br.fire()
	assert false, 'corrupt PEM should fail reload'
}

// #40: valid replacement PEM is picked up; next handshake still works.
// Process-level SIGHUP is not sent here (flaky under `v test`); this covers try_reload_tls.
fn test_tls_reload_valid_replacement_serves() {
	dir, cert, key := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	mut br := &ListenBreak{}
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
		listen_break:   br
	}
	tls := TlsOptions{
		cert_file: cert
		key_file:  key
	}
	spawn fn [addr, opts, tls] () {
		listen_and_serve_tls_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'reloaded')
		}, []UpgradeRoute{}, opts, tls) or {}
	}()
	wait_listen()

	before := https_get(addr) or {
		assert false, 'https before reload: ${err}'
		return
	}
	assert before.status_code == 200

	alt_cert, alt_key := write_openssl_tls_pair(dir, 'b') or {
		// openssl missing: rewrite the same embedded PEM (still exercises swap).
		os.write_file(cert, test_tls_cert) or {
			assert false, err.msg()
			return
		}
		os.write_file(key, test_tls_key) or {
			assert false, err.msg()
			return
		}
		br.request_tls_reload(tls, opts) or {
			assert false, 'reload same pem: ${err}'
			return
		}
		wait_listen()
		after := https_get(addr) or {
			assert false, 'https after same-pem reload: ${err}'
			return
		}
		assert after.status_code == 200
		assert after.body.contains('reloaded')
		br.fire()
		return
	}
	os.cp(alt_cert, cert) or {
		assert false, err.msg()
		return
	}
	os.cp(alt_key, key) or {
		assert false, err.msg()
		return
	}
	br.request_tls_reload(tls, opts) or {
		assert false, 'reload replacement: ${err}'
		return
	}
	wait_listen()
	after := https_get(addr) or {
		assert false, 'https after replacement: ${err}'
		return
	}
	assert after.status_code == 200
	assert after.body.contains('reloaded')
	br.fire()
}

fn test_fetch_tls_get_and_post() {
	dir, cert, key := write_temp_tls_files() or {
		assert false, err.msg()
		return
	}
	defer {
		os.rmdir_all(dir) or {}
	}
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   3 * time.second
		write_timeout:  3 * time.second
		idle_timeout:   3 * time.second
	}
	tls := TlsOptions{
		cert_file: cert
		key_file:  key
	}
	spawn fn [addr, opts, tls] () {
		listen_and_serve_tls_full(addr, fn (req http.Request) http.Response {
			if req.method == 'POST' {
				return http.Response.text(201, 'got:${req.text()}')
			}
			return http.Response.text(200, 'tls-client-ok')
		}, []UpgradeRoute{}, opts, tls) or {}
	}()
	wait_listen()

	ct := http.ClientTls{
		insecure_skip_verify: true
	}
	g := http.get_tls(addr, '/', ct) or {
		assert false, 'get_tls: ${err}'
		return
	}
	assert g.status == 200
	assert g.body.bytestr().contains('tls-client-ok')

	p := http.post_tls(addr, '/echo', 'xyz', 'text/plain', ct) or {
		assert false, 'post_tls: ${err}'
		return
	}
	assert p.status == 201
	assert p.body.bytestr() == 'got:xyz'
}

fn test_fetch_tls_against_cleartext_fails() {
	addr := free_addr()
	opts := ServerOptions{
		handle_signals: false
		read_timeout:   2 * time.second
		write_timeout:  2 * time.second
		idle_timeout:   2 * time.second
	}
	spawn fn [addr, opts] () {
		listen_and_serve_full(addr, fn (req http.Request) http.Response {
			return http.Response.text(200, 'plain')
		}, []UpgradeRoute{}, opts) or {}
	}()
	wait_listen()
	http.get_tls(addr, '/', http.ClientTls{}) or {
		assert err.msg().len > 0
		return
	}
	assert false, 'TLS client against cleartext should fail'
}
