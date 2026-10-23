# Formal verification (proof of concept)

This directory holds formal models of the node's consensus-critical logic.
The first model covers `x/poa`, the module that controls the validator set
and mints and burns staking tokens.

The PoC has two halves that check the same properties:

| | What | Where | Run |
|---|---|---|---|
| **Spec** | A [Quint](https://quint-lang.org) state machine of `x/poa` plus the slice of `x/bank` / `x/staking` it touches, with the invariants it must keep | `formal/poa/poa.qnt` | `make formal-check` |
| **Model-based test** | Random message sequences run against the real app keepers. A Go reference model, mirroring the spec, predicts every outcome, and the spec's invariants are checked on chain state after every step | `tests/integration/poa_model_test.go` | `make test-poa-model` |

The spec checks the design against the invariants. The model-based test checks
the Go code against the design. Together they keep the spec from drifting away
from the code.

## Properties

| Invariant | Meaning | Code it protects |
|---|---|---|
| `authorityGate` | Only the authority changes the bonded validator set. The one exception: a validator removing itself, and nobody else | `msg_server_add_validator.go`, `msg_server_remove_validator.go`, `msg_server_self_remove_validator.go` |
| `rejectedTxHasNoEffect` | A failed message changes nothing | all handlers |
| `supplyConserved` | Bond-denom supply == liquid balances + bonded pool + not-bonded pool | `ExecuteAddValidator` (mint), `ExecuteRemoveValidator` (burn) |
| `poolsConsistent` | The bonded pool holds exactly the bonded validators' tokens. The not-bonded pool holds the rest plus unbonding entries | burn from `BondedPoolName` vs `NotBondedPoolName` |
| `maxValidators` | Number of validators <= `MaxValidators` | `ErrMaxValidatorsReached` check |
| `noNegativeAmounts` | No balance or pool goes negative | |
| `onlySelfDelegation` | A bonded validator's shares all belong to its operator. This is the precondition for `RemoveValidator`'s final `Unbond`, so the authority can always remove a validator | `ExecuteRemoveValidator` → `sk.Unbond(..., changedVal.DelegatorShares)` |

The model-based test additionally checks that the chain agrees with the model:
each step succeeds or fails as predicted, total supply matches, and each
validator's tokens match.

## Running

```bash
make formal-check     # typecheck + simulate the spec (Node.js; Quint via npx)
make test-poa-model   # model-based test against the real keepers
make formal-what-if   # print the counterexample of the what-if model (below)
make formal-verify    # exhaustive bounded check with Apalache (Java 17+), not yet run
```

`make formal-check` runs three kinds of check:

1. **Invariants hold** in the deployed configuration (module `deployed`).
2. **Witnesses are reached.** `witnessNoSelfRemove` and `witnessNeverFull` *must*
   be violated. Each violation is a trace proving that self-removal and a full
   validator set actually happen, so the invariants are not true just because
   nothing interesting is reachable.
3. **The what-if model fails as expected** (module `stakingReachable`, below).

The model-based test runs 5 seeds × 60 steps by default and also runs as part
of `make test-integration`. To reproduce or extend a run:
`POA_MODEL_SEED=7 POA_MODEL_STEPS=500 make test-poa-model`.

## The what-if model

`PoaDecorator` (`x/poa/ante/poa.go`) rejects `MsgDelegate`, `MsgUndelegate` and
the other staking messages. In the deployed model those actions are therefore
disabled.

The `stakingReachable` instance enables them. It models any path that reaches
`x/staking` without going through the Cosmos ante chain. The checker then finds
a trace like this one:

1. validator `bob` undelegates part of its self-bond, and the unbonding completes
2. `bob` delegates the liquid tokens to validator `alice`
3. `alice`'s shares are no longer all self-owned (`onlySelfDelegation` fails),
   so `RemoveValidator(alice)` reverts with `ErrNotEnoughDelegationShares`.
   Governance can no longer remove `alice`.

This shows how the spec works as a design tool. `onlySelfDelegation` holds only
because every staking entry point is blocked. A new entry point would silently
break the authority's ability to remove validators, and the model says exactly
how.

## Mutation check

Both halves were checked against deliberately broken code:

| Mutation | Caught by |
|---|---|
| Spec: drop `signer != AUTHORITY` from `addValidator` | `authorityGate` violation |
| Go: drop `k.authority != msg.Authority` from `AddValidator` | model-based test: "model expected failure" |
| Go: burn bonded tokens from `NotBondedPoolName` | model-based test: "model expected success" (burn fails) |

## Limits

- `quint run` is random simulation, not a proof: it samples traces up to
  `QUINT_STEPS` long. `make formal-verify` runs Apalache for an exhaustive
  bounded check; it has not been run in this PoC yet.
- The model abstracts amounts (`POWER = 2` stands for
  `sdk.DefaultPowerReduction`) and folds bonding into a single step. The
  model-based test runs the real staking lifecycle and reads validator
  existence and liquid balances from the chain instead of modelling them.
- The model-based test calls the msg server directly, so signature checks and
  the ante handler are out of its scope. `SelfRemoveValidator`'s signer is
  `msg.Address` by construction.

## Next steps

1. Replay Quint traces (ITF JSON from `quint run --out-itf`) in the Go test,
   instead of the Go generator, so the spec drives the code directly.
2. Model the ante handler's routing (`app/ante/ante.go`) as a decision table
   and prove totality and exclusivity, and that no route skips signature
   verification or fee deduction.
3. A determinism check in CI: no map iteration feeding state writes, no
   goroutines, no `time.Now()` in keeper code.
