// hs13.h: viltrum's own TLS 1.3 server handshake (RFC 8446) for the one shape that
// almost every client offers: TLS 1.3, X25519, TLS_AES_128_GCM_SHA256 and an RSA
// certificate signed for with rsa_pss_rsae_sha256. The handshake was mbedtls' (about
// 7 ms of CPU on the test VM against 3 ms for OpenSSL): x25519.h and rsa.h do its two
// expensive steps, this file the messages and the key schedule. SHA-256, HMAC and
// HKDF stay on mbedtls: they cost microseconds here.
//
// Anything else goes to mbedtls unchanged: TLS 1.2, a ClientHello without an X25519
// key share (it would need a HelloRetryRequest), another certificate key, early data,
// a ClientHello split across records. viltrum_hs13_parse only reads the ClientHello,
// so the bytes are still there for mbedtls when it says no. No session tickets are
// issued (as with mbedtls here), so a pre_shared_key offer is ignored and the
// handshake is a full one; no client certificate is asked for.
//
// Every read of the ClientHello is bounded by the length it was given. In
// engine/hs13_linux_test.v the parser is fuzzed and the key schedule checked against
// RFC 8448's trace; engine/tls_linux_test.v runs the handshake against mbedtls'
// client and OpenSSL's.
#ifndef VILTRUM_HS13_H
#define VILTRUM_HS13_H

#include <stdint.h>
#include <string.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/hkdf.h>
#include <mbedtls/md.h>
#include <mbedtls/sha256.h>
#include <mbedtls/x509_crt.h>
#include "aesgcm.h"
#include "rsa.h"
#include "x25519.h"

#define VILTRUM_HS13_GROUP_X25519 0x001d
#define VILTRUM_HS13_SUITE 0x1301 // TLS_AES_128_GCM_SHA256
#define VILTRUM_HS13_SIG_PSS_SHA256 0x0804
#define VILTRUM_HS13_MAX_EXT 64

// What a ClientHello hs13 serves told it.
typedef struct {
	uint8_t random[32];
	uint8_t session_id[32];
	size_t session_id_len;
	uint8_t share[32]; // the client's X25519 public key
	int alpn;          // what ALPN chose: 0 none offered, 1 http/1.1, 2 h2
	int h2;            // set by the caller: the listener speaks h2, so h2 is chosen when offered
} viltrum_hs13_hello;

// What the rest of the handshake needs once the server flight is out.
typedef struct {
	uint8_t c_key[16]; // the client's handshake key and IV: its Finished arrives under them
	uint8_t c_iv[12];
	uint8_t c_fin[32]; // the client Finished verify_data to expect
	uint8_t c_ap[32];  // application traffic secrets
	uint8_t s_ap[32];
	uint8_t s_iv[12];  // the server handshake IV and the next record's sequence number under
	uint64_t s_seq;    // it (the key stays in tx): for an alert before the switch
} viltrum_hs13_keys;

static void viltrum_hs13_wipe(void *p, size_t n) {
	volatile unsigned char *b = (volatile unsigned char *)p;
	for (size_t i = 0; i < n; i++) {
		b[i] = 0;
	}
}

// A bounded reader: every take checks the length first, and a failed take leaves
// ok cleared for good, so a parse checks ok once at the end of a step.
typedef struct {
	const uint8_t *p;
	size_t n;
	int ok;
} viltrum_hs13_rd;

static viltrum_hs13_rd viltrum_hs13_rd_new(const uint8_t *p, size_t n) {
	viltrum_hs13_rd r = {p, n, 1};
	return r;
}

static const uint8_t *viltrum_hs13_take(viltrum_hs13_rd *r, size_t n) {
	if (!r->ok || r->n < n) {
		r->ok = 0;
		r->n = 0;
		return NULL;
	}
	const uint8_t *p = r->p;
	r->p += n;
	r->n -= n;
	return p;
}

static uint32_t viltrum_hs13_u8(viltrum_hs13_rd *r) {
	const uint8_t *p = viltrum_hs13_take(r, 1);
	return p ? p[0] : 0;
}

static uint32_t viltrum_hs13_u16(viltrum_hs13_rd *r) {
	const uint8_t *p = viltrum_hs13_take(r, 2);
	return p ? (uint32_t)p[0] << 8 | p[1] : 0;
}

