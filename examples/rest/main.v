module main

// In-memory TODO JSON API — keep-alive, params, body, shared state.

import viltrum

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

fn extract_title(raw string) ?string {
	key := '"title"'
	idx := raw.index(key) or { return none }
	rest := raw[idx + key.len..]
	colon := rest.index(':') or { return none }
	after := rest[colon + 1..].trim_space()
	if !after.starts_with('"') {
		return none
	}
	mut i := 1
	mut out := ''
	for i < after.len {
		c := after[i]
		if c == `\\` && i + 1 < after.len {
			out += after[i + 1].ascii_str()
			i += 2
			continue
		}
		if c == `"` {
			return out
		}
		out += c.ascii_str()
		i++
	}
	return none
}

fn main() {
	shared store := Store{}

	mut app := viltrum.new()
	app.use(viltrum.logger)

	app.get('/todos', fn [shared store] (_req viltrum.Request) viltrum.Response {
		mut parts := []string{}
		rlock store {
			for _, t in store.items {
				parts << todo_json(t)
			}
		}
		return viltrum.json(200, '[${parts.join(',')}]')
	})

	app.post('/todos', fn [shared store] (req viltrum.Request) viltrum.Response {
		title := extract_title(req.text()) or {
			return viltrum.text(400, 'expected {"title":"..."}')
		}
		if title.len == 0 {
			return viltrum.text(400, 'empty title')
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
		return viltrum.json(201, todo_json(t))
	})

	app.get('/todos/:id', fn [shared store] (req viltrum.Request) viltrum.Response {
		id_str := req.param('id') or { return viltrum.not_found() }
		id := id_str.int()
		rlock store {
			if id in store.items {
				return viltrum.json(200, todo_json(store.items[id]))
			}
		}
		return viltrum.not_found()
	})

	app.delete('/todos/:id', fn [shared store] (req viltrum.Request) viltrum.Response {
		id_str := req.param('id') or { return viltrum.not_found() }
		id := id_str.int()
		lock store {
			if id in store.items {
				store.items.delete(id)
				return viltrum.empty(204)
			}
		}
		return viltrum.not_found()
	})

	addr := '127.0.0.1:8081'
	println('Viltrum REST → http://${addr}')
	println('  GET    /todos')
	println('  POST   /todos   {"title":"..."}')
	println('  GET    /todos/:id')
	println('  DELETE /todos/:id')
	app.listen(addr) or { panic(err) }
}
