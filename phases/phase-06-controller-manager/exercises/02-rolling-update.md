# Exercise 02 — Rolling Update

> **Mục tiêu**: Rolling update image, quan sát 2 ReplicaSet (cũ + mới) cùng tồn tại, pod thay đổi dần. Hiểu maxSurge/maxUnavailable.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4)

## Bối cảnh

Deployment rolling update tạo ReplicaSet mới, scale lên dần, scale ReplicaSet cũ xuống dần. Bài này quan sát 2 RS cùng tồn tại, pod thay đổi từng bước.

## Bước 1: Deploy v1

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 4
  selector:
    matchLabels:
      app: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Verify
kubectl get deploy web
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    4/4     4            4           10s

kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    4         4         4       10s
```

**Kiểm tra**: 4 pod running nginx:1.25, 1 ReplicaSet.

## Bước 2: Trigger rolling update — v2

```bash
# Update image
kubectl set image deployment/web nginx=nginx:1.26

# Quan sát rollout status realtime
kubectl rollout status deployment/web --watch
# Waiting for deployment "web" rollout to finish: 1 out of 4 new replicas have been updated...
# Waiting for deployment "web" rollout to finish: 2 out of 4 new replicas have been updated...
# Waiting for deployment "web" rollout to finish: 3 out of 4 new replicas have been updated...
# Waiting for deployment "web" rollout to finish: 4 out of 4 new replicas have been updated...
# deployment "web" successfully rolled out
```

## Bước 3: Quan sát 2 ReplicaSet cùng tồn tại

```bash
# Trong lúc rolling update (chạy nhanh, có thể cần watch)
kubectl get rs -l app=web -w
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    4         4         4       2m      ← RS cũ (v1)
# web-def456    0         0         0       0s      ← RS mới (v2) vừa tạo
# web-def456    1         0         0       1s      ← RS mới scale lên 1 (maxSurge=1)
# web-abc123    3         4         4       2m      ← RS cũ scale xuống 3 (pod v2 ready)
# web-def456    2         1         1       3s
# web-abc123    2         3         3       2m
# web-def456    3         2         2       5s
# web-abc123    1         2         2       2m
# web-def456    4         3         3       7s
# web-abc123    0         1         1       2m
# web-def456    4         4         4       10s     ← RS mới full, RS cũ = 0
```

> 2 RS cùng tồn tại: RS-cũ scale xuống, RS-mới scale lên. `maxSurge=1` → tổng pod tối đa = 4+1 = 5. `maxUnavailable=0` → tổng available ≥ 4.

```bash
# Sau rollout complete
kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    0         0         0       5m     ← RS cũ (replicas=0, kept for rollback)
# web-def456    4         4         4       3m     ← RS mới (current)
```

**Kiểm tra**: 2 ReplicaSet — RS-mới `DESIRED=4`, RS-cũ `DESIRED=0` (giữ lại cho rollback).

## Bước 4: Verify pod chạy image mới

```bash
# Check image version
kubectl get pod -l app=web -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-def456-aaa   nginx:1.26
# web-def456-bbb   nginx:1.26
# web-def456-ccc   nginx:1.26
# web-def456-ddd   nginx:1.26

# All pod running nginx:1.26
```

**Kiểm tra**: Tất cả pod chạy `nginx:1.26`.

## Bước 5: Quan sát event log

```bash
kubectl get events --sort-by='.lastTimestamp' | grep -E "(web|Scaling)"
# NORMAL  ScalingReplicaSet  deployment/web  Scaled up replica set web-def456 to 1
# NORMAL  ScalingReplicaSet  deployment/web  Scaled down replica set web-abc123 to 3
# NORMAL  ScalingReplicaSet  deployment/web  Scaled up replica set web-def456 to 2
# NORMAL  ScalingReplicaSet  deployment/web  Scaled down replica set web-abc123 to 2
# NORMAL  ScalingReplicaSet  deployment/web  Scaled up replica set web-def456 to 3
# NORMAL  ScalingReplicaSet  deployment/web  Scaled down replica set web-abc123 to 1
# NORMAL  ScalingReplicaSet  deployment/web  Scaled up replica set web-def456 to 4
# NORMAL  ScalingReplicaSet  deployment/web  Scaled down replica set web-abc123 to 0
```

> Deployment controller scale RS lên/xuống **đan xen** — scale RS-mới lên 1, scale RS-cũ xuống 1, repeat. Đảm bảo `maxSurge` và `maxUnavailable`.

## Bước 6: Test maxSurge=0, maxUnavailable=1

```bash
# Update strategy
kubectl patch deployment web --type=json -p='[
  {"op":"replace","path":"/spec/strategy/rollingUpdate/maxSurge","value":0},
  {"op":"replace","path":"/spec/strategy/rollingUpdate/maxUnavailable","value":1}
]'

