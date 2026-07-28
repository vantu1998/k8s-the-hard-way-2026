# 05 — Health Checking

## Probe là gì

Kubelet chạy **probe** để check container health. 3 loại probe:

| Probe | Khi nào check | Fail action |
|-------|---------------|-------------|
| **Startup** | Lúc khởi động (cho app start chậm) | Restart container |
| **Liveness** | Liên tục (sau khi started) | Restart container |
| **Readiness** | Liên tục (sau khi started) | Remove từ Service endpoints |

```
Container start
    │
    ▼
Startup probe (if configured)
    ├── Fail → restart container
    └── Pass → stop startup probe, start liveness + readiness
    │
    ▼
Liveness probe (continuous)
    ├── Fail → restart container
    └── Pass → container healthy

Readiness probe (continuous)
    ├── Fail → remove from Service endpoints (no traffic)
    └── Pass → add to Service endpoints (receive traffic)
```

## Startup probe

```yaml
spec:
  containers:
  - name: app
    image: my-app:latest
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30    # Fail 30 lần → restart
      periodSeconds: 10       # Check mỗi 10s
```

> Startup probe chạy **chỉ lúc khởi động**. `failureThreshold: 30` × `periodSeconds: 10` = 300s timeout. App có 5 phút để start. Sau khi pass → startup probe stop, liveness + readiness bắt đầu.

### Tại sao cần startup probe?

```
Without startup probe:
  - App start chậm (JVM warmup, DB migration) → 60s
  - Liveness probe fail (app chưa ready) → restart container
  - Container restart → app start lại → liveness fail → restart
  → CrashLoopBackOff (never finish starting)

With startup probe:
  - Startup probe: failureThreshold=30, period=10s → 300s timeout
  - App có 300s để start
  - Liveness probe DISABLED cho đến khi startup pass
  - App start xong → startup pass → liveness begin
```

> Startup probe **disable liveness** cho đến khi pass — app start chậm không bị restart. Dùng cho app có init时间长 (JVM, Python, DB migration).

## Liveness probe

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 15    # Đợi 15s trước khi check đầu tiên
  periodSeconds: 10          # Check mỗi 10s
  timeoutSeconds: 5          # Timeout 5s cho mỗi check
  failureThreshold: 3        # Fail 3 lần liên tiếp → restart
  successThreshold: 1        # Pass 1 lần → healthy
```

```
Liveness check timeline:
  t=0s:    Container start
  t=15s:   First liveness check (initialDelaySeconds=15)
  t=15s:   Pass → healthy
  t=25s:   Check → Pass
  t=35s:   Check → Fail (1/3)
  t=45s:   Check → Fail (2/3)
  t=55s:   Check → Fail (3/3) → RESTART container
```

> Liveness fail `failureThreshold` lần liên tiếp → kubelet **restart container**. Container restart = kill + create new container (not same process).

### Liveness không nên check dependency

```yaml
# BAD — liveness check DB connection
livenessProbe:
  httpGet:
    path: /db-health    # fail if DB down
  # → DB down → liveness fail → restart container
  # → container restart → DB still down → liveness fail → restart
  # → CrashLoopBackOff (restart không fix DB)

# GOOD — liveness check app process only
livenessProbe:
  httpGet:
    path: /healthz      # fail if app deadlock/crash
  # → App deadlock → liveness fail → restart → fix deadlock
```

> Liveness probe check **app process health** — không check dependency. DB down → readiness fail (remove traffic), không liveness fail (restart không giúp).

## Readiness probe

```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

```
Readiness check:
  Pass → pod added to Service endpoints (receive traffic)
  Fail → pod removed from Service endpoints (no traffic)
```

> Readiness fail **không restart** — chỉ remove khỏi Service endpoints. Pod vẫn chạy nhưng không nhận traffic. Dùng cho: app đang xử lý, DB down, config reload.

### Readiness vs Liveness

