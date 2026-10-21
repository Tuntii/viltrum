// tls_linux.h: the C side of the engine's mbedtls integration. Things that are
// awkward from V: static tables mbedtls keeps pointers to, BIO callbacks that map
// errno, struct fields V's mbedtls declarations leave opaque, and stat with ns mtime.
#ifndef VILTRUM_TLS_LINUX_H
#define VILTRUM_TLS_LINUX_H

#include <errno.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <mbedtls/ssl.h>
#include <mbedtls/ssl_ciphersuites.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/ctr_drbg.h>
#include <psa/crypto.h>

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

// We speak HTTP/1.1 only, so that is all ALPN offers.
static const char *viltrum_tls_alpn[] = {"http/1.1", NULL};

// viltrum_tls_conf applies the server policy to conf. The certificate comes from
// cert_cb on every handshake rather than being bound here, which is what lets a
// replaced file take effect without touching live connections.
static int viltrum_tls_conf(mbedtls_ssl_config *conf, int (*cert_cb)(mbedtls_ssl_context *),
		mbedtls_ctr_drbg_context *drbg) {
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
	ret = mbedtls_ssl_conf_alpn_protocols(conf, viltrum_tls_alpn);
	if (ret != 0) {
		return ret;
	}
	mbedtls_ssl_conf_cert_cb(conf, cert_cb);
	return 0;
}

// BIO callbacks. ctx points at the connection's fd. MSG_NOSIGNAL: a peer that has
// gone must not raise SIGPIPE.
static int viltrum_tls_send(void *ctx, const unsigned char *buf, size_t len) {
	ssize_t n = send(*(int *)ctx, buf, len, MSG_NOSIGNAL);
	if (n < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
			return MBEDTLS_ERR_SSL_WANT_WRITE;
		}
		return MBEDTLS_ERR_NET_SEND_FAILED;
	}
	return (int)n;
}

static int viltrum_tls_recv(void *ctx, unsigned char *buf, size_t len) {
	ssize_t n = recv(*(int *)ctx, buf, len, 0);
	if (n < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
			return MBEDTLS_ERR_SSL_WANT_READ;
		}
		return MBEDTLS_ERR_NET_RECV_FAILED;
	}
	return (int)n;
}

// net.mbedtls declares session_reset without its result; this keeps it.
static int viltrum_tls_reset(mbedtls_ssl_context *ssl) {
	return mbedtls_ssl_session_reset(ssl);
}

static void viltrum_tls_set_bio(mbedtls_ssl_context *ssl, int *fd) {
	mbedtls_ssl_set_bio(ssl, fd, viltrum_tls_send, viltrum_tls_recv, NULL);
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
