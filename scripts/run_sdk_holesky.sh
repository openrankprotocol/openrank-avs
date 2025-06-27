#!/bin/bash

set -e

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load environment variables from .env file if it exists
[ -f ""$CURRENT_DIR"/../.env" ] && source "$CURRENT_DIR"/../.env

# Override URLs for host machine
export DA_PROXY_URL=http://127.0.0.1:3100
export IMAGE_ARCHIVER_URL=http://127.0.0.1:9090

# Load contract addresses from JSON files
SCRIPT_DIR=""$CURRENT_DIR"/../script/holesky"

export OPENRANK_MANAGER_ADDRESS=$(jq -r '.addresses.openRankManager' "$SCRIPT_DIR/output/deploy_or_contracts_output.json")
export REEXECUTION_ENDPOINT_ADDRESS=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR/output/deploy_rxp_contracts_output.json")
export IMAGE_ID=$([ -f "./scripts/image_id.txt" ] && cat "./scripts/image_id.txt" || echo "0")

# Run the globally installed openrank-sdk
openrank-sdk meta-compute-request ./datasets/trust/ ./datasets/seed/
