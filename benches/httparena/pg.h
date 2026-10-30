// Non-blocking Postgres pool for GET /async-db. One thread owns every PGconn
// and drives it with epoll; HTTP workers only enqueue a slot and park the
// request. libpq is not called from a worker, so a query never holds one.
#ifndef VILTRUM_HTTPARENA_PG_H
#define VILTRUM_HTTPARENA_PG_H

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <libpq-fe.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>

#define PG_SLOTS    4096
#define PG_BODY     16384
#define PG_CONN_MAX 480

enum {
	PG_FREE = 0,
	PG_QUEUED = 1,
	PG_RUN = 2,
	PG_DONE = 3,
	PG_FAIL = 4,
	PG_ABANDON = 5,
};

enum {
	PG_DOWN = 0,
	PG_CONNECT = 1,
	PG_PREPARE = 2,
	PG_IDLE = 3,
	PG_QUERY = 4,
};

static const char pg_sql[] = "SELECT id, name, category, price, quantity, active, tags::text, rating_score, rating_count FROM items WHERE price BETWEEN $1::int AND $2::int LIMIT $3::int";
static const char pg_empty[] = "{\"items\":[],\"count\":0}";

typedef struct {
	int      state;
	uint32_t gen;
	int      min_v, max_v, limit_v;
	int      body_len;
	int64_t  deadline_ms;
	char     body[PG_BODY];
} PgSlot;

typedef struct PgConn PgConn;
struct PgConn {
	PGconn *c;
	int     fd;
	int     phase;
	int     slot;
	int     watched;
	int     want;
	int64_t retry_at;
};

static PgSlot          pg_slots[PG_SLOTS];
static int             pg_free_stack[PG_SLOTS];
static int             pg_nfree;
static int             pg_queue[PG_SLOTS];
static int             pg_qh, pg_qt, pg_qcount;
static PgConn          pg_conns[PG_CONN_MAX];
static int             pg_nconn;
static pthread_mutex_t pg_mu = PTHREAD_MUTEX_INITIALIZER;
static int             pg_ep = -1;
static int             pg_ev = -1;
static int             pg_started;
static char           *pg_url;
static int             pg_ev_tag;
static void           *pg_app_ptr;
static pthread_t       pg_thread;

// Defined by the V program: resume the HTTP request parked on token.
void viltrum_pg_on_ready(uint64_t token);

static int64_t pg_now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static uint64_t pg_token(int slot) {
	return ((uint64_t)pg_slots[slot].gen << 32) | (uint64_t)(slot + 1);
}

// -1 when token does not name the slot's current generation.
static int pg_slot_of(uint64_t token) {
	uint32_t idx = (uint32_t)token;
	uint32_t gen = (uint32_t)(token >> 32);
	if (idx == 0 || idx > PG_SLOTS) {
		return -1;
	}
	int slot = (int)idx - 1;
	if (pg_slots[slot].gen != gen) {
		return -1;
	}
	return slot;
}

static void pg_slot_free(int slot) {
	PgSlot *s = &pg_slots[slot];
	s->gen = s->gen == 0xffffffffu ? 1u : s->gen + 1;
	s->state = PG_FREE;
	s->body_len = 0;
	pg_free_stack[pg_nfree++] = slot;
}

static void pg_wake_slot(int slot, int ok) {
	uint64_t token = 0;
	int      wake = 0;
	pthread_mutex_lock(&pg_mu);
	PgSlot *s = &pg_slots[slot];
	if (s->state == PG_ABANDON || s->state == PG_FREE) {
		if (s->state != PG_FREE) {
			pg_slot_free(slot);
		}
	} else {
		if (!ok) {
			memcpy(s->body, pg_empty, sizeof(pg_empty) - 1);
			s->body_len = (int)(sizeof(pg_empty) - 1);
			s->state = PG_FAIL;
		} else {
			s->state = PG_DONE;
		}
		token = pg_token(slot);
		wake = 1;
	}
	pthread_mutex_unlock(&pg_mu);
	if (wake) {
		viltrum_pg_on_ready(token);
	}
}

static int pg_jadd(PgSlot *s, const char *p, int n) {
	if (n < 0 || s->body_len + n >= PG_BODY) {
		return -1;
	}
	memcpy(s->body + s->body_len, p, (size_t)n);
	s->body_len += n;
	return 0;
}

