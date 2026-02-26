#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROFILE="${1:-standard}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT_DIR/dist/stress/compat-gate/$STAMP"
mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/compat-gate.log"
touch "$LOG"

failures=0

float_le() {
  local lhs="$1"
  local rhs="$2"
  awk -v a="$lhs" -v b="$rhs" 'BEGIN { exit (a <= b) ? 0 : 1 }'
}

run_and_capture() {
  local name="$1"
  shift
  local case_log="$OUT_DIR/${name}.log"
  echo "===== CASE $name =====" | tee -a "$LOG"
  /usr/bin/time -p swift run Drawbridge --stress "$@" >"$case_log" 2>&1
  cat "$case_log" | tee -a "$LOG"
  echo | tee -a "$LOG"
}

validate_save_case() {
  local name="$1"
  local expected_iters="$2"
  local max_p95_ms="$3"
  local case_log="$OUT_DIR/${name}.log"

  local save_iter_count
  save_iter_count="$(rg '^save_iter=' "$case_log" | awk 'END { print NR + 0 }')"
  if [ "$save_iter_count" -ne "$expected_iters" ]; then
    echo "FAIL [$name] expected $expected_iters save iterations, got $save_iter_count" | tee -a "$LOG"
    failures=$((failures + 1))
  fi

  local missing_markers
  missing_markers="$(rg '^save_iter=' "$case_log" | awk '!/marker_present=1$/ { bad += 1 } END { print bad + 0 }')"
  if [ "$missing_markers" -ne 0 ]; then
    echo "FAIL [$name] detected $missing_markers save iterations without persisted marker" | tee -a "$LOG"
    failures=$((failures + 1))
  fi

  local p95
  p95="$(rg '^save_write_ms ' "$case_log" | sed -E 's/.*p95=([0-9.]+).*/\1/' | tail -n 1)"
  if [ -z "$p95" ]; then
    echo "FAIL [$name] could not parse save_write_ms p95" | tee -a "$LOG"
    failures=$((failures + 1))
    return
  fi

  if ! float_le "$p95" "$max_p95_ms"; then
    echo "FAIL [$name] save_write_ms p95=$p95 exceeded threshold=$max_p95_ms" | tee -a "$LOG"
    failures=$((failures + 1))
  else
    echo "PASS [$name] save_write_ms p95=$p95 <= $max_p95_ms" | tee -a "$LOG"
  fi
}

validate_custom_compat_case() {
  local name="$1"
  local case_log="$OUT_DIR/${name}.log"
  local result_line
  result_line="$(rg '^custom_compat_probe_result ' "$case_log" | tail -n 1 || true)"
  if [ -z "$result_line" ]; then
    echo "FAIL [$name] missing custom compatibility probe result line" | tee -a "$LOG"
    failures=$((failures + 1))
    return
  fi
  if ! echo "$result_line" | rg -q 'custom_subclass=0'; then
    echo "FAIL [$name] expected custom_subclass=0 (plain annotation reload), got: $result_line" | tee -a "$LOG"
    failures=$((failures + 1))
  fi
  if ! echo "$result_line" | rg -q 'visible=1'; then
    echo "FAIL [$name] expected visible=1, got: $result_line" | tee -a "$LOG"
    failures=$((failures + 1))
  fi
  if echo "$result_line" | rg -q 'custom_subclass=0' && echo "$result_line" | rg -q 'visible=1'; then
    echo "PASS [$name] $result_line" | tee -a "$LOG"
  fi
}

run_profile_smoke() {
  run_and_capture smoke-5k --pages 100 --markups-per-page 50 --iterations 1 --save-iterations 5 --out "$OUT_DIR/smoke-5k.pdf"
  validate_save_case smoke-5k 5 1500

  run_and_capture smoke-10k --pages 200 --markups-per-page 50 --iterations 1 --save-iterations 5 --out "$OUT_DIR/smoke-10k.pdf"
  validate_save_case smoke-10k 5 3000

  run_and_capture smoke-custom --pages 10 --markups-per-page 20 --iterations 1 --verify-custom-markup-compat --out "$OUT_DIR/smoke-custom.pdf"
  validate_custom_compat_case smoke-custom
}

run_profile_standard() {
  run_and_capture tier-6k --pages 100 --markups-per-page 60 --iterations 1 --save-iterations 20 --out "$OUT_DIR/tier-6k.pdf"
  validate_save_case tier-6k 20 1500

  run_and_capture tier-20k --pages 250 --markups-per-page 80 --iterations 1 --save-iterations 20 --out "$OUT_DIR/tier-20k.pdf"
  validate_save_case tier-20k 20 5000

  run_and_capture tier-50k --pages 500 --markups-per-page 100 --iterations 1 --save-iterations 10 --out "$OUT_DIR/tier-50k.pdf"
  validate_save_case tier-50k 10 12000

  run_and_capture custom-compat --pages 10 --markups-per-page 20 --iterations 1 --verify-custom-markup-compat --out "$OUT_DIR/custom-compat.pdf"
  validate_custom_compat_case custom-compat
}

case "$PROFILE" in
  smoke)
    run_profile_smoke
    ;;
  standard)
    run_profile_standard
    ;;
  *)
    echo "Unknown profile: $PROFILE (expected smoke|standard)" | tee -a "$LOG"
    exit 2
    ;;
esac

if [ "$failures" -ne 0 ]; then
  echo "COMPAT GATE FAILED: failures=$failures log=$LOG" | tee -a "$LOG"
  exit 1
fi

echo "COMPAT GATE PASSED: profile=$PROFILE log=$LOG" | tee -a "$LOG"
