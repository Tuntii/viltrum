// tls_linux.h: the C side of the engine's mbedtls integration. Things that are
// awkward from V: static tables mbedtls keeps pointers to, BIO callbacks that map
// errno, struct fields V's mbedtls declarations leave opaque, and stat with ns mtime.
#ifndef VILTRUM_TLS_LINUX_H
#define VILTRUM_TLS_LINUX_H

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <mbedtls/ssl.h>
#include <mbedtls/ssl_ciphersuites.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/ctr_drbg.h>
#include <psa/crypto.h>
#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>

// viltrum_tls_wipe zeroes key material where the compiler may not drop the stores.
static void viltrum_tls_wipe(void *p, size_t n) {
	volatile unsigned char *b = (volatile unsigned char *)p;
	for (size_t i = 0; i < n; i++) {
		b[i] = 0;
	}
}

// AEAD only. mbedtls 3.x has no SSLv3, TLS 1.0 or 1.1 at all; the floor below is 1.2.
static const int viltrum_tls_suites[] = {
	MBEDTLS_TLS1_3_AES_128_GCM_SHA256,
	MBEDTLS_TLS1_3_AES_256_GCM_SHA384,
	MBEDTLS_TLS1_3_CHACHA20_POLY1305_SHA256,
	MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
	MBEDTLS_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
	MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
	MBEDTLS_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
	MBEDTLS_TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
	MBEDTLS_TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
	0,
};

static const uint16_t viltrum_tls_groups[] = {
	MBEDTLS_SSL_IANA_TLS_GROUP_X25519,
	MBEDTLS_SSL_IANA_TLS_GROUP_SECP256R1,
	MBEDTLS_SSL_IANA_TLS_GROUP_SECP384R1,
	MBEDTLS_SSL_IANA_TLS_GROUP_NONE,
};

// What ALPN offers: HTTP/1.1, and h2 first on a listener that speaks it (mbedtls
// takes the first of ours the client also offers).
static const char *viltrum_tls_alpn[] = {"http/1.1", NULL};
static const char *viltrum_tls_alpn_h2[] = {"h2", "http/1.1", NULL};

// viltrum_tls_conf applies the server policy to conf. The certificate comes from
// cert_cb on every handshake rather than being bound here, which is what lets a
// replaced file take effect without touching live connections.
static int viltrum_tls_conf(mbedtls_ssl_config *conf, int (*cert_cb)(mbedtls_ssl_context *),
		mbedtls_ctr_drbg_context *drbg, int h2) {
	int ret = mbedtls_ssl_config_defaults(conf, MBEDTLS_SSL_IS_SERVER,
		MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
	if (ret != 0) {
		return ret;
	}
	mbedtls_ssl_conf_rng(conf, mbedtls_ctr_drbg_random, drbg);
	mbedtls_ssl_conf_authmode(conf, MBEDTLS_SSL_VERIFY_NONE);
	mbedtls_ssl_conf_min_tls_version(conf, MBEDTLS_SSL_VERSION_TLS1_2);
	mbedtls_ssl_conf_max_tls_version(conf, MBEDTLS_SSL_VERSION_TLS1_3);
	mbedtls_ssl_conf_ciphersuites(conf, viltrum_tls_suites);
	mbedtls_ssl_conf_groups(conf, viltrum_tls_groups);
	mbedtls_ssl_conf_renegotiation(conf, MBEDTLS_SSL_RENEGOTIATION_DISABLED);
#if defined(MBEDTLS_SSL_SESSION_TICKETS) && defined(MBEDTLS_SSL_PROTO_TLS1_3)
	// no ticket keys are configured; do not promise tickets in TLS 1.3 either
	mbedtls_ssl_conf_new_session_tickets(conf, 0);
#endif
	ret = mbedtls_ssl_conf_alpn_protocols(conf, h2 ? viltrum_tls_alpn_h2 : viltrum_tls_alpn);
	if (ret != 0) {
		return ret;
	}
	mbedtls_ssl_conf_cert_cb(conf, cert_cb);
	return 0;
}

// viltrum_bio is the transport under one TLS session. mbedtls reads a record as a
// 5-byte header and then the body, two recv calls; reading ahead into buf turns that
// into one per batch of records. drained means the last recv came back short, so the
// socket is empty until epoll says otherwise (level-triggered, so it will): no
// EAGAIN syscall to find that out.
typedef struct {
	int *fd;
	unsigned char *buf;
	size_t cap;
	size_t off;
	size_t len;
	int drained;
} viltrum_bio;

// BIO callbacks. MSG_NOSIGNAL: a peer that has gone must not raise SIGPIPE.
static int viltrum_tls_send(void *ctx, const unsigned char *buf, size_t len) {
	ssize_t n = send(*((viltrum_bio *)ctx)->fd, buf, len, MSG_NOSIGNAL);
	if (n < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
			return MBEDTLS_ERR_SSL_WANT_WRITE;
		}
		return MBEDTLS_ERR_NET_SEND_FAILED;
	}
	return (int)n;
}

