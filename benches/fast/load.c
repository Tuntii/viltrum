// load: a small keep-alive HTTP/1.1 load client for benches/fast.
//
//   load HOST PORT PATH [-c conns] [-p depth] [-n requests | -d seconds] [-H header]...
//
// Every connection sends `depth` requests in one write and waits for all of
// their responses before it writes again. With -n it sends exactly that many
// requests in total; with -d it runs for that many seconds. Responses are
// counted by status line and Content-Length. It prints one line,
//   requests=<n> errors=<e> seconds=<s> rps=<r>
// and exits 0 only when no request failed.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define RBUF (256 * 1024)

typedef struct {
	int   fd;
	int   inflight;
	int   len;
	char *buf;
} Conn;

static double now_s(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static void die(const char *what) {
	perror(what);
	exit(2);
}

static int dial(const char *host, int port) {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		die("socket");
	}
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((unsigned short)port);
	if (inet_pton(AF_INET, host, &a.sin_addr) != 1) {
		fprintf(stderr, "bad host %s\n", host);
		exit(2);
	}
	if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) {
		die("connect");
	}
	int one = 1;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	return fd;
}

static void send_all(int fd, const char *p, size_t n) {
	while (n > 0) {
		ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
		if (w < 0) {
			if (errno == EINTR) {
				continue;
			}
			die("send");
		}
		p += w;
		n -= (size_t)w;
	}
}

// parse takes complete responses off the front of c->buf. It returns how many
// it took and adds non-2xx ones to *errors; -1 means the bytes are not HTTP.
static int parse(Conn *c, long *errors) {
	int got = 0;
	for (;;) {
		char *end = memmem(c->buf, (size_t)c->len, "\r\n\r\n", 4);
		if (end == NULL) {
			return c->len >= RBUF ? -1 : got;
		}
		int head = (int)(end - c->buf) + 4;
		if (c->len < 12 || memcmp(c->buf, "HTTP/1.", 7) != 0) {
			return -1;
		}
		int  status = atoi(c->buf + 9);
		long body = -1;
		for (char *p = c->buf; p < end; p++) {
			if (p[0] == '\n' && strncasecmp(p + 1, "content-length:", 15) == 0) {
				body = strtol(p + 16, NULL, 10);
				break;
			}
		}
		if (body < 0 || head + body > RBUF) {
			return -1;
		}
		if (c->len < head + body) {
			return got;
		}
		if (status < 200 || status > 299) {
			(*errors)++;
		}
		int used = head + (int)body;
		memmove(c->buf, c->buf + used, (size_t)(c->len - used));
		c->len -= used;
		got++;
	}
}

