#!/usr/bin/env bash
# Runs Autobahn|Testsuite (fuzzingclient) against benches/autobahn/main.v. Linux,
# Docker, V on PATH. The HTML report lands in benches/autobahn/reports/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
v -prod -o /tmp/viltrum-autobahn "$here"
/tmp/viltrum-autobahn &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
sleep 1
mkdir -p "$here/reports"
docker run --rm --network host \
	-v "$here/fuzzingclient.json:/config/fuzzingclient.json:ro" \
	-v "$here/reports:/reports" \
	crossbario/autobahn-testsuite \
	wstest -m fuzzingclient -s /config/fuzzingclient.json
python3 - "$here/reports/index.json" <<'PY'
import collections, json, sys
res = json.load(open(sys.argv[1]))["viltrum"]
by = collections.defaultdict(collections.Counter)
for case, r in res.items():
    by[case.split(".")[0]][r["behavior"]] += 1
    if r["behavior"] not in ("OK", "INFORMATIONAL", "UNIMPLEMENTED", "NON-STRICT"):
        print("case", case, r["behavior"], r.get("behaviorClose"))
for sec in sorted(by, key=int):
    print(sec, dict(by[sec]))
PY
