module main

// Multipart + urlencoded form demo.
//
//   v run examples/upload
//   curl -s -F title=hi -F file=@README.md http://127.0.0.1:8085/upload
//   curl -s -d 'title=urlencoded' http://127.0.0.1:8085/form

import viltrum {
	Request
	Response
	json
	json_escape
	logger
	new
	recover
	text
}

fn main() {
	mut app := new()
	app.use(recover)
	app.use(logger)

	app.post('/form', fn (req Request) Response {
		title := req.form_value('title') or { return text(400, 'need title') }
		return json(200, '{"title":"${json_escape(title)}"}')
	})

	app.post('/upload', fn (req Request) Response {
		title := req.form_value('title') or { '' }
		f := req.form_file('file') or { return text(400, 'need file field') }
		return json(200, '{"title":"${json_escape(title)}","filename":"${json_escape(f.filename)}","bytes":${f.data.len}}')
	})

	addr := '127.0.0.1:8085'
	println('Viltrum upload -> http://${addr}')
	println('  POST /form    application/x-www-form-urlencoded')
	println('  POST /upload  multipart/form-data (title + file)')
	app.listen(addr) or { panic(err) }
}
