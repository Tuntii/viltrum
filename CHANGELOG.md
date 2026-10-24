# Changelog

## [1.9.0](https://github.com/Tuntii/viltrum/compare/v1.8.0...v1.9.0) (2026-10-24)

### Features

* **engine:** HTTP/2 over TLS, chosen by ALPN on both handshake paths ([1772850](https://github.com/Tuntii/viltrum/commit/1772850ac84486180aeed558d064af32ac7db30e))

## [1.8.0](https://github.com/Tuntii/viltrum/compare/v1.7.0...v1.8.0) (2026-10-24)

### Features

* **engine:** HTTP/2 cleartext (h2c) beside HTTP/1.1 on the same listener ([727fe60](https://github.com/Tuntii/viltrum/commit/727fe60502c50459c08b964294f97756d84efe52))
* **http2:** HPACK header compression, the first piece of HTTP/2 ([5cfed6b](https://github.com/Tuntii/viltrum/commit/5cfed6b0138455be1a3cf2f9b573f073861d17bb))

### Bug Fixes

* **engine:** the buffer shrink limits live in shared code, for the HTTP/2 path off Linux ([0621105](https://github.com/Tuntii/viltrum/commit/062110594eb17d89ae5c5b766270bed8e1799c0d))

## [1.7.0](https://github.com/Tuntii/viltrum/compare/v1.6.1...v1.7.0) (2026-10-24)

### Features

* **engine:** viltrum's own TLS 1.3 handshake for X25519 and RSA certificates ([26e0977](https://github.com/Tuntii/viltrum/commit/26e09772f1b55cb869715ed4ce54039a13da3a41))
* **engine:** X25519 and RSA-PSS signing in C, for the TLS 1.3 handshake ([f644282](https://github.com/Tuntii/viltrum/commit/f644282b1d6e8eaf968fc6f4c0735ade424c00c3))

### Performance Improvements

* **engine:** one TLS handshake per turn of the loop, requests served between ([4df30e0](https://github.com/Tuntii/viltrum/commit/4df30e0355123b3a066281b000bf0ba7907680bf))

## [1.6.1](https://github.com/Tuntii/viltrum/compare/v1.6.0...v1.6.1) (2026-10-24)

### Bug Fixes

* **engine:** empty lines before a request, port 0, and listener setup failures ([c0b30cb](https://github.com/Tuntii/viltrum/commit/c0b30cb157967c9736d56622868338c05f8b6d72))
* **middleware:** logger status for unanswered requests, tab after a gzip q-value ([0096314](https://github.com/Tuntii/viltrum/commit/0096314594cbb44b6be73b3906db981086e3b9e3))
* **router:** refuse a second route with the same method and shape ([d8ac38e](https://github.com/Tuntii/viltrum/commit/d8ac38e703c01d7007b1e3ab91277f39ac9f1c4f))

## [1.6.0](https://github.com/Tuntii/viltrum/compare/v1.5.1...v1.6.0) (2026-10-24)

### Features

* request helpers without a cost on the hot path ([49e67d5](https://github.com/Tuntii/viltrum/commit/49e67d56dcc88407f185bd63bcc70d6cf8e48c82))

## [1.5.1](https://github.com/Tuntii/viltrum/compare/v1.5.0...v1.5.1) (2026-10-24)

### Performance Improvements

* **engine:** wake deferred responses on time, not on the next millisecond ([e9e2749](https://github.com/Tuntii/viltrum/commit/e9e2749b18a590506cd3f6dbe54e5ebd90d66bb8))

## [1.5.0](https://github.com/Tuntii/viltrum/compare/v1.4.0...v1.5.0) (2026-10-23)

### Features

* forms and uploads on the 1.x core (form_value, form_file, form_parts) ([72fe4e3](https://github.com/Tuntii/viltrum/commit/72fe4e36005534d3740ebccde44b1289fc31db64))

### Bug Fixes

* **engine:** handle_raw never answers a deferred response early ([221a6f9](https://github.com/Tuntii/viltrum/commit/221a6f9d27bfc25f43395d759ce7aa83923a609a))
* **engine:** lingering close, 413 at the read cap, EINTR on recv/send ([7fae422](https://github.com/Tuntii/viltrum/commit/7fae4229192be53c228d9bc57d179954e6fb9301))

## [1.4.0](https://github.com/Tuntii/viltrum/compare/v1.3.2...v1.4.0) (2026-10-23)

### Features

* static files on the 1.x core (static_files, c.file) ([d17aa55](https://github.com/Tuntii/viltrum/commit/d17aa55cee94a495d654c1638d812ef267a449b4))

### Bug Fixes

* **static:** report directories without opening them (Windows cannot) ([ccfbbfd](https://github.com/Tuntii/viltrum/commit/ccfbbfdd5b68912e698621fd701b627f2be34466))

## [1.3.2](https://github.com/Tuntii/viltrum/compare/v1.3.1...v1.3.2) (2026-10-22)

### Performance Improvements

* **engine:** TLS 1.3 AES-GCM records on AES-NI and PCLMUL ([d46b538](https://github.com/Tuntii/viltrum/commit/d46b538ff7821aac142e31f49d034bfd6b8e3679))

## [1.3.1](https://github.com/Tuntii/viltrum/compare/v1.3.0...v1.3.1) (2026-10-22)

### Performance Improvements

* **http1:** faster json-comp path: Huffman, CRC, match search, JSON ([ae25eb2](https://github.com/Tuntii/viltrum/commit/ae25eb2d5aa80cc875ecdcf38b8c33253e5080a7))
* **http1:** one pass for framing fields, one copy pass for responses ([050d202](https://github.com/Tuntii/viltrum/commit/050d20209c2e4fb689f6dde6ffe726e1411c7c90))

## [1.3.0](https://github.com/Tuntii/viltrum/compare/v1.2.2...v1.3.0) (2026-10-22)

### Features

* **engine:** WebSocket on the 1.x core ([5364c0b](https://github.com/Tuntii/viltrum/commit/5364c0bd41ff002241af0240e3a3a98ced5a3260))
* **engine:** WebSocket topics and sends from any thread ([9983543](https://github.com/Tuntii/viltrum/commit/998354333e42028dd616d8468d7a31ee4065210c))

## [1.2.2](https://github.com/Tuntii/viltrum/compare/v1.2.1...v1.2.2) (2026-10-21)

### Performance Improvements

* **http1:** gzip on viltrum's own DEFLATE encoder instead of miniz ([e970b7c](https://github.com/Tuntii/viltrum/commit/e970b7ca3b68a3be0197181614961fb976f86ce2))

## [1.2.1](https://github.com/Tuntii/viltrum/compare/v1.2.0...v1.2.1) (2026-10-21)

### Performance Improvements

* **jsonenc:** append in place behind one capacity check ([cdb0328](https://github.com/Tuntii/viltrum/commit/cdb0328655685e37a8cfd95e7be16629aeee414f))

## [1.2.0](https://github.com/Tuntii/viltrum/compare/v1.1.0...v1.2.0) (2026-10-21)

### Features

* **engine:** TLS listeners on the epoll workers ([144eb5a](https://github.com/Tuntii/viltrum/commit/144eb5ac79b219a8ad7885a1784bf22e4d494017))

### Performance Improvements

* **engine:** read ahead under TLS sessions ([c768622](https://github.com/Tuntii/viltrum/commit/c76862219a7e40b85f5029a8e37875982b90ea14))

## [1.1.0](https://github.com/Tuntii/viltrum/compare/v1.0.3...v1.1.0) (2026-10-19)

### Features

* **engine:** deferred responses with Ctx.after, answered from per-worker timers ([b6f1967](https://github.com/Tuntii/viltrum/commit/b6f1967d290c62d1f4135358fc976979071c6481))

### Bug Fixes

* **engine:** take a connection's timer generation from its worker ([8a42b86](https://github.com/Tuntii/viltrum/commit/8a42b867e5249ec0c428aa91e8721915cab13b26))

## [1.0.3](https://github.com/Tuntii/viltrum/compare/v1.0.2...v1.0.3) (2026-10-19)

### Bug Fixes

* **engine:** pool closed connections per worker instead of keeping one per fd ([8a6d52c](https://github.com/Tuntii/viltrum/commit/8a6d52c18141bce0d4e67e97841c7b82f108521d))

## [1.0.2](https://github.com/Tuntii/viltrum/compare/v1.0.1...v1.0.2) (2026-10-17)

### Bug Fixes

* **test:** fix parser fuzz double-eval crash and add non-Linux engine stubs ([4bb5d65](https://github.com/Tuntii/viltrum/commit/4bb5d659767de86095425d0a976d38ed764cf59d))

## [1.0.1](https://github.com/Tuntii/viltrum/compare/v1.0.0...v1.0.1) (2026-10-15)

### Performance Improvements

* **jsonenc,engine:** keep V's per-call GC scope pins off the hot path ([696ffbd](https://github.com/Tuntii/viltrum/commit/696ffbdb8c5964f24259c7987ea761f4d317f6a7))

## [1.0.0](https://github.com/Tuntii/viltrum/compare/v0.13.1...v1.0.0) (2026-10-15)

### ⚠ BREAKING CHANGES

* fn (req Request) Response handlers, HeaderMap and the
TLS, WebSocket, static, form and client features of 0.13 are gone in
1.0; see the README for what returns later.
* strip the tree to the v1 core scope

### Features

* **engine:** per-core epoll workers with SO_REUSEPORT, backpressure and timeouts ([6e24eef](https://github.com/Tuntii/viltrum/commit/6e24eef3cb4232f573e3518b2394e92b56aad824))
* **engine:** socket-free request processing with a zero-allocation gate ([cffaf7f](https://github.com/Tuntii/viltrum/commit/cffaf7ff40df70a2e86d561f847a4345cd63d7f3))
* **http1:** allocation-free byte helpers and GC probe ([1cf8cb0](https://github.com/Tuntii/viltrum/commit/1cf8cb068c51e154223bfa78704e11175233d959))
* **http1:** Ctx with request views, buffered response writer and chain ([9b829b4](https://github.com/Tuntii/viltrum/commit/9b829b4539cd08798cd306b395d94a3d85da60cf))
* **http1:** gzip middleware on miniz with per-worker compressor state ([d503fba](https://github.com/Tuntii/viltrum/commit/d503fbab1b49e6755bf43d287c7be4c7cfc1d6f1))
* **http1:** response writer primitives and a per-second Date cache ([f856b83](https://github.com/Tuntii/viltrum/commit/f856b832b2617be83220507ab26836c7f0750c3a))
* **http1:** resumable Content-Length and chunked framing ([c1ed846](https://github.com/Tuntii/viltrum/commit/c1ed846c84a4add334312b4972236d220187fae7))
* **http1:** span-based request head parser with the v0.13 strictness ([a63e4be](https://github.com/Tuntii/viltrum/commit/a63e4be0dd7ab538dc1dab15b7e29011bfc60106))
* **jsonenc:** compile-time JSON encoder that writes into a buffer ([c3a9878](https://github.com/Tuntii/viltrum/commit/c3a98787c1de26ded7066c116a02351326bd4eca))
* **router:** compiled router with allocation-free matching ([909fec8](https://github.com/Tuntii/viltrum/commit/909fec85baa27e512b85208a976cd17714317f95))
* viltrum 1.0 App API on the zero-allocation core ([386d1cb](https://github.com/Tuntii/viltrum/commit/386d1cbd23f6ecb4115dbd9c4202361bbf2d775b))

### Bug Fixes

* **engine:** fail serve on epoll setup errors, no 100 Continue for HTTP/1.0 ([35a47b5](https://github.com/Tuntii/viltrum/commit/35a47b5f0be6b263882f72a778db828582a46ed2))
* **engine:** per-request read deadlines, failing timeout tests, no accept spin on EMFILE ([fdf7475](https://github.com/Tuntii/viltrum/commit/fdf7475b20bbde0e08b0bf4fc5bc964627b4cf86))
* **http1:** drop header names/values that would split the response ([153e666](https://github.com/Tuntii/viltrum/commit/153e666105002c0e23613cdabf3e5d92f69440ba))
* **http1:** enforce the chunk line limit on complete lines ([4a070ee](https://github.com/Tuntii/viltrum/commit/4a070eec4a836fc574ada2e8d0d578ccf8aa78e0))
* **jsonenc:** shortest round-trip float output ([c19aaea](https://github.com/Tuntii/viltrum/commit/c19aaead5f9717405777520f942b47d630a262ee))
* **router:** static routes win over dynamic ones for every path spelling ([b4ee622](https://github.com/Tuntii/viltrum/commit/b4ee622cdad52793af0b54c56a8f60f2a4499049))

### Code Refactoring

* strip the tree to the v1 core scope ([a8e9188](https://github.com/Tuntii/viltrum/commit/a8e91883069702b35b6c17dd9d6911cfad8eba03))

## [0.13.1](https://github.com/Tuntii/viltrum/compare/v0.13.0...v0.13.1) (2026-10-14)

### Performance Improvements

* gzip middleware on miniz instead of compress.gzip ([b7c083b](https://github.com/Tuntii/viltrum/commit/b7c083b4d36065d27c26f77a4f0a06cd6799e1de))

## [0.13.0](https://github.com/Tuntii/viltrum/compare/v0.12.3...v0.13.0) (2026-10-13)

### Features

* gzip response middleware ([0077f8a](https://github.com/Tuntii/viltrum/commit/0077f8abed2e534575b66dfcba92a164761efb4d))
* **http:** accept chunked request bodies ([251ad3c](https://github.com/Tuntii/viltrum/commit/251ad3c52ecb00a4cfc096cf6e74d96b105e53c8))

## [0.12.3](https://github.com/Tuntii/viltrum/compare/v0.12.2...v0.12.3) (2026-10-13)

### Bug Fixes

* **engine:** build on newer V compilers ([e517557](https://github.com/Tuntii/viltrum/commit/e51755789bac344b2e14ef295c51eb280d473077))
* **engine:** raise listen backlog to 4096 ([a0f4fae](https://github.com/Tuntii/viltrum/commit/a0f4faea0e5db0344573633917d76022f5ec466c))

### Performance Improvements

* **engine:** batch pipelined responses into one write ([5fe5846](https://github.com/Tuntii/viltrum/commit/5fe58469d37f50b3533d20b974d536ddce7a9ccd))
* **engine:** no allocation for non-matching upgrade routes ([33d7214](https://github.com/Tuntii/viltrum/commit/33d721417d5a8d6e9342c772f03217fa8d0aabae))
* **engine:** skip the EAGAIN recv after a short epoll read ([47f58f0](https://github.com/Tuntii/viltrum/commit/47f58f006cd487779005bbb1acdbf3fc0478f26c))
* **http:** build Date header directly, push_many in serializer ([6442ff8](https://github.com/Tuntii/viltrum/commit/6442ff8b46495e8991fd59cb431238763a53b833))
* **http:** keep headers as a field list instead of a map ([9bc9e1d](https://github.com/Tuntii/viltrum/commit/9bc9e1d74b64aa903b911a08ea583c2ddf34e70e))
* **router:** match static routes without splitting the path ([1bd3a92](https://github.com/Tuntii/viltrum/commit/1bd3a928db6bf52fc0c9e113cdc13b2b673b58ec))

## [0.12.2](https://github.com/Tuntii/viltrum/compare/v0.12.1...v0.12.2) (2026-10-12)

### Bug Fixes

* **http:** reject ambiguous framing; fix multipart panic on non-ASCII content-type ([ad9e396](https://github.com/Tuntii/viltrum/commit/ad9e396d8c14295c9e453b91e6d01ad1c312d7a1))

## [0.12.1](https://github.com/Tuntii/viltrum/compare/v0.12.0...v0.12.1) (2026-09-25)

### Bug Fixes

* **engine:** count requests with stdatomic.add_u64 for the V 0.5.2 release compiler ([9e52fdd](https://github.com/Tuntii/viltrum/commit/9e52fddb30a3e7fc7112d80fbb5d9f6319eb909f))

## [0.12.0](https://github.com/Tuntii/viltrum/compare/v0.11.0...v0.12.0) (2026-09-25)

### Features

* **engine:** default I/O stays spawn; E/F medians spawn+recover 243532/207436, bare 226385/208933, epoll_cores=16+recover 244358/261497, bare 245334/264815 (E +0.3%, under +15%) ([77abd55](https://github.com/Tuntii/viltrum/commit/77abd552a9e55f4008daf9cf94045701f6b97d17))

## [0.11.0](https://github.com/Tuntii/viltrum/compare/v0.10.0...v0.11.0) (2026-09-05)

### Features

* **engine:** ConnStats.requests; skip drain/stats on epoll ([1ee3985](https://github.com/Tuntii/viltrum/commit/1ee398511521ffb00f0edb2c95750a36fd726296)), closes [#50](https://github.com/Tuntii/viltrum/issues/50) [#46](https://github.com/Tuntii/viltrum/issues/46)
* **http:** fetch_tls, Host polish, json_i64, multipart binary tests ([349faca](https://github.com/Tuntii/viltrum/commit/349facad679af295f95243aef599c024c87ab936)), closes [#42](https://github.com/Tuntii/viltrum/issues/42) [#43](https://github.com/Tuntii/viltrum/issues/43) [#44](https://github.com/Tuntii/viltrum/issues/44) [#49](https://github.com/Tuntii/viltrum/issues/49)

## [0.10.0](https://github.com/Tuntii/viltrum/compare/v0.9.0...v0.10.0) (2026-09-05)

### Features

* **http:** multipart part limits and safe_filename ([#38](https://github.com/Tuntii/viltrum/issues/38)) ([24e86c2](https://github.com/Tuntii/viltrum/commit/24e86c2cef3df5e4aafde08e9a70fb652ff17305))

### Bug Fixes

* **tls:** drop misleading swap retry; reject NUL in safe_filename ([700b310](https://github.com/Tuntii/viltrum/commit/700b3107d279d5f42b269a88d4d03e363023e4e0))
* **tls:** failed SIGHUP reload keeps the old cert ([#39](https://github.com/Tuntii/viltrum/issues/39)) ([4ddf683](https://github.com/Tuntii/viltrum/commit/4ddf683ebe9da54a1748e6cf4463fb4db47d6a9c)), closes [#40](https://github.com/Tuntii/viltrum/issues/40) [#41](https://github.com/Tuntii/viltrum/issues/41)
* **tls:** retry rebind after drop so a failed swap cannot exit ([bec528a](https://github.com/Tuntii/viltrum/commit/bec528ac3cabe4fd50b830212001ef2db7e6ed9a))

## [0.9.0](https://github.com/Tuntii/viltrum/compare/v0.8.1...v0.9.0) (2026-08-12)

### Features

* form/multipart, extra JSON helpers, cleartext client, TLS SIGHUP reload ([edcdb4a](https://github.com/Tuntii/viltrum/commit/edcdb4a8e458087fc1d8bd4e52c544f24698f8af))

## [0.8.1](https://github.com/Tuntii/viltrum/compare/v0.8.0...v0.8.1) (2026-08-11)

## [0.8.0](https://github.com/Tuntii/viltrum/compare/v0.7.9...v0.8.0) (2026-08-11)

### Features

* **engine:** graceful drain timeout and ConnStats ops hooks ([c8e77d1](https://github.com/Tuntii/viltrum/commit/c8e77d1860b44288f2e5aa358ce6b494e6b00190))

## [0.7.9](https://github.com/Tuntii/viltrum/compare/v0.7.8...v0.7.9) (2026-08-05)

### Performance Improvements

* **http:** experimental Linux epoll reactor (opt-in, default off) ([79adb02](https://github.com/Tuntii/viltrum/commit/79adb02f41e8c375f4934a279e514d146ad9916e))

## [0.7.8](https://github.com/Tuntii/viltrum/compare/v0.7.7...v0.7.8) (2026-08-05)

### Performance Improvements

* **http:** HeaderMap lowered hot path without extra to_lower ([ada4acb](https://github.com/Tuntii/viltrum/commit/ada4acb5d2ac3bed9a4a293df394ac051a631d20))

## [0.7.7](https://github.com/Tuntii/viltrum/compare/v0.7.6...v0.7.7) (2026-08-05)

### Performance Improvements

* **http:** experimental conn_workers pool (blocking) + A/B note ([50b5d4a](https://github.com/Tuntii/viltrum/commit/50b5d4a5139e278345ca263fdfbf7c9b3565042c))

## [0.7.6](https://github.com/Tuntii/viltrum/compare/v0.7.5...v0.7.6) (2026-08-04)

### Performance Improvements

* **http:** PR6 SO_REUSEPORT multi-listener experiment ([#22](https://github.com/Tuntii/viltrum/issues/22)) ([63e516d](https://github.com/Tuntii/viltrum/commit/63e516d8583d388e2204ac6056d8b1d1679c8d01)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)

## [0.7.5](https://github.com/Tuntii/viltrum/compare/v0.7.4...v0.7.5) (2026-08-04)

### Performance Improvements

* **http:** PR5 conn-local assembly and write buffer reuse ([#21](https://github.com/Tuntii/viltrum/issues/21)) ([bf4b78c](https://github.com/Tuntii/viltrum/commit/bf4b78c1b4204a5de523adb0d44cee3705867253)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)

## [0.7.4](https://github.com/Tuntii/viltrum/compare/v0.7.3...v0.7.4) (2026-08-04)

### Performance Improvements

* **http:** PR4 response []u8 builder and header casing cache ([#20](https://github.com/Tuntii/viltrum/issues/20)) ([32a3284](https://github.com/Tuntii/viltrum/commit/32a32845dce657fe64a42190f5de750df070a0ae)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)

## [0.7.3](https://github.com/Tuntii/viltrum/compare/v0.7.2...v0.7.3) (2026-08-04)

### Performance Improvements

* **http:** PR3 single message ownership, no double body clone ([#19](https://github.com/Tuntii/viltrum/issues/19)) ([39b7d14](https://github.com/Tuntii/viltrum/commit/39b7d14ccdf1764a7b55c30a88d1b2b54e03afdf)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)

## [0.7.2](https://github.com/Tuntii/viltrum/compare/v0.7.1...v0.7.2) (2026-07-29)

### Performance Improvements

* **http:** polish PR2 parse_request helpers and edge tests ([#18](https://github.com/Tuntii/viltrum/issues/18)) ([d66e238](https://github.com/Tuntii/viltrum/commit/d66e238e06731ce149b3fc424d7bad215fdfe648))
* **http:** PR2 parse_request byte walk without full bytestr ([#18](https://github.com/Tuntii/viltrum/issues/18)) ([6eef34c](https://github.com/Tuntii/viltrum/commit/6eef34c6db377663d5d1c8b40098203f51c86973))

## [0.7.1](https://github.com/Tuntii/viltrum/compare/v0.7.0...v0.7.1) (2026-07-28)

### Performance Improvements

* **http:** PR1 Axum compare harness and hot-path epic baseline ([#17](https://github.com/Tuntii/viltrum/issues/17)) ([227ae9a](https://github.com/Tuntii/viltrum/commit/227ae9af805b7bc8eca31a8e12b607d6bf33c7ec)), closes [#16](https://github.com/Tuntii/viltrum/issues/16)
* **http:** PR1 baseline harness without design doc share ([#17](https://github.com/Tuntii/viltrum/issues/17)) ([fec76eb](https://github.com/Tuntii/viltrum/commit/fec76ebf4043adec7406eb457b01d0310ec54d1f))

## [0.7.0](https://github.com/Tuntii/viltrum/compare/v0.6.1...v0.7.0) (2026-07-28)

### Features

* **tls:** in-process HTTPS and WSS via mbedtls ([#1](https://github.com/Tuntii/viltrum/issues/1)) ([00ab6c0](https://github.com/Tuntii/viltrum/commit/00ab6c0899c14671f31045a839d14ec34ac7648a))

## [0.6.1](https://github.com/Tuntii/viltrum/compare/v0.6.0...v0.6.1) (2026-07-23)

### Performance Improvements

* **http:** reuse read scratch and cheaper CL/TE scan ([#9](https://github.com/Tuntii/viltrum/issues/9)) ([34c2a13](https://github.com/Tuntii/viltrum/commit/34c2a134652a68e58a5f33ad53146974dbd3184d))

## [0.6.0](https://github.com/Tuntii/viltrum/compare/v0.5.2...v0.6.0) (2026-07-23)

### Features

* **bench:** first-party V WS load client and CI soak ([fc9f626](https://github.com/Tuntii/viltrum/commit/fc9f6269d3febe6523caa59d3708d27944d74582))

## [0.5.2](https://github.com/Tuntii/viltrum/compare/v0.5.1...v0.5.2) (2026-07-23)

### Bug Fixes

* **ws:** idle timeouts, UTF-8 opt-in, soak harness, Conn ref ([356a5eb](https://github.com/Tuntii/viltrum/commit/356a5ebb561824ea8b154d1cded4a6c094a11139)), closes [#4](https://github.com/Tuntii/viltrum/issues/4) [#8](https://github.com/Tuntii/viltrum/issues/8) [#5](https://github.com/Tuntii/viltrum/issues/5) [#6](https://github.com/Tuntii/viltrum/issues/6)

## [0.5.1](https://github.com/Tuntii/viltrum/compare/v0.5.0...v0.5.1) (2026-07-19)

### Bug Fixes

* keep accept loop alive when handle_signals is on ([2a3b3dc](https://github.com/Tuntii/viltrum/commit/2a3b3dc6af30a9a4a532cea1704e96b4d00f5745)), closes [#11](https://github.com/Tuntii/viltrum/issues/11)

From **v0.6.0** onward, entries are produced by [semantic-release](docs/releasing.md) from conventional commits on `main`. Earlier versions were written by hand.

## Unreleased (0.5.x)

### Hardening

- After `app.upgrade` / `app.ws`, Conn read deadline is `max(read_timeout, idle_timeout)` so quiet long-lived streams survive past the short HTTP request timeout (#4)
- Opt-in UTF-8 validation on text frames: `WsOptions{ validate_utf8: true }` closes with **1007** on invalid sequences; default remains off for compat (#8)
- Soak / close-storm harness: `bash benches/soak_ws.sh` (multi-conn echo + rapid open/close; optional `SOAK_SECONDS`) (#5)
- **Fix:** `WsSocket` holds `Conn` by reference (was a copy). Closing the socket then returning to the engine double-closed the TCP fd and raced new accepts under close-storm load
- Soak health check no longer requires `curl` (python sockets); CI runs a short soak + builds the V load client

### Performance

- WS server write path reuses an internal encode scratch buffer (`encode_server_into`) — public `write_text` / `write_binary` / `write_message` unchanged (#6)
- First-party V WS load client: `benches/ws_load_client.v`; `run_ws.sh` defaults to it (`CLIENT=python` keeps optional smoke) (#7)
- WS headline re-baseline (V client): multi-conn aggregate ~**30–40k msg/s** on developer laptop (method noted in `benches/RESULTS.md`)
- HTTP accept/read/write profile note (`benches/HTTP_PROFILE.md`) plus two micro-opts (#9): reuse `read_message` scratch `tmp` across keep-alive requests; engine Content-Length / Transfer-Encoding pre-scan is a byte-level field walk (no full-header `bytestr`+`split`+`to_lower`). No public API change; `RESULTS.md` unchanged (no oha re-run; expected win below the ~10% material bar without measurement)

## 0.5.0 — 2026-07-19

### WebSocket (`ws://`) — first-party engine

- New module `viltrum.ws`: RFC 6455 server framing on `engine.Conn` (not a third-party wrapper)
- `app.ws(pattern, handler)` / `app.ws_opts(pattern, opts, handler)` — handshake + `WsSocket` loop
- Handshake: `Upgrade: websocket`, version 13, `Sec-WebSocket-Accept` (RFC golden vector tested)
- Frames: text, binary, close, ping, pong; client mask required; server unmasked
- Fragmented data rejected (close 1002); message/frame size limits (default 1 MiB)
- Auto-pong (default on); optional `subprotocol` echo; optional `check_origin`
- Example: `examples/ws_echo` · Docs: `docs/ws.md`
- Tests: `v test ws/`

North star: performance and ergonomics stay non-negotiable; WS sits on the same Conn story as HTTP upgrade. `wss://` is v0.6.

## 0.4.0 — 2026-07-19

### Engine / upgrade

- `engine.Conn`: read/write/close/deadlines + pushback buffer for post-message bytes
- `Conn.peer_ip` for upgrade/logging
- `app.upgrade(method, pattern, handler)` — single hijack path; HTTP loop stops for that conn
- `viltrum.switching_protocols` / `Response.switching_protocols` for bare 101 responses
- `ServerOptions.max_conns` — excess accepts get **503** + close
- `ServerOptions.read_header_timeout`
- `ServerOptions.send_date` / `server_header` (opt-in; do not overwrite handler headers)
- `http.http_date` / `viltrum.http_date` for IMF-fixdate
- TE + Content-Length conflict → 400
- Example: `examples/upgrade_echo`
- Design note: `docs/upgrade.md`
- Integration tests: 101 echo, leftover, Date/Server, max_conns 503, peer_ip
- CI runs `v test engine/` and builds upgrade example

### From 0.3.x polish (shipped in this line)

- Docs: connection, deploy, request-response; README non-goals
- Chunked/TE reject; Expect 100-continue; HEAD body omit + GET fallback
- Absolute-form target, OPTIONS `*`; `patch`/`options`/`head`
- `App.server_options` (renamed from `options` for ServerOptions)

## 0.3.2 — 2026-07-18

- Trailing wildcard routes: `/files/*path`
- JSON field helpers: `req.json_string` / `json_int` / `json_bool` (minimal)
- Route middleware: `viltrum.chain([...], handler)` and `Mount.use`
- `scripts/install.sh` for `~/.vmodules` link
- Heavier bench notes (JSON body + higher concurrency)
- features example: wildcard, chain, mount header, json echo

## 0.3.1 — 2026-07-18

- `app.mount`, cors, static_files, parse fuzz, honest oha bench, GitHub Release

## 0.3.0 — 2026-07-18

- Graceful shutdown, idle timeout, recover, timed logger

## 0.2.x — 2026-07-18

- Framing, keep-alive, polish

## 0.1.0 — 2026-07-18

- Initial PoC
