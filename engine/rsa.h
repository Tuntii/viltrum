// rsa.h: RSA private-key operations for the TLS 1.3 handshake's CertificateVerify
// (hs13): RSASSA-PSS with SHA-256 (rsa_pss_rsae_sha256, RFC 8446 4.2.3). mbedtls
// signs on its generic bignum code in 5.1 ms on the test VM for a 2048-bit key, 70%
// of a handshake; this does the same operation in 64-bit limbs with Montgomery
// multiplication (Koc, Acar and Kaliski, "Analyzing and Comparing Montgomery
// Multiplication Algorithms", 1996, the CIOS method) and the Chinese remainder theorem.
//
// The key comes in through mbedtls (viltrum_rsa_load: parsing, and the cold
// precomputation of the Montgomery constants and the blinding pair, use its bignum);
// the signing path uses only the code below.
//
// Side channels and faults, after what mbedtls and OpenSSL do:
//   - constant time in the secret values: Montgomery products end in a masked
//     subtraction, exponentiation uses a fixed 4-bit window over every bit of the
//     exponent's limbs and reads the whole table for each lookup (no secret index);
//   - base blinding: the message is multiplied by r^e before the exponentiation and
//     the result by r^-1 after, with (r^e, r^-1) squared after each use;
//   - the signature is checked with the public exponent before it is released, so a
//     fault in the CRT halves cannot leak a factor of n (Boneh, DeMillo, Lipton).
//
// Moduli of 1024 to 4096 bits whose size is a multiple of 128 and whose primes are of
// equal limb length; anything else stays on mbedtls. engine/hs13_linux_test.v checks
// the signatures with mbedtls' PSS verification.
#ifndef VILTRUM_RSA_H
#define VILTRUM_RSA_H

#include <stdint.h>
#include <string.h>
#include <mbedtls/bignum.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/pk.h>
#include <mbedtls/rsa.h>
#include <mbedtls/sha256.h>

// VILTRUM_CT_HIDE keeps the compiler from knowing what a secret mask holds, so a
// masked select cannot be turned back into a branch (GCC already turns X25519's
// swap into cmov; another compiler could do worse).
#ifndef VILTRUM_CT_HIDE
#if defined(__GNUC__) || defined(__clang__)
#define VILTRUM_CT_HIDE(x) __asm__("" : "+r"(x))
#else
#define VILTRUM_CT_HIDE(x) (void)0
#endif
#endif

#if !defined(__TINYC__) && defined(__SIZEOF_INT128__)

#define VILTRUM_RSA_MAX_LIMBS 64 // 4096-bit modulus
#define VILTRUM_RSA_HALF_LIMBS 32

typedef unsigned __int128 viltrum_rsa_u128;

// viltrum_rsa is one private key with everything signing needs, numbers as
// little-endian 64-bit limbs. Values marked "mont" are in Montgomery form (times R
// modulo their modulus, R = 2^(64 * limbs)).
typedef struct {
	int limbs; // of n; p and q have limbs / 2
	int bits;  // of n
	uint64_t e;
	uint64_t n[VILTRUM_RSA_MAX_LIMBS];
	uint64_t n_n0;                           // -n^-1 mod 2^64
	uint64_t n_r2[VILTRUM_RSA_MAX_LIMBS];    // R^2 mod n
	uint64_t n_one[VILTRUM_RSA_MAX_LIMBS];   // R mod n: 1, mont
	uint64_t p[VILTRUM_RSA_HALF_LIMBS];
	uint64_t q[VILTRUM_RSA_HALF_LIMBS];
	uint64_t dp[VILTRUM_RSA_HALF_LIMBS];
	uint64_t dq[VILTRUM_RSA_HALF_LIMBS];
	uint64_t p_n0, q_n0;
	uint64_t p_r3[VILTRUM_RSA_HALF_LIMBS];   // R^3 mod p: takes REDC(x) to x, mont
	uint64_t q_r3[VILTRUM_RSA_HALF_LIMBS];
	uint64_t p_one[VILTRUM_RSA_HALF_LIMBS];  // R mod p
	uint64_t q_one[VILTRUM_RSA_HALF_LIMBS];
	uint64_t qinv_m[VILTRUM_RSA_HALF_LIMBS]; // q^-1 mod p, mont
	uint64_t bl_vi[VILTRUM_RSA_MAX_LIMBS];   // blinding: r^e mod n, mont
	uint64_t bl_vf[VILTRUM_RSA_MAX_LIMBS];   // blinding: r^-1 mod n, mont
	int ok;
} viltrum_rsa;

