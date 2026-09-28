#!/usr/bin/env sh
# Refuses to continue unless the RPC endpoint is the lab devnet.
# Usage: guard.sh <evm-rpc-url> [comet-rpc-url]
set -eu

DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lab.env
. "$DIR/lab.env"

RPC="${1:?usage: guard.sh <evm-rpc-url> [comet-rpc-url]}"
COMET="${2:-}"

die() { echo "GUARD: $*" >&2; exit 1; }

# Only lab hostnames. Blocks public RPCs even before any request is made.
host="$(echo "$RPC" | sed -E 's|^[a-z]+://([^/:]+).*|\1|')"
case "$host" in
  val[0-9]|localhost|127.0.0.1) ;;
  *) die "RPC host '$host' is not a lab host" ;;
esac

# JSON-RPC call via curl, or via foundry's cast when curl is not installed.
rpc() { # url method
  if command -v curl >/dev/null 2>&1; then
    curl -sf -m 5 -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":[]}" "$1"
  else
    timeout 5 cast rpc "$2" --rpc-url "$1"
  fi
}

hex="$(rpc "$RPC" eth_chainId | grep -oE '0x[0-9a-fA-F]+' | head -1)" || true
[ -n "$hex" ] || die "cannot read eth_chainId from $RPC"
evm_id="$(printf '%d' "$hex")"

for bad in $DENY_EVM_CHAIN_IDS; do
  [ "$evm_id" = "$bad" ] && die "EVM chain id $evm_id is a REAL network"
done
[ "$evm_id" = "$LAB_EVM_CHAIN_ID" ] || die "EVM chain id $evm_id is not the lab chain ($LAB_EVM_CHAIN_ID)"

if [ -n "$COMET" ]; then
  net="$(rpc "$COMET" status | grep -oE '"network": ?"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/')" || true
  [ -n "$net" ] || die "cannot read chain id from $COMET"
  for bad in $DENY_CHAIN_IDS; do
    [ "$net" = "$bad" ] && die "chain id $net is a REAL network"
  done
  [ "$net" = "$LAB_CHAIN_ID" ] || die "chain id $net is not the lab chain ($LAB_CHAIN_ID)"
fi

echo "GUARD: ok (evm $evm_id${COMET:+, chain $net})"
