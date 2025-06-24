DEPLOYMENT_ENV="$1"
CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRIPT_DIR="$CURRENT_DIR/../script/"$DEPLOYMENT_ENV""

ENV_FILE="$CURRENT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

# Load contract addresses from JSON files
OPENRANK_MANAGER_ADDRESS=$(jq -r '.addresses.openRankManager' "$SCRIPT_DIR"/output/deploy_or_contracts_output.json)
REEXECUTION_ENDPOINT_ADDRESS=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR"/output/deploy_rxp_contracts_output.json)

# Read image ID from file
IMAGE_ID=$(cat "$CURRENT_DIR"/image_id.txt)

echo "OPENRANK_MANAGER_ADDRESS: $OPENRANK_MANAGER_ADDRESS"
echo "REEXECUTION_ENDPOINT_ADDRESS: $REEXECUTION_ENDPOINT_ADDRESS"
echo "IMAGE_ID: $IMAGE_ID"

# Handle different sed syntax for Linux and macOS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    sed -i "s/OPENRANK_MANAGER_ADDRESS=.*/OPENRANK_MANAGER_ADDRESS=$OPENRANK_MANAGER_ADDRESS/" "$ENV_FILE"
    sed -i "s/REEXECUTION_ENDPOINT_ADDRESS=.*/REEXECUTION_ENDPOINT_ADDRESS=$REEXECUTION_ENDPOINT_ADDRESS/" "$ENV_FILE"
    sed -i "s/IMAGE_ID=.*/IMAGE_ID=$IMAGE_ID/" "$ENV_FILE"
else
    # macOS
    sed -i '' "s/OPENRANK_MANAGER_ADDRESS=.*/OPENRANK_MANAGER_ADDRESS=$OPENRANK_MANAGER_ADDRESS/" "$ENV_FILE"
    sed -i '' "s/REEXECUTION_ENDPOINT_ADDRESS=.*/REEXECUTION_ENDPOINT_ADDRESS=$REEXECUTION_ENDPOINT_ADDRESS/" "$ENV_FILE"
    sed -i '' "s/IMAGE_ID=.*/IMAGE_ID=$IMAGE_ID/" "$ENV_FILE"
fi

cd "$CURRENT_DIR/.."
forge script contracts/script/AddImageId.s.sol --private-keys $PRIVATE_KEY --rpc-url $RPC_URL --broadcast --tx-origin $ADDRESS -vvv
