# Security lab rules for coding agents

You are working in an isolated security lab for the XRPL EVM node. The goal is
to find and prove bugs **locally**. These rules are not optional.

## Layout

- `src/node`, `src/evm`, `src/cometbft`: the three codebases, wired together by
  `go.work`. Edits in `src/evm` or `src/cometbft` are used by the next build.
- `poc-go/`: in-process Go tests (no network). Reproduce every finding here first.
- `poc-evm/`: EVM PoCs, only ever run through `scripts/run-poc.sh` in the
  `poc-runner` container.

## Hard rules

1. Never send a transaction or RPC request to anything except the lab devnet
   (`val0`..`val3`, chain `xrplevm_1449999-1`, EVM chain id `1449999`).
   Mainnet (`1440000`), testnet (`1449000`) and devnet (`1449900`) are off limits,
   including read-only calls.
2. Never run `cast send`, `forge script --broadcast` or similar directly. Use
   `docker compose exec poc-runner scripts/run-poc.sh ...`, which checks the
   chain id first.
3. Never ask for, read or store real private keys or mnemonics.
4. A finding is only real when a test in `poc-go/` (or a PoC in `poc-evm/`)
   reproduces it. Report unreproduced ideas as hypotheses, not findings.
5. Never commit or push findings, PoCs or fixes to a public repository or
   post them anywhere public. They stay in this lab until disclosed privately.

## Commands

- Build: `./setup.sh` (first time) or `scripts/build.sh` (after edits)
- In-process tests: `scripts/test.sh` (optionally a `-run` regex)
- Devnet: `scripts/devnet-init.sh && docker compose up -d`
- Guard check: `docker compose exec poc-runner scripts/guard.sh http://val0:8545 http://val0:26657`

## Where to look first

State sync between the EVM StateDB and Cosmos stores:
`src/evm/x/vm/statedb/`, `src/evm/precompiles/common/balance_handler.go`,
`src/evm/x/vm/keeper/statedb.go`, the xrplevm-specific ERC20 changes in
`src/evm/x/erc20/keeper/{mint,burn,transfer_ownership,msg_server}.go` and
`src/evm/precompiles/erc20/`, and precompile wiring in `src/node/app/`.
