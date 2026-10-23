module main

import os
import viltrum

struct Echo {
	q      string
	worker int
}

const upload_form = '<form method="post" enctype="multipart/form-data">
<input name="title" placeholder="title"> <input type="file" name="doc"> <button>Upload</button>
</form>
'

fn main() {
	mut app := viltrum.new()
	app.use(viltrum.logger)
	app.use(viltrum.cors('*'))
	app.get('/', fn (mut c viltrum.Ctx) {
		c.text(200, 'try /search?q=caf%C3%A9, /api/ping, /big, /static/, /upload\n')
	})
	app.get('/search', fn (mut c viltrum.Ctx) {
		q := c.query_param('q') or { '' }
		c.json(200, Echo{
			q:      q
			worker: c.worker_id()
		})
	})
	mut api := app.group('/api')
	api.get('/ping', fn (mut c viltrum.Ctx) {
		c.text(200, 'pong')
	})
	app.get('/big', viltrum.gzip, fn (mut c viltrum.Ctx) {
		c.text(200, 'viltrum '.repeat(500))
	})
	// files next to this example, with validators, ranges and a day of caching
	app.static_files('/static', os.join_path(os.dir(@FILE), 'public'), max_age: 86400)
	// a multipart form: the fields and the file are views into the request
	app.get('/upload', fn (mut c viltrum.Ctx) {
		c.bytes(200, 'text/html; charset=utf-8', upload_form.bytes())
	})
	app.post('/upload', fn (mut c viltrum.Ctx) {
		title := c.form_value('title') or { '' }
		f := c.form_file('doc') or {
			c.text(400, 'no file\n')
			return
		}
		name := f.safe_filename() or { '(no name)' }
		c.text(200, '${title}: ${name}, ${f.data.len} bytes of ${f.content_type}\n')
	})
	app.listen('127.0.0.1:8082') or { panic(err) }
}