static int pg_jstr(PgSlot *s, const char *lit) {
	return pg_jadd(s, lit, (int)strlen(lit));
}

static int pg_jesc(PgSlot *s, const char *v) {
	if (pg_jadd(s, "\"", 1)) {
		return -1;
	}
	if (v == NULL) {
		v = "";
	}
	for (const unsigned char *p = (const unsigned char *)v; *p; p++) {
		if (*p == '"' || *p == '\\') {
			char e[2] = {'\\', (char)*p};
			if (pg_jadd(s, e, 2)) {
				return -1;
			}
		} else if (*p < 0x20) {
			char b[8];
			snprintf(b, sizeof b, "\\u%04x", *p);
			if (pg_jadd(s, b, 6)) {
				return -1;
			}
		} else if (pg_jadd(s, (const char *)p, 1)) {
			return -1;
		}
	}
	return pg_jadd(s, "\"", 1);
}

static int pg_jnum(PgSlot *s, const char *v) {
	if (v == NULL || v[0] == 0) {
		return pg_jstr(s, "0");
	}
	return pg_jadd(s, v, (int)strlen(v));
}

static int pg_render(PgSlot *s, PGresult *res) {
	s->body_len = 0;
	if (pg_jstr(s, "{\"items\":[")) {
		return -1;
	}
	int n = PQntuples(res);
	for (int i = 0; i < n; i++) {
		const char *tags = PQgetisnull(res, i, 6) ? "[]" : PQgetvalue(res, i, 6);
		const char *active = PQgetisnull(res, i, 5) ? "f" : PQgetvalue(res, i, 5);
		if (i > 0 && pg_jstr(s, ",")) {
			return -1;
		}
		if (pg_jstr(s, "{\"id\":") || pg_jnum(s, PQgetvalue(res, i, 0)) || pg_jstr(s, ",\"name\":")
		    || pg_jesc(s, PQgetvalue(res, i, 1)) || pg_jstr(s, ",\"category\":")
		    || pg_jesc(s, PQgetvalue(res, i, 2)) || pg_jstr(s, ",\"price\":")
		    || pg_jnum(s, PQgetvalue(res, i, 3)) || pg_jstr(s, ",\"quantity\":")
		    || pg_jnum(s, PQgetvalue(res, i, 4)) || pg_jstr(s, ",\"active\":")
		    || pg_jstr(s, active[0] == 't' ? "true" : "false") || pg_jstr(s, ",\"tags\":")
		    || pg_jstr(s, (tags != NULL && tags[0] == '[') ? tags : "[]")
		    || pg_jstr(s, ",\"rating\":{\"score\":") || pg_jnum(s, PQgetvalue(res, i, 7))
		    || pg_jstr(s, ",\"count\":") || pg_jnum(s, PQgetvalue(res, i, 8)) || pg_jstr(s, "}}")) {
			return -1;
		}
	}
	char nb[16];
	snprintf(nb, sizeof nb, "%d", n);
	if (pg_jstr(s, "],\"count\":") || pg_jstr(s, nb) || pg_jstr(s, "}")) {
		return -1;
	}
	return 0;
}

static void pg_unwatch(PgConn *cn) {
	if (cn->watched && cn->fd >= 0) {
		epoll_ctl(pg_ep, EPOLL_CTL_DEL, cn->fd, NULL);
	}
	cn->watched = 0;
	cn->want = 0;
}

static void pg_interest(PgConn *cn, int want) {
	if (cn->fd < 0) {
		return;
	}
	struct epoll_event ev;
	memset(&ev, 0, sizeof ev);
	ev.events = (uint32_t)want;
	ev.data.ptr = cn;
	int op = cn->watched ? EPOLL_CTL_MOD : EPOLL_CTL_ADD;
	if (!cn->watched || cn->want != want) {
		if (epoll_ctl(pg_ep, op, cn->fd, &ev) == 0) {
			cn->watched = 1;
			cn->want = want;
		}
	}
}

static void pg_drop(PgConn *cn, int fail_slot) {
	int slot = cn->slot;
	cn->slot = -1;
	pg_unwatch(cn);
	if (cn->c != NULL) {
		PQfinish(cn->c);
		cn->c = NULL;
	}
	cn->fd = -1;
	cn->phase = PG_DOWN;
	cn->retry_at = pg_now_ms() + 100;
	if (fail_slot && slot >= 0) {
		pg_wake_slot(slot, 0);
	}
}

