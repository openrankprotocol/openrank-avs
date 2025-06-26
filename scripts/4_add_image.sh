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

ENV_FILE="$CURRENT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

PREFIX=0x
IMAGESTORE_PRIVATE_KEY=${PRIVATE_KEY#"$PREFIX"}
IMAGE_NAME=openrank-rxp

# build the RxP image
docker build -f $CURRENT_DIR/../node/Dockerfile.rxp -t $IMAGE_NAME .

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
if [ "$DEPLOYMENT_ENV" = "local" ]; then
    RPC_URL=http://127.0.0.1:8545
    cast send --rpc-url $RPC_URL --private-key $PRIVATE_KEY $PAYMENT_TOKEN "approve(address,uint256)" "$RESERVATION_REGISTRY_ADDR" $(cast max-uint)
else
    cast send --rpc-url $CHAIN_RPC_URL --private-key $PRIVATE_KEY $PAYMENT_TOKEN "approve(address,uint256)" "$RESERVATION_REGISTRY_ADDR" $(cast max-uint)
fi

if [ "$DEPLOYMENT_ENV" = "local" ]; then
    RPC_URL=http://127.0.0.1:8545
    DA_URL=http://127.0.0.1:3100
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
else
    $IMAGESTORE_BIN_PATH \
        --image-name $IMAGE_NAME \
        --da-proxy-url $EIGEN_DA_PROXY_URL \
        --reservation-registry-address "$RESERVATION_REGISTRY_ADDR" \
        --reexecution-endpoint-address "$REEXECUTION_ENDPOINT_ADDR" \
        --private-key $IMAGESTORE_PRIVATE_KEY \
        --avs-address "$OPENRANK_MANAGER_ADDRESS" \
        --eth-rpc-url $CHAIN_RPC_URL \
        --docker-image-id "$DOCKER_IMAGE_ID" \
        --image-id-file "$CURRENT_DIR"/image_id.txt
fi

bash "$CURRENT_DIR"/add_image_id.sh $DEPLOYMENT_ENV
