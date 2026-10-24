// x25519.h: X25519 (RFC 7748) for the TLS 1.3 handshake (hs13). mbedtls computes it
// on its generic bignum code: 2.1 ms of CPU for a key pair and a shared secret on the
// test VM, a third of a handshake. Here a field element is five 51-bit limbs and a
// product is formed in 128-bit sums, after curve25519-donna's 64-bit code (Adam
// Langley); the ladder and the inversion chain are RFC 7748's and ref10's.
//
// Constant time: no branch and no memory index depends on the scalar or the point.
// engine/hs13_linux_test.v checks RFC 7748's vectors (section 5.2, the iterated ones,
// and the Diffie-Hellman example in 6.1) and RFC 8448's key exchange.
#ifndef VILTRUM_X25519_H
#define VILTRUM_X25519_H

#include <stdint.h>
#include <string.h>

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

typedef unsigned __int128 viltrum_u128;
typedef uint64_t viltrum_fe[5];

#define VILTRUM_FE_MASK 0x7ffffffffffffULL // 2^51 - 1

static void viltrum_fe_copy(viltrum_fe r, const viltrum_fe a) {
	for (int i = 0; i < 5; i++) {
		r[i] = a[i];
	}
}

static void viltrum_fe_add(viltrum_fe r, const viltrum_fe a, const viltrum_fe b) {
	for (int i = 0; i < 5; i++) {
		r[i] = a[i] + b[i];
	}
}

// viltrum_fe_sub is a - b + 2p, so no limb goes negative while b's limbs are below 2^52.
static void viltrum_fe_sub(viltrum_fe r, const viltrum_fe a, const viltrum_fe b) {
	r[0] = a[0] + 0xfffffffffffdaULL - b[0];
	r[1] = a[1] + 0xffffffffffffeULL - b[1];
	r[2] = a[2] + 0xffffffffffffeULL - b[2];
	r[3] = a[3] + 0xffffffffffffeULL - b[3];
	r[4] = a[4] + 0xffffffffffffeULL - b[4];
}

// viltrum_fe_carry folds 128-bit column sums back to 51-bit limbs; 2^255 = 19 mod p.
static void viltrum_fe_carry(viltrum_fe r, viltrum_u128 t0, viltrum_u128 t1, viltrum_u128 t2,
		viltrum_u128 t3, viltrum_u128 t4) {
	t1 += (uint64_t)(t0 >> 51);
	t2 += (uint64_t)(t1 >> 51);
	t3 += (uint64_t)(t2 >> 51);
	t4 += (uint64_t)(t3 >> 51);
	uint64_t r0 = (uint64_t)t0 & VILTRUM_FE_MASK;
	uint64_t r1 = (uint64_t)t1 & VILTRUM_FE_MASK;
	r[2] = (uint64_t)t2 & VILTRUM_FE_MASK;
	r[3] = (uint64_t)t3 & VILTRUM_FE_MASK;
	r[4] = (uint64_t)t4 & VILTRUM_FE_MASK;
	r0 += (uint64_t)(t4 >> 51) * 19;
	r1 += r0 >> 51;
	r[0] = r0 & VILTRUM_FE_MASK;
	r[1] = r1;
}

static void viltrum_fe_mul(viltrum_fe r, const viltrum_fe a, const viltrum_fe b) {
	uint64_t b1 = b[1] * 19, b2 = b[2] * 19, b3 = b[3] * 19, b4 = b[4] * 19;
	viltrum_u128 t0 = (viltrum_u128)a[0] * b[0] + (viltrum_u128)a[1] * b4 + (viltrum_u128)a[2] * b3
		+ (viltrum_u128)a[3] * b2 + (viltrum_u128)a[4] * b1;
	viltrum_u128 t1 = (viltrum_u128)a[0] * b[1] + (viltrum_u128)a[1] * b[0] + (viltrum_u128)a[2] * b4
		+ (viltrum_u128)a[3] * b3 + (viltrum_u128)a[4] * b2;
	viltrum_u128 t2 = (viltrum_u128)a[0] * b[2] + (viltrum_u128)a[1] * b[1] + (viltrum_u128)a[2] * b[0]
		+ (viltrum_u128)a[3] * b4 + (viltrum_u128)a[4] * b3;
	viltrum_u128 t3 = (viltrum_u128)a[0] * b[3] + (viltrum_u128)a[1] * b[2] + (viltrum_u128)a[2] * b[1]
		+ (viltrum_u128)a[3] * b[0] + (viltrum_u128)a[4] * b4;
	viltrum_u128 t4 = (viltrum_u128)a[0] * b[4] + (viltrum_u128)a[1] * b[3] + (viltrum_u128)a[2] * b[2]
		+ (viltrum_u128)a[3] * b[1] + (viltrum_u128)a[4] * b[0];
	viltrum_fe_carry(r, t0, t1, t2, t3, t4);
}

