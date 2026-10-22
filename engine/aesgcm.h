// aesgcm.h: AES-GCM (128 and 256-bit keys, 96-bit nonces) on AES-NI and PCLMULQDQ,
// for the TLS 1.3 record layer (tls13.v). mbedtls does GCM a block at a time through
// its cipher layer, which was two thirds of a 10 KB TLS echo; here eight counter
// blocks go through the AES rounds side by side, and GHASH multiplies eight blocks by
// H^8..H^1 and reduces once.
//
// The methods are Intel's published ones: AES key expansion with AESKEYGENASSIST and
// GHASH by carry-less multiplication over byte-reflected blocks (Gueron and Kounavis,
// "Intel Carry-Less Multiplication Instruction and its Usage for Computing the GCM
// Mode", 2010), with products summed unreduced before one shift and reduction.
// engine/aesgcm_test.v checks it against FIPS-197 and the GCM spec's test vectors
// and against mbedtls on random inputs.
//
// Built only by gcc or clang for x86-64, the instructions enabled for these functions
// alone; viltrum_aesgcm_supported() asks the CPU at run time. Elsewhere the functions
// are stubs that report no support, and TLS stays on mbedtls.
#ifndef VILTRUM_AESGCM_H
#define VILTRUM_AESGCM_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct viltrum_gcm viltrum_gcm;

#if defined(__x86_64__) && !defined(__TINYC__) && (defined(__GNUC__) || defined(__clang__))

#include <immintrin.h>

#define VILTRUM_GCM_TARGET __attribute__((target("aes,pclmul,sse4.1")))

struct viltrum_gcm {
	__m128i rk[15]; // round keys
	__m128i hp[8];  // H^1..H^8, byte-reflected
	int nr;         // rounds: 10 or 14
};

static int viltrum_aesgcm_supported(void) {
	__builtin_cpu_init();
	return __builtin_cpu_supports("aes") && __builtin_cpu_supports("pclmul")
		&& __builtin_cpu_supports("sse4.1");
}

static viltrum_gcm *viltrum_gcm_new(void) {
	void *p = NULL;
	if (posix_memalign(&p, 64, sizeof(viltrum_gcm)) != 0) {
		return NULL;
	}
	memset(p, 0, sizeof(viltrum_gcm));
	return (viltrum_gcm *)p;
}

static void viltrum_gcm_wipe(viltrum_gcm *g) {
	volatile unsigned char *p = (volatile unsigned char *)g;
	for (size_t i = 0; i < sizeof(viltrum_gcm); i++) {
		p[i] = 0;
	}
}