static uint32_t viltrum_hs13_u24(viltrum_hs13_rd *r) {
	const uint8_t *p = viltrum_hs13_take(r, 3);
	return p ? (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2] : 0;
}

// viltrum_hs13_sub splits off a vector of n bytes as its own reader.
static viltrum_hs13_rd viltrum_hs13_sub(viltrum_hs13_rd *r, size_t n) {
	const uint8_t *p = viltrum_hs13_take(r, n);
	viltrum_hs13_rd s = {p, p ? n : 0, p != NULL};
	return s;
}

// viltrum_hs13_parse reads one ClientHello handshake message (msg: its 4-byte header
// and body). 1: hs13 serves it, h filled in; 0: mbedtls should take it (not a hello
// hs13 serves, or malformed before it said TLS 1.3); -1: a TLS 1.3 hello that breaks
// the rules, refuse the connection.
static int viltrum_hs13_parse(const uint8_t *msg, size_t len, viltrum_hs13_hello *h) {
	int h2_ok = h->h2; // the caller's, kept across the reset
	memset(h, 0, sizeof(*h));
	h->h2 = h2_ok;
	int v13 = 0; // the hello offers TLS 1.3: from here on its faults are ours to refuse
	viltrum_hs13_rd r = viltrum_hs13_rd_new(msg, len);
	if (viltrum_hs13_u8(&r) != 1 || viltrum_hs13_u24(&r) != len - 4 || !r.ok) {
		goto malformed;
	}
	uint32_t legacy_version = viltrum_hs13_u16(&r);
	const uint8_t *random = viltrum_hs13_take(&r, 32);
	uint32_t sid_len = viltrum_hs13_u8(&r);
	const uint8_t *sid = viltrum_hs13_take(&r, sid_len);
	viltrum_hs13_rd suites = viltrum_hs13_sub(&r, viltrum_hs13_u16(&r));
	viltrum_hs13_rd comp = viltrum_hs13_sub(&r, viltrum_hs13_u8(&r));
	if (!r.ok || sid_len > 32 || suites.n == 0 || suites.n % 2 != 0 || comp.n == 0) {
		goto malformed;
	}
	if (r.n == 0) {
		return 0; // no extensions: not TLS 1.3, mbedtls' to answer
	}
	viltrum_hs13_rd exts = viltrum_hs13_sub(&r, viltrum_hs13_u16(&r));
	if (!r.ok || r.n != 0) {
		goto malformed; // trailing bytes after the extensions
	}
	int suite = 0;
	while (suites.n > 0) {
		suite |= viltrum_hs13_u16(&suites) == VILTRUM_HS13_SUITE;
	}
	// TLS 1.3 requires legacy_compression_methods to be exactly one null method
	int comp_null_only = comp.n == 1 && viltrum_hs13_u8(&comp) == 0;
	uint32_t seen[VILTRUM_HS13_MAX_EXT];
	int nseen = 0;
	int x25519_group = 0, share = 0, pss = 0, alpn = 0, alpn_h11 = 0, alpn_h2 = 0, defer = 0;
	while (exts.n > 0) {
		uint32_t type = viltrum_hs13_u16(&exts);
		viltrum_hs13_rd ext = viltrum_hs13_sub(&exts, viltrum_hs13_u16(&exts));
		if (!exts.ok) {
			goto malformed;
		}
		if (nseen == VILTRUM_HS13_MAX_EXT) {
			return 0; // an unusual hello: leave it to mbedtls
		}
		for (int i = 0; i < nseen; i++) {
			if (seen[i] == type) {
				goto malformed; // RFC 8446 4.2: no extension type twice
			}
		}
		seen[nseen++] = type;
		switch (type) {
		case 43: { // supported_versions
			viltrum_hs13_rd v = viltrum_hs13_sub(&ext, viltrum_hs13_u8(&ext));
			if (!ext.ok || ext.n != 0 || v.n == 0 || v.n % 2 != 0) {
				goto malformed;
			}
			while (v.n > 0) {
				v13 |= viltrum_hs13_u16(&v) == 0x0304;
			}
			break;
		}
		case 10: { // supported_groups
			viltrum_hs13_rd g = viltrum_hs13_sub(&ext, viltrum_hs13_u16(&ext));
			if (!ext.ok || ext.n != 0 || g.n == 0 || g.n % 2 != 0) {
				goto malformed;
			}
			while (g.n > 0) {
				x25519_group |= viltrum_hs13_u16(&g) == VILTRUM_HS13_GROUP_X25519;
			}
			break;
		}
		case 51: { // key_share
			viltrum_hs13_rd ks = viltrum_hs13_sub(&ext, viltrum_hs13_u16(&ext));
			if (!ext.ok || ext.n != 0) {
				goto malformed;
			}
			while (ks.n > 0) {
				uint32_t group = viltrum_hs13_u16(&ks);
				uint32_t klen = viltrum_hs13_u16(&ks);
				const uint8_t *key = viltrum_hs13_take(&ks, klen);
				if (!ks.ok || klen == 0) {
					goto malformed;
				}
				if (group == VILTRUM_HS13_GROUP_X25519) {
					if (klen != 32 || share) {
						goto malformed; // RFC 8446 4.2.8: one share per group
					}
					memcpy(h->share, key, 32);
					share = 1;
				}
			}
			break;
		}
		case 13: { // signature_algorithms
			viltrum_hs13_rd s = viltrum_hs13_sub(&ext, viltrum_hs13_u16(&ext));
			if (!ext.ok || ext.n != 0 || s.n == 0 || s.n % 2 != 0) {
				goto malformed;
			}
			while (s.n > 0) {
				pss |= viltrum_hs13_u16(&s) == VILTRUM_HS13_SIG_PSS_SHA256;
			}
			break;
		}
		case 16: { // application_layer_protocol_negotiation
			viltrum_hs13_rd l = viltrum_hs13_sub(&ext, viltrum_hs13_u16(&ext));
			if (!ext.ok || ext.n != 0 || l.n == 0) {
				goto malformed;
			}
			alpn = 1;
			while (l.n > 0) {
				uint32_t plen = viltrum_hs13_u8(&l);
				const uint8_t *proto = viltrum_hs13_take(&l, plen);
				if (!l.ok || plen == 0) {
					goto malformed;
				}
				alpn_h11 |= plen == 8 && memcmp(proto, "http/1.1", 8) == 0;
				alpn_h2 |= plen == 2 && memcmp(proto, "h2", 2) == 0;
			}
			break;
		}
		case 41: // pre_shared_key: must be the last extension (RFC 8446 4.2.11)
			if (exts.n != 0) {
				goto malformed;
			}
			break;
		case 42: // early_data: never accepted here, and the 0-RTT records would follow
		case 44: // cookie: only answers a HelloRetryRequest, which hs13 never sends
			defer = 1;
			break;
		default:
			break;
		}
	}
	if (!v13) {
		return 0; // TLS 1.2: mbedtls
	}
	// TLS 1.3 offered: these are the client's errors, not a reason to defer
	if (legacy_version != 0x0303 || !comp_null_only) {
		goto malformed;
	}
	// ALPN takes h2 when both sides speak it, else http/1.1; a client offering neither
	// is mbedtls' to answer
	int chosen = (h->h2 && alpn_h2) ? 2 : alpn_h11 ? 1 : 0;
	if (defer || !suite || !x25519_group || !share || !pss || (alpn && !chosen)) {
		return 0;
	}
	memcpy(h->random, random, 32);
	memcpy(h->session_id, sid, sid_len);
	h->session_id_len = sid_len;
	h->alpn = alpn ? chosen : 0;
	return 1;
malformed:
	// a TLS 1.3 hello hs13 refuses; anything else is mbedtls' to judge, as before hs13
	return v13 ? -1 : 0;
}