static void viltrum_fe_sq(viltrum_fe r, const viltrum_fe a) {
	uint64_t d0 = a[0] * 2, d1 = a[1] * 2, d2 = a[2] * 2 * 19, d3 = a[3] * 19, d4 = a[4] * 19;
	viltrum_u128 t0 = (viltrum_u128)a[0] * a[0] + (viltrum_u128)d1 * d4 + (viltrum_u128)d2 * a[3];
	viltrum_u128 t1 = (viltrum_u128)d0 * a[1] + (viltrum_u128)d2 * a[4] + (viltrum_u128)a[3] * d3;
	viltrum_u128 t2 = (viltrum_u128)d0 * a[2] + (viltrum_u128)a[1] * a[1] + (viltrum_u128)(a[3] * 2) * d4;
	viltrum_u128 t3 = (viltrum_u128)d0 * a[3] + (viltrum_u128)d1 * a[2] + (viltrum_u128)a[4] * d4;
	viltrum_u128 t4 = (viltrum_u128)d0 * a[4] + (viltrum_u128)d1 * a[3] + (viltrum_u128)a[2] * a[2];
	viltrum_fe_carry(r, t0, t1, t2, t3, t4);
}

static void viltrum_fe_sq_n(viltrum_fe r, const viltrum_fe a, int n) {
	viltrum_fe_sq(r, a);
	for (int i = 1; i < n; i++) {
		viltrum_fe_sq(r, r);
	}
}

// viltrum_fe_mul_a24 multiplies by (486662 - 2) / 4 = 121665.
static void viltrum_fe_mul_a24(viltrum_fe r, const viltrum_fe a) {
	viltrum_fe_carry(r, (viltrum_u128)a[0] * 121665, (viltrum_u128)a[1] * 121665,
		(viltrum_u128)a[2] * 121665, (viltrum_u128)a[3] * 121665, (viltrum_u128)a[4] * 121665);
}

// viltrum_fe_cswap swaps a and b when swap is 1, leaves them when it is 0.
static void viltrum_fe_cswap(viltrum_fe a, viltrum_fe b, uint64_t swap) {
	uint64_t mask = 0 - swap;
	VILTRUM_CT_HIDE(mask);
	for (int i = 0; i < 5; i++) {
		uint64_t x = (a[i] ^ b[i]) & mask;
		a[i] ^= x;
		b[i] ^= x;
	}
}

static uint64_t viltrum_load64_le(const uint8_t *p) {
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--) {
		v = (v << 8) | p[i];
	}
	return v;
}

// viltrum_fe_frombytes reads 255 bits little-endian; the top bit is ignored (RFC
// 7748 5) and a value of p or more is allowed: the arithmetic reduces it.
static void viltrum_fe_frombytes(viltrum_fe r, const uint8_t s[32]) {
	r[0] = viltrum_load64_le(s) & VILTRUM_FE_MASK;
	r[1] = (viltrum_load64_le(s + 6) >> 3) & VILTRUM_FE_MASK;
	r[2] = (viltrum_load64_le(s + 12) >> 6) & VILTRUM_FE_MASK;
	r[3] = (viltrum_load64_le(s + 19) >> 1) & VILTRUM_FE_MASK;
	r[4] = (viltrum_load64_le(s + 24) >> 12) & VILTRUM_FE_MASK;
}

