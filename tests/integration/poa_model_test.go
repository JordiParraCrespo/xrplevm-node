package integration

import (
	"fmt"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"time"

	sdkmath "cosmossdk.io/math"
	storetypes "cosmossdk.io/store/types"
	"github.com/cosmos/cosmos-sdk/crypto/keys/ed25519"
	"github.com/cosmos/cosmos-sdk/crypto/keys/secp256k1"
	sdktypes "github.com/cosmos/cosmos-sdk/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	stakingtypes "github.com/cosmos/cosmos-sdk/x/staking/types"
	poakeeper "github.com/xrplevm/node/v12/x/poa/keeper"
	poatypes "github.com/xrplevm/node/v12/x/poa/types"
)

// Model-based test of x/poa against the real app keepers.
//
// It runs random sequences of AddValidator, RemoveValidator,
// SelfRemoveValidator and "time passes" (staking EndBlocker), predicts the
// outcome of every step with a small reference model that mirrors
// formal/poa/poa.qnt, and after every step checks that the chain agrees
// with the model and that the invariants of the spec hold.
//
// Staking's own lifecycle (bonding, maturing, deleting validators) is not
// under test here: the model reads validator existence and liquid balances
// from the chain and owns only what x/poa decides (who may act, what is
// minted and burned).
//
// POA_MODEL_SEED=<n> runs a single seed; POA_MODEL_STEPS=<n> sets the
// number of steps per run.

const (
	poaModelDefaultSteps = 60
	poaModelFreshActors  = 3
)

type poaModel struct {
	authority string
	supply    sdkmath.Int            // bond-denom supply the model expects
	tokens    map[string]sdkmath.Int // operator -> tokens x/poa gave it
	selfDel   map[string]bool        // operator -> still holds its self-delegation
}

type poaHarness struct {
	s      *TestSuite
	ctx    sdktypes.Context
	srv    poatypes.MsgServer
	denom  string
	maxVal uint32
	model  *poaModel
	actors []sdktypes.AccAddress
	// coverage: "<msg> ok" / "<msg> rejected" -> count
	coverage map[string]int
}

func (s *TestSuite) TestPoaModelBased() {
	seeds := []int64{1, 2, 3, 4, 5}
	if v := os.Getenv("POA_MODEL_SEED"); v != "" {
		seed, err := strconv.ParseInt(v, 10, 64)
		s.Require().NoError(err)
		seeds = []int64{seed}
	}
	steps := poaModelDefaultSteps
	if v := os.Getenv("POA_MODEL_STEPS"); v != "" {
		n, err := strconv.Atoi(v)
		s.Require().NoError(err)
		steps = n
	}

	for _, seed := range seeds {
		s.Run(fmt.Sprintf("seed=%d", seed), func() {
			s.SetupTest()
			h := newPoaHarness(s)
			rng := rand.New(rand.NewSource(seed)) //nolint:gosec
			for i := 0; i < steps; i++ {
				desc := h.randomStep(rng)
				h.checkInvariants(fmt.Sprintf("seed=%d step=%d %s", seed, i, desc))
			}
			s.T().Logf("coverage: %v", h.coverage)
			// Guard against a vacuous run that only exercised rejections.
			for _, kind := range []string{"AddValidator ok", "AddValidator rejected", "RemoveValidator ok", "RemoveValidator rejected"} {
				s.Require().Positive(h.coverage[kind], "%s never happened; increase POA_MODEL_STEPS", kind)
			}
		})
	}
}

func newPoaHarness(s *TestSuite) *poaHarness {
	n := s.Network()
	ctx := n.GetContext().WithGasMeter(storetypes.NewInfiniteGasMeter())
	sk := n.StakingKeeper()
	pk := n.PoaKeeper()

	params, err := sk.GetParams(ctx)
	s.Require().NoError(err)

	h := &poaHarness{
		s:        s,
		ctx:      ctx,
		srv:      poakeeper.NewMsgServerImpl(pk),
		denom:    params.BondDenom,
		maxVal:   params.MaxValidators,
		coverage: map[string]int{},
		model: &poaModel{
			authority: pk.GetAuthority(),
			supply:    n.BankKeeper().GetSupply(ctx, params.BondDenom).Amount,
			tokens:    map[string]sdkmath.Int{},
			selfDel:   map[string]bool{},
		},
	}

	// Actors: the genesis validator operators plus a few fresh accounts.
	vals, err := sk.GetAllValidators(ctx)
	s.Require().NoError(err)
	for _, v := range vals {
		valAddr, err := sdktypes.ValAddressFromBech32(v.OperatorAddress)
		s.Require().NoError(err)
		acc := sdktypes.AccAddress(valAddr)
		h.actors = append(h.actors, acc)
		h.model.tokens[acc.String()] = v.Tokens
		_, err = sk.GetDelegation(ctx, acc, valAddr)
		h.model.selfDel[acc.String()] = err == nil
	}
	for i := 0; i < poaModelFreshActors; i++ {
		priv := secp256k1.GenPrivKeyFromSecret([]byte(fmt.Sprintf("poa-model-actor-%d", i)))
		h.actors = append(h.actors, sdktypes.AccAddress(priv.PubKey().Address()))
	}

	h.checkInvariants("genesis")
	return h
}