| | Liveness | Readiness |
|---|---|---|
| **Fail action** | Restart container | Remove from Service |
| **Use case** | App deadlock, crash | App running but not ready |
| **Dependency check** | No (don't check DB) | Yes (check DB, cache, config) |
| **Pod still runs** | No (restart) | Yes (just no traffic) |

```
Scenario: DB temporarily down
  Liveness fail → restart container → app still can't connect DB → restart again → CrashLoopBackOff
  Readiness fail → remove from Service → no traffic → DB recover → readiness pass → traffic resume
```

> **Readiness cho dependency, Liveness cho app process.** Readiness fail = temporary (DB down, config reload). Liveness fail = permanent (deadlock, crash).

## Probe types

### 1. HTTP GET

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
    httpHeaders:
    - name: Custom-Header
      value: health-check
  # Pass: HTTP 200-399
  # Fail: HTTP 400+ or connection refused
```

> Phổ biến nhất. App expose `/healthz` endpoint — return 200 if healthy, 500 if not.

### 2. TCP socket

```yaml
livenessProbe:
  tcpSocket:
    port: 3306
  # Pass: TCP connection success
  # Fail: TCP connection refused
```

> Dùng cho app không có HTTP endpoint (database, message queue). Check port open = healthy.

### 3. Exec

```yaml
livenessProbe:
  exec:
    command:
    - sh
    - -c
    - "pgrep nginx"
  # Pass: exit code 0
  # Fail: exit code non-zero
```

> Dùng cho custom check — chạy command trong container. Exit 0 = pass, non-zero = fail. Chậm hơn HTTP/TCP (spawn process mỗi check).

### 4. gRPC (v1.27+)

```yaml
livenessProbe:
  grpc:
    port: 9090
    service: myapp.HealthCheck   # optional
  # Uses gRPC Health Checking Protocol
```

> Dùng cho gRPC app — efficient, không cần HTTP endpoint. Implement `grpc.health.v1.Health` service.

## Probe timing parameters

| Parameter | Default | Ý nghĩa |
|-----------|---------|---------|
| `initialDelaySeconds` | 0 | Đợi N giây trước khi check đầu tiên |
| `periodSeconds` | 10 | Check mỗi N giây |
| `timeoutSeconds` | 1 | Timeout cho mỗi check |
| `failureThreshold` | 3 | Fail N lần liên tiếp → action |
| `successThreshold` | 1 | Pass N lần → healthy (readiness only) |

### initialDelaySeconds vs Startup probe

```
# Old way (before startup probe):
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 60    # Guess app needs 60s to start
  # Problem: if app starts in 5s → wait 55s unnecessarily
  # Problem: if app needs 90s → liveness fail at 60s → restart

# New way (startup probe):
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
  failureThreshold: 30
  periodSeconds: 10           # 300s timeout, no guessing
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 10           # starts after startup passes
```

> Startup probe tốt hơn `initialDelaySeconds` — không cần guess start time. App start xong → startup pass → liveness begin ngay.

### successThreshold (readiness only)

```yaml
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
  successThreshold: 2    # Need 2 consecutive pass → ready
  periodSeconds: 5
```

> `successThreshold: 2` = cần 2 lần pass liên tiếp mới add vào Service endpoints. Tránh flapping — app ready → not ready → ready. Default = 1.

> Liveness **ignore** `successThreshold` — luôn 1 (1 pass = healthy, restart counter reset).

## Probe best practices

### 1. Liveness: check app process only

```yaml
# GOOD — check app alive
livenessProbe:
  httpGet:
    path: /healthz       # return 200 if process alive
  failureThreshold: 3
  periodSeconds: 10

# BAD — check dependency
livenessProbe:
  httpGet:
    path: /db-check      # fail if DB down → restart (doesn't fix DB)
```

### 2. Readiness: check dependency

```yaml
# GOOD — check app + dependency
readinessProbe:
  httpGet:
    path: /ready         # return 200 if app ready + DB connected
  failureThreshold: 3
  periodSeconds: 5
```

### 3. Startup: cho app start chậm

```yaml
startupProbe:
  httpGet:
    path: /healthz
    port: 8080
  failureThreshold: 30   # 30 × 10s = 300s timeout
  periodSeconds: 10
```

### 4. Don't use liveness without readiness

```yaml
# BAD — only liveness, no readiness
# → Pod receive traffic immediately (before app ready)
# → Request fail until liveness first pass

# GOOD — readiness + liveness
readinessProbe:
  httpGet:
    path: /ready
    port: 8080
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
```

> Readiness = traffic control (don't send traffic to not-ready pod). Liveness = restart control (restart dead pod). Cần cả 2.

## Endpoint controller interaction

```
Readiness PASS → kubelet update pod status (Ready=True)
  → Endpoint controller watch pod status
  → Add pod IP to Service endpoints
  → kube-proxy update iptables → traffic route to pod

Readiness FAIL → kubelet update pod status (Ready=False)
  → Endpoint controller remove pod IP from Service endpoints
  → kube-proxy update iptables → no traffic to pod
```

```bash
# Check endpoints
kubectl get endpoints my-service
# NAME          ENDPOINTS
# my-service    10.244.1.5:8080,10.244.2.3:8080   ← only ready pods

# Pod not ready → not in endpoints
kubectl get pod -l app=web -o wide
# NAME       READY   STATUS    NODE
# web-aaa    1/1     Running   worker-1   ← Ready=True → in endpoints
# web-bbb    0/1     Running   worker-2   ← Ready=False → NOT in endpoints
```

> `READY` column = `readinessProbe pass / total containers`. `1/1` = all container ready. `0/1` = container running but readiness not pass → no traffic.

## Liên hệ với Kubernetes

- **Startup probe**: check lúc khởi động, disable liveness cho đến khi pass. Dùng cho app start chậm (JVM, DB migration).
- **Liveness probe**: check liên tục, fail → **restart container**. Check app process health, KHÔNG check dependency.
- **Readiness probe**: check liên tục, fail → **remove from Service endpoints** (no traffic). Check dependency (DB, cache).
- Probe types: HTTP GET (phổ biến), TCP socket (database), Exec (custom), gRPC (gRPC app).
- `initialDelaySeconds` = guess start time (deprecated — dùng startup probe).
- `failureThreshold` × `periodSeconds` = timeout window (3 × 10s = 30s).
- `successThreshold` chỉ cho readiness — cần N pass liên tiếp để add vào endpoints (tránh flapping).
- Liveness check app process, Readiness check dependency. Cần cả 2.
- Readiness pass → Endpoint controller add pod IP → kube-proxy route traffic.
- Readiness fail → pod vẫn chạy nhưng no traffic — temporary state (DB down, config reload).
