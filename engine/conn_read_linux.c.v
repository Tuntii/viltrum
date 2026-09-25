module engine

import time

// Cleartext reads: one SO_RCVTIMEO for the current deadline, then blocking recv.
// Does not call V's per-read readiness wait. A changed deadline installs once.

#include <errno.h>
#include <sys/socket.h>
#include <sys/time.h>

fn (mut c Conn) install_rcvtimeo() {
	d := c.tcp.read_timeout
	if c.rcv_installed && c.rcv_dur == d {
		return
	}
	secs := u64(d / time.second)
	us := u64((d % time.second) / time.microsecond)
	mut tv := C.timeval{
		tv_sec:  secs
		tv_usec: us
	}
	fd := c.tcp.sock.handle
	C.setsockopt(fd, C.SOL_SOCKET, C.SO_RCVTIMEO, &tv, sizeof(C.timeval))
	c.rcv_installed = true
	c.rcv_dur = d
}

fn (mut c Conn) read_tcp(mut buf []u8) !int {
	c.install_rcvtimeo()
	fd := c.tcp.sock.handle
	for {
		n := unsafe { C.recv(fd, &buf[0], buf.len, 0) }
		if n == 0 {
			return error('eof')
		}
		if n > 0 {
			return n
		}
		e := C.errno
		if e == C.EINTR {
			continue
		}
		if e == C.EAGAIN || e == C.EWOULDBLOCK || e == C.ETIMEDOUT {
			return error('read timed out')
		}
		return error('read failed')
	}
	return error('read failed')
}