static int viltrum_tls_recv(void *ctx, unsigned char *buf, size_t len) {
	viltrum_bio *b = (viltrum_bio *)ctx;
	if (b->off == b->len) {
		if (b->drained) {
			return MBEDTLS_ERR_SSL_WANT_READ;
		}
		ssize_t n = recv(*b->fd, b->buf, b->cap, 0);
		if (n < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
				b->drained = 1;
				return MBEDTLS_ERR_SSL_WANT_READ;
			}
			return MBEDTLS_ERR_NET_RECV_FAILED;
		}
		if (n == 0) {
			return 0;
		}
		b->off = 0;
		b->len = (size_t)n;
		b->drained = (size_t)n < b->cap;
	}
	size_t k = b->len - b->off;
	if (k > len) {
		k = len;
	}
	memcpy(buf, b->buf + b->off, k);
	b->off += k;
	return (int)k;
}

// net.mbedtls declares session_reset without its result; this keeps it.
static void viltrum_tls_bio_init(viltrum_bio *b, int *fd, unsigned char *buf, size_t cap) {
	b->fd = fd;
	b->buf = buf;
	b->cap = cap;
	b->off = 0;
	b->len = 0;
	b->drained = 0;
}

// viltrum_tls_bind_bio puts ssl on b, whatever b has read ahead already: hs13 may have
// read the ClientHello it hands to mbedtls.
static void viltrum_tls_bind_bio(mbedtls_ssl_context *ssl, viltrum_bio *b) {
	mbedtls_ssl_set_bio(ssl, b, viltrum_tls_send, viltrum_tls_recv, NULL);
}

// viltrum_tls_check_pair reports whether key is the private half of crt's leaf key.
static int viltrum_tls_check_pair(mbedtls_x509_crt *crt, mbedtls_pk_context *key,
		mbedtls_ctr_drbg_context *drbg) {
	return mbedtls_pk_check_pair(&crt->pk, key, mbedtls_ctr_drbg_random, drbg);
}

static int viltrum_tls_load_key(mbedtls_pk_context *key, const char *path,
		mbedtls_ctr_drbg_context *drbg) {
	return mbedtls_pk_parse_keyfile(key, path, NULL, mbedtls_ctr_drbg_random, drbg);
}

static int viltrum_tls_seed(mbedtls_ctr_drbg_context *drbg, mbedtls_entropy_context *entropy) {
	static const unsigned char pers[] = "viltrum";
	return mbedtls_ctr_drbg_seed(drbg, mbedtls_entropy_func, entropy, pers, sizeof(pers) - 1);
}

// viltrum_tls_secrets receives the TLS 1.3 application traffic secrets as the
// handshake derives them (mbedtls' key export callback), so the record layer can
// move to tls13.v once the handshake is done.
typedef struct {
	unsigned char client[48];
	unsigned char server[48];
	size_t len;
	int have; // 1: client, 2: server
} viltrum_tls_secrets;