static const mbedtls_md_info_t *viltrum_hs13_md(void) {
	return mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
}

// viltrum_hs13_expand is HKDF-Expand-Label (RFC 8446 7.1) over SHA-256.
static int viltrum_hs13_expand(const uint8_t secret[32], const char *label, const uint8_t *ctx,
		size_t ctx_len, uint8_t *out, size_t out_len) {
	uint8_t info[2 + 1 + 6 + 32 + 1 + 64];
	size_t ll = strlen(label);
	if (ll > 32 || ctx_len > 64) {
		return -1;
	}
	size_t n = 0;
	info[n++] = (uint8_t)(out_len >> 8);
	info[n++] = (uint8_t)out_len;
	info[n++] = (uint8_t)(6 + ll);
	memcpy(info + n, "tls13 ", 6);
	n += 6;
	memcpy(info + n, label, ll);
	n += ll;
	info[n++] = (uint8_t)ctx_len;
	if (ctx_len > 0) {
		memcpy(info + n, ctx, ctx_len);
		n += ctx_len;
	}
	return mbedtls_hkdf_expand(viltrum_hs13_md(), secret, 32, info, n, out, out_len);
}

// viltrum_hs13_hash_now is the transcript hash so far, leaving the running hash as is.
static int viltrum_hs13_hash_now(const mbedtls_sha256_context *running, uint8_t out[32]) {
	mbedtls_sha256_context c;
	mbedtls_sha256_init(&c);
	mbedtls_sha256_clone(&c, running);
	int ret = mbedtls_sha256_finish(&c, out);
	mbedtls_sha256_free(&c);
	return ret;
}

