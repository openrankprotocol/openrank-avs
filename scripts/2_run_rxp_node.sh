#!/bin/bash

# Exit on error
set -e

RXP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../contracts/lib/rxp
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../script
RESERVATION_REGISTRY_ADDRESS=$(jq -r '.addresses.reservationRegistry.proxy' "$SCRIPT_DIR"/local/output/deploy_rxp_contracts_output.json)

cp "$RXP_DIR"/archiver/.env.example "$RXP_DIR"/archiver/.env


# This is running in ubuntu, so we need to get the IP of the default interface
if [ "$CI" = true ]; then
    # Get IP of the default interface
    HOST_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
    sed -i "s|ETH_RPC_URL=.*|ETH_RPC_URL=ws://$HOST_IP:8545/|" "$RXP_DIR"/archiver/.env
    sed -i "s|DA_PROXY_URL=.*|DA_PROXY_URL=http://$HOST_IP:3100/|" "$RXP_DIR"/archiver/.env
fi

# Update RESERVATION_REGISTRY_ADDRESS in .env
# Handle different sed syntax for Linux and macOS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    sed -i "s/RESERVATION_REGISTRY_ADDRESS=.*/RESERVATION_REGISTRY_ADDRESS=$RESERVATION_REGISTRY_ADDRESS/" "$RXP_DIR"/archiver/.env
else
    # macOS
    sed -i '' "s/RESERVATION_REGISTRY_ADDRESS=.*/RESERVATION_REGISTRY_ADDRESS=$RESERVATION_REGISTRY_ADDRESS/" "$RXP_DIR"/archiver/.env
fi

# Start postgres
echo "Starting postgres and image archiver"
cd "$RXP_DIR"/archiver && docker compose -f docker-compose.yml up --build -d

# ------------------------------------------------------------------------------------------------

REEXECUTION_ENDPOINT_ADDRESS=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR"/local/output/deploy_rxp_contracts_output.json)
RESERVATION_REGISTRY_ADDRESS=$(jq -r '.addresses.reservationRegistry.proxy' "$SCRIPT_DIR"/local/output/deploy_rxp_contracts_output.json)
cp "$RXP_DIR"/node/.env.example "$RXP_DIR"/node/.env

echo "REEXECUTION_ENDPOINT_ADDRESS: $REEXECUTION_ENDPOINT_ADDRESS"
echo "RESERVATION_REGISTRY_ADDRESS: $RESERVATION_REGISTRY_ADDRESS"

TMPDIR=$(mktemp -d)
HOST_DATA_DIR="$TMPDIR"/rxp/data
mkdir -p "$HOST_DATA_DIR"
echo "Created data directory: $HOST_DATA_DIR"

# Set the reexecution container CPU and memory limits for local development
echo >> "$RXP_DIR"/node/.env
echo "REEXECUTION_CONTAINER_CPU_LIMIT=1" >> "$RXP_DIR"/node/.env
echo "REEXECUTION_CONTAINER_MEMORY_LIMIT=2" >> "$RXP_DIR"/node/.env

if [ "$CI" = true ]; then
    # Get IP of the default interface
    HOST_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
    sed -i "s|ETH_RPC_URL=.*|ETH_RPC_URL=ws://$HOST_IP:8545/|" "$RXP_DIR"/node/.env
    sed -i "s|DA_PROXY_URL=.*|DA_PROXY_URL=http://$HOST_IP:3100|" "$RXP_DIR"/node/.env
    sed -i "s|IMAGE_ARCHIVER_URL=.*|IMAGE_ARCHIVER_URL=http://$HOST_IP:9090/|" "$RXP_DIR"/node/.env
fi

# Update REEXECUTION_ENDPOINT_ADDRESS and RESERVATION_REGISTRY_ADDRESS in .env
# Handle different sed syntax for Linux and macOS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    sed -i "s/REEXECUTION_ENDPOINT_ADDRESS=.*/REEXECUTION_ENDPOINT_ADDRESS=$REEXECUTION_ENDPOINT_ADDRESS/" "$RXP_DIR"/node/.env
    sed -i "s/RESERVATION_REGISTRY_ADDRESS=.*/RESERVATION_REGISTRY_ADDRESS=$RESERVATION_REGISTRY_ADDRESS/" "$RXP_DIR"/node/.env
    sed -i "s|HOST_DATA_DIR=.*|HOST_DATA_DIR=$HOST_DATA_DIR|" "$RXP_DIR"/node/.env
else
    # macOS
    sed -i '' "s/REEXECUTION_ENDPOINT_ADDRESS=.*/REEXECUTION_ENDPOINT_ADDRESS=$REEXECUTION_ENDPOINT_ADDRESS/" "$RXP_DIR"/node/.env
    sed -i '' "s/RESERVATION_REGISTRY_ADDRESS=.*/RESERVATION_REGISTRY_ADDRESS=$RESERVATION_REGISTRY_ADDRESS/" "$RXP_DIR"/node/.env
    sed -i '' "s|HOST_DATA_DIR=.*|HOST_DATA_DIR=$HOST_DATA_DIR|" "$RXP_DIR"/node/.env
fi

echo "Building reexecution proxy"
docker build -f "$RXP_DIR/proxy/Dockerfile" -t ghcr.io/layr-labs/rxp/proxy:latest "$RXP_DIR"

echo "Starting node and postgres"
cd "$RXP_DIR"/node && docker compose -f docker-compose.yml up --build -d
