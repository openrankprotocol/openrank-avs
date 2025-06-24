CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$CURRENT_DIR/.."

ENV_FILE="$ROOT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

if [ "$1" = "local" ]; then
    forge script contracts/script/DeployOpenRankLocal.s.sol --private-keys $PRIVATE_KEY --rpc-url $RPC_URL --broadcast --tx-origin $ADDRESS -vvv
else
    forge script contracts/script/DeployOpenRankTestnet.s.sol --private-keys $PRIVATE_KEY --rpc-url $RPC_URL --broadcast --tx-origin $ADDRESS -vvv
fi
