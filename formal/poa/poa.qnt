// -*- mode: Bluespec; -*-
/**
 * Formal model of the x/poa module (validator add / remove / self-remove)
 * together with the slice of x/bank and x/staking it touches.
 *
 * The model mirrors x/poa/keeper/keeper.go step by step; every guard and
 * every effect cites the Go code it stands for. Token amounts are
 * abstract: POWER stands for sdk.DefaultPowerReduction (10^18 base units).
 *
 * Checked properties (see formal/README.md for how to run them):
 *   - authorityGate        only the authority changes the bonded set,
 *                          except a validator removing itself
 *   - supplyConserved      supply == liquid balances + both staking pools
 *   - poolsConsistent      each pool holds exactly the tokens it should
 *   - maxValidators        |validators| <= MAX_VALIDATORS
 *   - onlySelfDelegation   validators are only self-delegated, which is
 *                          what lets RemoveValidator's Unbond succeed
 */
module poa {
  // ---------------------------------------------------------------- types
  type Addr = str
  type Status = Bonded | Unbonding
  type Validator = { status: Status, tokens: int, shares: int }
  type Tx = { kind: str, signer: Addr, target: Addr, ok: bool }
  type State = {
    balance: Addr -> int, validators: Addr -> Validator,
    delegations: (Addr, Addr) -> int, unbondings: (Addr, Addr) -> int,
    bondedPool: int, notBondedPool: int, supply: int,
  }

  // ------------------------------------------------------------ constants
  pure val AUTHORITY = "gov"                 // keeper.authority (gov module account)
  pure val USERS = Set("alice", "bob", "carol", "dave")
  pure val SIGNERS = USERS.union(Set(AUTHORITY))
  pure val POWER = 2                         // sdk.DefaultPowerReduction, abstracted
  pure val MAX_VALIDATORS = 3                // staking params.MaxValidators

  // The Cosmos ante chain (x/poa/ante PoaDecorator) rejects MsgDelegate and
  // MsgUndelegate, so in the deployed configuration they are unreachable.
  // Instance `stakingReachable` (end of file) sets this to true to model a
  // path that reaches x/staking without going through that decorator; the
  // checker then reports how the invariants break.
  const STAKING_MSGS_REACHABLE: bool

  // ---------------------------------------------------------------- state
  var balance: Addr -> int                   // liquid bond-denom balance (x/bank)
  var validators: Addr -> Validator          // x/staking validators, keyed by operator
  var delegations: (Addr, Addr) -> int       // (delegator, validator) -> shares
  var unbondings: (Addr, Addr) -> int        // (delegator, validator) -> tokens unbonding
  var bondedPool: int                        // stakingtypes.BondedPoolName
  var notBondedPool: int                     // stakingtypes.NotBondedPoolName
  var supply: int                            // bank total supply of the bond denom

  // ghost state, used only by the step properties
  var lastTx: Tx
  var prev: State                            // all state before lastTx

  // -------------------------------------------------------------- helpers
  pure def sum(s: Set[a], f: a => int): int = s.fold(0, (acc, x) => acc + f(x))
  pure def without(m: a -> b, k: a): a -> b = m.keys().exclude(Set(k)).mapBy(x => m.get(x))
  pure def getOr(m: a -> int, k: a): int = if (m.keys().contains(k)) m.get(k) else 0

  pure def bondedOf(vs: Addr -> Validator): Set[Addr] = vs.keys().filter(v => vs.get(v).status == Bonded)
  def bondedSet: Set[Addr] = bondedOf(validators)
  def prevBonded: Set[Addr] = bondedOf(prev.validators)
  def snapshot: State = {
    balance: balance, validators: validators, delegations: delegations,
    unbondings: unbondings, bondedPool: bondedPool, notBondedPool: notBondedPool,
    supply: supply,
  }
  def isValidator(v: Addr): bool = validators.keys().contains(v)
  def tokensOf(v: Addr): int = if (isValidator(v)) validators.get(v).tokens else 0

  // Effects shared by every transaction: record it, remember the state before it.
  action record(kind: str, signer: Addr, target: Addr, ok: bool): bool = all {
    lastTx' = { kind: kind, signer: signer, target: target, ok: ok },
    prev' = snapshot,
  }

  // A transaction that fails is reverted: no state change except the record.
  action reject(kind: str, signer: Addr, target: Addr): bool = all {
    balance' = balance, validators' = validators, delegations' = delegations,
    unbondings' = unbondings, bondedPool' = bondedPool,
    notBondedPool' = notBondedPool, supply' = supply,
    record(kind, signer, target, false),
  }

  // ----------------------------------------------------------------- init
  // Genesis: alice and bob are bonded validators, self-delegated with POWER.
  pure val GENESIS: State = {
    balance: USERS.mapBy(_ => 0),
    validators: Set("alice", "bob").mapBy(_ => { status: Bonded, tokens: POWER, shares: POWER }),
    delegations: Map(("alice", "alice") -> POWER, ("bob", "bob") -> POWER),
    unbondings: Map(),
    bondedPool: 2 * POWER,
    notBondedPool: 0,
    supply: 2 * POWER,
  }

