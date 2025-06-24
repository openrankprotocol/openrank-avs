#!/bin/bash

# Exit on error
set -e

# This script is used to
# 1. Post Image to EigenDA
# 2. Reserve on RxP
# 3. Add Image to Reservation

DEPLOYMENT_ENV="$1"
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPT_DIR=$CURRENT_DIR/../script/"$DEPLOYMENT_ENV"
RXP_DIR=$CURRENT_DIR/../contracts/lib/rxp
IMAGESTORE_BIN_PATH=/Users/filiplazovic/go/bin/imagestore

IMAGE_NAME=openrank-rxp
IMAGESTORE_PRIVATE_KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC_URL=http://127.0.0.1:8545
DA_URL=http://127.0.0.1:3100

ENV_FILE="$CURRENT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

# build the RxP image
cd $CURRENT_DIR/../ && docker build -f node/Dockerfile.rxp -t $IMAGE_NAME .

PAYMENT_TOKEN=$(jq -r '.addresses.reservationRegistry.paymentToken' "$SCRIPT_DIR"/output/deploy_rxp_contracts_output.json)
RESERVATION_REGISTRY_ADDR=$(jq -r '.addresses.reservationRegistry.proxy' "$SCRIPT_DIR"/output/deploy_rxp_contracts_output.json)
REEXECUTION_ENDPOINT_ADDR=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR"/output/deploy_rxp_contracts_output.json)
OPENRANK_MANAGER_ADDRESS=$(jq -r '.addresses.openRankManager' "$SCRIPT_DIR"/output/deploy_or_contracts_output.json)
DOCKER_IMAGE_ID=$(docker inspect $IMAGE_NAME | jq -r '.[0].Id')

echo "OPENRANK_MANAGER_ADDRESS: $OPENRANK_MANAGER_ADDRESS"
echo "RESERVATION_REGISTRY_ADDR: $RESERVATION_REGISTRY_ADDR"
echo "REEXECUTION_ENDPOINT_ADDR: $REEXECUTION_ENDPOINT_ADDR"
echo "IMAGE_NAME: $IMAGE_NAME"

# approve the reservation registry to spend the token
cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $PAYMENT_TOKEN "approve(address,uint256)" "$RESERVATION_REGISTRY_ADDR" $(cast max-uint)

$IMAGESTORE_BIN_PATH \
    --image-name $IMAGE_NAME \
    --da-proxy-url $DA_URL \
    --reservation-registry-address "$RESERVATION_REGISTRY_ADDR" \
    --reexecution-endpoint-address "$REEXECUTION_ENDPOINT_ADDR" \
    --private-key $IMAGESTORE_PRIVATE_KEY \
    --avs-address "$OPENRANK_MANAGER_ADDRESS" \
    --eth-rpc-url $RPC_URL \
    --docker-image-id "$DOCKER_IMAGE_ID" \
    --image-id-file "$CURRENT_DIR"/image_id.txt

bash "$CURRENT_DIR"/add_image_id.sh "local"
