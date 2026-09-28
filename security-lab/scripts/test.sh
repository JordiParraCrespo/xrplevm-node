#!/usr/bin/env bash
# Runs the in-process lab tests from poc-go/ against the local sources.
# Usage: scripts/test.sh [go test -run regex]   (default: all lab tests)
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LAB_DIR/src/node"
GOWORK="$LAB_DIR/go.work" go test -tags=test ./tests/integration/ \
  -run "TestLabSuite/${1:-TestLab_}" -count=1 -v
