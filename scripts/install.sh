#!/usr/bin/env bash
# Link this repo into ~/.vmodules/viltrum for `import viltrum`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "${HOME}/.vmodules"
ln -sfn "${ROOT}" "${HOME}/.vmodules/viltrum"
echo "linked: ${HOME}/.vmodules/viltrum -> ${ROOT}"
if command -v v >/dev/null 2>&1; then
  echo "v: $(v version 2>/dev/null | head -1)"
  echo "try: v run examples/hello"
else
  echo "v not on PATH; install from https://github.com/vlang/v"
fi