# Trigger update
kubectl set image deployment/web nginx=nginx:1.27

# Quan sát — không có pod thừa (maxSurge=0), có lúc 3 pod available (maxUnavailable=1)
kubectl get rs -l app=web -w
# web-def456    4         4         4       5m     ← RS v2 (cũ giờ)
# web-ghi789    0         0         0       0s     ← RS v3 (mới)
# web-def456    3         4         4       5m     ← scale xuống 3 (unavailable=1)
# web-ghi789    1         0         0       1s     ← scale lên 1
# web-def456    2         3         3       5m
# web-ghi789    2         1         1       3s
# ...
```

> `maxSurge=0` → tổng pod không vượt 4. `maxUnavailable=1` → có lúc chỉ 3 pod available. **Không zero downtime** nhưng tiết kiệm resource.

**Kiểm tra**: Tổng pod không vượt 4 (maxSurge=0), có lúc 3 available (maxUnavailable=1).

## Bước 7: Test Recreate strategy

```bash
# Change strategy to Recreate
kubectl patch deployment web --type=json -p='[
  {"op":"replace","path":"/spec/strategy/type","value":"Recreate"}
]'

# Trigger update
kubectl set image deployment/web nginx=nginx:1.28

# Quan sát — xóa hết pod cũ trước, tạo pod mới sau (DOWNTIME)
kubectl get pod -l app=web -w
# web-ghi789-aaa   1/1   Terminating   0   5m
# web-ghi789-bbb   1/1   Terminating   0   5m
# web-ghi789-ccc   1/1   Terminating   0   5m
# web-ghi789-ddd   1/1   Terminating   0   5m
# (all pod deleted — DOWNTIME)
# web-jkl012-aaa   0/1   Pending       0   0s
# web-jkl012-bbb   0/1   Pending       0   0s
# web-jkl012-ccc   0/1   Pending       0   0s
# web-jkl012-ddd   0/1   Pending       0   0s
# (all new pod created at once)
```

> `Recreate` = xóa hết pod cũ → tạo hết pod mới. **Có downtime** (khoảng vài giây đến phút). Dùng khi app không hỗ trợ 2 version cùng chạy.

**Kiểm tra**: Tất cả pod cũ `Terminating` trước khi pod mới tạo — có downtime.

## Cleanup

```bash
kubectl delete deployment web
```

## Câu hỏi tự kiểm tra

1. Rolling update tạo bao nhiêu ReplicaSet? RS cũ có bị xóa không?
2. `maxSurge=1, maxUnavailable=0` với replicas=4 — tổng pod tối đa và tối thiểu trong rolling?
3. `maxSurge=0, maxUnavailable=1` — có zero downtime không? Tại sao?
4. `Recreate` strategy khác `RollingUpdate` thế nào? Khi nào dùng?
5. Tại sao Deployment giữ RS cũ (replicas=0) sau rolling update?

## Đáp án tham khảo

1. 2 ReplicaSet — RS-cũ (image cũ) và RS-mới (image mới). RS-cũ **không bị xóa** — scale xuống replicas=0, giữ lại cho rollback. Xóa khi vượt `revisionHistoryLimit` (default 10).
2. Tối đa = 4 + maxSurge = 5 pod. Tối thiểu available = 4 - maxUnavailable = 4 pod. Zero downtime — luôn đủ 4 pod available, có 1 pod thừa (surge) trong rolling.
3. **Không zero downtime** — `maxUnavailable=1` cho phép 1 pod unavailable → có lúc chỉ 3 pod available. `maxSurge=0` = không tạo pod thừa → tiết kiệm resource nhưng đánh đổi availability.
4. `Recreate` = xóa hết pod cũ, tạo hết pod mới → **có downtime**. `RollingUpdate` = tạo pod mới + xóa pod cũ dần → **zero downtime** (với maxUnavailable=0). Dùng `Recreate` khi app không hỗ trợ 2 version cùng chạy (schema migration, breaking change).
5. Giữ RS cũ (replicas=0) cho **rollback** — `kubectl rollout undo` scale RS-cũ lên, RS-mới xuống. Không tốn resource (không pod) nhưng tốn etcd storage. `revisionHistoryLimit` (default 10) giới hạn số RS cũ giữ.