static void viltrum_rsa_wipe(void *p, size_t n) {
	volatile unsigned char *b = (volatile unsigned char *)p;
	for (size_t i = 0; i < n; i++) {
		b[i] = 0;
	}
}

// (c0, c1, c2) += a * b: one step of a column sum in three words. VILTRUM_MULACC2
// adds the product twice (the cross terms of a square). On x86-64 these are the
// four (seven) instructions the sum takes; compilers build 128-bit sums from
// separate carry extractions, which ran at half the speed.
#if defined(__x86_64__)
#define VILTRUM_MULACC(a, b) \
	do { \
		uint64_t lo_ = (a), hi_; \
		__asm__("mulq %[y]\n\t" \
			"addq %[lo], %[x0]\n\t" \
			"adcq %[hi], %[x1]\n\t" \
			"adcq $0, %[x2]" \
			: [lo] "+&a"(lo_), [hi] "=&d"(hi_), [x0] "+r"(c0), [x1] "+r"(c1), [x2] "+r"(c2) \
			: [y] "rm"(b) \
			: "cc"); \
	} while (0)
#define VILTRUM_MULACC2(a, b) \
	do { \
		uint64_t lo_ = (a), hi_; \
		__asm__("mulq %[y]\n\t" \
			"addq %[lo], %[x0]\n\t" \
			"adcq %[hi], %[x1]\n\t" \
			"adcq $0, %[x2]\n\t" \
			"addq %[lo], %[x0]\n\t" \
			"adcq %[hi], %[x1]\n\t" \
			"adcq $0, %[x2]" \
			: [lo] "+&a"(lo_), [hi] "=&d"(hi_), [x0] "+r"(c0), [x1] "+r"(c1), [x2] "+r"(c2) \
			: [y] "rm"(b) \
			: "cc"); \
	} while (0)
#else
#define VILTRUM_MULACC(a, b) \
	do { \
		viltrum_rsa_u128 p_ = (viltrum_rsa_u128)(a) * (b); \
		viltrum_rsa_u128 s_ = (viltrum_rsa_u128)c0 + (uint64_t)p_; \
		c0 = (uint64_t)s_; \
		s_ = (viltrum_rsa_u128)c1 + (uint64_t)(p_ >> 64) + (uint64_t)(s_ >> 64); \
		c1 = (uint64_t)s_; \
		c2 += (uint64_t)(s_ >> 64); \
	} while (0)
#define VILTRUM_MULACC2(a, b) \
	do { \
		VILTRUM_MULACC(a, b); \
		VILTRUM_MULACC(a, b); \
	} while (0)
#endif