// viltrum_fe_tobytes writes the canonical encoding: fully reduced below p.
static void viltrum_fe_tobytes(uint8_t s[32], const viltrum_fe a) {
	uint64_t t[5];
	viltrum_fe_copy(t, a);
	for (int round = 0; round < 2; round++) {
		t[1] += t[0] >> 51;
		t[0] &= VILTRUM_FE_MASK;
		t[2] += t[1] >> 51;
		t[1] &= VILTRUM_FE_MASK;
		t[3] += t[2] >> 51;
		t[2] &= VILTRUM_FE_MASK;
		t[4] += t[3] >> 51;
		t[3] &= VILTRUM_FE_MASK;
		t[0] += (t[4] >> 51) * 19;
		t[4] &= VILTRUM_FE_MASK;
	}
	// t is below 2^255 now; t >= p exactly when t + 19 reaches 2^255
	t[0] += 19;
	t[1] += t[0] >> 51;
	t[0] &= VILTRUM_FE_MASK;
	t[2] += t[1] >> 51;
	t[1] &= VILTRUM_FE_MASK;
	t[3] += t[2] >> 51;
	t[2] &= VILTRUM_FE_MASK;
	t[4] += t[3] >> 51;
	t[3] &= VILTRUM_FE_MASK;
	t[0] += (t[4] >> 51) * 19;
	t[4] &= VILTRUM_FE_MASK;
	// t + 19 (mod 2^255 with the wrap folded back); adding 2^255 - 19 and dropping
	// the 2^255 leaves t - p when t >= p and t otherwise
	t[0] += 0x8000000000000ULL - 19;
	t[1] += 0x8000000000000ULL - 1;
	t[2] += 0x8000000000000ULL - 1;
	t[3] += 0x8000000000000ULL - 1;
	t[4] += 0x8000000000000ULL - 1;
	t[1] += t[0] >> 51;
	t[0] &= VILTRUM_FE_MASK;
	t[2] += t[1] >> 51;
	t[1] &= VILTRUM_FE_MASK;
	t[3] += t[2] >> 51;
	t[2] &= VILTRUM_FE_MASK;
	t[4] += t[3] >> 51;
	t[3] &= VILTRUM_FE_MASK;
	t[4] &= VILTRUM_FE_MASK;
	uint64_t w[4];
	w[0] = t[0] | (t[1] << 51);
	w[1] = (t[1] >> 13) | (t[2] << 38);
	w[2] = (t[2] >> 26) | (t[3] << 25);
	w[3] = (t[3] >> 39) | (t[4] << 12);
	for (int i = 0; i < 4; i++) {
		for (int j = 0; j < 8; j++) {
			s[8 * i + j] = (uint8_t)(w[i] >> (8 * j));
		}
	}
}

// viltrum_fe_invert is a^(p-2), ref10's chain of 254 squarings and 11 products.
static void viltrum_fe_invert(viltrum_fe r, const viltrum_fe z) {
	viltrum_fe z2, z9, z11, z2_5_0, z2_10_0, z2_20_0, z2_50_0, z2_100_0, t;
	viltrum_fe_sq(z2, z);
	viltrum_fe_sq_n(t, z2, 2);
	viltrum_fe_mul(z9, t, z);
	viltrum_fe_mul(z11, z9, z2);
	viltrum_fe_sq(t, z11);
	viltrum_fe_mul(z2_5_0, t, z9);
	viltrum_fe_sq_n(t, z2_5_0, 5);
	viltrum_fe_mul(z2_10_0, t, z2_5_0);
	viltrum_fe_sq_n(t, z2_10_0, 10);
	viltrum_fe_mul(z2_20_0, t, z2_10_0);
	viltrum_fe_sq_n(t, z2_20_0, 20);
	viltrum_fe_mul(t, t, z2_20_0);
	viltrum_fe_sq_n(t, t, 10);
	viltrum_fe_mul(z2_50_0, t, z2_10_0);
	viltrum_fe_sq_n(t, z2_50_0, 50);
	viltrum_fe_mul(z2_100_0, t, z2_50_0);
	viltrum_fe_sq_n(t, z2_100_0, 100);
	viltrum_fe_mul(t, t, z2_100_0);
	viltrum_fe_sq_n(t, t, 50);
	viltrum_fe_mul(t, t, z2_50_0);
	viltrum_fe_sq_n(t, t, 5);
	viltrum_fe_mul(r, t, z11);
}

