# Exercise 03 — Liveness Probe

> **Mục tiêu**: Deploy pod với liveness probe HTTP, kill endpoint, quan sát container restart. Hiểu liveness probe fail → restart.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4)

## Bối cảnh

Liveness probe check container health. Fail → kubelet restart container. Bài này deploy pod với liveness HTTP probe, break endpoint, quan sát restart.

## Bước 1: Deploy pod với liveness probe

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: liveness-http
  labels:
    app: liveness-http
spec:
  containers:
  - name: app
    image: registry.k8s.io/liveness
    args:
    - /server
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 3
EOF
```

> `registry.k8s.io/liveness` — image test cho probe. Endpoint `/healthz` return 200 (healthy) hoặc 500 (unhealthy). Image có built-in mechanism: sau 10 request `/healthz` → return 500.

```bash
# Đợi pod ready
kubectl wait --for=condition=Ready pod liveness-http --timeout=60s

# Verify
kubectl get pod liveness-http
# NAME            READY   STATUS    RESTARTS   AGE
# liveness-http   1/1     Running   0          15s
```

**Kiểm tra**: Pod Running, `RESTARTS=0`.

## Bước 2: Quan sát liveness probe pass

```bash
# Check pod events — liveness probe passing
kubectl describe pod liveness-http | grep -A 5 "Liveness"
# Liveness:  http-get http://:8080/healthz delay=5s timeout=1s period=5s #success=1 #failure=3

kubectl get events --sort-by='.lastTimestamp' | grep liveness
# NORMAL  Pulled       pod/liveness-http  Successfully pulled image
# NORMAL  Created      pod/liveness-http  Created container app
# NORMAL  Started      pod/liveness-http  Started container app
# NORMAL  Unhealthy    pod/liveness-http  Liveness probe failed: HTTP probe failed with statuscode: 500
# (sau vài request — image tự return 500 sau 10 request)
```

## Bước 3: Quan sát liveness fail → restart

```bash
# Watch pod — sau ~50s (10 request × 5s), liveness fail 3 lần → restart
kubectl get pod liveness-http -w
# NAME            READY   STATUS    RESTARTS   AGE
# liveness-http   1/1     Running   0          15s
# liveness-http   1/1     Running   0          30s
# liveness-http   1/1     Running   0          45s
# liveness-http   0/1     Running   0          50s    ← liveness fail (1/3)
# liveness-http   0/1     Running   0          55s    ← liveness fail (2/3)
# liveness-http   0/1     Running   0          60s    ← liveness fail (3/3)
# liveness-http   1/1     Running   1          62s    ← RESTART! RESTARTS=1
```

```bash
# Check events
kubectl describe pod liveness-http | tail -10
# Events:
#   NORMAL  Started      pod/liveness-http  Started container app
#   WARNING Unhealthy    pod/liveness-http  Liveness probe failed: HTTP probe failed with statuscode: 500
#   WARNING Unhealthy    pod/liveness-http  Liveness probe failed: HTTP probe failed with statuscode: 500
#   WARNING Unhealthy    pod/liveness-http  Liveness probe failed: HTTP probe failed with statuscode: 500
#   NORMAL  Killing      pod/liveness-http  Container app failed liveness probe, will be restarted
#   NORMAL  Pulled       pod/liveness-http  Container image "registry.k8s.io/liveness" already present on host
#   NORMAL  Created      pod/liveness-http  Created container app
#   NORMAL  Started      pod/liveness-http  Started container app
```

> Liveness fail 3 lần (`failureThreshold=3`) → kubelet **kill container** → **create new container**. `RESTARTS` +1. New container → liveness pass again (fresh state).

**Kiểm tra**: `RESTARTS=1` sau khi liveness fail 3 lần. Event log hiển thị `Killing` + `Created` + `Started`.

## Bước 4: Test TCP liveness probe

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: liveness-tcp
spec:
  containers:
  - name: nginx
    image: nginx
    livenessProbe:
      tcpSocket:
        port: 80
      periodSeconds: 5
      failureThreshold: 3
EOF
```

```bash
kubectl wait --for=condition=Ready pod liveness-tcp --timeout=60s

# Liveness TCP check — port 80 open = healthy
kubectl get pod liveness-tcp
# NAME           READY   STATUS    RESTARTS   AGE
# liveness-tcp   1/1     Running   0          10s

# Kill nginx inside container → port 80 closed → liveness fail
kubectl exec liveness-tcp -- nginx -s stop

# Quan sát — liveness fail → restart
kubectl get pod liveness-tcp -w
# liveness-tcp   1/1   Running   0   30s
# liveness-tcp   0/1   Running   0   35s   ← TCP probe fail (port closed)
# liveness-tcp   0/1   Running   0   40s
# liveness-tcp   0/1   Running   0   45s
# liveness-tcp   1/1   Running   1   47s   ← RESTART! nginx restart → port 80 open
```

