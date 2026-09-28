package integration

// Lab-only tests. setup.sh links this file into src/node/tests/integration so
// it runs against the in-process network: no ports, no peers, no real chains.
//
// Use it as the template for every AI finding: reproduce the bug here first,
// fix it in src/evm or src/cometbft, and keep the test as a regression guard.

import (
	"math/big"
	"testing"

	sdkmath "cosmossdk.io/math"
	banktypes "github.com/cosmos/cosmos-sdk/x/bank/types"
	evmtypes "github.com/cosmos/evm/x/vm/types"
	"github.com/stretchr/testify/suite"
	"github.com/xrplevm/node/v10/app"
)

type LabSuite struct {
	TestSuite
}

func TestLabSuite(t *testing.T) {
	suite.Run(t, new(LabSuite))
}

// requireBankEVMConsistent checks that, for every test account, the balance
// the EVM sees equals the spendable balance in x/bank. A mismatch is exactly
// the StateDB <-> bank desync behind GHSA-7g4w and GHSA-367m.
func (s *LabSuite) requireBankEVMConsistent() {
	ctx := s.network.GetContext()
	for i := range s.keyring.GetKeys() {
		acc := s.keyring.GetAccAddr(i)

		bankRes, err := s.network.GetBankClient().SpendableBalanceByDenom(ctx,
			&banktypes.QuerySpendableBalanceByDenomRequest{Address: acc.String(), Denom: app.BaseDenom})
		s.Require().NoError(err)

		evmRes, err := s.network.GetEvmClient().Balance(ctx,
			&evmtypes.QueryBalanceRequest{Address: s.keyring.GetAddr(i).Hex()})
		s.Require().NoError(err)

		s.Require().Equal(bankRes.Balance.Amount.String(), evmRes.Balance,
			"bank and EVM balances diverged for account %d (%s)", i, acc)
	}
}

func (s *LabSuite) totalSupply() sdkmath.Int {
	res, err := s.network.GetBankClient().SupplyOf(s.network.GetContext(),
		&banktypes.QuerySupplyOfRequest{Denom: app.BaseDenom})
	s.Require().NoError(err)
	return res.Amount.Amount
}

// TestLab_TransferKeepsInvariants is the baseline: a plain EVM value transfer
// must not create or destroy supply and must leave bank and EVM in agreement.
func (s *LabSuite) TestLab_TransferKeepsInvariants() {
	s.requireBankEVMConsistent()
	supplyBefore := s.totalSupply()

	to := s.keyring.GetAddr(1)
	res, err := s.factory.ExecuteEthTx(s.keyring.GetPrivKey(0), evmtypes.EvmTxArgs{
		To:     &to,
		Amount: big.NewInt(1_000_000),
	})
	s.Require().NoError(err)
	s.Require().True(res.IsOK(), "tx failed: %s", res.Log)
	s.Require().NoError(s.network.NextBlock())

	s.requireBankEVMConsistent()
	s.Require().True(supplyBefore.Equal(s.totalSupply()), "total supply changed")
}

// TestLab_PoCTemplate is where a finding gets reproduced. Replace the body
// with the attack steps (deploy the malicious contract, call the precompile,
// revert, ...) and keep the invariant checks at the end.
func (s *LabSuite) TestLab_PoCTemplate() {
	s.T().Skip("template: copy this test and fill in the attack steps")

	s.requireBankEVMConsistent()
	supplyBefore := s.totalSupply()

	// attack steps go here

	s.Require().NoError(s.network.NextBlock())
	s.requireBankEVMConsistent()
	s.Require().True(supplyBefore.Equal(s.totalSupply()), "total supply changed")
}