static void pg_assign(void);

static void pg_flush(PgConn *cn) {
	int f = PQflush(cn->c);
	if (f < 0) {
		pg_drop(cn, 1);
		return;
	}
	pg_interest(cn, f == 1 ? EPOLLOUT : (EPOLLIN | EPOLLRDHUP));
}

static void pg_command_done(PgConn *cn) {
	if (PQconsumeInput(cn->c) == 0) {
		pg_drop(cn, 1);
		return;
	}
	if (PQisBusy(cn->c)) {
		pg_interest(cn, EPOLLIN | EPOLLRDHUP);
		return;
	}
	PGresult *res = PQgetResult(cn->c);
	int       ok = res != NULL && PQresultStatus(res) == PGRES_COMMAND_OK;
	if (res != NULL) {
		PQclear(res);
	}
	PGresult *extra;
	while ((extra = PQgetResult(cn->c)) != NULL) {
		PQclear(extra);
	}
	if (!ok || PQstatus(cn->c) != CONNECTION_OK) {
		pg_drop(cn, 1);
		return;
	}
	cn->phase = PG_IDLE;
	pg_unwatch(cn);
	pg_assign();
}

static void pg_rows_done(PgConn *cn) {
	if (PQconsumeInput(cn->c) == 0) {
		pg_drop(cn, 1);
		return;
	}
	if (PQisBusy(cn->c)) {
		pg_interest(cn, EPOLLIN | EPOLLRDHUP);
		return;
	}
	PGresult *res = PQgetResult(cn->c);
	int       slot = cn->slot;
	int       ok = 0;
	if (slot >= 0 && res != NULL && PQresultStatus(res) == PGRES_TUPLES_OK) {
		ok = pg_render(&pg_slots[slot], res) == 0;
	}
	if (res != NULL) {
		PQclear(res);
	}
	PGresult *extra;
	while ((extra = PQgetResult(cn->c)) != NULL) {
		PQclear(extra);
	}
	cn->slot = -1;
	if (PQstatus(cn->c) != CONNECTION_OK) {
		cn->phase = PG_DOWN;
		pg_drop(cn, 0);
		if (slot >= 0) {
			pg_wake_slot(slot, 0);
		}
		return;
	}
	cn->phase = PG_IDLE;
	pg_unwatch(cn);
	if (slot >= 0) {
		pg_wake_slot(slot, ok);
	}
	pg_assign();
}

static void pg_start_prepare(PgConn *cn) {
	if (PQsendPrepare(cn->c, "adb", pg_sql, 3, NULL) == 0) {
		pg_drop(cn, 1);
		return;
	}
	cn->phase = PG_PREPARE;
	pg_flush(cn);
}

static void pg_poll_connect(PgConn *cn) {
	PostgresPollingStatusType st = PQconnectPoll(cn->c);
	int                       fd = PQsocket(cn->c);
	if (fd != cn->fd) {
		pg_unwatch(cn);
		cn->fd = fd;
	}
	if (st == PGRES_POLLING_READING) {
		pg_interest(cn, EPOLLIN | EPOLLRDHUP);
	} else if (st == PGRES_POLLING_WRITING) {
		pg_interest(cn, EPOLLOUT);
	} else if (st == PGRES_POLLING_OK) {
		pg_start_prepare(cn);
	} else {
		pg_drop(cn, 1);
	}
}

static void pg_start_connect(PgConn *cn) {
	if (cn->c != NULL) {
		pg_unwatch(cn);
		PQfinish(cn->c);
		cn->c = NULL;
	}
	cn->fd = -1;
	cn->c = PQconnectStart(pg_url);
	if (cn->c == NULL || PQstatus(cn->c) == CONNECTION_BAD) {
		if (cn->c != NULL) {
			PQfinish(cn->c);
			cn->c = NULL;
		}
		cn->phase = PG_DOWN;
		cn->retry_at = pg_now_ms() + 100;
		return;
	}
	PQsetnonblocking(cn->c, 1);
	cn->fd = PQsocket(cn->c);
	cn->phase = PG_CONNECT;
	pg_poll_connect(cn);
}