VILTRUM_GCM_TARGET static inline __m128i viltrum_bswap128(__m128i x) {
	return _mm_shuffle_epi8(x, _mm_set_epi8(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
}

VILTRUM_GCM_TARGET static inline __m128i viltrum_aes128_step(__m128i k, __m128i assist) {
	assist = _mm_shuffle_epi32(assist, 0xff);
	__m128i t = _mm_slli_si128(k, 4);
	k = _mm_xor_si128(k, t);
	t = _mm_slli_si128(t, 4);
	k = _mm_xor_si128(k, t);
	t = _mm_slli_si128(t, 4);
	k = _mm_xor_si128(k, t);
	return _mm_xor_si128(k, assist);
}

// viltrum_aes256_odd is the odd round key step of AES-256: SubWord without RotWord.
VILTRUM_GCM_TARGET static inline __m128i viltrum_aes256_odd(__m128i prev, __m128i k) {
	__m128i assist = _mm_shuffle_epi32(_mm_aeskeygenassist_si128(prev, 0x00), 0xaa);
	__m128i t = _mm_slli_si128(k, 4);
	k = _mm_xor_si128(k, t);
	t = _mm_slli_si128(t, 4);
	k = _mm_xor_si128(k, t);
	t = _mm_slli_si128(t, 4);
	k = _mm_xor_si128(k, t);
	return _mm_xor_si128(k, assist);
}

VILTRUM_GCM_TARGET static void viltrum_aes_expand(viltrum_gcm *g, const uint8_t *key, int key_len) {
	__m128i *rk = g->rk;
	if (key_len == 16) {
		g->nr = 10;
		rk[0] = _mm_loadu_si128((const __m128i *)key);
#define VILTRUM_K128(i, rcon) rk[i] = viltrum_aes128_step(rk[i - 1], _mm_aeskeygenassist_si128(rk[i - 1], rcon))
		VILTRUM_K128(1, 0x01);
		VILTRUM_K128(2, 0x02);
		VILTRUM_K128(3, 0x04);
		VILTRUM_K128(4, 0x08);
		VILTRUM_K128(5, 0x10);
		VILTRUM_K128(6, 0x20);
		VILTRUM_K128(7, 0x40);
		VILTRUM_K128(8, 0x80);
		VILTRUM_K128(9, 0x1b);
		VILTRUM_K128(10, 0x36);
#undef VILTRUM_K128
		return;
	}
	g->nr = 14;
	rk[0] = _mm_loadu_si128((const __m128i *)key);
	rk[1] = _mm_loadu_si128((const __m128i *)(key + 16));
#define VILTRUM_K256(i, rcon)                                                             \
	rk[i] = viltrum_aes128_step(rk[i - 2], _mm_aeskeygenassist_si128(rk[i - 1], rcon)); \
	if (i + 1 < 15) {                                                                     \
		rk[i + 1] = viltrum_aes256_odd(rk[i], rk[i - 1]);                                 \
	}
	VILTRUM_K256(2, 0x01);
	VILTRUM_K256(4, 0x02);
	VILTRUM_K256(6, 0x04);
	VILTRUM_K256(8, 0x08);
	VILTRUM_K256(10, 0x10);
	VILTRUM_K256(12, 0x20);
	VILTRUM_K256(14, 0x40);
#undef VILTRUM_K256
}

VILTRUM_GCM_TARGET static inline __m128i viltrum_aes_block(const viltrum_gcm *g, __m128i x) {
	x = _mm_xor_si128(x, g->rk[0]);
	for (int r = 1; r < g->nr; r++) {
		x = _mm_aesenc_si128(x, g->rk[r]);
	}
	return _mm_aesenclast_si128(x, g->rk[g->nr]);
}

// viltrum_clmul_wide is the 256-bit carry-less product of a and b as (lo, hi), not
// yet reduced; products to be added are summed in this form and reduced once.
VILTRUM_GCM_TARGET static inline void viltrum_clmul_wide(__m128i a, __m128i b, __m128i *lo, __m128i *hi) {
	__m128i l = _mm_clmulepi64_si128(a, b, 0x00);
	__m128i h = _mm_clmulepi64_si128(a, b, 0x11);
	__m128i m = _mm_xor_si128(_mm_clmulepi64_si128(a, b, 0x10), _mm_clmulepi64_si128(a, b, 0x01));
	*lo = _mm_xor_si128(*lo, _mm_xor_si128(l, _mm_slli_si128(m, 8)));
	*hi = _mm_xor_si128(*hi, _mm_xor_si128(h, _mm_srli_si128(m, 8)));
}

// viltrum_gf_reduce turns a 256-bit product of byte-reflected operands into their
// GF(2^128) product: a one-bit left shift for the reflection, then reduction modulo
// x^128 + x^7 + x^2 + x + 1.
VILTRUM_GCM_TARGET static inline __m128i viltrum_gf_reduce(__m128i lo, __m128i hi) {
	__m128i t7 = _mm_srli_epi32(lo, 31);
	__m128i t8 = _mm_srli_epi32(hi, 31);
	lo = _mm_slli_epi32(lo, 1);
	hi = _mm_slli_epi32(hi, 1);
	__m128i t9 = _mm_srli_si128(t7, 12);
	t8 = _mm_slli_si128(t8, 4);
	t7 = _mm_slli_si128(t7, 4);
	lo = _mm_or_si128(lo, t7);
	hi = _mm_or_si128(_mm_or_si128(hi, t8), t9);
	t7 = _mm_slli_epi32(lo, 31);
	t8 = _mm_slli_epi32(lo, 30);
	t9 = _mm_slli_epi32(lo, 25);
	t7 = _mm_xor_si128(_mm_xor_si128(t7, t8), t9);
	t8 = _mm_srli_si128(t7, 4);
	t7 = _mm_slli_si128(t7, 12);
	lo = _mm_xor_si128(lo, t7);
	__m128i t2 = _mm_srli_epi32(lo, 1);
	__m128i t4 = _mm_srli_epi32(lo, 2);
	__m128i t5 = _mm_srli_epi32(lo, 7);
	t2 = _mm_xor_si128(_mm_xor_si128(_mm_xor_si128(t2, t4), t5), t8);
	lo = _mm_xor_si128(lo, t2);
	return _mm_xor_si128(hi, lo);
}

VILTRUM_GCM_TARGET static inline __m128i viltrum_gf_mul(__m128i a, __m128i b) {
	__m128i lo = _mm_setzero_si128();
	__m128i hi = _mm_setzero_si128();
	viltrum_clmul_wide(a, b, &lo, &hi);
	return viltrum_gf_reduce(lo, hi);
}

// viltrum_gcm_init sets the key (16 or 32 bytes) and H's powers. 0, or -1 for a bad length.
VILTRUM_GCM_TARGET static int viltrum_gcm_init(viltrum_gcm *g, const uint8_t *key, int key_len) {
	if (key_len != 16 && key_len != 32) {
		return -1;
	}
	viltrum_aes_expand(g, key, key_len);
	__m128i h = viltrum_bswap128(viltrum_aes_block(g, _mm_setzero_si128()));
	g->hp[0] = h;
	for (int i = 1; i < 8; i++) {
		g->hp[i] = viltrum_gf_mul(g->hp[i - 1], h);
	}
	return 0;
}

// viltrum_ghash_blocks folds n whole blocks at p into y (byte-reflected).
VILTRUM_GCM_TARGET static inline __m128i viltrum_ghash_blocks(const viltrum_gcm *g, __m128i y, const uint8_t *p, size_t n) {
	while (n >= 8) {
		__m128i lo = _mm_setzero_si128();
		__m128i hi = _mm_setzero_si128();
		__m128i x0 = _mm_xor_si128(y, viltrum_bswap128(_mm_loadu_si128((const __m128i *)p)));
		viltrum_clmul_wide(x0, g->hp[7], &lo, &hi);
		for (int k = 1; k < 8; k++) {
			__m128i x = viltrum_bswap128(_mm_loadu_si128((const __m128i *)(p + 16 * k)));
			viltrum_clmul_wide(x, g->hp[7 - k], &lo, &hi);
		}
		y = viltrum_gf_reduce(lo, hi);
		p += 128;
		n -= 8;
	}
	while (n > 0) {
		y = viltrum_gf_mul(_mm_xor_si128(y, viltrum_bswap128(_mm_loadu_si128((const __m128i *)p))), g->hp[0]);
		p += 16;
		n--;
	}
	return y;
}

// viltrum_ghash folds len bytes at p into y, zero-padding a final partial block.
VILTRUM_GCM_TARGET static inline __m128i viltrum_ghash(const viltrum_gcm *g, __m128i y, const uint8_t *p, size_t len) {
	y = viltrum_ghash_blocks(g, y, p, len / 16);
	size_t rest = len % 16;
	if (rest > 0) {
		uint8_t last[16] = {0};
		memcpy(last, p + len - rest, rest);
		y = viltrum_ghash_blocks(g, y, last, 1);
	}
	return y;
}

// viltrum_gcm_ctr XORs n bytes of in with the keystream from counter block 2 on (block
// 1 masks the tag), eight blocks at a time. in and out may be the same buffer.
VILTRUM_GCM_TARGET static void viltrum_gcm_ctr(const viltrum_gcm *g, const uint8_t iv[12], const uint8_t *in, uint8_t *out, size_t n) {
	uint8_t cb[16];
	memcpy(cb, iv, 12);
	memset(cb + 12, 0, 4);
	const __m128i base = _mm_loadu_si128((const __m128i *)cb);
	uint32_t ctr = 2;
	const int nr = g->nr;
	while (n >= 128) {
		__m128i b[8];
		for (int k = 0; k < 8; k++) {
			b[k] = _mm_xor_si128(_mm_insert_epi32(base, (int)__builtin_bswap32(ctr + (uint32_t)k), 3), g->rk[0]);
		}
		for (int r = 1; r < nr; r++) {
			const __m128i key = g->rk[r];
			for (int k = 0; k < 8; k++) {
				b[k] = _mm_aesenc_si128(b[k], key);
			}
		}
		for (int k = 0; k < 8; k++) {
			b[k] = _mm_aesenclast_si128(b[k], g->rk[nr]);
			__m128i x = _mm_loadu_si128((const __m128i *)(in + 16 * k));
			_mm_storeu_si128((__m128i *)(out + 16 * k), _mm_xor_si128(x, b[k]));
		}
		ctr += 8;
		in += 128;
		out += 128;
		n -= 128;
	}
	while (n > 0) {
		__m128i ks = viltrum_aes_block(g, _mm_insert_epi32(base, (int)__builtin_bswap32(ctr), 3));
		ctr++;
		if (n >= 16) {
			_mm_storeu_si128((__m128i *)out, _mm_xor_si128(_mm_loadu_si128((const __m128i *)in), ks));
			in += 16;
			out += 16;
			n -= 16;
		} else {
			uint8_t k[16];
			_mm_storeu_si128((__m128i *)k, ks);
			for (size_t i = 0; i < n; i++) {
				out[i] = in[i] ^ k[i];
			}
			n = 0;
		}
	}
}

// viltrum_gcm_tag finishes GHASH with the length block and masks it with block 1.
VILTRUM_GCM_TARGET static void viltrum_gcm_tag(const viltrum_gcm *g, const uint8_t iv[12], __m128i y, size_t aad_len, size_t n, uint8_t tag[16]) {
	__m128i lens = _mm_set_epi64x((long long)(aad_len * 8), (long long)(n * 8));
	// the length block is big-endian; reflected, the two 64-bit halves land as set
	y = viltrum_gf_mul(_mm_xor_si128(y, lens), g->hp[0]);
	uint8_t cb[16];
	memcpy(cb, iv, 12);
	cb[12] = 0;
	cb[13] = 0;
	cb[14] = 0;
	cb[15] = 1;
	__m128i s = _mm_xor_si128(viltrum_bswap128(y), viltrum_aes_block(g, _mm_loadu_si128((const __m128i *)cb)));
	_mm_storeu_si128((__m128i *)tag, s);
}

// viltrum_gcm_seal encrypts n bytes (in may equal out) and writes the 16-byte tag.
VILTRUM_GCM_TARGET static void viltrum_gcm_seal(const viltrum_gcm *g, const uint8_t iv[12], const uint8_t *aad, size_t aad_len, const uint8_t *in, uint8_t *out, size_t n, uint8_t tag[16]) {
	viltrum_gcm_ctr(g, iv, in, out, n);
	__m128i y = viltrum_ghash(g, _mm_setzero_si128(), aad, aad_len);
	y = viltrum_ghash(g, y, out, n);
	viltrum_gcm_tag(g, iv, y, aad_len, n, tag);
}

// viltrum_gcm_open checks the tag, in constant time, and only then decrypts (in may
// equal out). 0, or -1 when the tag does not match and nothing was written.
VILTRUM_GCM_TARGET static int viltrum_gcm_open(const viltrum_gcm *g, const uint8_t iv[12], const uint8_t *aad, size_t aad_len, const uint8_t *in, uint8_t *out, size_t n, const uint8_t tag[16]) {
	__m128i y = viltrum_ghash(g, _mm_setzero_si128(), aad, aad_len);
	y = viltrum_ghash(g, y, in, n);
	uint8_t want[16];
	viltrum_gcm_tag(g, iv, y, aad_len, n, want);
	unsigned diff = 0;
	for (int i = 0; i < 16; i++) {
		diff |= (unsigned)(want[i] ^ tag[i]);
	}
	if (diff != 0) {
		return -1;
	}
	viltrum_gcm_ctr(g, iv, in, out, n);
	return 0;
}

#else

struct viltrum_gcm {
	int unused;
};

static int viltrum_aesgcm_supported(void) {
	return 0;
}

static viltrum_gcm *viltrum_gcm_new(void) {
	return NULL;
}

static void viltrum_gcm_wipe(viltrum_gcm *g) {
	(void)g;
}

static int viltrum_gcm_init(viltrum_gcm *g, const uint8_t *key, int key_len) {
	(void)g;
	(void)key;
	(void)key_len;
	return -1;
}

static void viltrum_gcm_seal(const viltrum_gcm *g, const uint8_t iv[12], const uint8_t *aad, size_t aad_len, const uint8_t *in, uint8_t *out, size_t n, uint8_t tag[16]) {
	(void)g;
	(void)iv;
	(void)aad;
	(void)aad_len;
	(void)in;
	(void)out;
	(void)n;
	(void)tag;
}

static int viltrum_gcm_open(const viltrum_gcm *g, const uint8_t iv[12], const uint8_t *aad, size_t aad_len, const uint8_t *in, uint8_t *out, size_t n, const uint8_t tag[16]) {
	(void)g;
	(void)iv;
	(void)aad;
	(void)aad_len;
	(void)in;
	(void)out;
	(void)n;
	(void)tag;
	return -1;
}

#endif

#endif
