#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <input-pdf> [output-dir]" >&2
  exit 2
fi

INPUT="$1"
OUT_DIR="${2:-$(dirname "$INPUT")}"

swift run Drawbridge --stress --export-link-compat "$INPUT" --export-link-compat-out "$OUT_DIR"
