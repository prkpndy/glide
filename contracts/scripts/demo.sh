#!/usr/bin/env bash
# End-to-end Glide demo against a local Unichain fork.
#
#   terminal 1:  anvil --fork-url https://mainnet.unichain.org --fork-block-number 58230608 --chain-id 130
#   terminal 2:  ./scripts/demo.sh            # deploy, ship, swap direct, advance time, swap via Uniswap
#
# Uses anvil's default funded accounts: 0 deployer, 1 maker, 2 taker.
# For a non-linear path, ship with a schedule instead (weights in WAD, durations in seconds summing to DURATION), e.g.
#   WEIGHTS=166666666666666666,166666666666666666,700000000000000000 DURATIONS=21600,64800 ... forge script script/Ship.s.sol ...
set -euo pipefail
cd "$(dirname "$0")/.."

export RPC=${RPC:-http://127.0.0.1:8545}
export PRIVATE_KEY=${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
export MAKER_PK=${MAKER_PK:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
export TAKER_PK=${TAKER_PK:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}
MAKER=$(cast wallet address --private-key "$MAKER_PK")
TAKER=$(cast wallet address --private-key "$TAKER_PK")

WETH=0x4200000000000000000000000000000000000006
USDC=0x078D782b760474a361dDA0AF3839290b0EF57AD6

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

seed_usdc() { # seed_usdc <address> <amount>  (FiatTokenV2 balances mapping lives in slot 9)
  local who=$1 amount=$2 slot
  for candidate in 9 0 1 2 3 4 5 6 7 8 10 11 12; do
    slot=$(cast index address "$who" "$candidate")
    cast rpc anvil_setStorageAt "$USDC" "$slot" "$(cast to-uint256 "$amount")" --rpc-url "$RPC" >/dev/null
    if [ "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$who" --rpc-url "$RPC" | cut -d' ' -f1)" = "$amount" ]; then
      return 0
    fi
  done
  echo "could not seed USDC" >&2; exit 1
}

log "seeding balances"
cast send "$WETH" 'deposit()' --value 20ether --private-key "$MAKER_PK" --rpc-url "$RPC" >/dev/null
cast send "$WETH" 'deposit()' --value 20ether --private-key "$TAKER_PK" --rpc-url "$RPC" >/dev/null
seed_usdc "$MAKER" 5000000000      # 5,000 USDC
seed_usdc "$TAKER" 50000000000     # 50,000 USDC
echo "maker WETH $(cast call $WETH 'balanceOf(address)(uint256)' $MAKER --rpc-url $RPC)  USDC $(cast call $USDC 'balanceOf(address)(uint256)' $MAKER --rpc-url $RPC)"

log "deploying router, lens, hook, pool"
forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast 2>&1 | grep -E 'router|lens|hook|swapRouter|written|Error|revert' || true

log "maker ships: 3,000 USDC + 5 WETH, 1 ETH = 3,000 USDC, glide USDC share to 70% over 24h, 0.3% fee"
AMOUNT_A=3000000000 AMOUNT_B=5000000000000000000 PRICE_A=1000000000000000000 PRICE_B=3000000000000000000000 \
END_WEIGHT_A=700000000000000000 DURATION=86400 FEE_BPS=30000 \
forge script script/Ship.s.sol --rpc-url "$RPC" --broadcast 2>&1 | grep -E 'maker|orderHash|wA0|wA1|written|Error|revert' || true

log "taker swaps 300 USDC -> WETH directly through the Glide router"
A_TO_B=true AMOUNT_IN=300000000 VIA=direct forge script script/Swap.s.sol --rpc-url "$RPC" --broadcast 2>&1 | grep -E 'via|amountIn|quoted|received|maker wallet|Error|revert' || true

log "advancing the fork 12 hours"
cast rpc evm_increaseTime 43200 --rpc-url "$RPC" >/dev/null && cast rpc evm_mine --rpc-url "$RPC" >/dev/null

log "taker swaps 300 USDC -> WETH through Uniswap v4 (PoolManager -> GlideHook -> router -> Aqua)"
A_TO_B=true AMOUNT_IN=300000000 VIA=uniswap forge script script/Swap.s.sol --rpc-url "$RPC" --broadcast 2>&1 | grep -E 'via|amountIn|quoted|received|maker wallet|Error|revert' || true

log "taker swaps 0.2 WETH -> USDC through Uniswap v4"
A_TO_B=false AMOUNT_IN=200000000000000000 VIA=uniswap forge script script/Swap.s.sol --rpc-url "$RPC" --broadcast 2>&1 | grep -E 'via|amountIn|quoted|received|maker wallet|Error|revert' || true

log "done. maker wallet now: WETH $(cast call $WETH 'balanceOf(address)(uint256)' $MAKER --rpc-url $RPC)  USDC $(cast call $USDC 'balanceOf(address)(uint256)' $MAKER --rpc-url $RPC)"
