#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PAGES="${1:-300}"
MARKUPS_PER_PAGE="${2:-100}"
OUT="${3:-$ROOT_DIR/dist/stress/Drawbridge-Stress.pdf}"

mkdir -p "$(dirname "$OUT")"

swift run Drawbridge --stress --pages "$PAGES" --markups-per-page "$MARKUPS_PER_PAGE" --out "$OUT"

