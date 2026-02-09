# htcheck – HTTP health checker with Prometheus metrics

# Run tests
test:
    zig build test

# Build release binary
build:
    zig build -Doptimize=ReleaseSafe

# Run locally
run url="https://wikipedia.org/":
    zig build run -- {{url}}