// viltrum_mont_k sets r = a * b / R mod m (k limbs; a, b < m), or a * a / R when sq
// is set; r may alias a or b. Product scanning (the FIPS method of Koc et al.):
// column i of a * b + u * m is summed in three words, u[i] chosen so the column's
// low word cancels, so nothing but the running sum is written until the result. A
// square sums each cross product once, doubled: a quarter fewer products. Inlined
// into one copy per key size and kind, so the compiler sees k and sq as constants.
static inline __attribute__((always_inline)) void viltrum_mont_k(uint64_t *r, const uint64_t *a,
		const uint64_t *b, const uint64_t *m, uint64_t n0, const int k, const int sq) {
	uint64_t u[VILTRUM_RSA_MAX_LIMBS];
	uint64_t t[VILTRUM_RSA_MAX_LIMBS + 1];
	uint64_t c0 = 0, c1 = 0, c2 = 0;
	for (int i = 0; i < 2 * k - 1; i++) {
		int lo = i < k ? 0 : i - k + 1;
		if (sq) {
			for (int j = lo; j < i - j; j++) {
				VILTRUM_MULACC2(a[j], a[i - j]);
			}
			if ((i & 1) == 0) {
				VILTRUM_MULACC(a[i / 2], a[i / 2]);
			}
		} else {
			for (int j = lo; j <= i && j < k; j++) {
				VILTRUM_MULACC(a[j], b[i - j]);
			}
		}
		if (i < k) {
			for (int j = 0; j < i; j++) {
				VILTRUM_MULACC(u[j], m[i - j]);
			}
			u[i] = c0 * n0;
			VILTRUM_MULACC(u[i], m[0]); // the low word is 0 now
		} else {
			for (int j = lo; j < k; j++) {
				VILTRUM_MULACC(u[j], m[i - j]);
			}
			t[i - k] = c0;
		}
		c0 = c1;
		c1 = c2;
		c2 = 0;
	}
	t[k - 1] = c0;
	t[k] = c1;
	// t < 2m: subtract m unless that borrows past t's top limb, without a branch
	uint64_t d[VILTRUM_RSA_MAX_LIMBS];
	uint64_t borrow = 0;
	for (int j = 0; j < k; j++) {
		viltrum_rsa_u128 s = (viltrum_rsa_u128)t[j] - m[j] - borrow;
		d[j] = (uint64_t)s;
		borrow = (uint64_t)(s >> 64) & 1;
	}
	uint64_t use_d = 0 - ((t[k] | (borrow ^ 1)) & 1);
	VILTRUM_CT_HIDE(use_d);
	for (int j = 0; j < k; j++) {
		r[j] = (d[j] & use_d) | (t[j] & ~use_d);
	}
}

#define VILTRUM_MONT_SIZE(K) \
	static void viltrum_mont_mul##K(uint64_t *r, const uint64_t *a, const uint64_t *b, const uint64_t *m, \
			uint64_t n0) { \
		viltrum_mont_k(r, a, b, m, n0, K, 0); \
	} \
	static void viltrum_mont_sqr##K(uint64_t *r, const uint64_t *a, const uint64_t *m, uint64_t n0) { \
		viltrum_mont_k(r, a, a, m, n0, K, 1); \
	}

VILTRUM_MONT_SIZE(16)
VILTRUM_MONT_SIZE(24)
VILTRUM_MONT_SIZE(32)

static void viltrum_mont_mul_any(uint64_t *r, const uint64_t *a, const uint64_t *b, const uint64_t *m,
		uint64_t n0, int k) {
	viltrum_mont_k(r, a, b, m, n0, k, 0);
}

static void viltrum_mont_sqr_any(uint64_t *r, const uint64_t *a, const uint64_t *m, uint64_t n0, int k) {
	viltrum_mont_k(r, a, a, m, n0, k, 1);
}

// viltrum_mont_mul and viltrum_mont_sqr are viltrum_mont_k for any k, with the
// common prime sizes (2048, 3072 and 4096-bit moduli) on their own copies.
static void viltrum_mont_mul(uint64_t *r, const uint64_t *a, const uint64_t *b, const uint64_t *m,
		uint64_t n0, int k) {
	switch (k) {
	case 16:
		viltrum_mont_mul16(r, a, b, m, n0);
		break;
	case 24:
		viltrum_mont_mul24(r, a, b, m, n0);
		break;
	case 32:
		viltrum_mont_mul32(r, a, b, m, n0);
		break;
	default:
		viltrum_mont_mul_any(r, a, b, m, n0, k);
	}
}

static void viltrum_mont_sqr(uint64_t *r, const uint64_t *a, const uint64_t *m, uint64_t n0, int k) {
	switch (k) {
	case 16:
		viltrum_mont_sqr16(r, a, m, n0);
		break;
	case 24:
		viltrum_mont_sqr24(r, a, m, n0);
		break;
	case 32:
		viltrum_mont_sqr32(r, a, m, n0);
		break;
	default:
		viltrum_mont_sqr_any(r, a, m, n0, k);
	}
}

