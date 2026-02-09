# htcheck – HTTP health checker with Prometheus metrics

# Run tests
test:
    zig build test

# Build release binary
build:
    zig build -Doptimize=ReleaseSafe

cc:
    zig build-exe -OReleaseSafe src/certcheck.zig

# Run locally
run url="https://wikipedia.org/":
    zig build run -- {{url}}

# Run with --short flag
short url="https://wikipedia.org/":
    zig run -- --short {{url}}
