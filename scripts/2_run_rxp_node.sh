#!/bin/bash

# Exit on error
set -e

DEPLOYMENT_ENV="$1"
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RXP_DIR="$CURRENT_DIR"/../contracts/lib/rxp
SCRIPT_DIR="$CURRENT_DIR"/../script
ROOT_DIR="$CURRENT_DIR/.."

ENV_FILE="$ROOT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi
CHAIN_WS_URL="${CHAIN_RPC_URL/http/ws}"
PREFIX=0x
PRIVATE_KEY_SHORT=${PRIVATE_KEY#"$PREFIX"}
BLS_PRIVATE_KEY=11
RESERVATION_REGISTRY_ADDRESS=$(jq -r '.addresses.reservationRegistry.proxy' "$SCRIPT_DIR"/"$DEPLOYMENT_ENV"/output/deploy_rxp_contracts_output.json)
REEXECUTION_ENDPOINT_ADDRESS=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR"/"$DEPLOYMENT_ENV"/output/deploy_rxp_contracts_output.json)
echo "REEXECUTION_ENDPOINT_ADDRESS: $REEXECUTION_ENDPOINT_ADDRESS"
echo "RESERVATION_REGISTRY_ADDRESS: $RESERVATION_REGISTRY_ADDRESS"

cp "$RXP_DIR"/archiver/.env.example "$RXP_DIR"/archiver/.env

# Update RESERVATION_REGISTRY_ADDRESS in .env
# Handle different sed syntax for Linux and macOS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    sed -i "s/RESERVATION_REGISTRY_ADDRESS=.*/RESERVATION_REGISTRY_ADDRESS=$RESERVATION_REGISTRY_ADDRESS/" "$RXP_DIR"/archiver/.env
    sed -i "s|ETH_RPC_URL=.*|ETH_RPC_URL=$CHAIN_WS_URL|" "$RXP_DIR"/archiver/.env
else
    # macOS
    sed -i '' "s/RESERVATION_REGISTRY_ADDRESS=.*/RESERVATION_REGISTRY_ADDRESS=$RESERVATION_REGISTRY_ADDRESS/" "$RXP_DIR"/archiver/.env
    sed -i '' "s|ETH_RPC_URL=.*|ETH_RPC_URL=$CHAIN_WS_URL|" "$RXP_DIR"/archiver/.env
fi

# Start postgres
echo "Starting postgres and image archiver"
cd "$RXP_DIR"/archiver && docker compose -f docker-compose.yml up --build -d

# ------------------------------------------------------------------------------------------------
cp "$RXP_DIR"/node/.env.example "$RXP_DIR"/node/.env

TMPDIR=$(mktemp -d)
HOST_DATA_DIR="$TMPDIR"/rxp/data
mkdir -p "$HOST_DATA_DIR"
echo "Created data directory: $HOST_DATA_DIR"

# Set the reexecution container CPU and memory limits
echo >> "$RXP_DIR"/node/.env
echo "REEXECUTION_CONTAINER_CPU_LIMIT=1" >> "$RXP_DIR"/node/.env
echo "REEXECUTION_CONTAINER_MEMORY_LIMIT=2" >> "$RXP_DIR"/node/.env

# Update REEXECUTION_ENDPOINT_ADDRESS and RESERVATION_REGISTRY_ADDRESS in .env
# Handle different sed syntax for Linux and macOS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    sed -i "s/REEXECUTION_ENDPOINT_ADDRESS=.*/REEXECUTION_ENDPOINT_ADDRESS=$REEXECUTION_ENDPOINT_ADDRESS/" "$RXP_DIR"/node/.env
    sed -i "s/RESERVATION_REGISTRY_ADDRESS=.*/RESERVATION_REGISTRY_ADDRESS=$RESERVATION_REGISTRY_ADDRESS/" "$RXP_DIR"/node/.env
    sed -i "s|ETH_RPC_URL=.*|ETH_RPC_URL=$CHAIN_WS_URL|" "$RXP_DIR"/node/.env
    sed -i "s/PRIVATE_KEY=.*/PRIVATE_KEY=$PRIVATE_KEY_SHORT/" "$RXP_DIR"/node/.env
    sed -i "s/BLS_PRIVATE_KEY=.*/BLS_PRIVATE_KEY=$BLS_PRIVATE_KEY/" "$RXP_DIR"/node/.env
    sed -i "s|HOST_DATA_DIR=.*|HOST_DATA_DIR=$HOST_DATA_DIR|" "$RXP_DIR"/node/.env
else
    # macOS
    sed -i '' "s/REEXECUTION_ENDPOINT_ADDRESS=.*/REEXECUTION_ENDPOINT_ADDRESS=$REEXECUTION_ENDPOINT_ADDRESS/" "$RXP_DIR"/node/.env
    sed -i '' "s/RESERVATION_REGISTRY_ADDRESS=.*/RESERVATION_REGISTRY_ADDRESS=$RESERVATION_REGISTRY_ADDRESS/" "$RXP_DIR"/node/.env
    sed -i '' "s|ETH_RPC_URL=.*|ETH_RPC_URL=$CHAIN_WS_URL|" "$RXP_DIR"/node/.env
    sed -i '' "s/PRIVATE_KEY=.*/PRIVATE_KEY=$PRIVATE_KEY_SHORT/" "$RXP_DIR"/node/.env
    sed -i '' "s/BLS_PRIVATE_KEY=.*/BLS_PRIVATE_KEY=$BLS_PRIVATE_KEY/" "$RXP_DIR"/node/.env
    sed -i '' "s|HOST_DATA_DIR=.*|HOST_DATA_DIR=$HOST_DATA_DIR|" "$RXP_DIR"/node/.env
fi

echo "Building reexecution proxy"
docker build -t reex-proxy "$RXP_DIR"

echo "Starting node and postgres"
cd "$RXP_DIR"/node && docker compose -f docker-compose.yml up --build -d