// viltrum_mont_redc sets r = x / R mod m for a 2k-limb x < m * R (Montgomery reduction).
static void viltrum_mont_redc(uint64_t *r, const uint64_t *x, const uint64_t *m, uint64_t n0, int k) {
	uint64_t t[2 * VILTRUM_RSA_HALF_LIMBS + 1];
	memcpy(t, x, sizeof(uint64_t) * (size_t)(2 * k));
	// top is the carry out of t[i + k], owed to t[i + k + 1]: added there in the next
	// round rather than rippled up now, which would take a data-dependent time
	uint64_t top = 0;
	for (int i = 0; i < k; i++) {
		uint64_t mq = t[i] * n0;
		uint64_t c = 0;
		for (int j = 0; j < k; j++) {
			viltrum_rsa_u128 s = (viltrum_rsa_u128)mq * m[j] + t[i + j] + c;
			t[i + j] = (uint64_t)s;
			c = (uint64_t)(s >> 64);
		}
		viltrum_rsa_u128 s = (viltrum_rsa_u128)t[i + k] + c + top;
		t[i + k] = (uint64_t)s;
		top = (uint64_t)(s >> 64);
	}
	t[2 * k] = top;
	uint64_t d[VILTRUM_RSA_HALF_LIMBS];
	uint64_t borrow = 0;
	for (int j = 0; j < k; j++) {
		viltrum_rsa_u128 s = (viltrum_rsa_u128)t[k + j] - m[j] - borrow;
		d[j] = (uint64_t)s;
		borrow = (uint64_t)(s >> 64) & 1;
	}
	uint64_t use_d = 0 - ((t[2 * k] | (borrow ^ 1)) & 1);
	VILTRUM_CT_HIDE(use_d);
	for (int j = 0; j < k; j++) {
		r[j] = (d[j] & use_d) | (t[k + j] & ~use_d);
	}
}

// viltrum_mont_exp sets r = a^e mod m, a and r mont, e of k limbs (every bit is
// processed, so the time does not depend on e's value).
static void viltrum_mont_exp(uint64_t *r, const uint64_t *a, const uint64_t *e, const uint64_t *m,
		uint64_t n0, const uint64_t *one, int k) {
	uint64_t table[16][VILTRUM_RSA_HALF_LIMBS];
	uint64_t acc[VILTRUM_RSA_HALF_LIMBS];
	uint64_t sel[VILTRUM_RSA_HALF_LIMBS];
	memcpy(table[0], one, sizeof(uint64_t) * (size_t)k);
	memcpy(table[1], a, sizeof(uint64_t) * (size_t)k);
	for (int i = 2; i < 16; i++) {
		viltrum_mont_mul(table[i], table[i - 1], a, m, n0, k);
	}
	memcpy(acc, one, sizeof(uint64_t) * (size_t)k);
	for (int w = k * 16 - 1; w >= 0; w--) {
		for (int s = 0; s < 4; s++) {
			viltrum_mont_sqr(acc, acc, m, n0, k);
		}
		uint64_t idx = (e[w >> 4] >> ((w & 15) * 4)) & 15;
		memset(sel, 0, sizeof(uint64_t) * (size_t)k);
		for (uint64_t i = 0; i < 16; i++) {
			uint64_t x = i ^ idx;
			uint64_t mask = ((x | (0 - x)) >> 63) - 1; // all ones when i == idx
			VILTRUM_CT_HIDE(mask);
			for (int j = 0; j < k; j++) {
				sel[j] |= table[i][j] & mask;
			}
		}
		viltrum_mont_mul(acc, acc, sel, m, n0, k);
	}
	memcpy(r, acc, sizeof(uint64_t) * (size_t)k);
	viltrum_rsa_wipe(table, sizeof(table));
	viltrum_rsa_wipe(acc, sizeof(acc));
	viltrum_rsa_wipe(sel, sizeof(sel));
}

