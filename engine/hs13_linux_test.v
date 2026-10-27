module engine

import encoding.hex
import os
import rand

#include "@VMODROOT/engine/hs13_test.h"

fn C.viltrum_x25519(out &u8, scalar &u8, point &u8)
fn C.viltrum_x25519_base(out &u8, scalar &u8)
fn C.viltrum_hs13_server_hello(out &u8, h &C.viltrum_hs13_hello, random &u8, pub &u8) u64
fn C.viltrum_hs13_schedule(dh &u8, th &u8, c_hs &u8, s_hs &u8, master &u8) int
fn C.viltrum_hs13_traffic(secret &u8, key &u8, iv &u8) int
fn C.viltrum_hs13_finished_mac(secret &u8, th &u8, out &u8) int
fn C.viltrum_hs13_app(master &u8, th &u8, c_ap &u8, s_ap &u8) int
fn C.viltrum_hs13_flight_with(rnd &u8, ch &u8, ch_len u64, h &C.viltrum_hs13_hello, cert &u8, cert_len u64, key &C.viltrum_rsa, tx &C.viltrum_gcm, out &u8, cap u64, out_len &u64, keys &C.viltrum_hs13_keys) int
fn C.viltrum_rsa_pss_sha256(key &C.viltrum_rsa, mhash &u8, salt &u8, sig &u8) int
fn C.viltrum_test_pss_verify(pk &C.mbedtls_pk_context, hash &u8, sig &u8) int
fn C.viltrum_test_sha256(input &u8, n u64, out &u8) int

const hs13_testdata = os.join_path(os.dir(@FILE), 'testdata', 'tls')

fn unhex(s string) []u8 {
	return hex.decode(s) or { panic(err) }
}

fn sha(parts ...string) []u8 {
	mut all := []u8{}
	for p in parts {
		all << unhex(p)
	}
	mut out := []u8{len: 32}
	C.viltrum_test_sha256(all.data, u64(all.len), out.data)
	return out
}

fn x25519(k []u8, u []u8) []u8 {
	mut out := []u8{len: 32}
	C.viltrum_x25519(out.data, k.data, u.data)
	return out
}

