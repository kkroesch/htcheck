# htcheck

HTTP health checker with Prometheus-compatible metric output. Written in Zig.

## Requirements

Zig 0.15.2

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

Binary: `zig-out/bin/htcheck`

## Usage

```bash
echo "https://example.com" | ./zig-out/bin/htcheck
```

## Output

```
# HELP htcheck_http_status_code HTTP response status code (0 if no response)
# TYPE htcheck_http_status_code gauge
htcheck_http_status_code{url="https://example.com"} 200

# HELP htcheck_dns_error DNS resolution error (1=error, 0=ok)
# TYPE htcheck_dns_error gauge
htcheck_dns_error{url="https://example.com"} 0

# HELP htcheck_response_time_seconds Time until HTTP response in seconds
# TYPE htcheck_response_time_seconds gauge
htcheck_response_time_seconds{url="https://example.com"} 0.042318

# HELP htcheck_connection_error TCP connection error (1=error, 0=ok)
# TYPE htcheck_connection_error gauge
htcheck_connection_error{url="https://example.com"} 0

# HELP htcheck_tls_error TLS handshake error (1=error, 0=ok)
# TYPE htcheck_tls_error gauge
htcheck_tls_error{url="https://example.com"} 0

# HELP htcheck_up Target reachable with valid HTTP response (1=up, 0=down)
# TYPE htcheck_up gauge
htcheck_up{url="https://example.com"} 1
```

## Integration

### Textfile Collector (node_exporter)

```bash
echo "https://myservice.example.com" | /usr/local/bin/htcheck \
  > /var/lib/prometheus/node-exporter/htcheck_myservice.prom
```

### Cron

```cron
* * * * * echo "https://myservice.example.com" | /usr/local/bin/htcheck > /var/lib/prometheus/node-exporter/htcheck_myservice.prom 2>&1
```

### script_exporter

Works with [script_exporter](https://github.com/ricoberger/script_exporter) as well.
