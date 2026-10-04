#!/bin/zsh
# Rebuild and (re)launch Chilk.
set -euo pipefail
cd "${0:A:h}/.."
APP=$(./scripts/build.sh | tail -1)
pkill -x Chilk 2>/dev/null || true
sleep 0.3
open "$APP"
echo "launched $APP"
