#!/usr/bin/env sh
# Runs an EVM PoC inside the poc-runner container, after the guard passes.
# Usage (from the host): docker compose exec poc-runner scripts/run-poc.sh <cmd...>
# Example: scripts/run-poc.sh forge script poc-evm/Template.s.sol --broadcast
set -eu

DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$DIR/scripts/guard.sh" "$RPC_URL" "$COMET_RPC"

PRIVATE_KEY="0x$(cat "$DIR/attacker.key")"
export PRIVATE_KEY
exec "$@" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY"