// ------------------------------------------------------------------ steps

func (h *poaHarness) randomStep(rng *rand.Rand) string {
	actor := h.actors[rng.Intn(len(h.actors))]
	// Half of the authority-gated messages are signed by the authority, the
	// other half by a random actor.
	signer := h.model.authority
	if rng.Intn(2) == 0 {
		signer = h.actors[rng.Intn(len(h.actors))].String()
	}

	switch rng.Intn(5) {
	case 0, 1:
		return h.addValidator(signer, actor)
	case 2:
		return h.removeValidator(signer, actor)
	case 3:
		return h.selfRemoveValidator(actor)
	default:
		return h.passTime()
	}
}

func (h *poaHarness) addValidator(signer string, acc sdktypes.AccAddress) string {
	desc := fmt.Sprintf("AddValidator(signer=%s, %s)", h.short(signer), h.short(acc.String()))
	vals := h.allValidators()

	// Model: msg_server_add_validator.go + Keeper.ExecuteAddValidator
	want := signer == h.model.authority &&
		uint32(len(vals)) < h.maxVal && //nolint:gosec
		h.liquid(acc).IsZero() &&
		!h.validatorExists(acc)

	msg, err := poatypes.NewMsgAddValidator(signer, acc.String(), ed25519.GenPrivKey().PubKey(),
		stakingtypes.Description{Moniker: "model"})
	h.s.Require().NoError(err)
	got := h.deliver(func(ctx sdktypes.Context) error {
		_, err := h.srv.AddValidator(ctx, msg)
		return err
	})
	h.expect(desc, want, got)

	if want {
		h.model.supply = h.model.supply.Add(sdktypes.DefaultPowerReduction)
		h.model.tokens[acc.String()] = sdktypes.DefaultPowerReduction
		h.model.selfDel[acc.String()] = true
	}
	return desc
}

func (h *poaHarness) removeValidator(signer string, acc sdktypes.AccAddress) string {
	desc := fmt.Sprintf("RemoveValidator(signer=%s, %s)", h.short(signer), h.short(acc.String()))
	want := signer == h.model.authority && h.canRemove(acc)

	msg := poatypes.NewMsgRemoveValidator(signer, acc.String())
	got := h.deliver(func(ctx sdktypes.Context) error {
		_, err := h.srv.RemoveValidator(ctx, msg)
		return err
	})
	h.expect(desc, want, got)
	if want {
		h.applyRemove(acc)
	}
	return desc
}

// SelfRemoveValidator has no authority check: the signer (msg.Address,
// enforced by the tx's GetSigners) removes its own validator.
func (h *poaHarness) selfRemoveValidator(acc sdktypes.AccAddress) string {
	desc := fmt.Sprintf("SelfRemoveValidator(%s)", h.short(acc.String()))
	want := h.canRemove(acc)

	msg := poatypes.NewMsgSelfRemoveValidator(acc.String())
	got := h.deliver(func(ctx sdktypes.Context) error {
		_, err := h.srv.SelfRemoveValidator(ctx, msg)
		return err
	})
	h.expect(desc, want, got)
	if want {
		h.applyRemove(acc)
	}
	return desc
}

// passTime moves past the unbonding period and runs the staking EndBlocker,
// which bonds new validators and deletes matured ones.
func (h *poaHarness) passTime() string {
	params, err := h.s.Network().StakingKeeper().GetParams(h.ctx)
	h.s.Require().NoError(err)
	h.ctx = h.ctx.
		WithBlockHeight(h.ctx.BlockHeight() + 1).
		WithBlockTime(h.ctx.BlockTime().Add(params.UnbondingTime + time.Second))
	_, err = h.s.Network().StakingKeeper().EndBlocker(h.ctx)
	h.s.Require().NoError(err)
	return "PassTime"
}

// Model: Keeper.ExecuteRemoveValidator. The final Unbond needs the
// self-delegation to exist and to hold all of the validator's shares.
func (h *poaHarness) canRemove(acc sdktypes.AccAddress) bool {
	return h.validatorExists(acc) && h.model.selfDel[acc.String()]
}

func (h *poaHarness) applyRemove(acc sdktypes.AccAddress) {
	h.model.supply = h.model.supply.Sub(h.model.tokens[acc.String()])
	h.model.tokens[acc.String()] = sdkmath.ZeroInt()
	h.model.selfDel[acc.String()] = false
}