// viltrum_rsa_n0 is -m0^-1 mod 2^64 for an odd m0 (Newton's iteration).
static uint64_t viltrum_rsa_n0(uint64_t m0) {
	uint64_t x = 1;
	for (int i = 0; i < 6; i++) {
		x *= 2 - m0 * x;
	}
	return 0 - x;
}

// viltrum_rsa_from_mpi writes an mbedtls number as k little-endian limbs; -1 when it
// does not fit.
static int viltrum_rsa_from_mpi(uint64_t *out, const mbedtls_mpi *x, int k) {
	unsigned char buf[VILTRUM_RSA_MAX_LIMBS * 8];
	if (mbedtls_mpi_write_binary(x, buf, (size_t)k * 8) != 0) {
		return -1;
	}
	for (int i = 0; i < k; i++) {
		uint64_t v = 0;
		const unsigned char *p = buf + (size_t)(k - 1 - i) * 8;
		for (int j = 0; j < 8; j++) {
			v = (v << 8) | p[j];
		}
		out[i] = v;
	}
	viltrum_rsa_wipe(buf, sizeof(buf));
	return 0;
}

// viltrum_rsa_mont_const sets out = R^power mod m (power 1 to 3) and, if x is not
// NULL, x * R mod m instead of R^power. cold: key load.
static int viltrum_rsa_mont_const(uint64_t *out, const mbedtls_mpi *m, int k, int power,
		const mbedtls_mpi *x) {
	mbedtls_mpi r;
	mbedtls_mpi_init(&r);
	int ret = mbedtls_mpi_lset(&r, 1);
	if (ret == 0) {
		ret = mbedtls_mpi_shift_l(&r, (size_t)(64 * k * power));
	}
	if (ret == 0 && x != NULL) {
		ret = mbedtls_mpi_mul_mpi(&r, &r, x);
	}
	if (ret == 0) {
		ret = mbedtls_mpi_mod_mpi(&r, &r, m);
	}
	if (ret == 0) {
		ret = viltrum_rsa_from_mpi(out, &r, k);
	}
	mbedtls_mpi_free(&r);
	return ret;
}

