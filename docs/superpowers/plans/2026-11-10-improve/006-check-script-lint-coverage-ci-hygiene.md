# Plan 006: One check script that CI also runs, a hot-path lint that cannot miss new files, and bounded CI jobs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat acb27f3..HEAD -- scripts/ .github/workflows/ CONTRIBUTING.md .github/pull_request_template.md http1/file_cache.v http1/dx.v AGENTS.md`
> Plan 005 edits `.github/pull_request_template.md` and creates `AGENTS.md`; that is
> expected. If `.github/workflows/ci.yml` or `scripts/hotpath_lint.sh` changed, compare
> the "Current state" excerpts against the live files; on a mismatch, STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW–MED (changes CI workflow files; a mistake shows up as a red CI run, not as broken code)
- **Depends on**: none (if plan 005 landed, also update `AGENTS.md` in Step 5)
- **Category**: dx
- **Planned at**: commit `acb27f3`, 2026-11-10 (branch `feat/http-client`)

## Why this matters

- The list of test directories is written out three times in `ci.yml`, once in
  `CONTRIBUTING.md` and once in the PR template, and the copies already disagree (the
  template omitted `http2/`). The example list is written three times too. Adding a
  test directory or an example means editing six places.
- `scripts/hotpath_lint.sh` — the lint that keeps allocating constructs out of the
  request path — checks a hand-written list of files. A new source file is simply not
  linted until someone remembers to add it. Today three files on the request path are
  missing from the list, and one of them has an unmarked `.clone()`.
