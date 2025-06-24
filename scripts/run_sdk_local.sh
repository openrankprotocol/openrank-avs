#!/bin/bash

set -e

cd "$(dirname "$0")/.."

# Check if openrank-sdk is installed globally
if ! command -v openrank-sdk &> /dev/null; then
    echo "Error: openrank-sdk not found. Please install it globally first." >&2
    exit 1
fi

# Load environment variables from .env file if it exists
[ -f ".env" ] && source .env

# Override URLs for host machine
export CHAIN_RPC_URL=http://localhost:8545
export CHAIN_WSS_URL=ws://localhost:8545
export DA_PROXY_URL=http://localhost:3100
export EIGEN_DA_PROXY_URL=http://localhost:3100
export IMAGE_ARCHIVER_URL=http://localhost:9090

# Load contract addresses from JSON files
SCRIPT_DIR="./script/local"

export OPENRANK_MANAGER_ADDRESS=$(jq -r '.addresses.openRankManager' "$SCRIPT_DIR/output/deploy_or_contracts_output.json")
export REEXECUTION_ENDPOINT_ADDRESS=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR/output/deploy_rxp_contracts_output.json")
export IMAGE_ID=$([ -f "./scripts/image_id.txt" ] && cat "./scripts/image_id.txt" || echo "0")

# Run the globally installed openrank-sdk
openrank-sdk meta-compute-request ./datasets/trust/ ./datasets/seed/
