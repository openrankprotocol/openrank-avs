#!/bin/bash

# Exit on error
set -e

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEPLOYMENT_ENV="holesky"

echo "Starting OpenRank AVS local deployment sequence..."

# Step 0: Deploy OpenRank contracts
echo "Step 0: Deploying OpenRank contracts..."
bash "$CURRENT_DIR/0_deploy_openrank.sh" "$DEPLOYMENT_ENV"

# Step 1: Run EigenDA proxy
echo "Step 1: Running EigenDA proxy..."
bash "$CURRENT_DIR/1_run_eigenda_proxy.sh"

# Step 2: Run RxP node
echo "Step 2: Running RxP node..."
bash "$CURRENT_DIR/2_run_rxp_node.sh" "$DEPLOYMENT_ENV"

# Step 3: Register RxP node
echo "Step 3: Registering RxP node..."
bash "$CURRENT_DIR/3_register_rxp_no.sh" "$DEPLOYMENT_ENV"

# Step 4: Add image
echo "Step 4: Adding image..."
bash "$CURRENT_DIR/4_add_image.sh" "$DEPLOYMENT_ENV"

echo "OpenRank AVS local deployment sequence completed successfully!"