- No CI job has a timeout (a hung socket test burns GitHub's 6-hour default), `ci.yml`
  and `perf.yml` do not limit the workflow token, and the release job runs on Node 20,
  which is past its end of life.

## Current state

### `scripts/hotpath_lint.sh` (whole file)

```bash
#!/usr/bin/env bash
# Fails when a hot-path file uses a construct that allocates per request. A line can
# opt out with a trailing "// cold:" comment explaining why it is off the hot path.
set -uo pipefail
files="http1/bytes.v http1/frame.v http1/chunked.v http1/parse.v http1/writer.v http1/date.v
http1/ctx.v http1/gzip.v http1/deflate.v http1/ws.v jsonenc/encode.v engine/process.v engine/timers.v engine/worker_linux.c.v
engine/tls_linux.c.v engine/ws.v engine/tls13_linux.c.v router/router.v http2/hpack.v http2/huffman.v http2/frame.v engine/h2.v
http1/stream.v engine/stream.v engine/h2_stream.v http1/reply.v engine/client.v engine/client_linux.c.v"
pattern='\$\{|\.str\(\)|\.split\(|\.to_lower\(|\.to_upper\(|\.trim|\.bytestr\(\)|\.clone\(\)|\[([^]]*[^. ])?\.\.[^]]*\]'
bad=0
for f in $files; do
	[ -f "$f" ] || { echo "missing: $f"; exit 1; }
	hits=$(grep -nE "$pattern" "$f" | grep -vE '^[0-9]+:\s*//' | grep -v '// cold:')
	if [ -n "$hits" ]; then
		echo "$f:"
		echo "$hits"
		bad=1
	fi
done
[ "$bad" = 0 ] && echo "hot path clean"
exit $bad
```

Non-test `.v` files in `http1/ http2/ engine/ router/ jsonenc/` that are **not** in
that list, with the number of lint hits each has today (measured by running the same
pattern over them):

| File | Hits | Role |
|---|---|---|
| `http1/file.v` | 0 | static files — request path |
| `http1/form.v` | 0 | forms — request path |
| `http1/file_cache.v` | 1 | static file cache — request path |
| `http1/dx.v` | 2 | cookies, redirects — request path |
| `engine/hub.v`, `engine/hub_linux.c.v` | 0 | publish across workers — request path |
| `engine/aesgcm_linux.c.v`, `engine/hs13_linux.c.v` | 0 | TLS records and handshake |
| `http1/testing.v` | 0 | test helper (cold) |
| `engine/options.v`, `engine/serve_default.v`, `engine/tls_default.c.v` | 0 | config / stubs (cold) |
| `engine/serve_linux.c.v` | 5 | startup (cold) |
| `engine/upstream.v` | 7 | startup URL parsing (cold) |
| `router/add.v` | 11 | route registration (cold) |

The three hits in request-path files:

```
http1/file_cache.v:64:		c.fcache_idx[str_view(c.pbuf, 0, c.pbuf.len).clone()] = s + 1
http1/dx.v:136:			panic('viltrum: invalid cookie ${ck.name}')
http1/dx.v:264:			panic('viltrum: response header values over ${c.hval.len} bytes')
```

`file_cache.v:64` sits right under `c.fcache << CachedFile{} // cold: once per file`
(line 62), in the branch that adds a file to the cache the first time it is served.
`dx.v:136` and `:264` are inside `$if viltrum_debug ? { ... }` blocks (debug builds
only).

### `.github/workflows/ci.yml`

Three jobs — `portable` (macOS, Windows), `v-master` (Ubuntu), `test` (Ubuntu) — each
with this step:

```yaml
      - name: Unit tests
        run: |
          v test http1/
          v test http2/
          v test jsonenc/
          v test router/
          v test engine/
          v test tests/
```

and each with a "Build examples" step that names the six examples one by one
(`hello rest features https ws_chat sse`), writing binaries to `$RUNNER_TEMP` or
`/tmp`. The `portable` job sets `defaults: run: shell: bash` (so bash works on the
Windows runner). The workflow has no `permissions:` key and no job has
`timeout-minutes`. Typical durations: `portable` under 1 min, `test` about 3 min,
`v-master` about 5 min.

### `.github/workflows/perf.yml`

One job `gate`; no `permissions:`, no `timeout-minutes`; takes about 2 min. It reads
`github.event.pull_request.labels` from the event payload (no API call).

### `.github/workflows/release.yml`

Has its own `permissions:` block (leave it). Lines 35-38:

```yaml
      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: npm
```

It then runs `npm ci` and `npx semantic-release`. `package-lock.json` pins
semantic-release 24.x, which supports Node 22.

### `CONTRIBUTING.md:18-28`

```markdown
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
```

### Conventions

- Scripts in `scripts/` are bash, start with `#!/usr/bin/env bash`, a comment saying
  what they do, and `set -euo pipefail` (see `scripts/install.sh`,
  `scripts/gcpin_check.sh`). Tabs for indentation inside bash blocks.
- Shell scripts must have LF line endings. If you are on Windows, make sure your
  editor does not write CRLF (`file scripts/check.sh` must not say "CRLF").

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Link the module (once) | `bash scripts/install.sh` | prints `linked: ...` |
| Lint | `bash scripts/hotpath_lint.sh` | `hot path clean` |
| New script | `bash scripts/check.sh tests` / `examples` / (no argument) | exit 0 |
| YAML sanity | `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]; print('yaml ok')" .github/workflows/ci.yml .github/workflows/perf.yml .github/workflows/release.yml` | `yaml ok` |
| Format (after adding `// cold:`) | `v fmt -verify .` | exit 0 |

(If Python has no `yaml` module, use any YAML parser available; if none is, say so in
your report rather than skipping silently.)

## Scope

**In scope**:

- `scripts/check.sh` (create)
- `scripts/hotpath_lint.sh`
- `http1/file_cache.v` (append one `// cold:` comment to line 64), `http1/dx.v`
  (append `// cold:` comments to lines 136 and 264) — comments only
- `.github/workflows/ci.yml`, `.github/workflows/perf.yml`,
  `.github/workflows/release.yml` (the `node-version` line only)
- `CONTRIBUTING.md` (the "Checks" section), `.github/pull_request_template.md` (line 4)
- `AGENTS.md` (the "Setup and checks" block) — only if the file exists

**Out of scope**:

- Any change to what the lint pattern matches.
- `package.json`, `package-lock.json`, semantic-release plugin versions.
- Making the release wait for CI, caching the V master build, splitting CI jobs,
  pinning actions to commit SHAs — considered and left out (see Maintenance notes).
- `scripts/gcpin_check.sh`, `scripts/install.sh`, `benches/`.
- Any code change in a `.v` file beyond the three comments.

## Git workflow

- Branch from `feat/http-client`: `advisor/006-check-script-ci-hygiene`.
- Commits, Conventional style: `ci: run the test and example lists from scripts/check.sh`,
  `ci(lint): fail on a source file the hot-path lint does not know`,
  `ci: job timeouts, read-only token, Node 22 for the release`.
- Do NOT push or open a PR unless told to. Do not change git config.

## Steps

### Step 1: `scripts/check.sh`

Create it (LF line endings, tabs inside blocks):

```bash
#!/usr/bin/env bash
# The checks CI runs, in one place. CI calls the `tests` and `examples` parts; run it
# with no argument before a pull request.
#   bash scripts/check.sh            everything this machine can run
#   bash scripts/check.sh tests      the unit tests
#   bash scripts/check.sh examples   build every example
set -euo pipefail
cd "$(dirname "$0")/.."

test_dirs="http1 http2 jsonenc router engine tests"

run_tests() {
	for d in $test_dirs; do
		v test "$d/"
	done
}

build_examples() {
	out=$(mktemp -d)
	for e in examples/*/; do
		name=$(basename "$e")
		v -o "$out/viltrum-$name" "examples/$name"
	done
	rm -rf "$out"
}

case "${1:-all}" in
tests) run_tests ;;
examples) build_examples ;;
all)
	v fmt -verify .
	run_tests
	v -d viltrum_debug test router/ engine/ tests/
	bash scripts/hotpath_lint.sh
	build_examples
	if [ "$(uname -s)" = Linux ]; then
		bash scripts/gcpin_check.sh
		if command -v gcc >/dev/null 2>&1; then
			v -cc gcc test engine/aesgcm_linux_test.v engine/tls13_linux_test.v engine/tls_linux_test.v engine/hs13_linux_test.v
			v -cc gcc test http1/deflate_test.v jsonenc/
		fi
	else
		echo "skipped (Linux only): gcpin_check, the gcc TLS tests; the engine's socket tests did not run"
	fi
	echo "all checks passed"
	;;
*)
	echo "usage: bash scripts/check.sh [tests|examples]" >&2
	exit 2
	;;
esac
```

**Verify**:
- `bash scripts/check.sh examples` → exit 0.
- `bash scripts/check.sh tests` → exit 0.
- `bash scripts/check.sh nope; echo $?` → prints the usage line and `2`.
- `ls examples/*/main.v | wc -l` equals the number of directories in `examples/`
  (every example directory is a buildable app). If not, see STOP conditions.

### Step 2: The lint knows every source file

a) Mark the three request-path hits as cold (comments only; keep the code identical):