// viltrum_hs13_cert_msg writes the Certificate message (RFC 8446 4.4.2) for a chain:
// an empty request context and each certificate with no extensions. Returns its
// length, or the length it needs when cap is too small (call again with that much).
// cold: certificate load.
static size_t viltrum_hs13_cert_msg(const mbedtls_x509_crt *crt, uint8_t *out, size_t cap) {
	size_t list = 0;
	for (const mbedtls_x509_crt *c = crt; c != NULL && c->raw.len > 0; c = c->next) {
		list += 3 + c->raw.len + 2;
	}
	size_t body = 1 + 3 + list, total = 4 + body;
	if (out == NULL || cap < total) {
		return total;
	}
	size_t n = 0;
	out[n++] = 11;
	out[n++] = (uint8_t)(body >> 16);
	out[n++] = (uint8_t)(body >> 8);
	out[n++] = (uint8_t)body;
	out[n++] = 0; // certificate_request_context
	out[n++] = (uint8_t)(list >> 16);
	out[n++] = (uint8_t)(list >> 8);
	out[n++] = (uint8_t)list;
	for (const mbedtls_x509_crt *c = crt; c != NULL && c->raw.len > 0; c = c->next) {
		out[n++] = (uint8_t)(c->raw.len >> 16);
		out[n++] = (uint8_t)(c->raw.len >> 8);
		out[n++] = (uint8_t)c->raw.len;
		memcpy(out + n, c->raw.p, c->raw.len);
		n += c->raw.len;
		out[n++] = 0;
		out[n++] = 0;
	}
	return total;
}

// viltrum_hs13_seal appends records of type 23 carrying msg (inner type 22) to out
// at *n, under key g and iv from sequence number *seq.
static int viltrum_hs13_seal(viltrum_gcm *g, const uint8_t iv[12], uint64_t *seq, const uint8_t *msg,
		size_t len, uint8_t *out, size_t cap, size_t *n) {
	while (len > 0) {
		size_t chunk = len > 16384 ? 16384 : len;
		size_t rlen = chunk + 1 + 16;
		if (*n + 5 + rlen > cap) {
			return -1;
		}
		uint8_t *p = out + *n;
		p[0] = 23;
		p[1] = 3;
		p[2] = 3;
		p[3] = (uint8_t)(rlen >> 8);
		p[4] = (uint8_t)rlen;
		memcpy(p + 5, msg, chunk);
		p[5 + chunk] = 22;
		uint8_t nonce[12];
		memcpy(nonce, iv, 12);
		for (int i = 0; i < 8; i++) {
			nonce[11 - i] ^= (uint8_t)(*seq >> (8 * i));
		}
		viltrum_gcm_seal(g, nonce, p, 5, p + 5, p + 5, chunk + 1, p + 5 + chunk + 1);
		(*seq)++;
		*n += 5 + rlen;
		msg += chunk;
		len -= chunk;
	}
	return 0;
}

// viltrum_hs13_server_hello writes the ServerHello (4-byte header and body) for h
// with our random and X25519 public key; returns its length (at most 128).
static size_t viltrum_hs13_server_hello(uint8_t *p, const viltrum_hs13_hello *h, const uint8_t random[32],
		const uint8_t pub[32]) {
	size_t body = 2 + 32 + 1 + h->session_id_len + 2 + 1 + 2 + (4 + 36) + (4 + 2);
	size_t n = 0;
	p[n++] = 2;
	p[n++] = 0;
	p[n++] = (uint8_t)(body >> 8);
	p[n++] = (uint8_t)body;
	p[n++] = 3; // legacy_version
	p[n++] = 3;
	memcpy(p + n, random, 32);
	n += 32;
	p[n++] = (uint8_t)h->session_id_len;
	memcpy(p + n, h->session_id, h->session_id_len);
	n += h->session_id_len;
	p[n++] = VILTRUM_HS13_SUITE >> 8;
	p[n++] = VILTRUM_HS13_SUITE & 0xff;
	p[n++] = 0; // legacy_compression_method
	p[n++] = 0;
	p[n++] = (4 + 36) + (4 + 2); // extensions
	p[n++] = 0; // key_share: X25519
	p[n++] = 51;
	p[n++] = 0;
	p[n++] = 36;
	p[n++] = 0;
	p[n++] = 0x1d;
	p[n++] = 0;
	p[n++] = 32;
	memcpy(p + n, pub, 32);
	n += 32;
	p[n++] = 0; // supported_versions: TLS 1.3
	p[n++] = 43;
	p[n++] = 0;
	p[n++] = 2;
	p[n++] = 3;
	p[n++] = 4;
	return n;
}

