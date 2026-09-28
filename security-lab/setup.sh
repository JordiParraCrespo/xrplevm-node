#!/usr/bin/env bash
# Clones node, cosmos/evm (xrplevm fork) and cometbft side by side, wires them
# together with a Go workspace and builds bin/exrpd from the local sources.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab.env
source "$LAB_DIR/lab.env"
SRC="$LAB_DIR/src"
mkdir -p "$SRC" "$LAB_DIR/bin"

clone() { # repo ref dir
  if [ -d "$3/.git" ]; then
    echo "==> $3 already present, leaving it untouched"
    return
  fi
  echo "==> cloning $1 @ $2"
  git clone --quiet "$1" "$3"
  git -C "$3" checkout --quiet "$2"
}

clone "$NODE_REPO" "$NODE_REF" "$SRC/node"

# Read the versions node actually builds with.
modjson="$(cd "$SRC/node" && go mod edit -json)"
if [ -z "$EVM_REF" ]; then
  EVM_REF="$(jq -r '.Replace[] | select(.Old.Path=="github.com/cosmos/evm") | .New.Version' <<<"$modjson")"
fi
if [ -z "$COMETBFT_REF" ]; then
  COMETBFT_REF="$(jq -r '.Require[] | select(.Path=="github.com/cometbft/cometbft") | .Version' <<<"$modjson")"
fi

clone "$EVM_REPO" "$EVM_REF" "$SRC/evm"
clone "$COMETBFT_REPO" "$COMETBFT_REF" "$SRC/cometbft"

# go.work replaces take precedence over node/go.mod replaces, so edits in
# src/evm and src/cometbft are picked up without touching any go.mod.
cat >"$LAB_DIR/go.work" <<EOF
go $(cd "$SRC/node" && go mod edit -json | jq -r .Go)

use ./src/node

replace (
	github.com/cosmos/evm => ./src/evm
	github.com/cometbft/cometbft => ./src/cometbft
)
EOF

# Local-only proof-of-concept tests live in poc-go/ and are linked into the
# node integration package so they can use its in-process network.
shopt -s nullglob
for f in "$LAB_DIR"/poc-go/*_test.go; do
  ln -sf "$f" "$SRC/node/tests/integration/zz_lab_$(basename "$f")"
done

echo "==> building exrpd (node $NODE_REF, evm $EVM_REF, cometbft $COMETBFT_REF)"
# Static so the same binary runs in the devnet containers regardless of libc.
(cd "$SRC/node" && GOWORK="$LAB_DIR/go.work" go build -tags netgo,osusergo \
  -ldflags '-linkmode external -extldflags "-static"' -o "$LAB_DIR/bin/exrpd" ./cmd/exrpd)
echo "==> done: $LAB_DIR/bin/exrpd"
