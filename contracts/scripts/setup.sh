#!/usr/bin/env bash
# Seed the fork's demo accounts and deploy Glide, without shipping a position (the maker ships from the app).
#   terminal 1:  anvil --port 8546 --fork-url https://mainnet.unichain.org --fork-block-number 58230608 --chain-id 130
#   terminal 2:  RPC=http://127.0.0.1:8546 ./scripts/setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

export RPC=${RPC:-http://127.0.0.1:8546}
export DEPLOY_SALT=${DEPLOY_SALT:-1} # same fresh fork + contract build => same addresses as the hosted frontend
export PRIVATE_KEY=${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
MAKER_PK=${MAKER_PK:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}
TAKER_PK=${TAKER_PK:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}
MAKER=$(cast wallet address --private-key "$MAKER_PK")
TAKER=$(cast wallet address --private-key "$TAKER_PK")
WETH=0x4200000000000000000000000000000000000006
USDC=0x078D782b760474a361dDA0AF3839290b0EF57AD6

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

log "seeding maker and taker with WETH and USDC on the fork"
cast send "$WETH" 'deposit()' --value 20ether --private-key "$MAKER_PK" --rpc-url "$RPC" >/dev/null
cast send "$WETH" 'deposit()' --value 20ether --private-key "$TAKER_PK" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setStorageAt "$USDC" "$(cast index address "$MAKER" 9)" "$(cast to-uint256 5000000000)"  --rpc-url "$RPC" >/dev/null
cast rpc anvil_setStorageAt "$USDC" "$(cast index address "$TAKER" 9)" "$(cast to-uint256 50000000000)" --rpc-url "$RPC" >/dev/null
echo "maker $MAKER  WETH $(cast call $WETH 'balanceOf(address)(uint256)' $MAKER --rpc-url $RPC)  USDC $(cast call $USDC 'balanceOf(address)(uint256)' $MAKER --rpc-url $RPC)"

log "deploying GlideSwapVMRouter, GlideLens, GlideHook and the USDC/WETH pool"
forge script script/Deploy.s.sol --rpc-url "$RPC" --broadcast
rm -f deployments/position-130.json

log "done. next: cd ../web && npm run dev   (the app reads deployments/130.json)"
