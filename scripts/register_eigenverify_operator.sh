#!/usr/bin/env bash

# Get the directory where the script is located
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
RPC_URL=http://127.0.0.1:8545
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RXP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../contracts/lib/rxp
REGISTRAR_BIN_PATH=/Users/filiplazovic/go/bin/register

# Operator key (same as DEPLOYER_KEY for local development)
OPERATOR_KEY=$DEPLOYER_KEY
OPERATOR_ADDRESS=$(cast wallet address "$OPERATOR_KEY")
SIGNING_KEY=59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

# Optional parameters
WEIGHT=1000
METADATA_URI="https://example.com"

# Get deployment addresses from rxp deployment output
# TODO: This should be moved to eigenverify deployment output
RXP_DEPLOYMENT="$CURRENT_DIR/../script/local/output/deploy_rxp_contracts_output.json"

# Get contract addresses from deployment file
REGISTRAR_ADDRESS=$(jq -r '.addresses.operatorRegistrar' "$RXP_DEPLOYMENT")
SET_MANAGER_ADDRESS=$(jq -r '.addresses.operatorSetManager' "$RXP_DEPLOYMENT")

# Check if addresses are available
if [ -z "$REGISTRAR_ADDRESS" ] || [ "$REGISTRAR_ADDRESS" == "null" ]; then
    echo "Error: Could not find EigenVerifyOperatorRegistrar address in deployment file"
    exit 1
fi

if [ -z "$SET_MANAGER_ADDRESS" ] || [ "$SET_MANAGER_ADDRESS" == "null" ]; then
    echo "Error: Could not find EigenVerifyOperatorSetManager address in deployment file"
    exit 1
fi

# Send some ETH to the operator if needed
cast send "$OPERATOR_ADDRESS" --value 0.1ether --private-key "$DEPLOYER_KEY" --rpc-url "$RPC_URL"

# Register operator with EigenVerify
echo "Registering operator to EigenVerify..."
$REGISTRAR_BIN_PATH \
  --eth-rpc-url "$RPC_URL" \
  --ecdsa-private-key "$OPERATOR_KEY" \
  --signing-key "$SIGNING_KEY" \
  --registrar-address "$REGISTRAR_ADDRESS" \
  --set-manager-address "$SET_MANAGER_ADDRESS" \
  --deployer-key "$DEPLOYER_KEY" \
  --weight "$WEIGHT" \
  --metadata-uri "$METADATA_URI"
