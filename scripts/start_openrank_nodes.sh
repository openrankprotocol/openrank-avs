#!/bin/bash

# OpenRank Node Startup Script
# This script builds and starts the openrank-node-computer and openrank-node-challenger services

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

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if docker-compose is available
check_docker_compose() {
    if command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    elif command -v docker &> /dev/null && docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    else
        print_error "Neither 'docker-compose' nor 'docker compose' is available. Please install Docker Compose."
        exit 1
    fi
    print_status "Using: $DOCKER_COMPOSE_CMD"
}

# Function to check if .env file exists
check_env_file() {
    if [ ! -f ".env" ]; then
        print_warning ".env file not found. Make sure to set the required environment variables:"
        echo "  - EIGEN_DA_PROXY_URL"
        echo "  - CHAIN_RPC_URL"
        echo "  - CHAIN_WSS_URL"
        echo "  - OPENRANK_MANAGER_ADDRESS"
        echo "  - REEXECUTION_ENDPOINT_ADDRESS"
        echo "  - MNEMONIC"
        echo "  - AWS_ACCESS_KEY_ID"
        echo "  - AWS_SECRET_ACCESS_KEY"
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Aborted by user"
            exit 1
        fi
    else
        print_success ".env file found"
    fi
}

# Function to stop existing containers
stop_existing_containers() {
    print_status "Stopping existing OpenRank node containers..."
    $DOCKER_COMPOSE_CMD stop openrank-node-computer openrank-node-challenger 2>/dev/null || true
    print_success "Existing containers stopped"
}

# Function to build containers
build_containers() {
    print_status "Building OpenRank node containers..."
    $DOCKER_COMPOSE_CMD build openrank-node-computer openrank-node-challenger
    print_success "Containers built successfully"
}

# Function to start containers
start_containers() {
    print_status "Starting OpenRank node containers..."

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

    OPENRANK_MANAGER_ADDRESS=$(jq -r '.addresses.openRankManager' "$SCRIPT_DIR/output/deploy_or_contracts_output.json")
    REEXECUTION_ENDPOINT_ADDRESS=$(jq -r '.addresses.reexecutionEndpoint.proxy' "$SCRIPT_DIR/output/deploy_rxp_contracts_output.json")

    # Read image ID from file if it exists
    if [ -f "./scripts/image_id.txt" ]; then
        IMAGE_ID=$(cat "./scripts/image_id.txt")
    else
        print_warning "Image ID file not found, using default value 0"
        IMAGE_ID=0
    fi

    print_status "Loaded contract addresses:"
    echo "  OPENRANK_MANAGER_ADDRESS: $OPENRANK_MANAGER_ADDRESS"
    echo "  REEXECUTION_ENDPOINT_ADDRESS: $REEXECUTION_ENDPOINT_ADDRESS"
    echo "  IMAGE_ID: $IMAGE_ID"

    # Export environment variables for Docker containers
    export OPENRANK_MANAGER_ADDRESS
    export REEXECUTION_ENDPOINT_ADDRESS
    export IMAGE_ID

    # Start in detached mode
    $DOCKER_COMPOSE_CMD up -d openrank-node-computer openrank-node-challenger

    print_success "OpenRank nodes started successfully!"
    echo ""
    print_status "Container status:"
    $DOCKER_COMPOSE_CMD ps openrank-node-computer openrank-node-challenger
    echo ""
    print_status "Services are running on:"
    echo "  - Computer Mode:   http://localhost:8082"
    echo "  - Challenger Mode: http://localhost:8081"
}

# Function to show logs
show_logs() {
    echo ""
    read -p "Do you want to view the logs? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Showing logs (Press Ctrl+C to exit)..."
        $DOCKER_COMPOSE_CMD logs -f openrank-node-computer openrank-node-challenger
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -l, --logs     Show logs after starting"
    echo "  -s, --stop     Stop the containers instead of starting"
    echo "  --no-build     Skip building containers (use existing images)"
    echo ""
    echo "This script builds and starts the OpenRank node services:"
    echo "  - openrank-node-computer (port 8080)"
    echo "  - openrank-node-challenger (port 8081)"
}

# Parse command line arguments
SHOW_LOGS=false
SKIP_BUILD=false
STOP_CONTAINERS=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -l|--logs)
            SHOW_LOGS=true
            shift
            ;;
        --no-build)
            SKIP_BUILD=true
            shift
            ;;
        -s|--stop)
            STOP_CONTAINERS=true
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Main execution
main() {
    print_status "OpenRank Node Startup Script"
    echo "==============================="

    # Change to project root directory (assuming script is in ./scripts/)
    cd "$(dirname "$0")/.."
    print_status "Working directory: $(pwd)"

    # Check prerequisites
    check_docker_compose

    if [ "$STOP_CONTAINERS" = true ]; then
        print_status "Stopping OpenRank node containers..."
        $DOCKER_COMPOSE_CMD stop openrank-node-computer openrank-node-challenger
        $DOCKER_COMPOSE_CMD rm -f openrank-node-computer openrank-node-challenger 2>/dev/null || true
        print_success "OpenRank node containers stopped and removed"
        exit 0
    fi

    check_env_file

    # Stop existing containers
    stop_existing_containers

    # Build containers (unless skipped)
    if [ "$SKIP_BUILD" = false ]; then
        build_containers
    else
        print_warning "Skipping build (using existing images)"
    fi

    # Start containers
    start_containers

    # Show logs if requested
    if [ "$SHOW_LOGS" = true ]; then
        show_logs
    else
        echo ""
        print_status "To view logs, run:"
        echo "  $DOCKER_COMPOSE_CMD logs -f openrank-node-computer openrank-node-challenger"
        echo ""
        print_status "To stop the services, run:"
        echo "  $0 --stop"
        echo "  or"
        echo "  $DOCKER_COMPOSE_CMD stop openrank-node-computer openrank-node-challenger"
    fi
}

# Run main function
main "$@"
