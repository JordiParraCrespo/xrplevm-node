# XRPL EVM security lab

A local workspace for finding and proving bugs across the three codebases that
make up the node, without any chance of touching mainnet or testnet.

```
security-lab/
├── src/node       xrplevm/node        (NODE_REF in lab.env, default main)
├── src/evm        xrplevm/evm         (version pinned by node/go.mod)
├── src/cometbft   cometbft/cometbft   (version pinned by node/go.mod)
├── go.work        points node at the local evm and cometbft checkouts
├── poc-go/        in-process Go tests: no ports, no network
├── poc-evm/       Solidity PoCs, run only on the isolated devnet
└── docker-compose.yml   4-validator devnet on an internal-only network
```

## Setup

Requires Go, git, jq and Docker.

```sh
./setup.sh                          # clone the three repos, write go.work, build bin/exrpd
scripts/test.sh                     # run the in-process lab tests
docker compose run --rm fetch-solc  # one time: download solc into a shared volume
scripts/devnet-init.sh              # fresh genesis and throwaway keys in .devnet/
docker compose up -d                # start the isolated devnet and poc-runner
```

After editing anything under `src/`, run `scripts/build.sh` and restart the
devnet (`docker compose restart`), or just rerun `scripts/test.sh`.

## Workflow for a finding

1. **Reproduce in-process.** Copy `TestLab_PoCTemplate` in
   `poc-go/invariants_test.go`, write the attack steps, and run
   `scripts/test.sh TestLab_MyFinding`. The invariant helpers check that bank
   and EVM balances agree and that total supply is unchanged.
2. **Reproduce on the devnet if needed** (multi-validator behaviour, real
   JSON-RPC, Solidity contracts):
   `docker compose exec poc-runner scripts/run-poc.sh forge create poc-evm/MyPoC.sol:PoC --broadcast`
3. **Fix** in `src/evm`, `src/cometbft` or `src/node`, rebuild, and confirm
   the same test now passes. Keep the test as a regression guard.
4. **Disclose privately** (GitHub private security advisory). Nothing from
   `poc-go/` or `poc-evm/` other than the templates is tracked by git.

## Why nothing can reach a real network

| Layer | Protection |
|---|---|
| Network | The `lab` Docker network is `internal: true`: no route or DNS to the internet, and no ports published to the host. |
| Guard | `scripts/run-poc.sh` runs `scripts/guard.sh` first: only `val*`/localhost hosts, only EVM chain id `1449999` and chain `xrplevm_1449999-1`; mainnet, testnet and devnet ids are hard-denied. |
| Keys | Every key is generated fresh by `devnet-init.sh`. No mnemonic is recovered, so nothing in the lab can sign for a real account. |
| Agents | `AGENTS.md`/`CLAUDE.md` rules plus `opencode.json` permissions deny `cast send`, `forge script`, `git push` and any `xrplevm.org` host. These are a second line; the network is the first. |

The in-process tests in `poc-go/` do not open sockets at all.

## Coding agents

The same rules file works for both agents:

- **opencode + GLM-5.3 (DeepInfra):** `export DEEPINFRA_API_KEY=...` and run
  `opencode` from this directory. `opencode.json` selects `zai-org/GLM-5.3`
  and sets the permissions.
- **Claude Code:** run `claude` from this directory; `CLAUDE.md` imports
  `AGENTS.md`.

Run agents from `security-lab/` so they see the rules and all three codebases.
