# Releasing

Viltrum uses **[semantic-release](https://semantic-release.gitbook.io/)** on `main`.

You do **not** hand-edit version tags for routine ships. Merge conventional commits → CI runs `semantic-release` → version, `CHANGELOG.md`, `v.mod`, GitHub Release, and tag `vX.Y.Z` are produced automatically when commits warrant a release.

## Conventional commits

| Prefix | Release |
|--------|---------|
| `feat:` | **minor** (0.5.0 → 0.6.0) |
| `fix:` | **patch** (0.5.0 → 0.5.1) |
| `perf:` | **patch** |
| `refactor:` | **patch** (behavior-preserving; use `feat`/`fix` if user-visible) |
| `docs:`, `chore:`, `test:`, `ci:`, `build:`, `style:` | no release |
| `BREAKING CHANGE:` footer or `feat!:` / `fix!:` | **major** |

Examples:

```text
feat: add idle timeout option for WebSocket sockets
fix: reject unmasked frames before payload alloc
docs: clarify proxy Upgrade headers
chore: ignore local bench dumps
```

Breaking:

```text
feat!: rename App.options to App.server_options

BREAKING CHANGE: App.options no longer sets ServerOptions; use server_options().
```

## What the pipeline updates

1. Analyzes commits since the last tag
2. Bumps version (`scripts/bump-version.sh` → `v.mod` + `package.json`)
3. Prepends notes to `CHANGELOG.md`
4. Commits `chore(release): X.Y.Z [skip ci]`
5. Tags `vX.Y.Z` and creates the GitHub Release

Config: [`.releaserc.yml`](../.releaserc.yml) · workflow: [`.github/workflows/release.yml`](../.github/workflows/release.yml)

## Local dry-run

```bash
npm ci
npx semantic-release --dry-run
```

Requires a clean git history and network only if plugins need it; dry-run does not publish.

## Manual hotfix (rare)

If automation is blocked:

1. Fix on `main` with a `fix:` commit
2. Prefer letting the next push to `main` cut the patch
3. Only hand-tag if CI is down — then mirror the usual `CHANGELOG` / `v.mod` edits so the next semantic-release run stays consistent

## First-time setup notes

- `package.json` / `package-lock.json` exist **only** for release tooling (not a Node library).
- Repo needs `contents: write` on the default `GITHUB_TOKEN` (set in the workflow).
- Protect `main` if you want; release commits use `[skip ci]` so unit CI is not doubled on the bump commit (optional; remove from the message if you prefer full re-test).
