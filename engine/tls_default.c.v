module engine

// TLS rides the epoll engine, which is Linux only; elsewhere these stay empty so
// Conn compiles.
struct TlsConn {}

struct TlsServer {}

fn (mut w Worker) tls_lend(mut t TlsConn) {}

fn (mut w Worker) tls_settle(mut t TlsConn, all bool) {}
