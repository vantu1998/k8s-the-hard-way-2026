# Exercise 04 — Graceful Shutdown

> **Mục tiêu**: Deploy pod với preStop hook + `terminationGracePeriodSeconds: 60`, delete pod, quan sát graceful shutdown flow.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4)

## Bối cảnh

Graceful shutdown: preStop hook → SIGTERM → wait grace period → SIGKILL. Bài này deploy pod với preStop hook, delete pod, quan sát shutdown timeline.

## Bước 1: Deploy pod với preStop hook

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: graceful-shutdown
  labels:
    app: graceful-shutdown
spec:
  terminationGracePeriodSeconds: 60
  containers:
  - name: nginx
    image: nginx
    ports:
    - containerPort: 80
    lifecycle:
      preStop:
        exec:
          command:
          - sh
          - -c
          - "echo 'preStop started at $(date)' >> /tmp/shutdown.log; nginx -s quit; sleep 10; echo 'preStop done at $(date)' >> /tmp/shutdown.log"
    volumeMounts:
    - name: log
      mountPath: /tmp
  volumes:
  - name: log
    emptyDir: {}
EOF
```

### Giải thích

| Field | Value | Ý nghĩa |
|-------|-------|---------|
| `terminationGracePeriodSeconds` | 60 | Tổng timeout: preStop + SIGTERM |
| `preStop.exec` | nginx -s quit + sleep 10 | Graceful quit nginx, đợi 10s |
| `emptyDir` volume | /tmp | Log file survive container restart (cho debug) |

```bash
kubectl wait --for=condition=Ready pod graceful-shutdown --timeout=60s

# Verify
kubectl get pod graceful-shutdown
# NAME                READY   STATUS    RESTARTS   AGE
# graceful-shutdown   1/1     Running   0          10s
```

**Kiểm tra**: Pod Running.

## Bước 2: Delete pod — quan sát graceful shutdown

```bash
# Record start time
date +%s
# 1735689600

# Delete pod (non-blocking — don't wait)
kubectl delete pod graceful-shutdown &
DELETE_PID=$!

# Immediately check pod status
kubectl get pod graceful-shutdown
# NAME                READY   STATUS        RESTARTS   AGE
# graceful-shutdown   1/1     Terminating   0          30s   ← Terminating (not deleted yet)
```

```bash
# Check events — preStop + SIGTERM
kubectl get events --sort-by='.lastTimestamp' --watch | grep graceful
# NORMAL  Killing     pod/graceful-shutdown  Stopping container nginx
# (preStop hook running — nginx -s quit + sleep 10)
```

## Bước 3: Quan sát shutdown timeline

```bash
# Check pod status over time
kubectl get pod graceful-shutdown -w
# graceful-shutdown   1/1   Running      0   30s
# graceful-shutdown   1/1   Terminating  0   31s   ← preStop starts
# graceful-shutdown   1/1   Terminating  0   41s   ← preStop done (10s), SIGTERM sent
# graceful-shutdown   1/1   Terminating  0   50s   ← container shutting down
# graceful-shutdown   0/1   Terminating  0   55s   ← container exited
# graceful-shutdown   0/1   Terminating  0   56s   ← sandbox destroying
# (pod deleted)
```

```
Timeline (terminationGracePeriodSeconds=60):
  t=0s:   Delete pod → preStop hook starts
  t=0s:   preStop: nginx -s quit (graceful stop accepting new connections)
  t=10s:  preStop: sleep 10 done → preStop complete
  t=10s:  SIGTERM sent to container
  t=10s:  Container graceful shutdown (finish in-flight requests)
  t=15s:  Container exits (nginx graceful quit complete)
  t=15s:  Kubelet stop container (CRI: StopContainer)
  t=15s:  Kubelet destroy sandbox (CRI: StopPodSandbox + RemovePodSandbox)
  t=16s:  Pod deleted from API Server
```

> preStop (10s) + SIGTERM + container exit (5s) = 15s total. Well within 60s grace period. Nếu container không exit trong 60s → SIGKILL.

**Kiểm tra**: Pod `Terminating` trong ~15s, preStop chạy trước SIGTERM.

## Bước 4: Verify preStop log

```bash
# Trong lúc pod Terminating, exec vào container để read log
kubectl exec graceful-shutdown -- cat /tmp/shutdown.log
# preStop started at Mon Jan  1 00:00:00 UTC 2026
# preStop done at Mon Jan  1 00:00:10 UTC 2026

# (Nếu pod đã deleted, log mất — emptyDir bị xóa khi pod delete)
```

> preStop log: started at t=0, done at t=10s (sleep 10). Confirm preStop chạy trước SIGTERM.

**Kiểm tra**: Log hiển thị preStop start + done time, 10s apart.

## Bước 5: Test grace period exceeded — SIGKILL

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: slow-shutdown
spec:
  terminationGracePeriodSeconds: 10   # short grace period
  containers:
  - name: app
    image: busybox
    args:
    - /bin/sh
    - -c
    - "trap 'echo SIGTERM received; sleep 30' TERM; sleep 600"
    lifecycle:
      preStop:
        exec:
          command: ["sleep", "5"]
EOF
```

