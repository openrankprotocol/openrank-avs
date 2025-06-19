#!/bin/bash

# OpenRank SDK Runner Script
# This script sets the correct environment variables for running the SDK on the host machine

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Change to project root directory
cd "$(dirname "$0")/.."

# Check if .env file exists and load it
if [ -f ".env" ]; then
    print_status "Loading base environment variables from .env file"
    source .env
fi

# Override URLs for host machine (localhost instead of host.docker.internal)
export CHAIN_RPC_URL=http://localhost:8545
export CHAIN_WSS_URL=ws://localhost:8545
export DA_PROXY_URL=http://localhost:3100
export EIGEN_DA_PROXY_URL=http://localhost:3100
export IMAGE_ARCHIVER_URL=http://localhost:9090

# Load contract addresses from JSON files
SCRIPT_DIR="./script/local"

if [ ! -f "$SCRIPT_DIR/output/deploy_or_contracts_output.json" ]; then
    print_error "OpenRank contracts output file not found: $SCRIPT_DIR/output/deploy_or_contracts_output.json"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/output/deploy_rxp_contracts_output.json" ]; then
    print_error "RXP contracts output file not found: $SCRIPT_DIR/output/deploy_rxp_contracts_output.json"
    exit 1
fi

export OPENRANK_MANAGER_ADDRESS=$(jq -r '.addresses.openRankManager' "$SCRIPT_DIR/output/deploy_or_contracts_output.json")
export REEXECUTION_ENDPOINT_ADDRESS=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR/output/deploy_rxp_contracts_output.json")

# Read image ID from file if it exists
if [ -f "./scripts/image_id.txt" ]; then
    export IMAGE_ID=$(cat "./scripts/image_id.txt")
else
    print_warning "Image ID file not found, using default value 0"
    export IMAGE_ID=0
fi

print_status "Environment configured for host machine:"
echo "  CHAIN_RPC_URL: $CHAIN_RPC_URL"
echo "  DA_PROXY_URL: $DA_PROXY_URL"
echo "  OPENRANK_MANAGER_ADDRESS: $OPENRANK_MANAGER_ADDRESS"
echo "  REEXECUTION_ENDPOINT_ADDRESS: $REEXECUTION_ENDPOINT_ADDRESS"
echo "  IMAGE_ID: $IMAGE_ID"

# Check if arguments are provided
if [ $# -eq 0 ]; then
    print_error "No arguments provided!"
    echo ""
    echo "Usage: $0 <sdk-command> [args...]"
    echo ""
    echo "Examples:"
    echo "  $0 meta-compute-request ./datasets/trust/ ./datasets/seed/"
    echo "  $0 compute-local ./datasets/trust/sample.csv ./datasets/seed/sample.csv"
    echo "  $0 upload-trust ./trust.csv ./trust_certs.bin"
    echo ""
    exit 1
fi

print_status "Running SDK command: $*"
cargo run --bin openrank-sdk -- "$@"

if [ $? -eq 0 ]; then
    print_success "SDK command completed successfully"
else
    print_error "SDK command failed"
    exit 1
fi
