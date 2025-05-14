CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

ENV_FILE="$CURRENT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

forge script contracts/script/DeployOpenRank.s.sol --private-keys $PRIVATE_KEY --rpc-url $CHAIN_RPC_URL --broadcast --tx-origin $ADDRESS -vvv
