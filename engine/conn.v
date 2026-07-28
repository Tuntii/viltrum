module engine

// Conn is the byte-stream abstraction for one accepted connection.
// After HTTP upgrade/hijack, ownership moves to the UpgradeFn; the HTTP loop stops.
// Cleartext TCP and mbedtls SSL share this surface (read/write/close/deadlines).
import net
import net.mbedtls
import time

// ConnKind selects the underlying transport for Conn I/O.
pub enum ConnKind {
	tcp
	ssl
	buffered // tests / pushback-only
}

pub struct Conn {
mut:
	kind   ConnKind
	tcp    net.TcpConn
	ssl    &mbedtls.SSLConn = unsafe { nil }
	rbuf   []u8 // unread bytes (HTTP leftover / pushback)
	closed bool
}

// wrap takes ownership of an accepted TCP conn.
// `buffered` is already-read data that must be returned by read() before the socket.
pub fn Conn.wrap(mut tcp net.TcpConn, buffered []u8) Conn {
	return Conn{
		kind:   .tcp
		tcp:    tcp
		rbuf:   buffered.clone()
		closed: false
	}
}

// wrap_ssl takes ownership of an accepted TLS conn (mbedtls).
pub fn Conn.wrap_ssl(ssl &mbedtls.SSLConn, buffered []u8) Conn {
	return Conn{
		kind:   .ssl
		ssl:    ssl
		rbuf:   buffered.clone()
		closed: false
	}
}

// new_buffered builds a Conn that only serves pushback bytes (no live socket).
// Used in tests to prove leftover ownership without a TCP race.
pub fn Conn.new_buffered(data []u8) Conn {
	return Conn{
		kind:   .buffered
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
	match c.kind {
		.tcp {
			c.tcp.set_read_timeout(d)
		}
		.ssl {
			c.ssl.set_read_timeout(d)
		}
		.buffered {}
	}
}

pub fn (mut c Conn) set_write_timeout(d time.Duration) {
	if c.closed {
		return
	}
	match c.kind {
		.tcp {
			c.tcp.set_write_timeout(d)
		}
		// mbedtls SSLConn has no write-deadline API.
		.ssl {}
		.buffered {}
	}
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
	match c.kind {
		.tcp {
			n := c.tcp.read(mut buf) or { return err }
			if n < 0 {
				return error('negative read')
			}
			return n
		}
		.ssl {
			n := c.ssl.read(mut buf) or { return err }
			if n < 0 {
				return error('negative read')
			}
			return n
		}
		.buffered {
			return error('eof')
		}
	}
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
	match c.kind {
		.tcp {
			return c.tcp.write(data)
		}
		.ssl {
			return c.ssl.write(data)
		}
		.buffered {
			return error('write on buffered conn')
		}
	}
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
	match c.kind {
		.tcp {
			c.tcp.close() or { return err }
		}
		.ssl {
			c.ssl.close() or { return err }
		}
		.buffered {}
	}
}

// peer_ip returns the remote address string (host:port or host), if available.
pub fn (c &Conn) peer_ip() !string {
	if c.closed {
		return error('conn closed')
	}
	match c.kind {
		.tcp {
			return c.tcp.peer_ip()
		}
		.ssl {
			addr := c.ssl.peer_addr() or { return err }
			return addr.str()
		}
		.buffered {
			return error('no peer on buffered conn')
		}
	}
}
