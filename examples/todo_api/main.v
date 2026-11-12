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

fn build_app() &viltrum.App {
	mut store := &Store{}
	mut app := viltrum.new()
	mut todos := app.group('/todos')

	todos.get('/', fn [mut store] (mut c viltrum.Ctx) {
		mut result := []Todo{}
		store.mu.lock()
		for id in 1 .. store.next {
			todo := store.todos[id] or { Todo{} }
			if todo.id != 0 {
				result << todo
			}
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
		id := c.param_int('id') or {
			c.text(400, 'invalid todo id')
			return
		}
		if id <= 0 {
			c.text(400, 'invalid todo id')
			return
		}
		store.mu.lock()
		todo := store.todos[int(id)] or { Todo{} }
		store.mu.unlock()
		if todo.id == 0 {
			c.text(404, 'todo not found')
			return
		}
		c.json(200, todo)
	})
	todos.put('/:id', fn [mut store] (mut c viltrum.Ctx) {
		id := c.param_int('id') or {
			c.text(400, 'invalid todo id')
			return
		}
		if id <= 0 {
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
		mut todo := store.todos[int(id)] or { Todo{} }
		if todo.id != 0 {
			todo = Todo{
				id:        int(id)
				title:     input.title
				completed: completed
			}
			store.todos[int(id)] = todo
		}
		store.mu.unlock()
		if todo.id == 0 {
			c.text(404, 'todo not found')
			return
		}
		c.json(200, todo)
	})
	todos.delete('/:id', fn [mut store] (mut c viltrum.Ctx) {
		id := c.param_int('id') or {
			c.text(400, 'invalid todo id')
			return
		}
		if id <= 0 {
			c.text(400, 'invalid todo id')
			return
		}
		store.mu.lock()
		todo := store.todos[int(id)] or { Todo{} }
		if todo.id != 0 {
			store.todos.delete(int(id))
		}
		store.mu.unlock()
		if todo.id == 0 {
			c.text(404, 'todo not found')
			return
		}
		c.no_content(204)
	})
	return app
}

fn main() {
	mut app := build_app()
	app.listen('127.0.0.1:8086') or { panic(err) }
}
