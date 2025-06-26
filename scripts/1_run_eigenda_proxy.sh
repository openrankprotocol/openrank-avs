#!/bin/bash

# Exit on error
set -e

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RXP_SCRIPT_DIR="$CURRENT_DIR"/../contracts/lib/rxp/scripts/
EIGENDA_SERVICE_MANAGER_ADDR=0x0000000000000000000000000000000000000000
ROOT_DIR="$CURRENT_DIR/.."

ENV_FILE="$ROOT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment variables from .env file"
    source $ENV_FILE
fi

# Start the EigenDA proxy
"$RXP_SCRIPT_DIR"/eigenda/start-da-proxy.sh $CHAIN_RPC_URL $EIGENDA_SERVICE_MANAGER_ADDR