static void pg_assign(void) {
	for (;;) {
		PgConn *cn = NULL;
		for (int i = 0; i < pg_nconn; i++) {
			if (pg_conns[i].phase == PG_IDLE && pg_conns[i].slot < 0) {
				cn = &pg_conns[i];
				break;
			}
		}
		if (cn == NULL) {
			return;
		}
		int slot = -1;
		pthread_mutex_lock(&pg_mu);
		while (pg_qcount > 0) {
			int s = pg_queue[pg_qh];
			pg_qh = (pg_qh + 1) % PG_SLOTS;
			pg_qcount--;
			if (pg_slots[s].state == PG_QUEUED) {
				pg_slots[s].state = PG_RUN;
				slot = s;
				break;
			}
			if (pg_slots[s].state == PG_ABANDON) {
				pg_slot_free(s);
			}
		}
		pthread_mutex_unlock(&pg_mu);
		if (slot < 0) {
			return;
		}
		char        a[16], b[16], d[16];
		const char *vals[3];
		snprintf(a, sizeof a, "%d", pg_slots[slot].min_v);
		snprintf(b, sizeof b, "%d", pg_slots[slot].max_v);
		snprintf(d, sizeof d, "%d", pg_slots[slot].limit_v);
		vals[0] = a;
		vals[1] = b;
		vals[2] = d;
		cn->slot = slot;
		cn->phase = PG_QUERY;
		if (PQsendQueryPrepared(cn->c, "adb", 3, vals, NULL, NULL, 0) == 0) {
			cn->slot = -1;
			pg_wake_slot(slot, 0);
			pg_drop(cn, 0);
			continue;
		}
		pg_flush(cn);
	}
}

static void pg_on_conn(PgConn *cn, uint32_t events) {
	if (cn->phase == PG_CONNECT) {
		pg_poll_connect(cn);
		return;
	}
	if (events & (EPOLLERR | EPOLLHUP | EPOLLRDHUP)) {
		if (cn->phase == PG_QUERY || cn->phase == PG_PREPARE) {
			// still try to read what libpq has; a clean result may have arrived
			if (cn->phase == PG_QUERY) {
				pg_rows_done(cn);
			} else {
				pg_command_done(cn);
			}
			return;
		}
	}
	if ((events & EPOLLOUT) && (cn->phase == PG_QUERY || cn->phase == PG_PREPARE)) {
		pg_flush(cn);
		if (cn->phase != PG_QUERY && cn->phase != PG_PREPARE) {
			return;
		}
		if (cn->want & EPOLLOUT) {
			return;
		}
	}
	if (events & (EPOLLIN | EPOLLRDHUP | EPOLLERR | EPOLLHUP)) {
		if (cn->phase == PG_QUERY) {
			pg_rows_done(cn);
		} else if (cn->phase == PG_PREPARE) {
			pg_command_done(cn);
		}
	}
}

static void *pg_main(void *unused) {
	(void)unused;
	for (int i = 0; i < pg_nconn; i++) {
		pg_conns[i].slot = -1;
		pg_conns[i].fd = -1;
		pg_conns[i].phase = PG_DOWN;
		pg_start_connect(&pg_conns[i]);
	}
	struct epoll_event evs[64];
	for (;;) {
		int timeout = -1;
		int64_t now = pg_now_ms();
		for (int i = 0; i < pg_nconn; i++) {
			if (pg_conns[i].phase == PG_DOWN) {
				timeout = 100;
				if (pg_conns[i].retry_at <= now) {
					pg_start_connect(&pg_conns[i]);
				}
			}
		}
		int n = epoll_wait(pg_ep, evs, 64, timeout);
		for (int i = 0; i < n; i++) {
			if (evs[i].data.ptr == &pg_ev_tag) {
				uint64_t v;
				if (read(pg_ev, &v, 8) < 0 && errno != EAGAIN) {
					// the thread stays up; the next submit writes again
				}
				pg_assign();
				continue;
			}
			pg_on_conn((PgConn *)evs[i].data.ptr, evs[i].events);
		}
		now = pg_now_ms();
		for (int i = 0; i < pg_nconn; i++) {
			if (pg_conns[i].phase == PG_DOWN && pg_conns[i].retry_at <= now) {
				pg_start_connect(&pg_conns[i]);
			}
		}
	}
	return NULL;
}

void viltrum_pg_bind(void *app) {
	pg_app_ptr = app;
}

void *viltrum_pg_app(void) {
	return pg_app_ptr;
}