// deliver runs fn like a transaction: its writes are kept only on success.
func (h *poaHarness) deliver(fn func(sdktypes.Context) error) error {
	cctx, write := h.ctx.CacheContext()
	err := fn(cctx)
	if err == nil {
		write()
	}
	return err
}

func (h *poaHarness) expect(desc string, want bool, got error) {
	kind := desc[:strings.IndexByte(desc, '(')]
	if got == nil {
		h.coverage[kind+" ok"]++
	} else {
		h.coverage[kind+" rejected"]++
	}
	if want {
		h.s.Require().NoError(got, "%s: model expected success", desc)
	} else {
		h.s.Require().Error(got, "%s: model expected failure", desc)
	}
}

// ------------------------------------------------------------- invariants

// checkInvariants checks the chain against the model and the properties of
// formal/poa/poa.qnt.
func (h *poaHarness) checkInvariants(where string) {
	r := h.s.Require()
	bk := h.s.Network().BankKeeper()
	sk := h.s.Network().StakingKeeper()

	// Model agreement: x/poa minted and burned exactly what the model says.
	supply := bk.GetSupply(h.ctx, h.denom).Amount
	r.True(h.model.supply.Equal(supply), "%s: supply %s, model expects %s", where, supply, h.model.supply)

	// supplyConserved: every bond-denom token is in some account.
	held := sdkmath.ZeroInt()
	bk.IterateAllBalances(h.ctx, func(_ sdktypes.AccAddress, c sdktypes.Coin) bool {
		if c.Denom == h.denom {
			held = held.Add(c.Amount)
		}
		return false
	})
	r.True(supply.Equal(held), "%s: supply %s != sum of balances %s", where, supply, held)

	// poolsConsistent: each pool holds exactly what it is accountable for.
	vals := h.allValidators()
	bonded, notBonded := sdkmath.ZeroInt(), sdkmath.ZeroInt()
	for _, v := range vals {
		if v.IsBonded() {
			bonded = bonded.Add(v.Tokens)
		} else {
			notBonded = notBonded.Add(v.Tokens)
		}
	}
	r.NoError(sk.IterateUnbondingDelegations(h.ctx, func(_ int64, ubd stakingtypes.UnbondingDelegation) bool {
		for _, e := range ubd.Entries {
			notBonded = notBonded.Add(e.Balance)
		}
		return false
	}))
	bondedPool := bk.GetBalance(h.ctx, authtypes.NewModuleAddress(stakingtypes.BondedPoolName), h.denom).Amount
	notBondedPool := bk.GetBalance(h.ctx, authtypes.NewModuleAddress(stakingtypes.NotBondedPoolName), h.denom).Amount
	r.True(bondedPool.Equal(bonded), "%s: bonded pool %s != bonded tokens %s", where, bondedPool, bonded)
	r.True(notBondedPool.Equal(notBonded), "%s: not-bonded pool %s != tokens %s", where, notBondedPool, notBonded)

	// maxValidators
	r.LessOrEqual(uint32(len(vals)), h.maxVal, "%s: too many validators", where) //nolint:gosec

	for _, v := range vals {
		valAddr, err := sdktypes.ValAddressFromBech32(v.OperatorAddress)
		r.NoError(err)
		acc := sdktypes.AccAddress(valAddr)

		// Model agreement: validator tokens are what x/poa gave it.
		if want, ok := h.model.tokens[acc.String()]; ok {
			r.True(v.Tokens.Equal(want), "%s: %s has %s tokens, model expects %s", where, h.short(acc.String()), v.Tokens, want)
		}

		// onlySelfDelegation: the precondition for RemoveValidator to succeed.
		if v.Tokens.IsPositive() {
			del, err := sk.GetDelegation(h.ctx, acc, valAddr)
			r.NoError(err, "%s: %s has tokens but no self-delegation", where, h.short(acc.String()))
			r.True(del.Shares.Equal(v.DelegatorShares), "%s: %s is not only self-delegated", where, h.short(acc.String()))
		}
	}
}

// ---------------------------------------------------------------- helpers

func (h *poaHarness) allValidators() []stakingtypes.Validator {
	vals, err := h.s.Network().StakingKeeper().GetAllValidators(h.ctx)
	h.s.Require().NoError(err)
	return vals
}

func (h *poaHarness) validatorExists(acc sdktypes.AccAddress) bool {
	_, err := h.s.Network().StakingKeeper().GetValidator(h.ctx, sdktypes.ValAddress(acc))
	return err == nil
}

func (h *poaHarness) liquid(acc sdktypes.AccAddress) sdkmath.Int {
	return h.s.Network().BankKeeper().GetBalance(h.ctx, acc, h.denom).Amount
}

func (h *poaHarness) short(addr string) string {
	if addr == h.model.authority {
		return "authority"
	}
	if len(addr) > 12 {
		return addr[len(addr)-6:]
	}
	return addr
}
