module main

import sync
import viltrum
import x.json2

struct User {
	id   int
	name string
}

// Store is shared by every worker thread, so it is locked.
@[heap]
struct Store {
mut:
	mu    sync.Mutex
	users map[int]User
	next  int = 1
}

fn main() {
	mut store := &Store{}
	mut app := viltrum.new()
	app.use(viltrum.recover)
	app.get('/users/:id', fn [mut store] (mut c viltrum.Ctx) {
		id := int(c.param_int('id') or { 0 })
		store.mu.lock()
		u := store.users[id] or { User{} }
		store.mu.unlock()
		if u.id == 0 {
			c.text(404, 'no such user')
			return
		}
		c.json(200, u)
	})
	app.post('/users', fn [mut store] (mut c viltrum.Ctx) {
		input := json2.decode[User](c.body().bytestr()) or {
			c.text(400, 'bad json')
			return
		}
		store.mu.lock()
		u := User{
			id:   store.next
			name: input.name
		}
		store.users[u.id] = u
		store.next++
		store.mu.unlock()
		c.json(201, u)
	})
	app.listen('127.0.0.1:8081') or { panic(err) }
}
