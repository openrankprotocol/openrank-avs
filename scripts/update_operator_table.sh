
#!/usr/bin/env bash

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
RPC_URL=http://127.0.0.1:8545
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PARENT_DIR="$SCRIPT_DIR/.."
RXP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../contracts/lib/rxp

# Get deployment addresses from output files
RXP_DEPLOYMENT="$PARENT_DIR/script/local/output/deploy_rxp_contracts_output.json"

# Extract contract addresses
TABLE_CALCULATOR_ADDRESS=$(jq -r '.addresses.operatorTableCalculator' "$RXP_DEPLOYMENT")
CERTIFICATE_VERIFIER_ADDRESS=$(jq -r '.addresses.rxpCertificateVerifier' "$RXP_DEPLOYMENT")

# Check if addresses are available
if [ -z "$TABLE_CALCULATOR_ADDRESS" ] || [ "$TABLE_CALCULATOR_ADDRESS" == "null" ]; then
    echo "Error: Could not find EigenVerifyOperatorTableCalculator address in deployment file"
    exit 1
fi

if [ -z "$CERTIFICATE_VERIFIER_ADDRESS" ] || [ "$CERTIFICATE_VERIFIER_ADDRESS" == "null" ]; then
    echo "Error: Could not find CertificateVerifier address in deployment file"
    exit 1
fi

echo "Using addresses:"
echo "- Table Calculator: $TABLE_CALCULATOR_ADDRESS"
echo "- Certificate Verifier: $CERTIFICATE_VERIFIER_ADDRESS"

# Get current block number for timestamp
BLOCK_NUMBER=$(cast block-number --rpc-url "$RPC_URL")
echo "Current block number: $BLOCK_NUMBER"

# Use Forge script to update the operator table
echo "Updating the operator table in the CertificateVerifier contract..."
forge script "$RXP_DIR/contracts/script/local/setup/update_operator_table.s.sol" -vv \
  --rpc-url "$RPC_URL" \
  --private-key "$DEPLOYER_KEY" \
  --sig "run(address,address,uint32)" \
  "$TABLE_CALCULATOR_ADDRESS" "$CERTIFICATE_VERIFIER_ADDRESS" "$BLOCK_NUMBER" \
  --broadcast

echo "Operator table update complete."
