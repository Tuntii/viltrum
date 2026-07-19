module engine

// Conn is the byte-stream abstraction for one accepted connection.
// After HTTP upgrade/hijack, ownership moves to the UpgradeFn; the HTTP loop stops.
// Future TLS will wrap the same surface (read/write/close/deadlines).

import net
import time

pub struct Conn {
mut:
	tcp    net.TcpConn
	rbuf   []u8 // unread bytes (HTTP leftover / pushback)
	closed bool
}

// wrap takes ownership of an accepted TCP conn.
// `buffered` is already-read data that must be returned by read() before the socket.
pub fn Conn.wrap(mut tcp net.TcpConn, buffered []u8) Conn {
	return Conn{
		tcp:    tcp
		rbuf:   buffered.clone()
		closed: false
	}
}

// new_buffered builds a Conn that only serves pushback bytes (no live socket).
// Used in tests to prove leftover ownership without a TCP race.
pub fn Conn.new_buffered(data []u8) Conn {
	return Conn{
		rbuf:   data.clone()
		closed: false
	}
}

// buffered_len is how many bytes sit in the pushback buffer (not yet read by the peer API).
pub fn (c &Conn) buffered_len() int {
	return c.rbuf.len
}

pub fn (c &Conn) is_closed() bool {
	return c.closed
}

pub fn (mut c Conn) set_read_timeout(d time.Duration) {
	if c.closed {
		return
	}
	c.tcp.set_read_timeout(d)
}

pub fn (mut c Conn) set_write_timeout(d time.Duration) {
	if c.closed {
		return
	}
	c.tcp.set_write_timeout(d)
}

// read fills buf from pushback first, then the socket. Returns bytes read (0 only on empty buf).
pub fn (mut c Conn) read(mut buf []u8) !int {
	if c.closed {
		return error('conn closed')
	}
	if buf.len == 0 {
		return 0
	}
	if c.rbuf.len > 0 {
		n := if buf.len < c.rbuf.len { buf.len } else { c.rbuf.len }
		for i in 0 .. n {
			buf[i] = c.rbuf[i]
		}
		if n >= c.rbuf.len {
			c.rbuf = []u8{}
		} else {
			c.rbuf = c.rbuf[n..].clone()
		}
		return n
	}
	n := c.tcp.read(mut buf) or { return err }
	if n < 0 {
		return error('negative read')
	}
	return n
}

// read_exact reads exactly buf.len bytes (from pushback + socket).
pub fn (mut c Conn) read_exact(mut buf []u8) ! {
	mut off := 0
	for off < buf.len {
		mut slice := unsafe { buf[off..] }
		n := c.read(mut slice) or { return err }
		if n == 0 {
			return error('eof')
		}
		off += n
	}
}

pub fn (mut c Conn) write(data []u8) !int {
	if c.closed {
		return error('conn closed')
	}
	if data.len == 0 {
		return 0
	}
	return c.tcp.write(data)
}

// write_all writes the full buffer or returns an error.
pub fn (mut c Conn) write_all(data []u8) ! {
	mut off := 0
	for off < data.len {
		n := c.write(data[off..]) or { return err }
		if n <= 0 {
			return error('short write')
		}
		off += n
	}
}

// close is idempotent. After close, read/write fail.
pub fn (mut c Conn) close() ! {
	if c.closed {
		return
	}
	c.closed = true
	c.rbuf = []u8{}
	c.tcp.close() or { return err }
}

// peer_ip returns the remote address string (host:port or host), if available.
pub fn (c &Conn) peer_ip() !string {
	if c.closed {
		return error('conn closed')
	}
	return c.tcp.peer_ip()
}
