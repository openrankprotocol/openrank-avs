#! /bin/bash

RXP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/../contracts/lib/rxp

cd "$RXP_DIR"/node && docker compose -f docker-compose.yml down && docker volume rm node_postgres_data

cd "$RXP_DIR"/archiver && docker compose -f docker-compose.yml down && docker volume rm archiver_postgres_data

cd "$RXP_DIR"/eigenda && docker compose -f docker-compose.yml down

pkill -f anvil

# Delete all networks starting with "reex-"
PREFIX="reex-"

# Get all networks that start with the specified prefix
CONTAINERS=$(docker ps -a --filter "name=$PREFIX" --format "{{.Names}}")

# Check if any networks were found
if [ -z "$CONTAINERS" ]; then
    echo "No containers found starting with: $PREFIX"
fi

# Print networks that will be deleted
echo "The following containers will be deleted:"
echo "$CONTAINERS"

# Prompt for confirmation
read -p "Do you want to proceed? (y/n): " CONFIRM

if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Delete each network
for CONTAINER in $CONTAINERS; do
    echo "Stopping container: $CONTAINER"
    docker stop $CONTAINER > /dev/null 2>&1
    echo "Removing container: $CONTAINER"
    docker rm $CONTAINER
    if [ $? -eq 0 ]; then
        echo "Successfully deleted: $CONTAINER"
    else
        echo "Failed to delete: $CONTAINER"
    fi
done

echo "Searching for Docker networks starting with: $PREFIX"

# Get all networks that start with the specified prefix
NETWORKS=$(docker network ls --filter "name=$PREFIX" --format "{{.Name}}")

# Check if any networks were found
if [ -z "$NETWORKS" ]; then
    echo "No networks found starting with: $PREFIX"
fi

# Print networks that will be deleted
echo "The following networks will be deleted:"
echo "$NETWORKS"

# Prompt for confirmation
read -p "Do you want to proceed? (y/n): " CONFIRM

if [[ $CONFIRM != "y" && $CONFIRM != "Y" ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Delete each network
for NETWORK in $NETWORKS; do
    echo "Deleting network: $NETWORK"
    docker network rm $NETWORK
    if [ $? -eq 0 ]; then
        echo "Successfully deleted: $NETWORK"
    else
        echo "Failed to delete: $NETWORK"
    fi
done

echo "Operation completed."
