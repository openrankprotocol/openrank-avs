set -e  # Exit on any error
# Build the base image first (contains both binaries)
docker build -t openrank-node:latest -f node/Dockerfile .
# Build the specialized images that use the base image
docker build -t openrank-node-computer:latest -f node/Dockerfile.node-computer .
docker build -t openrank-node-challenger:latest -f node/Dockerfile.node-challenger .