// viltrum_rsa_load prepares key for signing; 0 on success, -1 when the key is not
// RSA or not of a shape this code handles (the handshake then stays on mbedtls).
// cold: certificate load.
static int viltrum_rsa_load(viltrum_rsa *key, mbedtls_pk_context *pk, mbedtls_ctr_drbg_context *drbg) {
	memset(key, 0, sizeof(*key));
	if (mbedtls_pk_get_type(pk) != MBEDTLS_PK_RSA) {
		return -1;
	}
	mbedtls_rsa_context *rsa = mbedtls_pk_rsa(*pk);
	mbedtls_mpi N, P, Q, D, E, DP, DQ, QP, R, T;
	mbedtls_mpi *all[] = {&N, &P, &Q, &D, &E, &DP, &DQ, &QP, &R, &T};
	for (int i = 0; i < 10; i++) {
		mbedtls_mpi_init(all[i]);
	}
	int ret = -1;
	if (mbedtls_rsa_export(rsa, &N, &P, &Q, &D, &E) != 0 || mbedtls_rsa_export_crt(rsa, &DP, &DQ, &QP) != 0) {
		goto done;
	}
	size_t bits = mbedtls_mpi_bitlen(&N);
	if (bits < 1024 || bits > 64 * VILTRUM_RSA_MAX_LIMBS || bits % 128 != 0) {
		goto done;
	}
	int k = (int)(bits / 64), h = k / 2;
	// both primes fill exactly h limbs; the CRT recombination relies on q < 2p
	if (mbedtls_mpi_bitlen(&P) != (size_t)(64 * h) || mbedtls_mpi_bitlen(&Q) != (size_t)(64 * h)
		|| mbedtls_mpi_bitlen(&E) > 64 || mbedtls_mpi_cmp_int(&E, 3) < 0) {
		goto done;
	}
	key->limbs = k;
	key->bits = (int)bits;
	uint64_t e_limb[1];
	if (viltrum_rsa_from_mpi(e_limb, &E, 1) != 0) {
		goto done;
	}
	key->e = e_limb[0];
	if (viltrum_rsa_from_mpi(key->n, &N, k) || viltrum_rsa_from_mpi(key->p, &P, h)
		|| viltrum_rsa_from_mpi(key->q, &Q, h) || viltrum_rsa_from_mpi(key->dp, &DP, h)
		|| viltrum_rsa_from_mpi(key->dq, &DQ, h)) {
		goto done;
	}
	key->n_n0 = viltrum_rsa_n0(key->n[0]);
	key->p_n0 = viltrum_rsa_n0(key->p[0]);
	key->q_n0 = viltrum_rsa_n0(key->q[0]);
	if (viltrum_rsa_mont_const(key->n_r2, &N, k, 2, NULL) || viltrum_rsa_mont_const(key->n_one, &N, k, 1, NULL)
		|| viltrum_rsa_mont_const(key->p_r3, &P, h, 3, NULL) || viltrum_rsa_mont_const(key->q_r3, &Q, h, 3, NULL)
		|| viltrum_rsa_mont_const(key->p_one, &P, h, 1, NULL) || viltrum_rsa_mont_const(key->q_one, &Q, h, 1, NULL)
		|| viltrum_rsa_mont_const(key->qinv_m, &P, h, 1, &QP)) {
		goto done;
	}
	// the blinding pair: a random r prime to n, r^e and r^-1
	do {
		if (mbedtls_mpi_fill_random(&R, (size_t)k * 8 - 1, mbedtls_ctr_drbg_random, drbg) != 0) {
			goto done;
		}
	} while (mbedtls_mpi_cmp_int(&R, 1) <= 0 || mbedtls_mpi_inv_mod(&T, &R, &N) != 0);
	if (viltrum_rsa_mont_const(key->bl_vf, &N, k, 1, &T)) {
		goto done;
	}
	if (mbedtls_mpi_exp_mod(&T, &R, &E, &N, NULL) != 0 || viltrum_rsa_mont_const(key->bl_vi, &N, k, 1, &T)) {
		goto done;
	}
	key->ok = 1;
	ret = 0;
done:
	for (int i = 0; i < 10; i++) {
		mbedtls_mpi_free(all[i]);
	}
	if (ret != 0) {
		viltrum_rsa_wipe(key, sizeof(*key));
	}
	return ret;
}

