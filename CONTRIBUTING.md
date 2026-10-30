# Contributing

Everyone taking part in this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh   # ~/.vmodules/viltrum → this repo
```

Requires [V](https://github.com/vlang/v) on `PATH`.

## Checks

The ones CI runs on every pull request ([ci.yml](.github/workflows/ci.yml)). The unit tests and examples also run
on V master.

```bash
v fmt -verify .
v test http1/ http2/ jsonenc/ router/ engine/ tests/
v -d viltrum_debug test router/ engine/ tests/
bash scripts/hotpath_lint.sh
bash scripts/gcpin_check.sh
v -o /tmp/viltrum-hello examples/hello
```

The engine tests serve on Linux only. On macOS and Windows the unit tests still run and the examples build.

Optional benches (local only):

```bash
bash benches/run.sh
bash benches/run_ws.sh
```

## Commit messages

This repo uses **[Conventional Commits](https://www.conventionalcommits.org/)** so [semantic-release](docs/releasing.md) can version automatically.

```text
<type>(optional-scope): <short summary>

[optional body]
```

Common types: `feat`, `fix`, `docs`, `perf`, `refactor`, `test`, `chore`, `ci`.

- User-visible behavior → `feat` or `fix` (not only `refactor`)
- Breaking API → `!` after type or a `BREAKING CHANGE:` footer

## Scope of the project

Read [ROADMAP.md](ROADMAP.md) and the non-goals there before large PRs. Prefer small surface area and first-party engine work over wrapping foreign stacks.

## Docs

- Index: [docs/README.md](docs/README.md)
- When you change public API or wire protocol, update the matching file under `docs/`