// viltrum_hs13_schedule runs the key schedule (RFC 8446 7.1) from the (EC)DHE secret
// and the transcript hash through the ServerHello to the handshake traffic secrets
// and the master secret.
static int viltrum_hs13_schedule(const uint8_t shared[32], const uint8_t th[32], uint8_t c_hs[32],
		uint8_t s_hs[32], uint8_t master[32]) {
	uint8_t zeros[32], empty_hash[32], early[32], derived[32], hs_secret[32];
	memset(zeros, 0, sizeof(zeros));
	int ret = mbedtls_sha256(NULL, 0, empty_hash, 0)
		|| mbedtls_hkdf_extract(viltrum_hs13_md(), zeros, 32, zeros, 32, early)
		|| viltrum_hs13_expand(early, "derived", empty_hash, 32, derived, 32)
		|| mbedtls_hkdf_extract(viltrum_hs13_md(), derived, 32, shared, 32, hs_secret)
		|| viltrum_hs13_expand(hs_secret, "c hs traffic", th, 32, c_hs, 32)
		|| viltrum_hs13_expand(hs_secret, "s hs traffic", th, 32, s_hs, 32)
		|| viltrum_hs13_expand(hs_secret, "derived", empty_hash, 32, derived, 32)
		|| mbedtls_hkdf_extract(viltrum_hs13_md(), derived, 32, zeros, 32, master);
	viltrum_hs13_wipe(early, sizeof(early));
	viltrum_hs13_wipe(derived, sizeof(derived));
	viltrum_hs13_wipe(hs_secret, sizeof(hs_secret));
	return ret ? -1 : 0;
}

// viltrum_hs13_traffic is the record key and IV of a traffic secret.
static int viltrum_hs13_traffic(const uint8_t secret[32], uint8_t key[16], uint8_t iv[12]) {
	return viltrum_hs13_expand(secret, "key", NULL, 0, key, 16) || viltrum_hs13_expand(secret, "iv", NULL, 0, iv, 12)
		? -1
		: 0;
}

// viltrum_hs13_finished_mac is a Finished verify_data: HMAC of the transcript hash
// under the finished key of a handshake traffic secret (RFC 8446 4.4.4).
static int viltrum_hs13_finished_mac(const uint8_t secret[32], const uint8_t th[32], uint8_t out[32]) {
	uint8_t fin_key[32];
	int ret = viltrum_hs13_expand(secret, "finished", NULL, 0, fin_key, 32)
		|| mbedtls_md_hmac(viltrum_hs13_md(), fin_key, 32, th, 32, out);
	viltrum_hs13_wipe(fin_key, sizeof(fin_key));
	return ret ? -1 : 0;
}

// viltrum_hs13_app is the application traffic secrets, from the master secret and the
// transcript hash through the server Finished.
static int viltrum_hs13_app(const uint8_t master[32], const uint8_t th[32], uint8_t c_ap[32], uint8_t s_ap[32]) {
	return viltrum_hs13_expand(master, "c ap traffic", th, 32, c_ap, 32)
			|| viltrum_hs13_expand(master, "s ap traffic", th, 32, s_ap, 32)
		? -1
		: 0;
}

