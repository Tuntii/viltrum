"""The PR perf gate: compares two measure.sh lines (base, head) and fails on a regression.

  gate.py BASE_LINE_FILE HEAD_LINE_FILE   prints a Markdown table; exit 1 when head is slower

Ir/request is deterministic for a given machine, so base and head are measured on the
same runner and any scenario more than LIMIT percent above base fails.
"""
import json
import sys

LIMIT = 1.0  # percent; the page colors the same threshold


def compare(base, head):
    """Returns (markdown, failed)."""
    if head.get("status") != "ok":
        return f"head: **{head.get('status')}**", True
    if base.get("status") != "ok":
        return f"base: {base.get('status')}, nothing to compare against", False
    rows = ["| scenario | base Ir/req | head Ir/req | change |", "|---|---:|---:|---:|"]
    failed = False
    for k, h in head["ir"].items():
        b = base["ir"].get(k)
        if b is None:
            rows.append(f"| {k} | – | {h} | new |")
            continue
        pct = (h - b) / b * 100
        mark = ""
        if pct > LIMIT:
            failed = True
            mark = " ❌"
        rows.append(f"| {k} | {b} | {h} | {pct:+.2f}%{mark} |")
    return "\n".join(rows), failed


def main():
    with open(sys.argv[1]) as f:
        base = json.loads(f.readline() or "{}")
    with open(sys.argv[2]) as f:
        head = json.loads(f.readline() or "{}")
    md, failed = compare(base, head)
    print(md)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