int viltrum_pg_start(char *url, int max_conn) {
	if (pg_started || url == NULL || url[0] == 0) {
		return -1;
	}
	pg_url = strdup(url);
	if (pg_url == NULL) {
		return -1;
	}
	int n = max_conn - 4; // Postgres keeps a few connections for the superuser
	if (n < 1) {
		n = 1;
	}
	if (n > PG_CONN_MAX) {
		n = PG_CONN_MAX;
	}
	pg_nconn = n;
	pg_nfree = 0;
	for (int i = PG_SLOTS - 1; i >= 0; i--) {
		pg_slots[i].state = PG_FREE;
		pg_slots[i].gen = 1;
		pg_free_stack[pg_nfree++] = i;
	}
	pg_ep = epoll_create1(EPOLL_CLOEXEC);
	pg_ev = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	if (pg_ep < 0 || pg_ev < 0) {
		return -1;
	}
	struct epoll_event ev;
	memset(&ev, 0, sizeof ev);
	ev.events = EPOLLIN;
	ev.data.ptr = &pg_ev_tag;
	if (epoll_ctl(pg_ep, EPOLL_CTL_ADD, pg_ev, &ev) != 0) {
		return -1;
	}
	pg_started = 1;
	if (pthread_create(&pg_thread, NULL, pg_main, NULL) != 0) {
		pg_started = 0;
		return -1;
	}
	return 0;
}

uint64_t viltrum_pg_submit(int min_v, int max_v, int limit_v) {
	if (!pg_started) {
		return 0;
	}
	pthread_mutex_lock(&pg_mu);
	if (pg_nfree <= 0 || pg_qcount >= PG_SLOTS) {
		pthread_mutex_unlock(&pg_mu);
		return 0;
	}
	int     slot = pg_free_stack[--pg_nfree];
	PgSlot *s = &pg_slots[slot];
	s->min_v = min_v;
	s->max_v = max_v;
	s->limit_v = limit_v;
	s->body_len = 0;
	s->deadline_ms = pg_now_ms() + 30000;
	s->state = PG_QUEUED;
	pg_queue[pg_qt] = slot;
	pg_qt = (pg_qt + 1) % PG_SLOTS;
	pg_qcount++;
	uint64_t token = pg_token(slot);
	pthread_mutex_unlock(&pg_mu);
	uint64_t one = 1;
	if (write(pg_ev, &one, 8) < 0 && errno != EAGAIN) {
		// the thread also retries down connections on its timeout
	}
	return token;
}

// 1 result ready, 0 still running, -1 failed or unknown token.
int viltrum_pg_status(uint64_t token) {
	pthread_mutex_lock(&pg_mu);
	int slot = pg_slot_of(token);
	int st = -1;
	if (slot >= 0) {
		int state = pg_slots[slot].state;
		if (state == PG_DONE) {
			st = 1;
		} else if (state == PG_FAIL) {
			st = -1;
		} else {
			st = 0;
		}
	}
	pthread_mutex_unlock(&pg_mu);
	return st;
}

// 1 when the request has waited long enough that an empty body is the answer.
int viltrum_pg_expired(uint64_t token) {
	pthread_mutex_lock(&pg_mu);
	int slot = pg_slot_of(token);
	int expired = 1;
	if (slot >= 0 && pg_now_ms() + 50 < pg_slots[slot].deadline_ms) {
		expired = 0;
	}
	pthread_mutex_unlock(&pg_mu);
	return expired;
}

char *viltrum_pg_body(uint64_t token, int *n) {
	pthread_mutex_lock(&pg_mu);
	int         slot = pg_slot_of(token);
	char *p = (char *)pg_empty;
	int         len = (int)(sizeof(pg_empty) - 1);
	if (slot >= 0 && pg_slots[slot].body_len > 0
	    && (pg_slots[slot].state == PG_DONE || pg_slots[slot].state == PG_FAIL)) {
		p = pg_slots[slot].body;
		len = pg_slots[slot].body_len;
	}
	pthread_mutex_unlock(&pg_mu);
	if (n != NULL) {
		*n = len;
	}
	return p;
}

void viltrum_pg_release(uint64_t token) {
	pthread_mutex_lock(&pg_mu);
	int slot = pg_slot_of(token);
	if (slot >= 0) {
		int state = pg_slots[slot].state;
		if (state == PG_RUN || state == PG_QUEUED) {
			pg_slots[slot].state = PG_ABANDON;
		} else if (state != PG_FREE) {
			pg_slot_free(slot);
		}
	}
	pthread_mutex_unlock(&pg_mu);
}

#endif