static void viltrum_x25519_wipe(void *p, size_t n) {
	volatile uint8_t *b = (volatile uint8_t *)p;
	for (size_t i = 0; i < n; i++) {
		b[i] = 0;
	}
}

// viltrum_x25519 sets out to scalar * point (RFC 7748 5). The result is all zeros
// for a point of small order; the caller must refuse that (RFC 8446 7.4.2).
static void viltrum_x25519(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]) {
	uint8_t k[32];
	memcpy(k, scalar, 32);
	k[0] &= 248;
	k[31] &= 127;
	k[31] |= 64;
	viltrum_fe x1, x2, z2, x3, z3, a, aa, b, bb, e, c, d, da, cb, t;
	viltrum_fe_frombytes(x1, point);
	memset(x2, 0, sizeof(x2));
	x2[0] = 1;
	memset(z2, 0, sizeof(z2));
	viltrum_fe_copy(x3, x1);
	memset(z3, 0, sizeof(z3));
	z3[0] = 1;
	uint64_t swap = 0;
	for (int pos = 254; pos >= 0; pos--) {
		uint64_t bit = (k[pos >> 3] >> (pos & 7)) & 1;
		swap ^= bit;
		viltrum_fe_cswap(x2, x3, swap);
		viltrum_fe_cswap(z2, z3, swap);
		swap = bit;
		viltrum_fe_add(a, x2, z2);
		viltrum_fe_sq(aa, a);
		viltrum_fe_sub(b, x2, z2);
		viltrum_fe_sq(bb, b);
		viltrum_fe_sub(e, aa, bb);
		viltrum_fe_add(c, x3, z3);
		viltrum_fe_sub(d, x3, z3);
		viltrum_fe_mul(da, d, a);
		viltrum_fe_mul(cb, c, b);
		viltrum_fe_add(t, da, cb);
		viltrum_fe_sq(x3, t);
		viltrum_fe_sub(t, da, cb);
		viltrum_fe_sq(t, t);
		viltrum_fe_mul(z3, x1, t);
		viltrum_fe_mul(x2, aa, bb);
		viltrum_fe_mul_a24(t, e);
		viltrum_fe_add(t, aa, t);
		viltrum_fe_mul(z2, e, t);
	}
	viltrum_fe_cswap(x2, x3, swap);
	viltrum_fe_cswap(z2, z3, swap);
	viltrum_fe_invert(z2, z2);
	viltrum_fe_mul(x2, x2, z2);
	viltrum_fe_tobytes(out, x2);
	// the scalar and every intermediate the ladder left on the stack
	viltrum_x25519_wipe(k, sizeof(k));
	viltrum_fe *fes[] = {&x1, &x2, &z2, &x3, &z3, &a, &aa, &b, &bb, &e, &c, &d, &da, &cb, &t};
	for (size_t i = 0; i < sizeof(fes) / sizeof(fes[0]); i++) {
		viltrum_x25519_wipe(fes[i], sizeof(viltrum_fe));
	}
}

// viltrum_x25519_base sets out to the public key of scalar: scalar * 9.
static void viltrum_x25519_base(uint8_t out[32], const uint8_t scalar[32]) {
	uint8_t nine[32] = {9};
	viltrum_x25519(out, scalar, nine);
}

static int viltrum_x25519_supported(void) {
	return 1;
}

#else

static void viltrum_x25519(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]) {
	(void)scalar;
	(void)point;
	memset(out, 0, 32);
}

static void viltrum_x25519_base(uint8_t out[32], const uint8_t scalar[32]) {
	(void)scalar;
	memset(out, 0, 32);
}

static int viltrum_x25519_supported(void) {
	return 0;
}

#endif

#endif