- `http1/file_cache.v:64`: append ` // cold: once per file`
- `http1/dx.v:136`: append ` // cold: debug builds only`
- `http1/dx.v:264`: append ` // cold: debug builds only`

Then run `v fmt -w http1/file_cache.v http1/dx.v`. If `v fmt` moves a comment off its
line (so the lint would not see it), see STOP conditions.

b) In `scripts/hotpath_lint.sh`:

- Add to the `files=` list (keep the list's wrapping style):
  `http1/file.v http1/form.v http1/file_cache.v http1/dx.v engine/hub.v engine/hub_linux.c.v engine/aesgcm_linux.c.v engine/hs13_linux.c.v`
- After the `files=` assignment add:

```bash
# Files that only run at startup, at route registration, or in tests. A source file in
# neither list fails the lint, so a new file cannot go unlinted by being forgotten.
cold="http1/testing.v engine/options.v engine/serve_default.v engine/tls_default.c.v
engine/serve_linux.c.v engine/upstream.v router/add.v"
```

- After the existing `for f in $files; do ... done` loop and before the
  `[ "$bad" = 0 ] && echo "hot path clean"` line, add:

```bash
for f in http1/*.v http2/*.v engine/*.v router/*.v jsonenc/*.v; do
	case "$f" in *_test.v) continue ;; esac
	case " $(echo $files $cold) " in
	*" $f "*) ;;
	*)
		echo "not linted: $f (add it to files, or to cold with the reason it is off the request path)"
		bad=1
		;;
	esac
done
```

**Verify**:
- `bash scripts/hotpath_lint.sh` → `hot path clean`, exit 0.
- Negative test: `touch http1/zz_probe.v && bash scripts/hotpath_lint.sh; echo "exit $?"; rm http1/zz_probe.v`
  → prints `not linted: http1/zz_probe.v ...` and `exit 1`. Confirm the probe file is
  removed (`git status --short` shows no `zz_probe.v`).
- `v fmt -verify .` → exit 0.

### Step 3: CI calls the script

In `.github/workflows/ci.yml`, in **each** of the three jobs:

- Replace the body of the "Unit tests" step with `run: bash scripts/check.sh tests`.
- Replace the body of the "Build examples" step with `run: bash scripts/check.sh examples`.

Leave every other step as it is (formatting, `viltrum_debug`, the gcc tests, the
lints, the fuzz step, and all "Install V" steps).

**Verify**: `grep -c "scripts/check.sh" .github/workflows/ci.yml` → `6`.
`grep -c "v test http2/" .github/workflows/ci.yml` → `0`. YAML sanity command → `yaml ok`.

### Step 4: Timeouts, token scope, Node

- `.github/workflows/ci.yml`: add at the top level, after the `concurrency:` block:

```yaml
permissions:
  contents: read
```

  and add `timeout-minutes: 20` to each of the three jobs (same indentation as
  `runs-on:`).
- `.github/workflows/perf.yml`: add the same top-level `permissions:` block after
  `concurrency:`, and `timeout-minutes: 20` to the `gate` job.
- `.github/workflows/release.yml`: change `node-version: "20"` to `node-version: "22"`.
  Add `timeout-minutes: 15` to the `release` job. Change nothing else in this file.

**Verify**: `grep -c "timeout-minutes" .github/workflows/*.yml` → `ci.yml:3`,
`perf.yml:1`, `release.yml:1`. `grep -n "node-version" .github/workflows/release.yml`
→ `"22"`. YAML sanity command → `yaml ok`.

### Step 5: Point the docs at the script

- `CONTRIBUTING.md`, "Checks" section: replace the bash block with

```bash
bash scripts/check.sh
```

  and the sentence before it with: "One script runs what CI runs on every pull request
  ([ci.yml](.github/workflows/ci.yml)): formatting, the unit tests, the tests under
  `viltrum_debug`, the hot-path lint, and a build of every example; on Linux also the
  scope-pin check and the gcc builds. CI adds V master and the parser fuzz runs."
  Keep the following sentence about Linux-only engine tests.
- `.github/pull_request_template.md` line 4 →
  ``- [ ] `bash scripts/check.sh` passes``
- If `AGENTS.md` exists: in its "Setup and checks" code block, replace the five check
  commands after `bash scripts/install.sh ...` with
  `bash scripts/check.sh              # what CI runs; Linux-only parts are skipped elsewhere`.

**Verify**: `grep -n "scripts/check.sh" CONTRIBUTING.md .github/pull_request_template.md` → one match each.

### Step 6: Final check

**Verify**:
- On Linux: `bash scripts/check.sh` → ends with `all checks passed`.
  Off Linux: it ends with the "skipped (Linux only)" line and `all checks passed`.
- `git status --short` → only in-scope files.
- `git diff -- http1/file_cache.v http1/dx.v` → only comment additions (3 lines).

## Test plan

- The negative test in Step 2 (a probe file fails the lint) is the regression test for
  the lint change; it is run by hand, not kept in the repo.
- CI itself is the test of Steps 3 and 4: after the branch is pushed by the operator,
  all four jobs of `ci` and the `perf` job must be green. You cannot run GitHub Actions
  locally; say in your report that this part is unverified until a CI run.

## Done criteria

- [ ] `scripts/check.sh` exists, has LF endings (`file scripts/check.sh` shows no CRLF), and `bash scripts/check.sh tests` and `examples` exit 0
- [ ] `bash scripts/hotpath_lint.sh` prints `hot path clean`
- [ ] A new empty `.v` file in `http1/` makes the lint exit 1 (Step 2 negative test), and the probe file is gone
- [ ] `grep -c "scripts/check.sh" .github/workflows/ci.yml` → `6`
- [ ] `grep -c "timeout-minutes" .github/workflows/ci.yml` → `3`; `perf.yml` → `1`; `release.yml` → `1`
- [ ] `grep -n "^permissions:" .github/workflows/ci.yml .github/workflows/perf.yml` → one match each
- [ ] All three workflow files parse as YAML
- [ ] `v fmt -verify .` exits 0; `git diff --stat -- '*.v'` shows only `http1/file_cache.v` and `http1/dx.v`, 3 changed lines
- [ ] `plans/README.md` status row updated

## STOP conditions

- `scripts/hotpath_lint.sh` or the three `ci.yml` "Unit tests" steps do not match the
  excerpts.
- After Step 2(b) the lint reports hits in one of the eight newly listed files other
  than the three lines named here. Do not add `// cold:` to make it pass: whether a
  line is really off the request path is a judgment for the maintainer. Report the
  hits and leave that file out of `files` **and** out of `cold` (the lint will then
  fail with "not linted" — report that too, and stop).
- `v fmt` moves one of the three `// cold:` comments to a different line than its
  code, so the lint still reports the line.
- An `examples/<dir>` has no `main.v` or does not build with `v -o ... examples/<dir>`
  (the glob in `build_examples` would then fail where the old fixed list passed).
- `bash scripts/check.sh tests` fails on a test that also fails on the untouched
  branch: that is a pre-existing failure — report it, do not fix it here.

## Maintenance notes

- A new source file in `http1/ http2/ engine/ router/ jsonenc/` now has to be added to
  `files` or `cold` in `scripts/hotpath_lint.sh`. That is the point: the choice is made
  on purpose once, instead of never.
- A new example directory is built automatically; a new test directory is one word in
  `test_dirs` in `scripts/check.sh`.
- `permissions: contents: read` is enough for both workflows today (they check out
  code and read the pull request's labels from the event). A future step that comments
  on a PR or uploads to a release needs its own `permissions:` on that job.
- Left out on purpose, for the maintainer to decide:
  - **Release waits for CI.** `release.yml` runs on every push to `main` without
    waiting for `ci`. Gating it (`workflow_run`) changes when releases are cut.
  - **V master build time** (about 2 min of the 5-min `v-master` job): cache by
    upstream commit, or move the job to a schedule.
  - **Pinning actions to SHAs**: only GitHub-owned actions are used.
  - **semantic-release major upgrade**: only the Node version changes here. If the
    first release run on Node 22 fails, revert that one line.
- Reviewer: check the first CI run after this lands on all three OSes — the Windows
  runner executes `scripts/check.sh` through Git Bash, where `mktemp -d` and
  `examples/*/` globbing are the parts most likely to differ.
