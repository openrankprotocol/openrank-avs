FROM rust:latest AS builder

WORKDIR /app

COPY . .

RUN cargo build --release --bin openrank-rxp

# Use a minimal alpine image for the final image
FROM alpine:latest

WORKDIR /app

# Copy the binary from the builder stage
COPY --from=builder /app/target/release/openrank-rxp .

# Set the entrypoint
ENTRYPOINT ["/app/openrank-rxp"]
