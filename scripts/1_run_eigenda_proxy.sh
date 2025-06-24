#!/bin/bash

# Exit on error
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../contracts/lib/rxp/scripts/
EIGENDA_SERVICE_MANAGER_ADDR=0x0000000000000000000000000000000000000000

ENV_FILE="$ROOT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

# Start the EigenDA proxy
"$SCRIPT_DIR"/eigenda/start-da-proxy.sh $CHAIN_RPC_URL $EIGENDA_SERVICE_MANAGER_ADDR