int main(int argc, char **argv) {
	if (argc < 4) {
		fprintf(stderr, "usage: load HOST PORT PATH [-c conns] [-p depth] [-n requests | -d seconds] [-H header]...\n");
		return 2;
	}
	const char *host = argv[1];
	int         port = atoi(argv[2]);
	const char *path = argv[3];
	int         conns = 1, depth = 1;
	long        total = 0;
	double      secs = 0;
	char        headers[4096] = "";
	for (int i = 4; i < argc; i++) {
		if (i + 1 >= argc) {
			fprintf(stderr, "missing value for %s\n", argv[i]);
			return 2;
		}
		const char *v = argv[++i];
		if (strcmp(argv[i - 1], "-c") == 0) {
			conns = atoi(v);
		} else if (strcmp(argv[i - 1], "-p") == 0) {
			depth = atoi(v);
		} else if (strcmp(argv[i - 1], "-n") == 0) {
			total = atol(v);
		} else if (strcmp(argv[i - 1], "-d") == 0) {
			secs = atof(v);
		} else if (strcmp(argv[i - 1], "-H") == 0) {
			if (strlen(headers) + strlen(v) + 3 > sizeof headers) {
				fprintf(stderr, "headers too long\n");
				return 2;
			}
			strcat(headers, v);
			strcat(headers, "\r\n");
		} else {
			fprintf(stderr, "unknown flag %s\n", argv[i - 1]);
			return 2;
		}
	}
	if (conns < 1 || depth < 1 || (total <= 0) == (secs <= 0)) {
		fprintf(stderr, "need conns >= 1, depth >= 1 and exactly one of -n / -d\n");
		return 2;
	}

	char one[8192];
	int  olen = snprintf(one, sizeof one, "GET %s HTTP/1.1\r\nHost: %s\r\n%s\r\n", path, host, headers);
	if (olen <= 0 || olen >= (int)sizeof one) {
		fprintf(stderr, "request too long\n");
		return 2;
	}
	char *batch = malloc((size_t)olen * (size_t)depth);
	for (int i = 0; i < depth; i++) {
		memcpy(batch + (size_t)i * (size_t)olen, one, (size_t)olen);
	}

	int ep = epoll_create1(0);
	if (ep < 0) {
		die("epoll_create1");
	}
	Conn *cs = calloc((size_t)conns, sizeof(Conn));
	for (int i = 0; i < conns; i++) {
		cs[i].fd = dial(host, port);
		cs[i].buf = malloc(RBUF);
		struct epoll_event ev = {.events = EPOLLIN, .data.ptr = &cs[i]};
		if (epoll_ctl(ep, EPOLL_CTL_ADD, cs[i].fd, &ev) != 0) {
			die("epoll_ctl");
		}
	}

	long   sent = 0, done = 0, errors = 0;
	double start = now_s();
	double deadline = secs > 0 ? start + secs : 0;
	double last = start;
	// fire a batch: with -n never more than what is left to send
	for (int i = 0; i < conns; i++) {
		int k = depth;
		if (total > 0 && total - sent < k) {
			k = (int)(total - sent);
		}
		if (k > 0) {
			send_all(cs[i].fd, batch, (size_t)olen * (size_t)k);
			cs[i].inflight = k;
			sent += k;
		}
	}
	struct epoll_event evs[256];
	for (;;) {
		if (total > 0 && done >= total) {
			break;
		}
		double t = now_s();
		if (deadline > 0 && t >= deadline) {
			break;
		}
		if (t - last > 10) {
			fprintf(stderr, "no response for 10 s\n");
			errors++;
			break;
		}
		int n = epoll_wait(ep, evs, 256, 100);
		if (n < 0 && errno != EINTR) {
			die("epoll_wait");
		}
		for (int i = 0; i < n; i++) {
			Conn   *c = evs[i].data.ptr;
			ssize_t r = recv(c->fd, c->buf + c->len, (size_t)(RBUF - c->len), MSG_DONTWAIT);
			if (r == 0 || (r < 0 && errno != EAGAIN && errno != EINTR)) {
				fprintf(stderr, "connection closed with %d requests in flight\n", c->inflight);
				errors += c->inflight;
				goto out;
			}
			if (r < 0) {
				continue;
			}
			c->len += (int)r;
			int got = parse(c, &errors);
			if (got < 0) {
				fprintf(stderr, "bad response\n");
				errors++;
				goto out;
			}
			if (got == 0) {
				continue;
			}
			last = now_s();
			if (deadline == 0 || last < deadline) {
				done += got;
			}
			c->inflight -= got;
			if (c->inflight == 0) {
				int k = depth;
				if (total > 0 && total - sent < k) {
					k = (int)(total - sent);
				}
				if (k > 0 && (deadline == 0 || last < deadline)) {
					send_all(c->fd, batch, (size_t)olen * (size_t)k);
					c->inflight = k;
					sent += k;
				}
			}
		}
	}
out:;
	double el = (deadline > 0 ? (now_s() < deadline ? now_s() : deadline) : now_s()) - start;
	printf("requests=%ld errors=%ld seconds=%.3f rps=%.0f\n", done, errors, el, el > 0 ? done / el : 0.0);
	return errors == 0 ? 0 : 1;
}
