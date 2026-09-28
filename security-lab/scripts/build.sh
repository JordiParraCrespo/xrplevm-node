#!/usr/bin/env bash
# Rebuilds bin/exrpd from the local node, evm and cometbft sources.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$LAB_DIR/src/node"
# Static so the same binary runs in the devnet containers regardless of libc.
GOWORK="$LAB_DIR/go.work" go build -tags netgo,osusergo \
  -ldflags '-linkmode external -extldflags "-static"' -o "$LAB_DIR/bin/exrpd" ./cmd/exrpd
echo "built $LAB_DIR/bin/exrpd"