```bash
kubectl wait --for=condition=Ready pod slow-shutdown --timeout=60s

# Delete pod
kubectl delete pod slow-shutdown &

# Quan sát — grace period 10s exceeded → SIGKILL
kubectl get pod slow-shutdown -w
# slow-shutdown   1/1   Running      0   15s
# slow-shutdown   1/1   Terminating  0   16s   ← preStop starts (sleep 5)
# slow-shutdown   1/1   Terminating  0   21s   ← preStop done (5s), SIGTERM sent
# slow-shutdown   1/1   Terminating  0   26s   ← container ignore SIGTERM (trap + sleep 30)
# slow-shutdown   1/1   Terminating  0   31s   ← grace period (10s) exceeded
# slow-shutdown   0/1   Terminating  0   31s   ← SIGKILL! container force killed
# (pod deleted)
```

```
Timeline (terminationGracePeriodSeconds=10):
  t=0s:   Delete → preStop starts (sleep 5)
  t=5s:   preStop done → SIGTERM sent
  t=5s:   Container trap SIGTERM → sleep 30 (ignore SIGTERM)
  t=10s:  Grace period exceeded (10s total) → SIGKILL
  t=10s:  Container force killed → pod deleted
```

> Container **ignore SIGTERM** (trap + sleep 30) → grace period 10s exceeded → **SIGKILL**. SIGKILL = kernel kill, không catch được. Container bị force kill ngay.

**Kiểm tra**: Pod Terminating > 10s → SIGKILL → pod deleted. Container không graceful exit.

## Bước 6: Test preStop HTTP hook

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: prestop-http
spec:
  terminationGracePeriodSeconds: 30
  containers:
  - name: nginx
    image: nginx
    lifecycle:
      preStop:
        httpGet:
          path: /
          port: 80
EOF
```

```bash
kubectl wait --for=condition=Ready pod prestop-http --timeout=60s

# Delete pod
kubectl delete pod prestop-http &

# preStop HTTP GET / port 80 → nginx return 200 → preStop done → SIGTERM
kubectl get events --sort-by='.lastTimestamp' | grep prestop-http
# NORMAL  Killing    pod/prestop-http  Stopping container nginx
# (preStop HTTP GET → 200 → done → SIGTERM)
```

> preStop HTTP hook: kubelet GET `http://<pod-ip>:80/` → 200 = preStop done → SIGTERM. Dùng cho app có `/shutdown` endpoint (deregister from load balancer).

**Kiểm tra**: Pod Terminating, preStop HTTP hook chạy (GET / port 80).

## Cleanup

```bash
kubectl delete pod graceful-shutdown slow-shutdown prestop-http 2>/dev/null
wait 2>/dev/null
```

## Câu hỏi tự kiểm tra

1. Graceful shutdown flow: preStop → SIGTERM → SIGKILL. Giải thích từng bước.
2. `terminationGracePeriodSeconds: 60` — preStop chạy 20s, SIGTERM có bao nhiêu giây trước SIGKILL?
3. Container ignore SIGTERM (trap + sleep) — điều gì xảy ra khi grace period exceeded?
4. preStop hook fail (exit non-zero) — pod có bị stuck không?
5. preStop exec vs preStop httpGet — khi nào dùng cái nào?

## Đáp án tham khảo

1. **preStop**: kubelet chạy preStop hook (exec/httpGet) trước SIGTERM — graceful quit, deregister. **SIGTERM**: kubelet send SIGTERM to container — container catch signal, cleanup, exit. **SIGKILL**: nếu container chưa exit sau grace period → kubelet send SIGKILL (kernel kill, không catch).
2. preStop 20s + SIGTERM = 60s total → SIGTERM có **40s** (60 - 20 = 40). preStop + SIGTERM **cùng countdown** grace period. Nếu preStop chạy lâu → SIGTERM ít thời gian hơn.
3. Grace period exceeded → **SIGKILL**. SIGKILL = kernel kill process ngay, không catch được, không cleanup. Container bị force kill. Data có thể lost (no flush, no save).
4. **Không stuck** — preStop fail (exit non-zero) → kubelet vẫn send SIGTERM. preStop error không block shutdown. Kubelet log warning nhưng tiếp tục shutdown flow.
5. **exec**: chạy command trong container — `nginx -s quit`, `curl localhost/deregister`. Dùng khi cần command cụ thể. **httpGet**: HTTP GET to container — `/shutdown`, `/deregister`. Dùng khi app có HTTP endpoint cho shutdown. exec flexible hơn, httpGet đơn giản hơn (không cần shell).
