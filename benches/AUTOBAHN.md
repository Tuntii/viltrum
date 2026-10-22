# Autobahn|Testsuite

`app.ws` is checked against [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite), the
conformance suite for RFC 6455 servers, in fuzzingclient mode: the suite connects as the client and runs
every case against an echo server ([autobahn/main.v](autobahn/main.v)).

Run on 2026-10-22, viltrum 1.3.0 (74e3540), V 0.5.2, Linux 5.15 x86_64 (8 vCPU VM), image
`crossbario/autobahn-testsuite` sha256:b0475418d42a. All 517 cases in 22.6 s.

| Section | Cases | Result |
|---------|------:|--------|
| 1 Framing | 16 | 16 OK |
| 2 Pings/Pongs | 11 | 11 OK |
| 3 Reserved bits | 7 | 7 OK |
| 4 Opcodes | 10 | 10 OK |
| 5 Fragmentation | 20 | 20 OK |
| 6 UTF-8 handling | 145 | 141 OK, 4 non-strict |
| 7 Close handling | 37 | 34 OK, 3 informational |
| 9 Limits/performance | 54 | 54 OK |
| 10 Misc (auto-fragmentation) | 1 | 1 OK |
| 12 WebSocket compression | 90 | unimplemented |
| 13 WebSocket compression | 126 | unimplemented |

No case failed.

- **Non-strict, 6.4.1–6.4.4**: a text message whose UTF-8 turns invalid in a middle fragment is refused with
  1007 when the message is complete, not as soon as the bad fragment arrives. RFC 6455 allows both; the suite
  marks the late close non-strict.
- **Informational, 7.1.6, 7.13.1–7.13.2**: cases the spec leaves open. 7.1.6 sends a 256 KiB message, a
  Close and a ping back to back (we echo the message, then answer the Close with 1000); 7.13.* send close
  codes 5000 and 65535, which we refuse with 1002.
- **Unimplemented, 12.\*–13.\***: permessage-deflate is not negotiated, so the compression cases do not apply.

Section 9 goes up to 16 MiB messages, so the echo server raises `max_message` to 32 MiB (the default is
1 MiB, and larger messages close with 1009).

## Reproduce

Linux, Docker, V on `PATH`, port 9001 free:

```bash
bash benches/autobahn/run.sh
```

It builds and starts the echo server on 127.0.0.1:9001, runs

```bash
docker run --rm --network host \
	-v "$PWD/benches/autobahn/fuzzingclient.json:/config/fuzzingclient.json:ro" \
	-v "$PWD/benches/autobahn/reports:/reports" \
	crossbario/autobahn-testsuite \
	wstest -m fuzzingclient -s /config/fuzzingclient.json
```

and prints the per-section counts above, plus any case outside OK / non-strict / informational /
unimplemented. The full HTML report is in `benches/autobahn/reports/index.html` (not committed).
