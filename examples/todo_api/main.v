module main

import sync
import viltrum
import x.json2

struct Todo {
	id        int
	title     string
	completed bool
}

struct CreateTodo {
	title string
}

struct UpdateTodo {
	title     string
	completed ?bool
}

@[heap]
struct Store {
mut:
	mu    sync.Mutex
	todos map[int]Todo
	next  int = 1
}

fn todo_id(mut c viltrum.Ctx) ?int {
	id := c.param_int('id') or { return none }
	if id <= 0 {
		return none
	}
	return int(id)
}

fn build_app() &viltrum.App {
	mut store := &Store{}
	mut app := viltrum.new()
	mut todos := app.group('/todos')

	todos.get('/', fn [mut store] (mut c viltrum.Ctx) {
		mut result := []Todo{}
		store.mu.lock()
		for _, todo in store.todos {
			result << todo
		}
		store.mu.unlock()
		c.json(200, result)
	})
	todos.post('/', fn [mut store] (mut c viltrum.Ctx) {
		input := json2.decode[CreateTodo](c.body().bytestr()) or {
			c.text(400, 'bad json')
			return
		}
		if input.title.trim_space().len == 0 {
			c.text(400, 'title is required')
			return
		}
		store.mu.lock()
		todo := Todo{
			id:        store.next
			title:     input.title
			completed: false
		}
		store.todos[todo.id] = todo
		store.next++
		store.mu.unlock()
		c.json(201, todo)
	})
	todos.get('/:id', fn [mut store] (mut c viltrum.Ctx) {
		id := todo_id(mut c) or {
			c.text(400, 'invalid todo id')
			return
		}
		store.mu.lock()
		if id !in store.todos {
			store.mu.unlock()
			c.text(404, 'todo not found')
			return
		}
		todo := store.todos[id]
		store.mu.unlock()
		c.json(200, todo)
	})
	todos.put('/:id', fn [mut store] (mut c viltrum.Ctx) {
		id := todo_id(mut c) or {
			c.text(400, 'invalid todo id')
			return
		}
		input := json2.decode[UpdateTodo](c.body().bytestr()) or {
			c.text(400, 'bad json')
			return
		}
		if input.title.trim_space().len == 0 {
			c.text(400, 'title is required')
			return
		}
		completed := input.completed or {
			c.text(400, 'completed is required')
			return
		}

		store.mu.lock()
		if id !in store.todos {
			store.mu.unlock()
			c.text(404, 'todo not found')
			return
		}
		todo := Todo{
			id:        id
			title:     input.title
			completed: completed
		}
		store.todos[id] = todo
		store.mu.unlock()
		c.json(200, todo)
	})
	todos.delete('/:id', fn [mut store] (mut c viltrum.Ctx) {
		id := todo_id(mut c) or {
			c.text(400, 'invalid todo id')
			return
		}
		store.mu.lock()
		if id !in store.todos {
			store.mu.unlock()
			c.text(404, 'todo not found')
			return
		}
		store.todos.delete(id)
		store.mu.unlock()
		c.no_content(204)
	})
	return app
}

fn main() {
	mut app := build_app()
	app.listen('127.0.0.1:8086') or { panic(err) }
}
