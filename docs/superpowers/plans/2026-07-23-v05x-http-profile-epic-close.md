# Plan: v0.5.x HTTP profile (#9) + epic close (#3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development.  
> **Branch:** `plan/v05x-http-profile-epic-close`  
> **Worktree:** `.worktrees/plan-v05x-http-profile-epic-close`  
> **Process:** Feature branch → PR → CI → merge. Do **not** push straight to `main`. Issues close only via PR (`Closes #N`).

## Context

Epic #3 (v0.5.x harden + measured perf) is nearly done. Children #4–#8 are closed. Remaining actionable child:

- **#9** `perf(http): profile accept/read/write path; micro-opts without API churn` (P2)

#1 (TLS interest) is **out of scope** (v0.6). Do not implement TLS.

## Global Constraints

1. **No public API break.** Surface stays `new` → routes → `listen` / `ws`. No second “fast unsafe” API.
2. **No architecture rewrite.** No reactor, io_uring, package explosion, modular monolit theme.
3. **No HTTP/2.** Cleartext HTTP/1.1 only.
4. **Profile-driven only.** Fix waste only if evidence is obvious (extra clones, repeated maps, needless allocs). Otherwise close as “no action — profile clean enough” with written evidence.
5. **Do not chase 100k req/s as a product claim.**
6. **Tests must stay green:** `v test http/`, `v test engine/`, `v test router/`, `v test ws/` (and existing soak if touched).
7. **Honest docs:** If benches change materially, update `benches/RESULTS.md` with method. If not material, say so.
8. **PR process:** All work lands via PR. Issue comments + `Closes #9` / epic close on merge path.
9. **V toolchain:** `export PATH="${HOME}/.local/bin:${PATH}"` and `bash scripts/install.sh` (link `~/.vmodules/viltrum`) before tests. Working directory must be the worktree root after link.

## Success Criteria

- #9 closed with either measured micro-win **or** documented no-action + evidence
- Epic #3 success criteria satisfied (children closed/deferred; API intact; RESULTS honest)
- One PR merged (or ready to merge) with green CI
- No TLS / no dual API / no rewrite

---

## Task 1: HTTP hot-path profile note

**Files:**
- Create: `benches/HTTP_PROFILE.md` (or `docs/local/` is gitignored — **must** be under `benches/` so it ships)
- Read: `engine/engine.v` (`handle_conn`, `read_message`, write path), `http/http.v` (parse + serialize)

**Steps:**
1. Read the accept → read → parse → handler → write path carefully.
2. List allocation / copy sites on GET `/` and POST JSON (header parse, body buffer, leftover clone, response `to_bytes`, header map).
3. Write `benches/HTTP_PROFILE.md` with:
   - Scope (GET `/`, POST small JSON)
   - Method (static code inspection + optional local timing if cheap; not a full `perf` lab claim)
   - Hot-path table: step → cost class (alloc / copy / syscall) → severity (high/med/low/none)
   - Recommendation: **fix candidate(s)** or **no action**
4. Commit: `docs(bench): HTTP accept/read/write profile note (#9)`

**Acceptance:**
- Profile note exists and is specific to this codebase (not generic advice)
- Names real functions/files

**Tests:** none required beyond “repo still builds” if no code change.

---

## Task 2: Opportunistic micro-opts OR explicit no-action

**Depends on:** Task 1 recommendation.

**If Task 1 found clear waste (e.g. double clone of leftover, avoidable full-buffer copy on serialize):**
1. Implement the smallest fix that removes that waste.
2. Keep public API unchanged.
3. Add/adjust unit tests if behavior could regress (prefer existing `http/` + `engine/` tests).
4. Run `v test http/` and `v test engine/`.
5. Optionally re-run a short oha sample if available; only update `benches/RESULTS.md` if material (>~10% sustained).
6. Commit: `perf(http): <one-line hot path fix> (#9)`

**If Task 1 recommended no action:**
1. Append a short “Decision” section to `benches/HTTP_PROFILE.md`: date, “no action — profile clean enough”, why.
2. No engine code change unless a trivial correctness bug was found (then fix + test).
3. Commit: `docs(bench): close #9 as no-action with profile evidence`

**Acceptance (either path):**
- Matches issue #9 acceptance: measured win **or** no-action with evidence
- Tests green

---

## Task 3: Epic closeout + PR packaging

**Files:**
- `CHANGELOG.md` (Unreleased 0.5.x)
- `ROADMAP.md` if it still lists open 0.5.x items that are done
- Issue comments (via `gh` after push is OK for implementer; controller opens PR)

**Steps:**
1. Update CHANGELOG Unreleased: note #9 outcome (win or no-action).
2. If ROADMAP has open checkboxes for 0.5.x children that are done, mark them honestly.
3. Ensure branch is ready: all Task 1–2 commits present, tree clean except intentional files.
4. Commit: `chore: v0.5.x epic closeout notes (#3 #9)`
5. Do **not** force-close issues from the implementer without PR — controller will open PR with body:

```
Closes #9
Closes #3
```

(Only if #9 is fully satisfied and all other children are already closed; #1 is not a child to close.)

**Acceptance:**
- CHANGELOG reflects #9
- PR body links Closes #9 and Closes #3
- Epic success criteria textually satisfied in PR description

---

## Out of scope (do not do)

- #1 TLS / WSS
- HTTP/2, plugins, reactor
- Rewriting benches/run.sh scenarios
- Marketing comparisons
