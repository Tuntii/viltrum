#!/usr/bin/env bash
# run.sh: the systemd timer's entry point on hostlab. Pulls viltrum, measures
# every commit that has no result for the current SETUP (oldest first) and
# republishes the page after each one, so a backfill fills the page as it goes.
# FAST_HOME holds repo/, data/dataset.json, work/, www/ and store.json.
# FAST_SCRIPTS_REF picks the checkout the scripts run from (origin/main).
set -euo pipefail

home=${FAST_HOME:-/opt/viltrum-fast}
repo=$home/repo
fast=$repo/benches/fast

publish() {
	python3 "$fast/results.py" publish --repo "$repo" --results "$home/store.json" --out "$home/www/results.json"
}

main() {
	exec 9>"$home/run.lock"
	flock -n 9 || {
		echo "busy: another run holds $home/run.lock" >&2
		exit 0
	}
	git -C "$repo" fetch -q origin
	# git replaces files rather than rewriting them, so this shell keeps reading
	# the run.sh it started with; everything below comes from the new checkout
	git -C "$repo" checkout -q --detach "${FAST_SCRIPTS_REF:-origin/main}"
	mkdir -p "$home/work" "$home/www"
	gcc -O2 -o "$home/load" "$fast/load.c"
	cp "$fast/page/index.html" "$fast/page/fast.js" "$home/www/"
	setup=$(tr -d '[:space:]' <"$fast/SETUP")
	publish
	for h in $(python3 "$fast/results.py" pending --repo "$repo" --results "$home/store.json" --setup "$setup"); do
		LOAD=$home/load FAST_DATA=$home/data/dataset.json nice -n 10 ionice -c3 \
			bash "$fast/measure.sh" "$repo" "$h" "$home/work" |
			python3 "$fast/results.py" add --results "$home/store.json"
		publish
	done
}

main "$@"
exit
