"""Which commits benches/fast measures, the result store, and what the page shows.

  results.py pending --repo R --results F --setup S   hashes still to measure, oldest first
  results.py add     --results F                      merge one measure.sh line from stdin
  results.py publish --repo R --results F --out O     write the page's results.json

The store holds every (hash, setup) ever measured. The page only gets a setup
whose results cover every commit, so the chart never mixes setups (README.md).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

SINCE = "v1.0.0"
RELEASE = re.compile(r"^chore\(release\): (\S+)")


def select_commits(log):
    """log: (hash, iso_date, subject) oldest first. Drops release commits and
    puts their version on the commit before them."""
    out = []
    for h, date, subject in log:
        m = RELEASE.match(subject)
        if m:
            if out:
                out[-1]["version"] = "v" + m.group(1)
            continue
        out.append({"hash": h, "date": date, "subject": subject})
    return out


def pending(commits, results, setup):
    done = {r["hash"] for r in results if r["setup"] == setup}
    return [c["hash"] for c in commits if c["hash"] not in done]


def add(results, line):
    key = (line["hash"], line["setup"])
    return [r for r in results if (r["hash"], r["setup"]) != key] + [line]


def publish(commits, results):
    """The newest setup that covers every commit, merged into the commits,
    newest first; None when no setup is complete."""
    by_setup = {}
    for r in results:
        by_setup.setdefault(r["setup"], {})[r["hash"]] = r
    for setup in sorted(by_setup, key=int, reverse=True):
        got = by_setup[setup]
        if all(c["hash"] in got for c in commits):
            rows = []
            for c in reversed(commits):
                r = got[c["hash"]]
                rows.append({**c, **{k: v for k, v in r.items() if k not in ("hash", "setup")}})
            return {"setup": setup, "commits": rows}
    return None


def write_json_atomic(path, obj):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, separators=(",", ":"))
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def git_log(repo, ref):
    out = subprocess.run(
        ["git", "-C", repo, "log", "--first-parent", "--reverse", "--format=%H%x09%cI%x09%s", f"{SINCE}..{ref}"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [tuple(line.split("\t", 2)) for line in out.splitlines() if line]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return []


def main():
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["pending", "add", "publish"])
    p.add_argument("--repo")
    p.add_argument("--ref", default="origin/main")
    p.add_argument("--results", required=True)
    p.add_argument("--setup")
    p.add_argument("--out")
    a = p.parse_args()
    have = load(a.results)
    if a.cmd == "add":
        write_json_atomic(a.results, add(have, json.loads(sys.stdin.readline())))
        return
    commits = select_commits(git_log(a.repo, a.ref))
    if a.cmd == "pending":
        print("\n".join(pending(commits, have, a.setup)))
        return
    page = publish(commits, have)
    if page is not None:
        write_json_atomic(a.out, page)


if __name__ == "__main__":
    main()
