
[![Zig Tests](https://github.com/kkroesch/htcheck/actions/workflows/test.yml/badge.svg)](https://github.com/kkroesch/htcheck/actions/workflows/test.yml)

![](logo.png)

# Htcheck & Co.

Lightweight monitoring tools with Prometheus-compatible metric output. Written in Zig.

Two binaries, one project:

- **htcheck** – HTTP health checker
- **certcheck** – TLS certificate expiry checker

## Requirements

- Zig 0.15.2
- `openssl` CLI in PATH (for certcheck)

## Build

```bash
zig build -Doptimize=ReleaseSafe
```

Binaries: `zig-out/bin/htcheck` and `zig-out/bin/certcheck`

```bash
zig build test        # Run all tests
zig build run-htcheck -- -s https://example.com
zig build run-certcheck -- -s example.com
```

## htcheck

HTTP health checker. Measures status code, response time, content length, and classifies errors (DNS, TCP, TLS).

### Usage

```bash
htcheck <url>              # Prometheus metrics (default)
htcheck -s <url>           # Short colored CLI output
htcheck --short <url>
htcheck -h                 # Help
```

### Short mode

```
✓ 2025-02-09 14:23:01  200  0.342s  12.4K  https://example.com
✗ 2025-02-09 14:23:02  ---  0.001s  0B     https://broken.invalid
  └ UnknownHostName
```

### Prometheus output

```
htcheck_http_status_code{url="https://example.com"} 200
htcheck_dns_error{url="https://example.com"} 0
htcheck_connection_error{url="https://example.com"} 0
htcheck_tls_error{url="https://example.com"} 0
htcheck_response_time_seconds{url="https://example.com"} 0.042318
htcheck_content_length_bytes{url="https://example.com"} 12847
htcheck_up{url="https://example.com"} 1
```

## certcheck

TLS certificate expiry checker. Connects to a remote host via `openssl s_client` and reports certificate details and days until expiry.

### Usage

```bash
certcheck <host[:port]>    # Prometheus metrics (default)
certcheck -s <host>        # Short colored CLI output
certcheck -h               # Help
```

Default port is 443. Also accepts URL-style input (`https://example.com`).

### Short mode

```
✓ 2025-02-09 14:23:01  🔒 87d  example.com  C=US, O=Let's Encrypt, CN=R3
✓ 2025-02-09 14:23:02  🔒 12d  staging.example.com  C=US, O=Let's Encrypt, CN=R3
✗ 2025-02-09 14:23:03  🔓 -3d  expired.example.com  C=US, O=Let's Encrypt, CN=R3
```

Color scheme: green (>30d), yellow (7–30d), red (≤7d).

### Prometheus output

```
certcheck_days_remaining{host="example.com",port="443"} 87
certcheck_expired{host="example.com",port="443"} 0
certcheck_up{host="example.com",port="443"} 1
```

## Integration

### Push to VictoriaMetrics

```bash
VM_URL="http://victoria:8428/api/v1/import/prometheus"

htcheck https://myservice.example.com \
  | curl -s -X POST "$VM_URL?extra_label=job=htcheck" --data-binary @-

certcheck example.com \
  | curl -s -X POST "$VM_URL?extra_label=job=certcheck" --data-binary @-
```

### Textfile collector (node_exporter / Caddy)

```bash
htcheck https://myservice.example.com > /var/lib/prometheus/htcheck.prom.tmp
mv /var/lib/prometheus/htcheck.prom.tmp /var/lib/prometheus/htcheck.prom
```

Atomic `mv` ensures no partial reads.

### Cron – check multiple targets

```bash
#!/bin/bash
for url in https://app.example.com https://api.example.com; do
    htcheck "$url" | curl -s -X POST "$VM_URL?extra_label=job=htcheck" --data-binary @-
done

for host in app.example.com api.example.com; do
    certcheck "$host" | curl -s -X POST "$VM_URL?extra_label=job=certcheck" --data-binary @-
done
```

### Quick admin check

```bash
for host in kroesch.ch api.example.com staging.example.com; do
    htcheck -s "https://$host"
    certcheck -s "$host"
done
```

### Alerting example (Prometheus/Alertmanager)

```yaml
groups:
  - name: moncheck
    rules:
      - alert: EndpointDown
        expr: htcheck_up == 0
        for: 5m
        labels:
          severity: critical

      - alert: CertExpiringSoon
        expr: certcheck_days_remaining < 14
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "Cert {{ $labels.host }} expires in {{ $value }} days"
```
