module engine

// TLS rides the epoll engine, which is Linux only; elsewhere these stay empty so
// Conn compiles.
struct TlsConn {}

struct TlsServer {}
