module main

// In-memory TODO JSON API: keep-alive, params, json_string helper, shared state.

import viltrum {
	new
	logger
	text
	json
	empty
	not_found
	Request
	Response
}

struct Todo {
	id    int
	title string
	done  bool
}

struct Store {
mut:
	next_id int = 1
	items   map[int]Todo
}

fn todo_json(t Todo) string {
	done := if t.done { 'true' } else { 'false' }
	title := t.title.replace('\\', '\\\\').replace('"', '\\"')
	return '{"id":${t.id},"title":"${title}","done":${done}}'
}

fn main() {
	shared store := Store{}

	mut app := new()
	app.use(logger)

	app.get('/todos', fn [shared store] (_req Request) Response {
		mut parts := []string{}
		rlock store {
			for _, t in store.items {
				parts << todo_json(t)
			}
		}
		return json(200, '[${parts.join(',')}]')
	})

	app.post('/todos', fn [shared store] (req Request) Response {
		title := req.json_string('title') or {
			return text(400, 'expected {"title":"..."}')
		}
		if title.len == 0 {
			return text(400, 'empty title')
		}
		mut t := Todo{}
		lock store {
			id := store.next_id
			store.next_id++
			t = Todo{
				id:    id
				title: title
				done:  false
			}
			store.items[id] = t
		}
		return json(201, todo_json(t))
	})

	app.get('/todos/:id', fn [shared store] (req Request) Response {
		id_str := req.param('id') or { return not_found() }
		id := id_str.int()
		rlock store {
			if id in store.items {
				return json(200, todo_json(store.items[id]))
			}
		}
		return not_found()
	})

	app.delete('/todos/:id', fn [shared store] (req Request) Response {
		id_str := req.param('id') or { return not_found() }
		id := id_str.int()
		lock store {
			if id in store.items {
				store.items.delete(id)
				return empty(204)
			}
		}
		return not_found()
	})

	addr := '127.0.0.1:8081'
	println('Viltrum REST -> http://${addr}')
	println('  GET    /todos')
	println('  POST   /todos   {"title":"..."}')
	println('  GET    /todos/:id')
	println('  DELETE /todos/:id')
	app.listen(addr) or { panic(err) }
}