// viltrum_hs13_flight_with answers a ClientHello hs13 accepted (ch: the message, h:
// what viltrum_hs13_parse read from it): the ServerHello, a change_cipher_spec when
// the client is in middlebox compatibility mode (a session ID, RFC 8446 D.4), and
// EncryptedExtensions, Certificate, CertificateVerify and Finished under the server's
// handshake key. rnd is 96 random bytes: the server random, our X25519 private key
// and the PSS salt. cert is the Certificate message (viltrum_hs13_cert_msg), tx a GCM
// state to seal with. The flight goes to out (*out_len bytes); keys gets what the
// client's Finished and the record layer need. 0 on success.
static int viltrum_hs13_flight_with(const uint8_t rnd[96], const uint8_t *ch, size_t ch_len,
		const viltrum_hs13_hello *h, const uint8_t *cert, size_t cert_len, viltrum_rsa *key, viltrum_gcm *tx,
		uint8_t *out, size_t cap, size_t *out_len, viltrum_hs13_keys *keys) {
	int ret = -1;
	size_t sig_len = (size_t)key->limbs * 8;
	uint8_t pub[32], shared[32], th[32], c_hs[32], s_hs[32], master[32], s_key[16], s_iv[12];
	uint8_t msg[4 + 4 + 512]; // CertificateVerify, the largest message besides Certificate
	size_t n = 0, m = 0;
	uint64_t seq = 0;
	mbedtls_sha256_context th_run;
	mbedtls_sha256_init(&th_run);
	*out_len = 0;
	if (!key->ok || sig_len > 512 || cap < 5 + 128 + 6) {
		goto done;
	}
	viltrum_x25519_base(pub, rnd + 32);
	viltrum_x25519(shared, rnd + 32, h->share);
	uint8_t acc = 0;
	for (int i = 0; i < 32; i++) {
		acc |= shared[i];
	}
	if (acc == 0) {
		goto done; // a small-order point: RFC 8446 7.4.2
	}
	// the ServerHello in a plaintext record
	size_t sh_len = viltrum_hs13_server_hello(out + 5, h, rnd, pub);
	out[0] = 22;
	out[1] = 3;
	out[2] = 3;
	out[3] = (uint8_t)(sh_len >> 8);
	out[4] = (uint8_t)sh_len;
	n = 5 + sh_len;
	if (mbedtls_sha256_starts(&th_run, 0) || mbedtls_sha256_update(&th_run, ch, ch_len)
		|| mbedtls_sha256_update(&th_run, out + 5, sh_len) || viltrum_hs13_hash_now(&th_run, th)) {
		goto done;
	}
	if (h->session_id_len > 0) {
		static const uint8_t ccs[6] = {20, 3, 3, 0, 1, 1};
		memcpy(out + n, ccs, 6);
		n += 6;
	}
	if (viltrum_hs13_schedule(shared, th, c_hs, s_hs, master) || viltrum_hs13_traffic(s_hs, s_key, s_iv)
		|| viltrum_hs13_traffic(c_hs, keys->c_key, keys->c_iv) || viltrum_gcm_init(tx, s_key, 16) != 0) {
		goto done;
	}
	// EncryptedExtensions: ALPN when the client asked, with the protocol chosen
	static const uint8_t alpn_h11[15] = {0, 16, 0, 11, 0, 9, 8, 'h', 't', 't', 'p', '/', '1', '.', '1'};
	static const uint8_t alpn_h2[9] = {0, 16, 0, 5, 0, 3, 2, 'h', '2'};
	const uint8_t *alpn_ext = h->alpn == 2 ? alpn_h2 : alpn_h11;
	size_t alpn_len = h->alpn == 2 ? sizeof(alpn_h2) : h->alpn == 1 ? sizeof(alpn_h11) : 0;
	msg[m++] = 8;
	msg[m++] = 0;
	msg[m++] = 0;
	msg[m++] = (uint8_t)(2 + alpn_len);
	msg[m++] = 0;
	msg[m++] = (uint8_t)alpn_len;
	memcpy(msg + m, alpn_ext, alpn_len);
	m += alpn_len;
	if (mbedtls_sha256_update(&th_run, msg, m) || mbedtls_sha256_update(&th_run, cert, cert_len)
		|| viltrum_hs13_seal(tx, s_iv, &seq, msg, m, out, cap, &n)
		|| viltrum_hs13_seal(tx, s_iv, &seq, cert, cert_len, out, cap, &n)
		|| viltrum_hs13_hash_now(&th_run, th)) {
		goto done;
	}
	// CertificateVerify: RSA-PSS over 64 spaces, the context string, 0 and the transcript
	{
		uint8_t content[64 + 33 + 1 + 32], mhash[32];
		memset(content, 0x20, 64);
		memcpy(content + 64, "TLS 1.3, server CertificateVerify", 33);
		content[97] = 0;
		memcpy(content + 98, th, 32);
		if (mbedtls_sha256(content, sizeof(content), mhash, 0)) {
			goto done;
		}
		m = 0;
		msg[m++] = 15;
		msg[m++] = (uint8_t)((4 + sig_len) >> 16);
		msg[m++] = (uint8_t)((4 + sig_len) >> 8);
		msg[m++] = (uint8_t)(4 + sig_len);
		msg[m++] = VILTRUM_HS13_SIG_PSS_SHA256 >> 8;
		msg[m++] = VILTRUM_HS13_SIG_PSS_SHA256 & 0xff;
		msg[m++] = (uint8_t)(sig_len >> 8);
		msg[m++] = (uint8_t)sig_len;
		if (viltrum_rsa_pss_sha256(key, mhash, rnd + 64, msg + m) != 0) {
			goto done;
		}
		m += sig_len;
	}
	if (mbedtls_sha256_update(&th_run, msg, m) || viltrum_hs13_seal(tx, s_iv, &seq, msg, m, out, cap, &n)
		|| viltrum_hs13_hash_now(&th_run, th)) {
		goto done;
	}
	// Finished
	m = 0;
	msg[m++] = 20;
	msg[m++] = 0;
	msg[m++] = 0;
	msg[m++] = 32;
	if (viltrum_hs13_finished_mac(s_hs, th, msg + m)) {
		goto done;
	}
	m += 32;
	if (mbedtls_sha256_update(&th_run, msg, m) || viltrum_hs13_seal(tx, s_iv, &seq, msg, m, out, cap, &n)
		|| viltrum_hs13_hash_now(&th_run, th)) {
		goto done;
	}
	// the application traffic secrets and the client Finished, from the transcript
	// through the server Finished
	if (viltrum_hs13_app(master, th, keys->c_ap, keys->s_ap) || viltrum_hs13_finished_mac(c_hs, th, keys->c_fin)) {
		goto done;
	}
	memcpy(keys->s_iv, s_iv, 12);
	keys->s_seq = seq;
	*out_len = n;
	ret = 0;
done:
	mbedtls_sha256_free(&th_run);
	viltrum_hs13_wipe(shared, sizeof(shared));
	viltrum_hs13_wipe(c_hs, sizeof(c_hs));
	viltrum_hs13_wipe(s_hs, sizeof(s_hs));
	viltrum_hs13_wipe(master, sizeof(master));
	viltrum_hs13_wipe(s_key, sizeof(s_key));
	viltrum_hs13_wipe(s_iv, sizeof(s_iv));
	if (ret != 0) {
		viltrum_hs13_wipe(keys, sizeof(*keys));
	}
	return ret;
}

