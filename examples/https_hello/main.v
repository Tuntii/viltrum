module main

// Minimal HTTPS server (self-signed).
//
//   bash scripts/dev-cert.sh
//   v run examples/https_hello
//   curl -k https://127.0.0.1:8443/
import os
import viltrum {
	Request,
	Response,
	TlsOptions,
	json,
	logger,
	new,
	recover,
	text,
}

fn env_or(key string, def string) string {
	v := os.getenv(key)
	if v.len == 0 {
		return def
	}
	return v
}

fn main() {
	cert := env_or('VILTRUM_CERT', 'certs/dev.crt')
	key := env_or('VILTRUM_KEY', 'certs/dev.key')
	if !os.exists(cert) || !os.exists(key) {
		eprintln('missing ${cert} / ${key}')
		eprintln('run: bash scripts/dev-cert.sh')
		exit(1)
	}

	mut app := new()
	app.use(recover)
	app.use(logger)

	app.get('/', fn (_req Request) Response {
		return text(200, 'hello over https\n')
	})
	app.get('/health', fn (_req Request) Response {
		return json(200, '{"status":"ok","tls":true}')
	})

	reload := os.getenv('VILTRUM_RELOAD') == '1'
	addr := '127.0.0.1:8443'
	println('Viltrum https_hello → https://${addr}')
	println('  cert=${cert} key=${key}')
	println('  curl -k https://${addr}/')
	if reload {
		println('  SIGHUP reload on (replace PEM files, then: kill -HUP <pid>)')
	}
	app.listen_tls(addr, TlsOptions{
		cert_file:        cert
		key_file:         key
		reload_on_sighup: reload
	}) or { panic(err) }
}
