module engine

import encoding.hex
import net.mbedtls
import rand

#include <mbedtls/gcm.h>

@[typedef]
struct C.mbedtls_gcm_context {}

fn C.mbedtls_gcm_init(ctx &C.mbedtls_gcm_context)
fn C.mbedtls_gcm_setkey(ctx &C.mbedtls_gcm_context, cipher int, key &u8, keybits u32) int
fn C.mbedtls_gcm_crypt_and_tag(ctx &C.mbedtls_gcm_context, mode int, length u64, iv &u8, iv_len u64, add &u8, add_len u64, input &u8, output &u8, tag_len u64, tag &u8) int
fn C.mbedtls_gcm_free(ctx &C.mbedtls_gcm_context)

// The GCM specification's test cases with 96-bit nonces (McGrew and Viega, 2005).
struct GcmVector {
	key string
	iv  string
	pt  string
	aad string
	ct  string
	tag string
}

const tc_key = 'feffe9928665731c6d6a8f9467308308'
const tc_iv = 'cafebabefacedbaddecaf888'
const tc_pt = 'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255'
const tc_aad = 'feedfacedeadbeeffeedfacedeadbeefabaddad2'

const gcm_vectors = [
	GcmVector{'00000000000000000000000000000000', '000000000000000000000000', '', '', '', '58e2fccefa7e3061367f1d57a4e7455a'},
	GcmVector{'00000000000000000000000000000000', '000000000000000000000000', '00000000000000000000000000000000', '', '0388dace60b6a392f328c2b971b2fe78', 'ab6e47d42cec13bdf53a67b21257bddf'},
	GcmVector{tc_key, tc_iv, tc_pt, '', '42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985', '4d5c2af327cd64a62cf35abd2ba6fab4'},
	GcmVector{tc_key, tc_iv, tc_pt[..120], tc_aad, '42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091', '5bc94fbc3221a5db94fae95ae7121a47'},
	GcmVector{'0000000000000000000000000000000000000000000000000000000000000000', '000000000000000000000000', '', '', '', '530f8afbc74536b9a963b4f1c4cb738b'},
	GcmVector{'0000000000000000000000000000000000000000000000000000000000000000', '000000000000000000000000', '00000000000000000000000000000000', '', 'cea7403d4d606b6e074ec5d3baf39d18', 'd0d1c8a799996bf0265b98b5d48ab919'},
	GcmVector{tc_key + tc_key, tc_iv, tc_pt, '', '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad', 'b094dac5d93471bdec1a502270e3cc6c'},
	GcmVector{tc_key + tc_key, tc_iv, tc_pt[..120], tc_aad, '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad'[..120], '76fc6ece0f4e1768cddf8853bb2d551b'},
]

fn new_gcm(key []u8) &C.viltrum_gcm {
	g := C.viltrum_gcm_new()
	assert !isnil(g)
	assert C.viltrum_gcm_init(g, key.data, key.len) == 0
	return g
}

fn seal(g &C.viltrum_gcm, iv []u8, aad []u8, pt []u8) ([]u8, []u8) {
	mut ct := []u8{len: pt.len}
	mut tag := []u8{len: 16}
	C.viltrum_gcm_seal(g, iv.data, aad.data, u64(aad.len), pt.data, ct.data, u64(pt.len), tag.data)
	return ct, tag
}

fn test_gcm_spec_vectors() {
	_ = mbedtls.SSLConnectConfig{}
	if !aesgcm_supported {
		eprintln('skipped: no AES-NI/PCLMUL build or CPU')
		return
	}
	for i, v in gcm_vectors {
		g := new_gcm(hex.decode(v.key)!)
		iv := hex.decode(v.iv)!
		aad := hex.decode(v.aad)!
		pt := hex.decode(v.pt)!
		ct, tag := seal(g, iv, aad, pt)
		assert ct.hex() == v.ct, 'case ${i} ciphertext'
		assert tag.hex() == v.tag, 'case ${i} tag'
		mut back := []u8{len: ct.len}
		assert C.viltrum_gcm_open(g, iv.data, aad.data, u64(aad.len), ct.data, back.data,
			u64(ct.len), tag.data) == 0, 'case ${i} open'
		assert back == pt, 'case ${i} round trip'
	}
}

// Random keys, nonces, AAD and lengths across the 8-block and 1-block paths, against
// mbedtls' GCM; then in place, and every tampering refused with nothing written.
fn test_gcm_matches_mbedtls() {
	if !aesgcm_supported {
		return
	}
	for key_len in [16, 32] {
		for n in 0 .. 600 {
			key := rand.bytes(key_len)!
			iv := rand.bytes(12)!
			aad := rand.bytes(n % 23)!
			pt := rand.bytes(n)!
			g := new_gcm(key)
			ct, tag := seal(g, iv, aad, pt)
			mut ref := C.mbedtls_gcm_context{}
			C.mbedtls_gcm_init(&ref)
			assert C.mbedtls_gcm_setkey(&ref, 2, key.data, u32(key_len * 8)) == 0 // MBEDTLS_CIPHER_ID_AES
			mut rct := []u8{len: n}
			mut rtag := []u8{len: 16}
			assert C.mbedtls_gcm_crypt_and_tag(&ref, 1, u64(n), iv.data, 12, aad.data,
				u64(aad.len), pt.data, rct.data, 16, rtag.data) == 0
			C.mbedtls_gcm_free(&ref)
			assert ct == rct, 'key ${key_len} length ${n}'
			assert tag == rtag, 'key ${key_len} length ${n} tag'
			// in place, both ways
			mut buf := pt.clone()
			mut tag2 := []u8{len: 16}
			C.viltrum_gcm_seal(g, iv.data, aad.data, u64(aad.len), buf.data, buf.data, u64(n),
				tag2.data)
			assert buf == ct && tag2 == tag
			assert C.viltrum_gcm_open(g, iv.data, aad.data, u64(aad.len), buf.data, buf.data,
				u64(n), tag.data) == 0
			assert buf == pt
			// a record: content and type sealed together, the content read in place
			mut rec_pt := pt.clone()
			rec_pt << u8(23)
			rct2, rtag2 := seal(g, iv, aad, rec_pt)
			mut rec := []u8{len: n + 1}
			mut rec_tag := []u8{len: 16}
			C.viltrum_gcm_seal_record(g, iv.data, aad.data, u64(aad.len), pt.data, u64(n), 23,
				rec.data, rec_tag.data)
			assert rec == rct2 && rec_tag == rtag2, 'record length ${n}'
			// tampering
			mut out := []u8{len: n, init: 0xee}
			mut bad_tag := tag.clone()
			bad_tag[n % 16] ^= 1
			assert C.viltrum_gcm_open(g, iv.data, aad.data, u64(aad.len), ct.data, out.data,
				u64(n), bad_tag.data) == -1
			if n > 0 {
				mut bad_ct := ct.clone()
				bad_ct[n / 2] ^= 0x80
				assert C.viltrum_gcm_open(g, iv.data, aad.data, u64(aad.len), bad_ct.data,
					out.data, u64(n), tag.data) == -1
			}
			mut bad_aad := aad.clone()
			bad_aad << u8(0)
			assert C.viltrum_gcm_open(g, iv.data, bad_aad.data, u64(bad_aad.len), ct.data,
				out.data, u64(n), tag.data) == -1
			assert out.all(it == 0xee), 'a refused open wrote output'
		}
	}
}
