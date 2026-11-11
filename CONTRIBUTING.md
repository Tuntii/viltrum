# Contributing

Everyone taking part in this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

Questions, ideas or not sure where to start? Ask on [Discord](https://discord.gg/mY7JBbGhp).

## Setup

```bash
git clone https://github.com/Tuntii/viltrum.git && cd viltrum
bash scripts/install.sh   # ~/.vmodules/viltrum → this repo
```

Requires [V](https://github.com/vlang/v) on `PATH`.

## Checks

One script runs what CI runs on every pull request
([ci.yml](.github/workflows/ci.yml)): formatting, the unit tests, the tests under
`viltrum_debug`, the hot-path lint, and a build of every example; on Linux also the
scope-pin check and the gcc builds. CI adds V master and the parser fuzz runs.

```bash
bash scripts/check.sh
```

The engine tests serve on Linux only. On macOS and Windows the unit tests still run and the examples build.

[perf.yml](.github/workflows/perf.yml) measures callgrind instructions per request for the PR's base and head
and fails when a scenario is more than 1% slower ([benches/fast](benches/fast/README.md#the-pr-gate)). If the
cost is deliberate, say why in the PR and add the `perf-ok` label.

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
