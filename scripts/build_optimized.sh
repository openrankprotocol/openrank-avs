#!/bin/bash

# Optimized Docker Build Script for OpenRank
# This script uses Docker BuildKit for faster builds with advanced caching

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

# Function to check Docker BuildKit
check_buildkit() {
    if ! docker buildx version &> /dev/null; then
        print_error "Docker BuildKit (buildx) not available. Please update Docker to a newer version."
        exit 1
    fi
    print_success "Docker BuildKit available"
}

# Function to enable BuildKit features
setup_buildkit() {
    export DOCKER_BUILDKIT=1
    export COMPOSE_DOCKER_CLI_BUILD=1
    print_status "Docker BuildKit enabled"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS] [TARGETS]"
    echo ""
    echo "Options:"
    echo "  -h, --help          Show this help message"
    echo "  --no-cache          Build without using cache"
    echo "  --pull              Always pull base images"
    echo "  --parallel          Build all targets in parallel"
    echo "  --push-cache        Push build cache to registry (requires REGISTRY env var)"
    echo ""
    echo "Targets (default: all):"
    echo "  computer            Build openrank-node-computer only"
    echo "  challenger          Build openrank-node-challenger only"
    echo "  rxp                 Build openrank-rxp only"
    echo "  all                 Build all targets"
    echo ""
    echo "Examples:"
    echo "  $0                         # Build all targets"
    echo "  $0 computer challenger     # Build specific targets"
    echo "  $0 --parallel              # Build all in parallel"
    echo "  $0 --no-cache computer     # Build computer without cache"
}

# Parse command line arguments
USE_CACHE=true
PULL_IMAGES=false
PARALLEL_BUILD=false
PUSH_CACHE=false
TARGETS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        --no-cache)
            USE_CACHE=false
            shift
            ;;
        --pull)
            PULL_IMAGES=true
            shift
            ;;
        --parallel)
            PARALLEL_BUILD=true
            shift
            ;;
        --push-cache)
            PUSH_CACHE=true
            shift
            ;;
        computer|challenger|rxp|all)
            TARGETS+=("$1")
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Default to all targets if none specified
if [ ${#TARGETS[@]} -eq 0 ]; then
    TARGETS=("all")
fi

# Function to build with advanced caching
build_with_cache() {
    local target=$1
    local cache_args=""

    if [ "$USE_CACHE" = true ]; then
        cache_args="--cache-from=type=local,src=/tmp/.buildx-cache"
        cache_args="$cache_args --cache-to=type=local,dest=/tmp/.buildx-cache-new,mode=max"
    fi

    if [ "$PULL_IMAGES" = true ]; then
        cache_args="$cache_args --pull"
    fi

    print_status "Building $target with optimized caching..."

    docker buildx build \
        --file node/Dockerfile.shared \
        --target $target \
        --tag openrank-$target:latest \
        --tag openrank-$target:$(date +%Y%m%d-%H%M%S) \
        $cache_args \
        --load \
        ./node

    print_success "$target built successfully"
}

# Function to build all targets in parallel
build_parallel() {
    print_status "Building all targets in parallel..."

    local cache_args=""
    if [ "$USE_CACHE" = true ]; then
        cache_args="--cache-from=type=local,src=/tmp/.buildx-cache"
        cache_args="$cache_args --cache-to=type=local,dest=/tmp/.buildx-cache-new,mode=max"
    fi

    if [ "$PULL_IMAGES" = true ]; then
        cache_args="$cache_args --pull"
    fi

    # Build all targets in one command (Docker will parallelize automatically)
    docker buildx build \
        --file node/Dockerfile.shared \
        --target computer \
        --tag openrank-computer:latest \
        $cache_args \
        --load \
        ./node &

    docker buildx build \
        --file node/Dockerfile.shared \
        --target challenger \
        --tag openrank-challenger:latest \
        $cache_args \
        --load \
        ./node &

    docker buildx build \
        --file node/Dockerfile.shared \
        --target rxp \
        --tag openrank-rxp:latest \
        $cache_args \
        --load \
        ./node &

    # Wait for all builds to complete
    wait
    print_success "All targets built successfully in parallel"
}

# Function to setup build cache directory
setup_cache() {
    mkdir -p /tmp/.buildx-cache
    print_status "Build cache directory ready"
}

# Function to rotate cache
rotate_cache() {
    if [ -d "/tmp/.buildx-cache-new" ]; then
        rm -rf /tmp/.buildx-cache
        mv /tmp/.buildx-cache-new /tmp/.buildx-cache
        print_status "Build cache rotated"
    fi
}

# Function to show build stats
show_build_stats() {
    echo ""
    print_status "Build Statistics:"
    echo "=================="

    for target in computer challenger rxp; do
        if docker image inspect openrank-$target:latest &> /dev/null; then
            local size=$(docker image inspect openrank-$target:latest --format='{{.Size}}' | numfmt --to=iec)
            echo "  $target: $size"
        fi
    done

    echo ""
    print_status "Available images:"
    docker images | grep openrank | head -10
}

# Main execution
main() {
    print_status "OpenRank Optimized Build Script"
    echo "================================="

    # Change to project root directory
    cd "$(dirname "$0")/.."
    print_status "Working directory: $(pwd)"

    # Setup
    check_buildkit
    setup_buildkit
    setup_cache

    # Handle different build scenarios
    if [ "$PARALLEL_BUILD" = true ] || [[ " ${TARGETS[@]} " =~ " all " ]]; then
        if [ "$PARALLEL_BUILD" = true ]; then
            build_parallel
        else
            # Build all targets sequentially but efficiently
            for target in computer challenger rxp; do
                build_with_cache $target
            done
        fi
    else
        # Build specific targets
        for target in "${TARGETS[@]}"; do
            if [[ "$target" =~ ^(computer|challenger|rxp)$ ]]; then
                build_with_cache $target
            else
                print_warning "Unknown target: $target (skipping)"
            fi
        done
    fi

    # Cleanup and stats
    rotate_cache
    show_build_stats

    echo ""
    print_success "Build completed successfully!"
    print_status "To run the containers, use:"
    echo "  docker run -p 8080:8080 openrank-computer:latest"
    echo "  docker run -p 8081:8080 openrank-challenger:latest"
    echo "  docker run -p 8082:8080 openrank-rxp:latest"
    echo ""
    print_status "Or use docker-compose:"
    echo "  docker-compose up -d"
}

# Run main function
main "$@"
