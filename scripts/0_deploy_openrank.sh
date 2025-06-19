CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$CURRENT_DIR/.."

ENV_FILE="$ROOT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

cd "$ROOT_DIR"
docker compose up anvil -d
forge script contracts/script/DeployOpenRank.s.sol --private-keys $PRIVATE_KEY --rpc-url http://localhost:8545 --broadcast --tx-origin $ADDRESS -vvv
