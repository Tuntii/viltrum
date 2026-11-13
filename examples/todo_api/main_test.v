module main

import viltrum

fn send(app &viltrum.App, method string, path string, body string) !string {
	return app.handle_raw('${method} ${path} HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: ${body.len}\r\n\r\n${body}')
}

fn test_get_todos_returns_empty_list() {
	app := build_app()
	response := send(app, 'GET', '/todos', '')!
	assert response.starts_with('HTTP/1.1 200 ')
	assert response.ends_with('\r\n\r\n[]')
}

fn test_post_todo_and_get_todo() {
	app := build_app()
	created := send(app, 'POST', '/todos', '{"title":"write tests"}')!
	assert created.starts_with('HTTP/1.1 201 ')
	assert created.ends_with('\r\n\r\n{"id":1,"title":"write tests","completed":false}')

	fetched := send(app, 'GET', '/todos/1', '')!
	assert fetched.starts_with('HTTP/1.1 200 ')
	assert fetched.ends_with('\r\n\r\n{"id":1,"title":"write tests","completed":false}')
	list := send(app, 'GET', '/todos', '')!
	assert list.ends_with('\r\n\r\n[{"id":1,"title":"write tests","completed":false}]')
}

fn test_post_todo_rejects_bad_json_and_empty_title() {
	app := build_app()
	bad_json := send(app, 'POST', '/todos', '{')!
	assert bad_json.starts_with('HTTP/1.1 400 ')
	empty_title := send(app, 'POST', '/todos', '{"title":"  "}')!
	assert empty_title.starts_with('HTTP/1.1 400 ')
}

fn test_get_todo_returns_bad_request_or_not_found() {
	app := build_app()
	invalid_id := send(app, 'GET', '/todos/nope', '')!
	assert invalid_id.starts_with('HTTP/1.1 400 ')
	missing := send(app, 'GET', '/todos/1', '')!
	assert missing.starts_with('HTTP/1.1 404 ')
}

fn test_put_todo_replaces_writable_fields() {
	app := build_app()
	_ = send(app, 'POST', '/todos', '{"title":"old title"}')!
	updated := send(app, 'PUT', '/todos/1', '{"title":"new title","completed":true}')!
	assert updated.starts_with('HTTP/1.1 200 ')
	assert updated.ends_with('\r\n\r\n{"id":1,"title":"new title","completed":true}')

	missing_completed := send(app, 'PUT', '/todos/1', '{"title":"missing field"}')!
	assert missing_completed.starts_with('HTTP/1.1 400 ')
	missing_todo := send(app, 'PUT', '/todos/2', '{"title":"missing todo","completed":false}')!
	assert missing_todo.starts_with('HTTP/1.1 404 ')
}

fn test_delete_todo_returns_no_content() {
	app := build_app()
	_ = send(app, 'POST', '/todos', '{"title":"temporary"}')!
	deleted := send(app, 'DELETE', '/todos/1', '')!
	assert deleted.starts_with('HTTP/1.1 204 ')
	assert deleted.ends_with('\r\n\r\n')

	fetched := send(app, 'GET', '/todos/1', '')!
	assert fetched.starts_with('HTTP/1.1 404 ')
	missing := send(app, 'DELETE', '/todos/1', '')!
	assert missing.starts_with('HTTP/1.1 404 ')
}