> TCP probe check port open = healthy. Port closed (nginx stopped) → fail 3 lần → restart. New container → nginx start → port 80 open → pass.

**Kiểm tra**: `RESTARTS=1` sau khi nginx stop, TCP probe fail.

## Bước 5: Test exec liveness probe

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: liveness-exec
spec:
  containers:
  - name: busybox
    image: busybox
    args:
    - /bin/sh
    - -c
    - touch /tmp/healthy; sleep 30; rm /tmp/healthy; sleep 600
    livenessProbe:
      exec:
        command:
        - cat
        - /tmp/healthy
      periodSeconds: 5
      failureThreshold: 3
EOF
```

```bash
kubectl get pod liveness-exec -w
# NAME            READY   STATUS    RESTARTS   AGE
# liveness-exec   1/1     Running   0          5s    ← /tmp/healthy exists → pass
# liveness-exec   1/1     Running   0          30s
# liveness-exec   1/1     Running   0          35s   ← rm /tmp/healthy → fail (1/3)
# liveness-exec   1/1     Running   0          40s   ← fail (2/3)
# liveness-exec   1/1     Running   0          45s   ← fail (3/3)
# liveness-exec   0/1   Running   1          47s   ← RESTART! touch /tmp/healthy again
# liveness-exec   1/1   Running   1          50s   ← pass again (file recreated)
```

> Exec probe: `cat /tmp/healthy` — exit 0 if file exists (pass), exit 1 if not (fail). Container tạo file, sleep 30s, xóa file → fail → restart → tạo file lại → pass.

**Kiểm tra**: `RESTARTS=1` sau khi file bị xóa, exec probe fail.

## Bước 6: Test startup probe

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: startup-probe
spec:
  containers:
  - name: app
    image: registry.k8s.io/liveness
    args:
    - /server
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      failureThreshold: 30
      periodSeconds: 10
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      periodSeconds: 5
      failureThreshold: 3
EOF
```

```bash
# Startup probe: 30 × 10s = 300s timeout
# Liveness DISABLED until startup passes
kubectl get pod startup-probe
# NAME            READY   STATUS    RESTARTS   AGE
# startup-probe   0/1     Running   0          5s    ← startup checking, liveness disabled

# After startup passes:
kubectl get pod startup-probe
# startup-probe   1/1     Running   0          15s   ← startup pass, liveness begins
```

> Startup probe disable liveness cho đến khi pass. App có 300s để start (thay vì `initialDelaySeconds` guess). Sau startup pass → liveness begin.

**Kiểm tra**: Pod `Running` với `READY=0` trong lúc startup probe checking. Sau pass → `READY=1`.

## Cleanup

```bash
kubectl delete pod liveness-http liveness-tcp liveness-exec startup-probe
```

## Câu hỏi tự kiểm tra

1. Liveness probe fail → điều gì xảy ra? Container restart hay pod reschedule?
2. `failureThreshold=3, periodSeconds=5` — bao lâu từ first fail đến restart?
3. HTTP vs TCP vs Exec probe — khác nhau thế nào? Khi nào dùng cái nào?
4. Startup probe khác `initialDelaySeconds` thế nào? Tại sao tốt hơn?
5. Liveness probe check DB connection — tốt hay xấu? Tại sao?

## Đáp án tham khảo

1. Liveness fail `failureThreshold` lần liên tiếp → kubelet **restart container** (kill + create new container, same pod). **Không reschedule** — pod vẫn trên cùng node. restartCount++ trong container status.
2. 3 × 5s = **15s** từ first fail đến restart. First fail at t=0, second at t=5s, third at t=10s → restart at t=10s (immediately after 3rd fail). Plus `initialDelaySeconds` before first check.
3. HTTP: check HTTP endpoint (200=pass, 400+=fail) — phổ biến nhất, app expose `/healthz`. TCP: check port open — cho database, message queue. Exec: chạy command (exit 0=pass) — custom check, chậm hơn (spawn process mỗi check). HTTP cho web app, TCP cho non-HTTP, Exec cho custom logic.
4. Startup probe **disable liveness** cho đến khi pass — app có timeout window (failureThreshold × periodSeconds) để start. `initialDelaySeconds` = guess fixed delay — nếu app start nhanh hơn → wait vô ích, nếu start chậm hơn → liveness fail → restart. Startup probe adaptive — không cần guess.
5. **Xấu** — DB down → liveness fail → restart container → DB vẫn down → liveness fail → restart → CrashLoopBackOff. Restart không fix DB. Dùng **readiness probe** check DB — fail → remove from Service (no traffic), pod vẫn chạy. DB recover → readiness pass → traffic resume.