// viltrum_hs13_flight is viltrum_hs13_flight_with on fresh random bytes from drbg.
static int viltrum_hs13_flight(const uint8_t *ch, size_t ch_len, const viltrum_hs13_hello *h,
		const uint8_t *cert, size_t cert_len, viltrum_rsa *key, mbedtls_ctr_drbg_context *drbg,
		viltrum_gcm *tx, uint8_t *out, size_t cap, size_t *out_len, viltrum_hs13_keys *keys) {
	uint8_t rnd[96];
	if (mbedtls_ctr_drbg_random(drbg, rnd, sizeof(rnd)) != 0) {
		return -1;
	}
	int ret = viltrum_hs13_flight_with(rnd, ch, ch_len, h, cert, cert_len, key, tx, out, cap, out_len, keys);
	viltrum_hs13_wipe(rnd, sizeof(rnd));
	return ret;
}

// viltrum_hs13_finished_ok compares the client's Finished message (4-byte header and
// body) with the one expected, in constant time.
static int viltrum_hs13_finished_ok(const uint8_t *msg, size_t len, const viltrum_hs13_keys *keys) {
	if (len != 4 + 32 || msg[0] != 20 || msg[1] != 0 || msg[2] != 0 || msg[3] != 32) {
		return 0;
	}
	uint8_t diff = 0;
	for (int i = 0; i < 32; i++) {
		diff |= msg[4 + i] ^ keys->c_fin[i];
	}
	return diff == 0;
}

static int viltrum_hs13_supported(void) {
	return viltrum_aesgcm_supported() && viltrum_x25519_supported() && viltrum_rsa_supported();
}

#endif
