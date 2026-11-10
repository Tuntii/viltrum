# Working on Viltrum (for coding agents)

Viltrum is an HTTP framework for V with its own engine: one epoll worker per CPU, HTTP/1.1, HTTP/2, WebSocket,
TLS 1.3, and an HTTP client on the same workers. Read [ROADMAP.md](ROADMAP.md) for the principles and the
non-goals before proposing a feature; each feature gets a design note in `docs/design/` first.

## Layout

| Path | What |
|------|------|
| `viltrum.v`, `middleware.v` | the public API (`App`, routes, listeners, middleware) |
| `http1/` | parser, `Ctx`, response writer, DEFLATE, WebSocket frames, files, forms, upstream replies |
| `http2/` | HPACK, Huffman, frames |
| `engine/` | the event loop (`worker_linux.c.v`), request processing, HTTP/2, TLS, the client; crypto in `*.h` |
| `router/`, `jsonenc/` | the router, the compile-time JSON encoder |
| `tests/` | app-level tests; unit tests sit beside their source as `*_test.v` |
| `benches/fast/` | the instruction-count measurement the PR perf gate uses |

## Setup and checks

```bash
bash scripts/install.sh            # links this checkout as ~/.vmodules/viltrum (import viltrum)
bash scripts/check.sh              # what CI runs; Linux-only parts are skipped elsewhere
```

V 0.5.2 is the pinned compiler; CI also runs the tests on V master.

`*_linux.c.v` and `*_linux_test.v` build and run on Linux only: the engine serves on epoll. On macOS and
Windows the remaining unit tests run and handlers can be exercised with `app.handle_raw`. If you cannot run
the Linux tests, say so; do not report them as passing.

## Rules that are easy to break

- **No allocation per request.** Tests run each request shape thousands of times and fail when the GC heap
  grows by a byte. In files `scripts/hotpath_lint.sh` lists, string interpolation, `.str()`, `.clone()`,
  `.bytestr()`, `.split(`, `.trim...`, `.to_lower(` and slices fail the lint. Code that truly runs off the
  request path (startup, a buffer growing once) ends its line with `// cold: <reason>`.
- **Request strings are views** into the connection's buffer, valid until the handler returns. Keep one with
  `.clone()`, in handler code only.
- **The perf gate.** A pull request fails when a measured scenario costs more than 1% more instructions per
  request than its base. A deliberate cost needs a sentence in the PR and the `perf-ok` label.
- **No third-party dependencies**, vendored or not. `v.mod` lists none. Write what is needed in the repo.
- **Do not edit `.v` files with shell heredocs, `sed` or inline scripts.** They turn the `\r`, `\n` and `\t`
  escapes inside V string and character literals into real control characters. Use a file-editing tool.
- **Docs follow the code.** A change to the public API or to what goes on the wire updates the matching file
  in `docs/` in the same change.
- **Misuse is quiet in release builds** and panics under `-d viltrum_debug`; V cannot recover from a panic,
  so library code must not panic on input from the network.

## Commits

Conventional Commits (`feat`, `fix`, `perf`, `docs`, `test`, `ci`, `chore`, `refactor`), with a scope where it
helps: `fix(h2): ...`. `feat` and `fix` cut a release through semantic-release ([docs/releasing.md](docs/releasing.md)),
so use them for changes users can see, and not for anything else.
