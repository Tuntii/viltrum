// crc32_clmul.h: CRC-32 (IEEE, reflected, as gzip uses) by carry-less multiplication,
// the folding method of Intel's "Fast CRC Computation for Generic Polynomials Using
// PCLMULQDQ Instruction" (Gopal et al., 2009). Four 128-bit lanes fold 64 bytes per
// step, then fold to one lane, then to 64 and 32 bits and a Barrett reduction.
//
// Only built by gcc or clang for x86-64, with the instructions enabled for these
// functions alone; the caller asks viltrum_have_clmul() at run time. Anywhere else
// (tcc, other CPUs) both functions are stubs and the table method does all the work.
#ifndef VILTRUM_CRC32_CLMUL_H
#define VILTRUM_CRC32_CLMUL_H

#include <stddef.h>
#include <stdint.h>

#if defined(__x86_64__) && !defined(__TINYC__) && (defined(__GNUC__) || defined(__clang__))

#include <immintrin.h>

static int viltrum_have_clmul(void) {
	__builtin_cpu_init();
	return __builtin_cpu_supports("pclmul") && __builtin_cpu_supports("sse4.1");
}

// Folding constants: x^(4*128+32) mod P and x^(4*128-32) mod P for the 4-lane fold,
// the same for one lane, x^64 mod P, and the Barrett pair (mu, P), bit-reflected.
static const uint64_t viltrum_k1k2[2] __attribute__((aligned(16))) = {0x0154442bd4, 0x01c6e41596};
static const uint64_t viltrum_k3k4[2] __attribute__((aligned(16))) = {0x01751997d0, 0x00ccaa009e};
static const uint64_t viltrum_k5k0[2] __attribute__((aligned(16))) = {0x0163cd6124, 0x0000000000};
static const uint64_t viltrum_poly[2] __attribute__((aligned(16))) = {0x01db710641, 0x01f7011641};

// viltrum_crc32_clmul continues crc (the running register, not inverted at the end)
// over n bytes, n >= 64 and a multiple of 16.
__attribute__((target("pclmul,sse4.1")))
static uint32_t viltrum_crc32_clmul(uint32_t crc, const uint8_t *p, size_t n) {
	__m128i x0, x1, x2, x3, x4, x5, x6, x7, x8, y5, y6, y7, y8;
	x1 = _mm_loadu_si128((const __m128i *)(p + 0x00));
	x2 = _mm_loadu_si128((const __m128i *)(p + 0x10));
	x3 = _mm_loadu_si128((const __m128i *)(p + 0x20));
	x4 = _mm_loadu_si128((const __m128i *)(p + 0x30));
	x1 = _mm_xor_si128(x1, _mm_cvtsi32_si128((int)crc));
	x0 = _mm_load_si128((const __m128i *)viltrum_k1k2);
	p += 64;
	n -= 64;
	while (n >= 64) {
		x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
		x6 = _mm_clmulepi64_si128(x2, x0, 0x00);
		x7 = _mm_clmulepi64_si128(x3, x0, 0x00);
		x8 = _mm_clmulepi64_si128(x4, x0, 0x00);
		x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
		x2 = _mm_clmulepi64_si128(x2, x0, 0x11);
		x3 = _mm_clmulepi64_si128(x3, x0, 0x11);
		x4 = _mm_clmulepi64_si128(x4, x0, 0x11);
		y5 = _mm_loadu_si128((const __m128i *)(p + 0x00));
		y6 = _mm_loadu_si128((const __m128i *)(p + 0x10));
		y7 = _mm_loadu_si128((const __m128i *)(p + 0x20));
		y8 = _mm_loadu_si128((const __m128i *)(p + 0x30));
		x1 = _mm_xor_si128(_mm_xor_si128(x1, x5), y5);
		x2 = _mm_xor_si128(_mm_xor_si128(x2, x6), y6);
		x3 = _mm_xor_si128(_mm_xor_si128(x3, x7), y7);
		x4 = _mm_xor_si128(_mm_xor_si128(x4, x8), y8);
		p += 64;
		n -= 64;
	}
	// four lanes into one
	x0 = _mm_load_si128((const __m128i *)viltrum_k3k4);
	x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
	x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
	x1 = _mm_xor_si128(_mm_xor_si128(x1, x2), x5);
	x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
	x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
	x1 = _mm_xor_si128(_mm_xor_si128(x1, x3), x5);
	x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
	x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
	x1 = _mm_xor_si128(_mm_xor_si128(x1, x4), x5);
	// the remaining 16-byte blocks
	while (n >= 16) {
		x2 = _mm_loadu_si128((const __m128i *)p);
		x5 = _mm_clmulepi64_si128(x1, x0, 0x00);
		x1 = _mm_clmulepi64_si128(x1, x0, 0x11);
		x1 = _mm_xor_si128(_mm_xor_si128(x1, x2), x5);
		p += 16;
		n -= 16;
	}
	// 128 bits to 64
	x2 = _mm_clmulepi64_si128(x1, x0, 0x10);
	x3 = _mm_setr_epi32(~0, 0, ~0, 0);
	x1 = _mm_srli_si128(x1, 8);
	x1 = _mm_xor_si128(x1, x2);
	x0 = _mm_loadl_epi64((const __m128i *)viltrum_k5k0);
	x2 = _mm_srli_si128(x1, 4);
	x1 = _mm_and_si128(x1, x3);
	x1 = _mm_clmulepi64_si128(x1, x0, 0x00);
	x1 = _mm_xor_si128(x1, x2);
	// Barrett reduction to 32 bits
	x0 = _mm_load_si128((const __m128i *)viltrum_poly);
	x2 = _mm_and_si128(x1, x3);
	x2 = _mm_clmulepi64_si128(x2, x0, 0x10);
	x2 = _mm_and_si128(x2, x3);
	x2 = _mm_clmulepi64_si128(x2, x0, 0x00);
	x1 = _mm_xor_si128(x1, x2);
	return (uint32_t)_mm_extract_epi32(x1, 1);
}

#else

static int viltrum_have_clmul(void) {
	return 0;
}

static uint32_t viltrum_crc32_clmul(uint32_t crc, const uint8_t *p, size_t n) {
	(void)p;
	(void)n;
	return crc;
}

#endif

#endif