static void viltrum_tls_export(void *p, mbedtls_ssl_key_export_type type, const unsigned char *secret,
		size_t secret_len, const unsigned char client_random[32], const unsigned char server_random[32],
		mbedtls_tls_prf_types prf) {
	(void)client_random;
	(void)server_random;
	(void)prf;
	viltrum_tls_secrets *s = (viltrum_tls_secrets *)p;
	if (secret_len > sizeof(s->client)) {
		return;
	}
	if (type == MBEDTLS_SSL_KEY_EXPORT_TLS1_3_CLIENT_APPLICATION_TRAFFIC_SECRET) {
		memcpy(s->client, secret, secret_len);
		s->len = secret_len;
		s->have |= 1;
	} else if (type == MBEDTLS_SSL_KEY_EXPORT_TLS1_3_SERVER_APPLICATION_TRAFFIC_SECRET) {
		memcpy(s->server, secret, secret_len);
		s->len = secret_len;
		s->have |= 2;
	}
}

static void viltrum_tls_set_export(mbedtls_ssl_context *ssl, viltrum_tls_secrets *s) {
	viltrum_tls_wipe(s, sizeof(*s));
	mbedtls_ssl_set_export_keys_cb(ssl, viltrum_tls_export, s);
}

static int viltrum_tls_is13(const mbedtls_ssl_context *ssl) {
	return mbedtls_ssl_get_version_number(ssl) == MBEDTLS_SSL_VERSION_TLS1_3;
}

// viltrum_tls_fresh is true until a ClientHello has been processed: the next step is
// the one that runs the key exchange and signs with the certificate's key.
static int viltrum_tls_fresh(const mbedtls_ssl_context *ssl) {
	return ssl->MBEDTLS_PRIVATE(state) <= MBEDTLS_SSL_CLIENT_HELLO;
}

// viltrum_tls13_expand is HKDF-Expand-Label (RFC 8446 7.1) with an empty context:
// out_len bytes of label ("key", "iv", "traffic upd") from secret, over SHA-256 or
// SHA-384 as the cipher suite says.
static int viltrum_tls13_expand(int sha384, const unsigned char *secret, size_t secret_len,
		const char *label, unsigned char *out, size_t out_len) {
	unsigned char info[2 + 1 + 6 + 16 + 1];
	size_t ll = strlen(label);
	if (ll > 16) {
		return -1;
	}
	info[0] = (unsigned char)(out_len >> 8);
	info[1] = (unsigned char)out_len;
	info[2] = (unsigned char)(6 + ll);
	memcpy(info + 3, "tls13 ", 6);
	memcpy(info + 9, label, ll);
	info[9 + ll] = 0; // context: empty
	const mbedtls_md_info_t *md = mbedtls_md_info_from_type(sha384 ? MBEDTLS_MD_SHA384 : MBEDTLS_MD_SHA256);
	if (md == NULL) {
		return -1;
	}
	return mbedtls_hkdf_expand(md, secret, secret_len, info, 10 + ll, out, out_len);
}

// FileId tells a replaced file from the one already loaded: a rename onto the path
// changes the inode, an in-place rewrite changes mtime or size.
typedef struct {
	uint64_t dev;
	uint64_t ino;
	int64_t size;
	int64_t mtime_sec;
	int64_t mtime_nsec;
} viltrum_file_id;

static int viltrum_tls_file_id(const char *path, viltrum_file_id *out) {
	struct stat st;
	if (stat(path, &st) != 0) {
		return -1;
	}
	out->dev = (uint64_t)st.st_dev;
	out->ino = (uint64_t)st.st_ino;
	out->size = (int64_t)st.st_size;
	out->mtime_sec = (int64_t)st.st_mtim.tv_sec;
	out->mtime_nsec = (int64_t)st.st_mtim.tv_nsec;
	return 0;
}

#endif
