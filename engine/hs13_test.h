// hs13_test.h: helpers for engine/hs13_linux_test.v only.
#ifndef VILTRUM_HS13_TEST_H
#define VILTRUM_HS13_TEST_H

#include <mbedtls/pk.h>
#include <mbedtls/rsa.h>
#include <mbedtls/sha256.h>

// viltrum_test_pss_verify checks an RSASSA-PSS (SHA-256, 32-byte salt) signature of
// hash with mbedtls: 0 when it verifies.
static int viltrum_test_pss_verify(mbedtls_pk_context *pk, const unsigned char hash[32], const unsigned char *sig) {
	if (mbedtls_pk_get_type(pk) != MBEDTLS_PK_RSA) {
		return -1;
	}
	return mbedtls_rsa_rsassa_pss_verify_ext(mbedtls_pk_rsa(*pk), MBEDTLS_MD_SHA256, 32, hash,
		MBEDTLS_MD_SHA256, 32, sig);
}

static int viltrum_test_sha256(const unsigned char *in, size_t n, unsigned char out[32]) {
	return mbedtls_sha256(in, n, out, 0);
}

#endif
