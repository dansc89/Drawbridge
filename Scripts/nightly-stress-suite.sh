#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT_DIR/dist/stress/nightly/$STAMP"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/nightly.log"

run_tier() {
  local name="$1"
  local pages="$2"
  local markups="$3"
  local out_pdf="$OUT_DIR/${name}.pdf"
  {
    echo "===== $name ====="
    echo "pages=$pages markups_per_page=$markups"
    date
    ./Scripts/run-stress.sh "$pages" "$markups" "$out_pdf"
    date
    echo
  } | tee -a "$LOG"
}

run_tier "tier-10k" 200 50
run_tier "tier-25k" 250 100
run_tier "tier-50k" 500 100

echo "Nightly suite complete. Log: $LOG"

