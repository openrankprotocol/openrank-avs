#!/bin/bash

set -e

cd "$(dirname "$0")/.."

DEPLOYMENT_ENV="$1"
cp .env."$DEPLOYMENT_ENV" .env
# Load contract addresses from JSON files or use environment variables
SCRIPT_DIR="./script/"$DEPLOYMENT_ENV""

# Try to load from JSON files first, fallback to environment variables
OPENRANK_MANAGER_ADDRESS=$(jq -r '.addresses.openRankManager' "$SCRIPT_DIR/output/deploy_or_contracts_output.json")
REEXECUTION_ENDPOINT_ADDRESS=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR/output/deploy_rxp_contracts_output.json")
IMAGE_ID=$([ -f "./scripts/image_id.txt" ] && cat "./scripts/image_id.txt" || echo "0")

echo "OPENRANK_MANAGER_ADDRESS=$OPENRANK_MANAGER_ADDRESS" >> .env
echo "REEXECUTION_ENDPOINT_ADDRESS=$REEXECUTION_ENDPOINT_ADDRESS" >> .env
echo "IMAGE_ID=$IMAGE_ID" >> .env

echo "OPENRANK_MANAGER_ADDRESS: $OPENRANK_MANAGER_ADDRESS"
echo "REEXECUTION_ENDPOINT_ADDRESS: $REEXECUTION_ENDPOINT_ADDRESS"
echo "IMAGE_ID: $IMAGE_ID"

# Start containers in detached mode
docker compose up -d openrank-node-computer openrank-node-challenger
