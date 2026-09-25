module engine

// Non-Linux: V's TcpConn.read (select + recv). Linux uses conn_read_linux.c.v.

fn (mut c Conn) read_tcp(mut buf []u8) !int {
	n := c.tcp.read(mut buf) or { return err }
	if n < 0 {
		return error('negative read')
	}
	return n
}
