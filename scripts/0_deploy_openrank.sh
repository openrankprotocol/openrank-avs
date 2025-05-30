CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

ENV_FILE="$CURRENT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

docker compose run -d --service-ports anvil

forge script contracts/script/DeployOpenRank.s.sol --private-keys $PRIVATE_KEY --rpc-url $CHAIN_RPC_URL --broadcast --tx-origin $ADDRESS -vvv

cast rpc anvil_mine 100 --rpc-url $CHAIN_RPC_URL

bash "$CURRENT_DIR"/register_eigenverify_operator.sh

bash "$CURRENT_DIR"/update_operator_table.sh
