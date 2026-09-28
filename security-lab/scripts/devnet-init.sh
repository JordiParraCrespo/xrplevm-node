#!/usr/bin/env bash
# Builds a fresh N-validator genesis for the isolated devnet in .devnet/.
# Keys are generated here, never recovered from a mnemonic, so nothing in the
# lab can sign for a real account.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lab.env
source "$LAB_DIR/lab.env"
BIN="$LAB_DIR/bin/exrpd"
OUT="$LAB_DIR/.devnet"
KR="--keyring-backend test"

rm -rf "$OUT"
home() { echo "$OUT/val$1"; }

for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  "$BIN" init "val$i" --chain-id "$LAB_CHAIN_ID" --home "$(home "$i")" >/dev/null 2>&1
  "$BIN" keys add "val$i" $KR --algo eth_secp256k1 --home "$(home "$i")" >/dev/null 2>&1
done
# One funded account for PoC transactions, also freshly generated.
"$BIN" keys add attacker $KR --algo eth_secp256k1 --home "$(home 0)" >/dev/null 2>&1

G="$(home 0)/config/genesis.json"
jqi() { jq "$1" "$G" >"$G.tmp" && mv "$G.tmp" "$G"; }
# Same genesis parameters as upstream local-node.sh.
jqi '.consensus.params.block.max_gas="10500000"'
jqi '.app_state.evm.params.evm_denom="axrp"'
jqi '.app_state.gov.params.min_deposit[0].denom="axrp" | .app_state.gov.params.min_deposit[0].amount="1"'
jqi '.app_state.gov.params.voting_period="10s" | .app_state.gov.params.expedited_voting_period="5s"'
jqi '.app_state.staking.params.bond_denom="apoa" | .app_state.staking.params.unbonding_time="60s"'
jqi '.app_state.feemarket.params.base_fee="0" | .app_state.feemarket.params.no_base_fee=true'
jqi '.app_state.bank.denom_metadata=[{"description":"XRP is the gas token","denom_units":[{"denom":"axrp"},{"denom":"xrp","exponent":18}],"base":"axrp","display":"xrp","name":"XRP","symbol":"XRP"}]'
jqi '.app_state.erc20.native_precompiles=["0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"]'
jqi '.app_state.erc20.token_pairs=[{contract_owner:1,erc20_address:"0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",denom:"axrp",enabled:true}]'
jqi '.app_state.slashing.params.slash_fraction_double_sign="0" | .app_state.slashing.params.slash_fraction_downtime="0"'

for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  addr="$("$BIN" keys show "val$i" -a $KR --home "$(home "$i")")"
  "$BIN" genesis add-genesis-account "$addr" 1000000apoa,1000000000000000000000000axrp --home "$(home 0)"
done
attacker="$("$BIN" keys show attacker -a $KR --home "$(home 0)")"
"$BIN" genesis add-genesis-account "$attacker" 1000000000000000000000000axrp --home "$(home 0)"

mkdir -p "$(home 0)/config/gentx"
for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  [ "$i" -eq 0 ] || cp "$G" "$(home "$i")/config/genesis.json"
  "$BIN" genesis gentx "val$i" 1000000apoa --gas-prices 0axrp $KR --chain-id "$LAB_CHAIN_ID" \
    --home "$(home "$i")" --output-document "$(home 0)/config/gentx/val$i.json" >/dev/null 2>&1
done
"$BIN" genesis collect-gentxs --home "$(home 0)" >/dev/null 2>&1
"$BIN" genesis validate --home "$(home 0)"

peers=""
for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  id="$("$BIN" comet show-node-id --home "$(home "$i")")"
  peers+="${peers:+,}$id@val$i:26656"
done

for i in $(seq 0 $((NUM_VALIDATORS - 1))); do
  h="$(home "$i")"
  [ "$i" -eq 0 ] || cp "$G" "$h/config/genesis.json"
  # Only the lab validators as peers: no seeds, no peer exchange.
  sed -i \
    -e "s|^persistent_peers = .*|persistent_peers = \"$peers\"|" \
    -e 's|^seeds = .*|seeds = ""|' \
    -e 's|^pex = .*|pex = false|' \
    -e 's|^addr_book_strict = .*|addr_book_strict = false|' \
    -e 's|^laddr = "tcp://127.0.0.1:26657"|laddr = "tcp://0.0.0.0:26657"|' \
    "$h/config/config.toml"
  sed -i \
    -e '/^\[json-rpc\]/,/^\[/ s|^enable = .*|enable = true|' \
    -e '/^\[json-rpc\]/,/^\[/ s|^address = .*|address = "0.0.0.0:8545"|' \
    "$h/config/app.toml"
done

# Hand the PoC runner the attacker key (a throwaway devnet key).
"$BIN" keys unsafe-export-eth-key attacker $KR --home "$(home 0)" >"$OUT/attacker.key"
echo "devnet ready in $OUT (chain $LAB_CHAIN_ID, $NUM_VALIDATORS validators)"
