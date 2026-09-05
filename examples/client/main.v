module main

// Tiny cleartext client against examples/hello (or any Viltrum server).
//
//   v run examples/hello
//   v run examples/client
import os
import viltrum { client_get, client_post }

fn env_or(key string, def string) string {
	v := os.getenv(key)
	if v.len == 0 {
		return def
	}
	return v
}

fn main() {
	addr := env_or('VILTRUM_ADDR', '127.0.0.1:8080')
	r := client_get(addr, '/') or {
		eprintln('get ${addr}: ${err}')
		exit(1)
	}
	print(r.body.bytestr())
	if os.args.len > 1 && os.args[1] == 'post' {
		p := client_post(addr, '/health', '', 'text/plain') or {
			eprintln('post: ${err}')
			exit(1)
		}
		print(p.body.bytestr())
	}
}