// viltrum_rsa_private sets out = in^d mod n (both big-endian, limbs * 8 bytes) by
// CRT under blinding, and checks the result with e. 0 on success, -1 when in >= n
// or the check fails.
static int viltrum_rsa_private(viltrum_rsa *key, const uint8_t *in, uint8_t *out) {
	int k = key->limbs, h = k / 2;
	uint64_t m[VILTRUM_RSA_MAX_LIMBS], x[VILTRUM_RSA_MAX_LIMBS], s1[VILTRUM_RSA_HALF_LIMBS],
		s2[VILTRUM_RSA_HALF_LIMBS], t[VILTRUM_RSA_HALF_LIMBS];
	for (int i = 0; i < k; i++) {
		uint64_t v = 0;
		const uint8_t *p = in + (size_t)(k - 1 - i) * 8;
		for (int j = 0; j < 8; j++) {
			v = (v << 8) | p[j];
		}
		m[i] = v;
	}
	// m < n (public: the encoding keeps it below)
	uint64_t borrow = 0;
	for (int j = 0; j < k; j++) {
		viltrum_rsa_u128 s = (viltrum_rsa_u128)m[j] - key->n[j] - borrow;
		borrow = (uint64_t)(s >> 64) & 1;
	}
	if (!borrow) {
		return -1;
	}
	// the next blinding pair, then x = m * r^e
	viltrum_mont_sqr(key->bl_vi, key->bl_vi, key->n, key->n_n0, k);
	viltrum_mont_sqr(key->bl_vf, key->bl_vf, key->n, key->n_n0, k);
	viltrum_mont_mul(x, m, key->bl_vi, key->n, key->n_n0, k);
	// s1 = x^dp mod p, s2 = x^dq mod q
	viltrum_mont_redc(t, x, key->p, key->p_n0, h);
	viltrum_mont_mul(t, t, key->p_r3, key->p, key->p_n0, h);
	viltrum_mont_exp(s1, t, key->dp, key->p, key->p_n0, key->p_one, h);
	memset(t, 0, sizeof(t));
	t[0] = 1;
	viltrum_mont_mul(s1, s1, t, key->p, key->p_n0, h);
	viltrum_mont_redc(t, x, key->q, key->q_n0, h);
	viltrum_mont_mul(t, t, key->q_r3, key->q, key->q_n0, h);
	viltrum_mont_exp(s2, t, key->dq, key->q, key->q_n0, key->q_one, h);
	memset(t, 0, sizeof(t));
	t[0] = 1;
	viltrum_mont_mul(s2, s2, t, key->q, key->q_n0, h);
	// h = (s1 - s2) * q^-1 mod p; s2 < q < 2p, so s2 mod p is one masked subtraction
	uint64_t d[VILTRUM_RSA_HALF_LIMBS];
	borrow = 0;
	for (int j = 0; j < h; j++) {
		viltrum_rsa_u128 s = (viltrum_rsa_u128)s2[j] - key->p[j] - borrow;
		d[j] = (uint64_t)s;
		borrow = (uint64_t)(s >> 64) & 1;
	}
	uint64_t keep = 0 - borrow; // s2 < p: keep s2
	VILTRUM_CT_HIDE(keep);
	for (int j = 0; j < h; j++) {
		t[j] = (s2[j] & keep) | (d[j] & ~keep);
	}
	borrow = 0;
	for (int j = 0; j < h; j++) {
		viltrum_rsa_u128 s = (viltrum_rsa_u128)s1[j] - t[j] - borrow;
		d[j] = (uint64_t)s;
		borrow = (uint64_t)(s >> 64) & 1;
	}
	uint64_t addp = 0 - borrow, c = 0;
	VILTRUM_CT_HIDE(addp);
	for (int j = 0; j < h; j++) {
		viltrum_rsa_u128 s = (viltrum_rsa_u128)d[j] + (key->p[j] & addp) + c;
		d[j] = (uint64_t)s;
		c = (uint64_t)(s >> 64);
	}
	viltrum_mont_mul(t, d, key->qinv_m, key->p, key->p_n0, h);
	// x = s2 + h * q
	memset(x, 0, sizeof(uint64_t) * (size_t)k);
	for (int i = 0; i < h; i++) {
		c = 0;
		for (int j = 0; j < h; j++) {
			viltrum_rsa_u128 s = (viltrum_rsa_u128)t[i] * key->q[j] + x[i + j] + c;
			x[i + j] = (uint64_t)s;
			c = (uint64_t)(s >> 64);
		}
		x[i + h] = c;
	}
	c = 0;
	for (int j = 0; j < k; j++) {
		viltrum_rsa_u128 s = (viltrum_rsa_u128)x[j] + (j < h ? s2[j] : 0) + c;
		x[j] = (uint64_t)s;
		c = (uint64_t)(s >> 64);
	}
	// unblind: x = x * r^-1
	viltrum_mont_mul(x, x, key->bl_vf, key->n, key->n_n0, k);
	// check x^e == m before letting x out
	uint64_t y[VILTRUM_RSA_MAX_LIMBS], acc[VILTRUM_RSA_MAX_LIMBS];
	viltrum_mont_mul(y, x, key->n_r2, key->n, key->n_n0, k);
	memcpy(acc, y, sizeof(uint64_t) * (size_t)k);
	int top = 63;
	while (!((key->e >> top) & 1)) {
		top--;
	}
	for (int b = top - 1; b >= 0; b--) {
		viltrum_mont_sqr(acc, acc, key->n, key->n_n0, k);
		if ((key->e >> b) & 1) {
			viltrum_mont_mul(acc, acc, y, key->n, key->n_n0, k);
		}
	}
	memset(y, 0, sizeof(uint64_t) * (size_t)k);
	y[0] = 1;
	viltrum_mont_mul(acc, acc, y, key->n, key->n_n0, k);
	uint64_t diff = 0;
	for (int j = 0; j < k; j++) {
		diff |= acc[j] ^ m[j];
	}
	int ret = diff == 0 ? 0 : -1;
	if (ret == 0) {
		for (int i = 0; i < k; i++) {
			uint64_t v = x[i];
			uint8_t *p = out + (size_t)(k - 1 - i) * 8;
			for (int j = 7; j >= 0; j--) {
				p[j] = (uint8_t)v;
				v >>= 8;
			}
		}
	}
	viltrum_rsa_wipe(m, sizeof(m));
	viltrum_rsa_wipe(x, sizeof(x));
	viltrum_rsa_wipe(s1, sizeof(s1));
	viltrum_rsa_wipe(s2, sizeof(s2));
	viltrum_rsa_wipe(t, sizeof(t));
	viltrum_rsa_wipe(d, sizeof(d));
	return ret;
}