  action init = all {
    balance' = GENESIS.balance,
    validators' = GENESIS.validators,
    delegations' = GENESIS.delegations,
    unbondings' = GENESIS.unbondings,
    bondedPool' = GENESIS.bondedPool,
    notBondedPool' = GENESIS.notBondedPool,
    supply' = GENESIS.supply,
    lastTx' = { kind: "genesis", signer: AUTHORITY, target: AUTHORITY, ok: true },
    prev' = GENESIS,
  }

  // --------------------------------------------------- x/poa: AddValidator
  // msg_server_add_validator.go + Keeper.ExecuteAddValidator
  def canAdd(v: Addr): bool = and {
    validators.keys().size() < MAX_VALIDATORS,                  // ErrMaxValidatorsReached
    balance.get(v) == 0,                                        // ErrAddressHasBankTokens
    tokensOf(v) == 0,                                           // ErrAddressHasBondedTokens
    validators.keys().forall(w =>                               // ErrAddressHasDelegatedTokens
      getOr(delegations, (v, w)) == 0 or tokensOf(w) == 0),
    validators.keys().forall(w => getOr(unbondings, (v, w)) == 0), // ErrAddressHasUnbondingTokens
    not(isValidator(v)),                                        // MsgCreateValidator: already exists
  }

  action addValidator(signer: Addr, v: Addr): bool =
    if (signer != AUTHORITY or not(canAdd(v)))                  // k.authority != msg.Authority
      reject("add", signer, v)
    else all {
      supply' = supply + POWER,                                 // MintCoins(POWER)
      balance' = balance,                                       // minted to v, then fully bonded
      bondedPool' = bondedPool + POWER,                         // MsgCreateValidator self-bond
      notBondedPool' = notBondedPool,
      validators' = validators.put(v, { status: Bonded, tokens: POWER, shares: POWER }),
      delegations' = delegations.put((v, v), POWER),
      unbondings' = unbondings,
      record("add", signer, v, true),
    }

  // ------------------------------------------------ x/poa: RemoveValidator
  // Keeper.ExecuteRemoveValidator
  action doRemove(kind: str, signer: Addr, v: Addr): bool = {
    val vd = validators.get(v)
    // SlashUnbondingDelegation(ubd, 0, 1.0) burns every unbonding entry of v
    val slashed = unbondings.keys().filter(k => k._2 == v)
    val slashedAmt = sum(slashed, k => unbondings.get(k))
    // Unbond(acc, val, changedVal.DelegatorShares) fails with
    // ErrNoDelegatorForAddress if the self-delegation is gone (validator
    // already removed), and with ErrNotEnoughDelegationShares unless the
    // self-delegation holds all of the validator's shares.
    val unbondOk = delegations.keys().contains((v, v)) and delegations.get((v, v)) >= vd.shares
    if (not(unbondOk))
      reject(kind, signer, v)
    else all {
      // RemoveValidatorTokens + BurnCoins from the pool matching the status
      bondedPool' = if (vd.status == Bonded) bondedPool - vd.tokens else bondedPool,
      notBondedPool' = notBondedPool - slashedAmt
                       - (if (vd.status == Unbonding) vd.tokens else 0),
      supply' = supply - slashedAmt - vd.tokens,
      balance' = balance,
      unbondings' = unbondings.keys().exclude(slashed).mapBy(k => unbondings.get(k)),
      delegations' = delegations.without((v, v)),
      validators' = validators.put(v, { status: Unbonding, tokens: 0, shares: 0 }),
      record(kind, signer, v, true),
    }
  }

  action removeValidator(signer: Addr, v: Addr): bool =
    if (signer != AUTHORITY or not(isValidator(v)))             // ErrInvalidSigner / ErrAddressIsNotAValidator
      reject("remove", signer, v)
    else doRemove("remove", signer, v)

  // --------------------------------------------- x/poa: SelfRemoveValidator
  // msg_server_self_remove_validator.go: no authority check; the tx signer
  // (msg.Address, enforced by GetSigners) removes its own validator.
  action selfRemoveValidator(signer: Addr): bool =
    if (not(isValidator(signer)))
      reject("selfRemove", signer, signer)
    else doRemove("selfRemove", signer, signer)

  // ------------------------------------------------------ time passes
  // Staking EndBlocker: a mature unbonding entry pays out to the delegator.
  action completeUnbonding(d: Addr, v: Addr): bool = all {
    unbondings.keys().contains((d, v)),
    val amt = unbondings.get((d, v))
    all {
      balance' = balance.setBy(d, b => b + amt),
      notBondedPool' = notBondedPool - amt,
      unbondings' = unbondings.without((d, v)),
      bondedPool' = bondedPool, supply' = supply,
      validators' = validators, delegations' = delegations,
      record("completeUnbonding", d, v, true),
    }
  }

