#!/bin/bash

# Exit on error
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../contracts/lib/rxp/script/
ETH_RPC_URL=http://127.0.0.1:8545
EIGENDA_SERVICE_MANAGER_ADDR=0x0000000000000000000000000000000000000000

# Start the EigenDA proxy
"$SCRIPT_DIR"/eigenda/start-da-proxy.sh $ETH_RPC_URL $EIGENDA_SERVICE_MANAGER_ADDR
