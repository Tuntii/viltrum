#!/usr/bin/env bash
# Bump version in v.mod and package.json for semantic-release prepare step.
# Usage: bash scripts/bump-version.sh 0.6.0
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?version required (e.g. 0.6.0)}"
VERSION="${VERSION#v}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
	echo "invalid version: $VERSION" >&2
	exit 1
fi

# v.mod: version: 'x.y.z'
if [[ -f "$ROOT/v.mod" ]]; then
	if grep -q "version:" "$ROOT/v.mod"; then
		sed -i "s/version: *'[^']*'/version: '${VERSION}'/" "$ROOT/v.mod"
	else
		echo "v.mod has no version field" >&2
		exit 1
	fi
fi

# package.json: release tooling mirror (optional)
if [[ -f "$ROOT/package.json" ]] && command -v node >/dev/null 2>&1; then
	node -e "
const fs = require('fs');
const p = '$ROOT/package.json';
const j = JSON.parse(fs.readFileSync(p, 'utf8'));
j.version = process.argv[1];
fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n');
" "$VERSION"
fi

echo "bumped version → ${VERSION}"