  // Staking EndBlocker: an unbonding validator with no shares is deleted.
  action deleteMatureValidator(v: Addr): bool = all {
    isValidator(v),
    validators.get(v).status == Unbonding,
    validators.get(v).shares == 0,
    validators' = validators.without(v),
    balance' = balance, delegations' = delegations, unbondings' = unbondings,
    bondedPool' = bondedPool, notBondedPool' = notBondedPool, supply' = supply,
    record("deleteValidator", v, v, true),
  }

  // -------------------------------- x/staking messages (blocked by ante)
  action delegate(d: Addr, v: Addr): bool = all {
    STAKING_MSGS_REACHABLE,
    isValidator(v), validators.get(v).status == Bonded,
    balance.get(d) >= 1,
    balance' = balance.setBy(d, b => b - 1),
    bondedPool' = bondedPool + 1,
    validators' = validators.setBy(v, x => { ...x, tokens: x.tokens + 1, shares: x.shares + 1 }),
    delegations' = delegations.put((d, v), getOr(delegations, (d, v)) + 1),
    notBondedPool' = notBondedPool, unbondings' = unbondings, supply' = supply,
    record("delegate", d, v, true),
  }

  action undelegate(d: Addr, v: Addr): bool = all {
    STAKING_MSGS_REACHABLE,
    isValidator(v), validators.get(v).status == Bonded,
    getOr(delegations, (d, v)) >= 1,
    validators.get(v).shares >= 2,     // keep the validator alive (min self-delegation)
    delegations' = delegations.put((d, v), delegations.get((d, v)) - 1),
    validators' = validators.setBy(v, x => { ...x, tokens: x.tokens - 1, shares: x.shares - 1 }),
    bondedPool' = bondedPool - 1,
    notBondedPool' = notBondedPool + 1,
    unbondings' = unbondings.put((d, v), getOr(unbondings, (d, v)) + 1),
    balance' = balance, supply' = supply,
    record("undelegate", d, v, true),
  }

  // ----------------------------------------------------------------- step
  action step = {
    nondet signer = SIGNERS.oneOf()
    nondet user = USERS.oneOf()
    nondet other = USERS.oneOf()
    any {
      addValidator(signer, user),
      removeValidator(signer, user),
      selfRemoveValidator(user),
      completeUnbonding(user, other),
      deleteMatureValidator(user),
      delegate(user, other),
      undelegate(user, other),
    }
  }

  // ----------------------------------------------------------- properties
  /// Only the authority may change the bonded validator set; the single
  /// exception is a validator removing itself (and nobody else).
  val authorityGate =
    bondedSet != prevBonded implies or {
      lastTx.signer == AUTHORITY,
      lastTx.kind == "selfRemove" and prevBonded.exclude(bondedSet) == Set(lastTx.signer)
                                  and bondedSet.subseteq(prevBonded),
    }

  /// A failed (reverted) transaction changes no state at all.
  val rejectedTxHasNoEffect = not(lastTx.ok) implies snapshot == prev

  /// No inflation, no lost funds: every bond-denom token is somewhere.
  val supplyConserved = supply == sum(USERS, u => balance.get(u)) + bondedPool + notBondedPool

  /// Each pool holds exactly the tokens it is accountable for.
  val poolsConsistent = and {
    bondedPool == sum(bondedSet, v => validators.get(v).tokens),
    notBondedPool == sum(validators.keys().exclude(bondedSet), v => validators.get(v).tokens)
                     + sum(unbondings.keys(), k => unbondings.get(k)),
  }

  val maxValidators = validators.keys().size() <= MAX_VALIDATORS

  val noNegativeAmounts = and {
    bondedPool >= 0, notBondedPool >= 0, supply >= 0,
    USERS.forall(u => balance.get(u) >= 0),
  }

  /// A bonded validator's shares all belong to its operator. This is the
  /// precondition for RemoveValidator's final Unbond call, i.e. for the
  /// authority to always be able to remove any validator.
  val onlySelfDelegation =
    bondedSet.forall(v => getOr(delegations, (v, v)) == validators.get(v).shares)

  val invariants = and {
    authorityGate, rejectedTxHasNoEffect, supplyConserved,
    poolsConsistent, maxValidators, noNegativeAmounts, onlySelfDelegation,
  }

  // ------------------------------------------------- reachability witnesses
  // These are expected to be VIOLATED: a violation is a trace showing the
  // behaviour is reachable, so the invariants above are not vacuous.
  val witnessNoSelfRemove = not(lastTx.kind == "selfRemove" and lastTx.ok)
  val witnessNeverFull = validators.keys().size() < MAX_VALIDATORS
}

/// The deployed configuration: the ante handler blocks x/staking messages.
module deployed {
  import poa(STAKING_MSGS_REACHABLE = false).*
}

/// What-if: delegate/undelegate reach x/staking (e.g. a path that skips the
/// Cosmos ante chain). Expected to violate onlySelfDelegation.
module stakingReachable {
  import poa(STAKING_MSGS_REACHABLE = true).*
}
