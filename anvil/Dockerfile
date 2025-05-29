# Use the latest foundry image
FROM ghcr.io/foundry-rs/foundry

USER root

# Install debugging tools
RUN apt-get update && apt-get install -y net-tools iproute2 && rm -rf /var/lib/apt/lists/*

# Set the working directory inside the container
WORKDIR /Anvil

# Copy our source code into the container
COPY . .

# Use array syntax for ENTRYPOINT
ENTRYPOINT ["anvil", "--host", "0.0.0.0"]
