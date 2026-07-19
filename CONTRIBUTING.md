# Contributing

## Setup

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh   # ~/.vmodules/viltrum → this repo
```

Requires [V](https://github.com/vlang/v) on `PATH`.

## Checks

```bash
v test http/
v test router/
v test engine/
v test ws/
v -o /tmp/viltrum-hello examples/hello
```

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
