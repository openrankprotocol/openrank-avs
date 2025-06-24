#!/usr/bin/env bash

DEPLOYMENT_ENV="$1"
RXP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../contracts/lib/rxp
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../script
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REGISTER_BIN_PATH=/Users/filiplazovic/go/bin/register

ENV_FILE="$CURRENT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

PRIVATE_KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
OPERATOR_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
BLS_PRIVATE_KEY=11
FUNDS_PK=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DELEGATION_MANAGER_ADDRESS=$(jq -r '.addresses.delegationManager' "$SCRIPT_DIR"/"$DEPLOYMENT_ENV"/output/deploy_eigenlayer_core_output.json)
STRATEGY_ADDRESS=$(jq -r '.addresses.operatorSet.mockStrategy' "$SCRIPT_DIR"/"$DEPLOYMENT_ENV"/output/deploy_rxp_contracts_output.json)

cleanup() {
  # set +e to avoid exiting the script if the rm commands fail
  set +e

  echo "Cleaning up..."
  rm "$HOME"/.eigenlayer/operator_keys/oprtemp.ecdsa.key.json
  rm oprtemp.ecdsa.key.json
  rm "$CURRENT_DIR"/operator_temp.yaml

  local status=$?
  echo "Cleaning up complete"
  exit $status
}

# trap cleanup on: interruption (ctrl+c), termination, and exit
trap cleanup EXIT INT TERM

# Setup dependencies
if ! command -v "$HOME"/bin/eigenlayer &> /dev/null; then
    echo "EigenLayer CLI is not installed"
    curl -sSfL https://raw.githubusercontent.com/layr-labs/eigenlayer-cli/master/scripts/install.sh | sh -s -- -b "$HOME"/bin v0.13.0
fi

## Create a new ecdsa key
echo "" | "$HOME"/bin/eigenlayer keys import --key-type=ecdsa --insecure oprtemp "$PRIVATE_KEY" > oprtemp.ecdsa.key.json

# Register operator to AVS
cp "$CURRENT_DIR"/operator.yaml "$CURRENT_DIR"/operator_temp.yaml
echo "$HOME"
# Detect OS for sed compatibility
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/address: <OPERATOR_ADDRESS>/address: $OPERATOR_ADDRESS/" "$CURRENT_DIR"/operator_temp.yaml
    sed -i '' "s|private_key_store_path: <PATH_TO_KEY>|private_key_store_path: $HOME/.eigenlayer/operator_keys/oprtemp.ecdsa.key.json|" "$CURRENT_DIR"/operator_temp.yaml
    sed -i '' "s|eth_rpc_url: <ETH_RPC_URL>|eth_rpc_url: $RPC_URL|" "$CURRENT_DIR"/operator_temp.yaml
    sed -i '' "s|el_delegation_manager_address: <DELEGATION_MANAGER_ADDRESS>|el_delegation_manager_address: $DELEGATION_MANAGER_ADDRESS|" "$CURRENT_DIR"/operator_temp.yaml
else
    # Linux and others
    sed -i "s/address: <OPERATOR_ADDRESS>/address: $OPERATOR_ADDRESS/" "$CURRENT_DIR"/operator_temp.yaml
    sed -i "s|private_key_store_path: <PATH_TO_KEY>|private_key_store_path: $HOME/.eigenlayer/operator_keys/oprtemp.ecdsa.key.json|" "$CURRENT_DIR"/operator_temp.yaml
    sed -i "s|eth_rpc_url: <ETH_RPC_URL>|eth_rpc_url: $RPC_URL|" "$CURRENT_DIR"/operator_temp.yaml
    sed -i "s|el_delegation_manager_address: <DELEGATION_MANAGER_ADDRESS>|el_delegation_manager_address: $DELEGATION_MANAGER_ADDRESS|" "$CURRENT_DIR"/operator_temp.yaml
fi

# Send funds to the operator
cast send "$OPERATOR_ADDRESS" --value 0.2ether --private-key "$FUNDS_PK" --rpc-url "$RPC_URL"

# Register the operator
echo "Registering operator..."
echo "" | "$HOME"/bin/eigenlayer operator register "$CURRENT_DIR"/operator_temp.yaml

# Restake
echo "Restaking..."
PARENT_DIR="$CURRENT_DIR/.."
bash "$RXP_DIR"/scripts/acquire_and_deposit_token.sh "$RPC_URL" "$PRIVATE_KEY" "$SCRIPT_DIR"/"$DEPLOYMENT_ENV"/output/deploy_rxp_contracts_output.json "$SCRIPT_DIR"/local/output/deploy_eigenlayer_core_output.json 3000000000000000000000 "$FUNDS_PK"

cast rpc anvil_mine 12000 --rpc-url "$RPC_URL"
# Register Operator to RxP AVS
SOCKET="127.0.0.1:6666"
echo "Registering operator to AVS with BLS private key $BLS_PRIVATE_KEY, ECDSA private key $PRIVATE_KEY, socket $SOCKET"
$REGISTER_BIN_PATH \
  --eth-rpc-url "$RPC_URL" \
  --eigenlayer-deployment-path "$SCRIPT_DIR"/"$DEPLOYMENT_ENV"/output/deploy_eigenlayer_core_output.json \
  --avs-deployment-path "$SCRIPT_DIR"/"$DEPLOYMENT_ENV"/output/deploy_rxp_contracts_output.json \
  --ecdsa-private-key "$PRIVATE_KEY" \
  --bls-private-key "$BLS_PRIVATE_KEY" \
  --socket "$SOCKET" \
  --strategy-address "$STRATEGY_ADDRESS"

echo "Current block number:"
cast block-number --rpc-url "$RPC_URL"

echo "Fast-forward 11 blocks"
cast rpc anvil_mine 11 --rpc-url "$RPC_URL"

echo "Current block number:"
cast block-number --rpc-url "$RPC_URL"