// RFC 7748 section 5.2 and the iterated test.
fn test_x25519_rfc7748() {
	if !hs13_supported {
		return
	}
	assert x25519(unhex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4'),
		unhex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c')).hex() == 'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552'
	// the u-coordinate's top bit is set: it must be ignored
	assert x25519(unhex('4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d'),
		unhex('e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493')).hex() == '95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957'
	mut k := []u8{len: 32}
	k[0] = 9
	mut u := k.clone()
	for i in 1 .. 1001 {
		out := x25519(k, u)
		u = k.clone()
		k = out.clone()
		if i == 1 {
			assert k.hex() == '422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079'
		}
	}
	assert k.hex() == '684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51'
}

// RFC 7748 section 6.1, and RFC 8448's key exchange.
fn test_x25519_diffie_hellman() {
	if !hs13_supported {
		return
	}
	a := unhex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a')
	b := unhex('5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb')
	mut pa := []u8{len: 32}
	mut pb := []u8{len: 32}
	C.viltrum_x25519_base(pa.data, a.data)
	C.viltrum_x25519_base(pb.data, b.data)
	assert pa.hex() == '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'
	assert pb.hex() == 'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f'
	secret := '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'
	assert x25519(a, pb).hex() == secret
	assert x25519(b, pa).hex() == secret
	mut sp := []u8{len: 32}
	C.viltrum_x25519_base(sp.data, unhex(r8448_server_priv).data)
	assert sp.hex() == r8448_server_pub
	assert x25519(unhex(r8448_server_priv), unhex(r8448_client_pub)).hex() == r8448_shared
	assert x25519(unhex(r8448_client_priv), unhex(r8448_server_pub)).hex() == r8448_shared
}

fn load_test_pair(name string) &CertPair {
	mut s := &TlsServer{
		cert_file: os.join_path(hs13_testdata, '${name}.crt')
		key_file:  os.join_path(hs13_testdata, '${name}.key')
	}
	C.mbedtls_entropy_init(&s.entropy)
	C.mbedtls_ctr_drbg_init(&s.drbg)
	assert C.viltrum_tls_seed(&s.drbg, &s.entropy) == 0
	return s.load_pair() or { panic(err) }
}

// Signatures from rsa.h verify with mbedtls, for fresh salts and hashes, over and
// over (the blinding pair is squared after each).
fn test_rsa_pss_signatures_verify() {
	if !hs13_supported {
		return
	}
	mut p := load_test_pair('a')
	assert p.own
	mut sig := []u8{len: 256}
	for i in 0 .. 64 {
		hash := sha(i.str().bytes().hex())
		salt := sha((i + 1000).str().bytes().hex())
		assert C.viltrum_rsa_pss_sha256(&p.rsa, hash.data, salt.data, sig.data) == 0
		assert C.viltrum_test_pss_verify(&p.key, hash.data, sig.data) == 0
		// a different hash does not verify
		sig[10] ^= 1
		assert C.viltrum_test_pss_verify(&p.key, hash.data, sig.data) != 0
	}
}

// The handshake's pieces against RFC 8448's simple 1-RTT trace (section 3).
fn test_hs13_rfc8448_trace() {
	if !hs13_supported {
		return
	}
	ch := unhex(r8448_client_hello)
	mut h := C.viltrum_hs13_hello{}
	assert C.viltrum_hs13_parse(ch.data, u64(ch.len), &h) == 1
	assert unsafe { h.share[..] }.hex() == r8448_client_pub
	assert h.session_id_len == 0 && h.alpn == 0
	// the ServerHello, byte for byte, from the trace's random and key
	sh := unhex(r8448_server_hello)
	random := sh[6..38]
	mut out := []u8{len: 256}
	n := int(C.viltrum_hs13_server_hello(out.data, &h, random.data, unhex(r8448_server_pub).data))
	assert out[..n].hex() == r8448_server_hello
	// the key schedule
	mut c_hs := []u8{len: 32}
	mut s_hs := []u8{len: 32}
	mut master := []u8{len: 32}
	th := sha(r8448_client_hello, r8448_server_hello)
	assert C.viltrum_hs13_schedule(unhex(r8448_shared).data, th.data, c_hs.data, s_hs.data,
		master.data) == 0
	assert c_hs.hex() == r8448_c_hs
	assert s_hs.hex() == r8448_s_hs
	assert master.hex() == r8448_master
	mut key := []u8{len: 16}
	mut iv := []u8{len: 12}
	assert C.viltrum_hs13_traffic(s_hs.data, key.data, iv.data) == 0
	assert key.hex() == r8448_s_hs_key && iv.hex() == r8448_s_hs_iv
	assert C.viltrum_hs13_traffic(c_hs.data, key.data, iv.data) == 0
	assert key.hex() == r8448_c_hs_key && iv.hex() == r8448_c_hs_iv
	// both Finished messages and the application secrets
	mut fin := []u8{len: 32}
	th_cv := sha(r8448_client_hello, r8448_server_hello, r8448_ee, r8448_cert, r8448_cv)
	assert C.viltrum_hs13_finished_mac(s_hs.data, th_cv.data, fin.data) == 0
	assert fin.hex() == r8448_s_fin[8..]
	th_fin := sha(r8448_client_hello, r8448_server_hello, r8448_ee, r8448_cert, r8448_cv,
		r8448_s_fin)
	assert C.viltrum_hs13_finished_mac(c_hs.data, th_fin.data, fin.data) == 0
	assert fin.hex() == r8448_c_fin[8..]
	mut c_ap := []u8{len: 32}
	mut s_ap := []u8{len: 32}
	assert C.viltrum_hs13_app(master.data, th_fin.data, c_ap.data, s_ap.data) == 0
	assert c_ap.hex() == r8448_c_ap && s_ap.hex() == r8448_s_ap
}

// The whole flight on the trace's ClientHello, random and key: its ServerHello
// record is the trace's, and the client handshake key matches.
fn test_hs13_flight_on_rfc8448() {
	if !hs13_supported {
		return
	}
	mut p := load_test_pair('a')
	ch := unhex(r8448_client_hello)
	mut h := C.viltrum_hs13_hello{}
	assert C.viltrum_hs13_parse(ch.data, u64(ch.len), &h) == 1
	mut rnd := []u8{len: 96}
	for i in 0 .. 32 {
		rnd[i] = unhex(r8448_server_hello)[6 + i]
		rnd[32 + i] = unhex(r8448_server_priv)[i]
	}
	mut tx := C.viltrum_gcm_new()
	mut out := []u8{len: 8192}
	mut out_len := u64(0)
	mut keys := C.viltrum_hs13_keys{}
	assert C.viltrum_hs13_flight_with(rnd.data, ch.data, u64(ch.len), &h, p.cert_msg.data,
		u64(p.cert_msg.len), &p.rsa, tx, out.data, u64(out.len), &out_len, &keys) == 0
	assert out[..5].hex() == '160303005a'
	assert out[5..5 + 90].hex() == r8448_server_hello
	// no session ID in the hello, so no change_cipher_spec: the next record is protected
	assert out[95] == 23
	assert unsafe { keys.c_key[..] }.hex() == r8448_c_hs_key
	assert unsafe { keys.c_iv[..] }.hex() == r8448_c_hs_iv
	C.viltrum_gcm_wipe(tx)
}

// hello builds a ClientHello: a TLS 1.3 one hs13 serves, changed by the arguments.
@[params]
struct HelloOpts {
	versions  []u16 = [u16(0x0304), 0x0303]
	suites    []u16 = [u16(0x1301), 0x1302]
	groups    []u16 = [u16(0x001d), 0x0017]
	shares    []u16 = [u16(0x001d)]
	sigs      []u16 = [u16(0x0804), 0x0403]
	alpn      []string
	sid_len   int  = 32
	comp      []u8 = [u8(0)]
	legacy    u16  = 0x0303
	extra     [][]u8 // whole extensions (type and length included) appended at the end
	no_exts   bool
	dup_group bool
}

fn be16(mut b []u8, v int) {
	b << u8(v >> 8)
	b << u8(v)
}

fn ext(typ int, body []u8) []u8 {
	mut b := []u8{}
	be16(mut b, typ)
	be16(mut b, body.len)
	b << body
	return b
}

fn u16_list(len_bytes int, vals []u16) []u8 {
	mut b := []u8{}
	if len_bytes == 1 {
		b << u8(vals.len * 2)
	} else {
		be16(mut b, vals.len * 2)
	}
	for v in vals {
		be16(mut b, v)
	}
	return b
}

fn hello(o HelloOpts) []u8 {
	mut body := []u8{}
	be16(mut body, o.legacy)
	for i in 0 .. 32 {
		body << u8(i)
	}
	body << u8(o.sid_len)
	for i in 0 .. o.sid_len {
		body << u8(0xa0 + i)
	}
	body << u16_list(2, o.suites)
	body << u8(o.comp.len)
	body << o.comp
	if !o.no_exts {
		mut exts := []u8{}
		exts << ext(43, u16_list(1, o.versions))
		exts << ext(10, u16_list(2, o.groups))
		mut ks := []u8{}
		for g in o.shares {
			be16(mut ks, g)
			klen := if g == 0x001d { 32 } else { 65 }
			be16(mut ks, klen)
			for i in 0 .. klen {
				ks << u8(i + 1)
			}
		}
		mut ksb := []u8{}
		be16(mut ksb, ks.len)
		ksb << ks
		exts << ext(51, ksb)
		exts << ext(13, u16_list(2, o.sigs))
		if o.alpn.len > 0 {
			mut l := []u8{}
			for a in o.alpn {
				l << u8(a.len)
				l << a.bytes()
			}
			mut ab := []u8{}
			be16(mut ab, l.len)
			ab << l
			exts << ext(16, ab)
		}
		if o.dup_group {
			exts << ext(10, u16_list(2, o.groups))
		}
		for e in o.extra {
			exts << e
		}
		be16(mut body, exts.len)
		body << exts
	}
	mut msg := [u8(1), u8(body.len >> 16), u8(body.len >> 8), u8(body.len)]
	msg << body
	return msg
}

fn parse(m []u8) int {
	mut h := C.viltrum_hs13_hello{}
	return C.viltrum_hs13_parse(m.data, u64(m.len), &h)
}

// alpn_chosen is what ALPN chooses for m on a listener that speaks h2 or not, or -1
// when hs13 does not serve m.
fn alpn_chosen(m []u8, h2 bool) int {
	mut h := C.viltrum_hs13_hello{}
	h.h2 = if h2 { 1 } else { 0 }
	if C.viltrum_hs13_parse(m.data, u64(m.len), &h) != 1 {
		return -1
	}
	return h.alpn
}

fn test_hs13_alpn_choice() {
	assert alpn_chosen(hello(), true) == 0
	assert alpn_chosen(hello(alpn: ['h2', 'http/1.1']), true) == 2
	assert alpn_chosen(hello(alpn: ['http/1.1', 'h2']), true) == 2 // our preference, not the client's
	assert alpn_chosen(hello(alpn: ['h2', 'http/1.1']), false) == 1
	assert alpn_chosen(hello(alpn: ['http/1.1']), true) == 1
	assert alpn_chosen(hello(alpn: ['h2']), true) == 2
	assert alpn_chosen(hello(alpn: ['h2']), false) == -1 // mbedtls' to answer
	assert alpn_chosen(hello(alpn: ['h3', 'spdy/3']), true) == -1
}

// Which ClientHellos hs13 serves (1), leaves to mbedtls (0) or refuses (-1).
// The parser is plain C: it runs in every build, tcc's included.
fn test_hs13_parse_decisions() {
	assert parse(hello()) == 1
	assert parse(hello(sid_len: 0)) == 1
	assert parse(hello(alpn: ['h2', 'http/1.1'])) == 1
	// mbedtls' to serve
	assert parse(hello(versions: [u16(0x0303)])) == 0 // TLS 1.2
	assert parse(hello(no_exts: true)) == 0
	assert parse(hello(shares: [u16(0x0017)])) == 0 // P-256 share only: would need an HRR
	assert parse(hello(suites: [u16(0x1302), 0x1303])) == 0
	assert parse(hello(sigs: [u16(0x0805), 0x0403])) == 0
	assert parse(hello(alpn: ['h2'])) == 0
	assert parse(hello(extra: [ext(42, []u8{})])) == 0 // early_data
	assert parse(hello(extra: [ext(44, [u8(0), 1, 7])])) == 0 // cookie
	// refused
	assert parse(hello(dup_group: true)) == -1
	assert parse(hello(comp: [u8(1), 0])) == -1
	assert parse(hello(legacy: 0x0301)) == -1
	// malformed before it offers TLS 1.3: mbedtls judges it, as before hs13
	assert parse(hello(sid_len: 33)) == 0
	assert parse(hello(extra: [ext(41, [u8(0), 0, 0, 0]), ext(0x1234, []u8{})])) == -1 // pre_shared_key not last
	assert parse(hello(extra: [ext(0x1234, []u8{}), ext(41, [u8(0), 0, 0, 0])])) == 1 // last: ignored
	// no truncation of a good hello is served, the header's length kept or fixed up
	good := hello(alpn: ['http/1.1'])
	for cut in 0 .. good.len {
		assert parse(good[..cut]) != 1, 'cut at ${cut}'
	}
	for cut in 4 .. good.len {
		mut m := good[..cut].clone()
		n := cut - 4
		m[1] = u8(n >> 16)
		m[2] = u8(n >> 8)
		m[3] = u8(n)
		assert parse(m) != 1, 'cut at ${cut}'
	}
}

// Mutated ClientHellos never crash the parser, and whatever it serves has a full
// X25519 share. CI runs this with VILTRUM_FUZZ_ITERS=500000.
fn test_hs13_parse_fuzz() {
	iters := os.getenv_opt('VILTRUM_FUZZ_ITERS') or { '20000' }.int()
	rand.seed([u32(0x5eed), 0x13])
	seeds := [hello(), hello(sid_len: 0, alpn: ['h2', 'http/1.1']),
		hello(shares: [u16(0x0017), 0x001d], extra: [ext(41, [u8(0), 0, 0, 0])]),
		unhex(r8448_client_hello)]
	mut served := 0
	for _ in 0 .. iters {
		mut b := seeds[rand.intn(seeds.len) or { 0 }].clone()
		for _ in 0 .. 1 + (rand.intn(4) or { 0 }) {
			pos := if b.len == 0 { 0 } else { rand.intn(b.len) or { 0 } }
			op := rand.intn(5) or { 0 }
			match op {
				0 {
					if b.len > 0 {
						b[pos] ^= u8(1) << u8(rand.intn(8) or { 0 })
					}
				}
				1 {
					if b.len > 0 {
						b[pos] = u8(rand.intn(256) or { 0 })
					}
				}
				2 {
					b = b[..pos].clone()
				}
				3 {
					b.insert(pos, u8(rand.intn(256) or { 0 }))
				}
				else {
					if b.len >= 4 {
						n := b.len - 4
						b[1] = u8(n >> 16)
						b[2] = u8(n >> 8)
						b[3] = u8(n)
					}
				}
			}
		}
		mut h := C.viltrum_hs13_hello{}
		r := C.viltrum_hs13_parse(b.data, u64(b.len), &h)
		assert r >= -1 && r <= 1
		if r == 1 {
			served++
			assert h.session_id_len <= 32
		}
	}
	assert iters == 0 || served > 0
}

// RFC 8448 section 3, the simple 1-RTT handshake
const r8448_client_pub = '99381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c'
const r8448_client_hello = '010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef6283024dece7000006130113031302010000910000000b0009000006736572766572ff01000100000a00140012001d0017001800190100010101020103010400230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603020308040805080604010501060102010402050206020202002d00020101001c00024001'
const r8448_server_priv = 'b1580eeadf6dd589b8ef4f2d5652578cc810e9980191ec8d058308cea216a21e'
const r8448_server_pub = 'c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f'
const r8448_server_hello = '020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304'
const r8448_shared = '8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d'
const r8448_c_hs = 'b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21'
const r8448_s_hs = 'b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38'
const r8448_master = '18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919'
const r8448_s_hs_key = '3fce516009c21727d0f2e4e86ee403bc'
const r8448_s_hs_iv = '5d313eb2671276ee13000b30'
const r8448_c_hs_key = 'dbfaa693d1762c5b666af5d950258d01'
const r8448_c_hs_iv = '5bd3c71b836e0b76bb73265f'
const r8448_ee = '080000240022000a00140012001d00170018001901000101010201030104001c0002400100000000'
const r8448_cert = '0b0001b9000001b50001b0308201ac30820115a003020102020102300d06092a864886f70d01010b0500300e310c300a06035504031303727361301e170d3136303733303031323335395a170d3236303733303031323335395a300e310c300a0603550403130372736130819f300d06092a864886f70d010101050003818d0030818902818100b4bb498f8279303d980836399b36c6988c0c68de55e1bdb826d3901a2461eafd2de49a91d015abbc9a95137ace6c1af19eaa6af98c7ced43120998e187a80ee0ccb0524b1b018c3e0b63264d449a6d38e22a5fda430846748030530ef0461c8ca9d9efbfae8ea6d1d03e2bd193eff0ab9a8002c47428a6d35a8d88d79f7f1e3f0203010001a31a301830090603551d1304023000300b0603551d0f0404030205a0300d06092a864886f70d01010b05000381810085aad2a0e5b9276b908c65f73a7267170618a54c5f8a7b337d2df7a594365417f2eae8f8a58c8f8172f9319cf36b7fd6c55b80f21a03015156726096fd335e5e67f2dbf102702e608ccae6bec1fc63a42a99be5c3eb7107c3c54e9b9eb2bd5203b1c3b84e0a8b2f759409ba3eac9d91d402dcc0cc8f8961229ac9187b42b4de10000'
const r8448_cv = '0f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145ab3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248eeaaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea20d53dfacd42f74f3'
const r8448_s_fin = '140000209b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718'
const r8448_c_ap = '9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5'
const r8448_s_ap = 'a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643'
const r8448_c_fin = '14000020a8ec436d677634ae525ac1fcebe11a039ec17694fac6e98527b642f2edd5ce61'
const r8448_client_priv = '49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005'