// viltrum_rsa_pss_sha256 signs the 32-byte hash mhash: EMSA-PSS-ENCODE (RFC 8017
// 9.1.1) with SHA-256, MGF1-SHA-256 and a 32-byte salt, as TLS 1.3 requires, then
// the private operation. sig gets limbs * 8 bytes. 0 on success.
static int viltrum_rsa_pss_sha256(viltrum_rsa *key, const uint8_t mhash[32], const uint8_t salt[32],
		uint8_t *sig) {
	if (!key->ok) {
		return -1;
	}
	size_t em_len = (size_t)key->limbs * 8; // emBits = bits - 1 and bits % 8 == 0
	size_t db_len = em_len - 32 - 1;
	uint8_t em[VILTRUM_RSA_MAX_LIMBS * 8];
	uint8_t mprime[8 + 32 + 32];
	memset(mprime, 0, 8);
	memcpy(mprime + 8, mhash, 32);
	memcpy(mprime + 40, salt, 32);
	uint8_t hash[32];
	if (mbedtls_sha256(mprime, sizeof(mprime), hash, 0) != 0) {
		return -1;
	}
	// DB = zeros || 0x01 || salt, masked with MGF1(H)
	memset(em, 0, db_len);
	em[db_len - 32 - 1] = 0x01;
	memcpy(em + db_len - 32, salt, 32);
	uint8_t block[36], mask[32];
	memcpy(block, hash, 32);
	for (uint32_t counter = 0, off = 0; off < db_len; counter++, off += 32) {
		block[32] = (uint8_t)(counter >> 24);
		block[33] = (uint8_t)(counter >> 16);
		block[34] = (uint8_t)(counter >> 8);
		block[35] = (uint8_t)counter;
		if (mbedtls_sha256(block, sizeof(block), mask, 0) != 0) {
			return -1;
		}
		for (size_t i = 0; i < 32 && off + i < db_len; i++) {
			em[off + i] ^= mask[i];
		}
	}
	em[0] &= 0x7f; // the one bit above emBits
	memcpy(em + db_len, hash, 32);
	em[em_len - 1] = 0xbc;
	return viltrum_rsa_private(key, em, sig);
}

static int viltrum_rsa_supported(void) {
	return 1;
}

#else

typedef struct {
	int limbs;
	int ok;
} viltrum_rsa;

static int viltrum_rsa_load(viltrum_rsa *key, mbedtls_pk_context *pk, mbedtls_ctr_drbg_context *drbg) {
	(void)pk;
	(void)drbg;
	key->ok = 0;
	return -1;
}

static int viltrum_rsa_pss_sha256(viltrum_rsa *key, const uint8_t mhash[32], const uint8_t salt[32],
		uint8_t *sig) {
	(void)key;
	(void)mhash;
	(void)salt;
	(void)sig;
	return -1;
}

static int viltrum_rsa_supported(void) {
	return 0;
}

#endif

#endif
