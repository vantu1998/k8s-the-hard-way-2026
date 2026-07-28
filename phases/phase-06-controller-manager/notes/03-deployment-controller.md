# 03 — Deployment Controller

## Deployment là gì

Deployment quản lý **ReplicaSet** cho rolling update và rollback. Deployment controller tạo ReplicaSet, ReplicaSet controller tạo Pod — **controller chain**.

```
Deployment (replicas=3, image=nginx:1.25)
    │
    ▼ creates
ReplicaSet-1 (image=nginx:1.25, replicas=3)
    │
    ▼ creates
Pod-1, Pod-2, Pod-3 (image=nginx:1.25)

--- Rolling update: image=nginx:1.26 ---

Deployment (replicas=3, image=nginx:1.26)
    │
    ├── ReplicaSet-1 (image=nginx:1.25, replicas=0)  ← scaled down
    └── ReplicaSet-2 (image=nginx:1.26, replicas=3)  ← scaled up
         │
         ▼ creates
    Pod-4, Pod-5, Pod-6 (image=nginx:1.26)
```

> Deployment giữ **ReplicaSet cũ** (replicas=0) để rollback. Không xóa ngay.

## Deployment spec

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
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
```

| Field | Ý nghĩa |
|-------|---------|
| `replicas` | Số pod desired |
| `selector` | Label selector (phải match template labels) |
| `strategy.type` | `RollingUpdate` (default) hoặc `Recreate` |
| `strategy.rollingUpdate.maxSurge` | Số pod vượt desired khi rolling (số hoặc %) |
| `strategy.rollingUpdate.maxUnavailable` | Số pod unavailable khi rolling (số hoặc %) |
| `template` | Pod template |

## Rolling Update strategy

### maxSurge & maxUnavailable

```
replicas=3, maxSurge=1, maxUnavailable=0

Step 1: RS-old=3, RS-new=0 → total=3 (desired)
Step 2: RS-old=3, RS-new=1 → total=4 (surge=1, maxSurge=1 ✓)
Step 3: RS-old=2, RS-new=1 → total=3 (unavailable=0 ✓)
Step 4: RS-old=2, RS-new=2 → total=4 (surge=1 ✓)
Step 5: RS-old=1, RS-new=2 → total=3 (unavailable=0 ✓)
Step 6: RS-old=1, RS-new=3 → total=4 (surge=1 ✓)
Step 7: RS-old=0, RS-new=3 → total=3 (done)
```

| Parameter | Default | Ý nghĩa |
|-----------|---------|---------|
| `maxSurge` | `25%` | Số pod **vượt** desired trong rolling. `1` hoặc `25%` of replicas. |
| `maxUnavailable` | `25%` | Số pod **unavailable** trong rolling. `0` = luôn đủ replica. |

### maxSurge=0, maxUnavailable=1 (no extra pod)

```
replicas=3, maxSurge=0, maxUnavailable=1

Step 1: RS-old=3, RS-new=0 → total=3
Step 2: RS-old=2, RS-new=0 → total=2 (unavailable=1 ✓, surge=0 ✓)
Step 3: RS-old=2, RS-new=1 → total=3 (surge=0 ✓, unavailable=0 ✓)
Step 4: RS-old=1, RS-new=1 → total=2 (unavailable=1 ✓)
Step 5: RS-old=1, RS-new=2 → total=3
Step 6: RS-old=0, RS-new=2 → total=2 (unavailable=1 ✓)
Step 7: RS-old=0, RS-new=3 → total=3 (done)
```

> `maxSurge=0` = không tạo pod thừa → tiết kiệm resource. Nhưng có lúc chỉ 2 pod available (unavailable=1). Trade-off: resource vs availability.

### maxSurge=1, maxUnavailable=0 (zero downtime)

```
replicas=3, maxSurge=1, maxUnavailable=0

→ Luôn có ≥3 pod running. Tạo pod mới trước, xóa pod cũ sau.
→ Zero downtime nhưng cần resource cho 4 pod (surge=1).
```

> Production thường dùng `maxUnavailable=0` (zero downtime) + `maxSurge=1` (cho phép 1 pod thừa trong rolling).

## Recreate strategy

```yaml
strategy:
  type: Recreate
```

```
Step 1: RS-old=3, RS-new=0 → total=3
Step 2: RS-old=0, RS-new=0 → total=0 ← DOWNTIME (xóa hết pod cũ)
Step 3: RS-old=0, RS-new=3 → total=3 (tạo hết pod mới)
```

> `Recreate` = xóa hết pod cũ, tạo hết pod mới. **Có downtime**. Dùng khi app không hỗ trợ 2 version cùng chạy (ví dụ: schema migration bắt buộc).

## Rolling update process

```
1. User: kubectl set image deployment/web nginx=nginx:1.26
2. Deployment controller detect spec change (generation++)
3. Tạo ReplicaSet-2 (image=nginx:1.26, replicas=0)
4. Scale RS-2 lên: replicas=1 (maxSurge check)
5. Đợi RS-2 pod ready
6. Scale RS-1 xuống: replicas=2 (maxUnavailable check)
7. Scale RS-2 lên: replicas=2
8. Đợi RS-2 pod ready
9. Scale RS-1 xuống: replicas=1
10. Scale RS-2 lên: replicas=3
11. Đợi RS-2 pod ready
12. Scale RS-1 xuống: replicas=0
13. Update Deployment status: updatedReplicas=3, readyReplicas=3
```

> Deployment controller **điều phối** RS-1 scale down + RS-2 scale up. ReplicaSet controller tạo/xóa pod. Hai controller phối hợp.

## ReplicaSet hash naming

```
Deployment: web
Template hash: abc123 (hash of pod template)
ReplicaSet: web-abc123

Update image → template hash change: def456
New ReplicaSet: web-def456
Old ReplicaSet: web-abc123 (replicas=0, kept for rollback)
```

> Hash = `fnv(template)`. Thay đổi bất kỳ field nào trong template → hash change → tạo RS mới. Không thay đổi template → hash same → reuse RS.

## Rollback

```bash
# Xem rollout history
kubectl rollout history deployment/web
# REVISION  CHANGE-CAUSE
# 1         kubectl apply --filename=web.yaml
# 2         kubectl set image deployment/web nginx=nginx:1.26

# Rollback về revision 1
kubectl rollout undo deployment/web --to-revision=1

# Hoặc undo 1 bước (revision trước)
kubectl rollout undo deployment/web
```

### Rollback process

```
Current: RS-2 (image=nginx:1.26, replicas=3), RS-1 (image=nginx:1.25, replicas=0)

kubectl rollout undo --to-revision=1

1. Deployment controller scale RS-1 lên: replicas=1
2. Scale RS-2 xuống: replicas=2
3. ... rolling update ngược (RS-1 lên, RS-2 xuống)
4. RS-1: replicas=3, RS-2: replicas=0
```

> Rollback = rolling update ngược. Deployment controller dùng RS cũ (replicas=0) → scale lên. **Không tạo RS mới** — reuse RS cũ.

### Rollback history

```bash
# Xem revision detail
kubectl rollout history deployment/web --revision=2
# pod-template-hash: def456
# image: nginx:1.26

# Xem status
kubectl rollout status deployment/web
# deployment "web" successfully rolled out
```

> Mỗi update tạo revision mới. `--record` flag (deprecated) ghi command vào CHANGE-CAUSE. Sử dụng annotation `kubernetes.io/change-cause` thay thế.

## Deployment status

```yaml
status:
  observedGeneration: 2       # Generation đã reconcile
  replicas: 3                 # Tổng pod
  updatedReplicas: 3          # Pod với template mới
  readyReplicas: 3            # Pod ready
  availableReplicas: 3        # Pod available (ready + minReadySeconds)
  unavailableReplicas: 0      # Pod unavailable
  conditions:
  - type: Progressing
    status: "True"
    reason: NewReplicaSetAvailable
  - type: Available
    status: "True"
  - type: ReplicaFailure
    status: "False"
```

| Condition | Ý nghĩa |
|-----------|---------|
| `Progressing` | Rolling update đang diễn ra hoặc completed |
| `Available` | Deployment có đủ pod available |
| `ReplicaFailure` | Pod tạo fail (insufficient resource, image pull error) |

### Progressing conditions

| Reason | Ý nghĩa |
|--------|---------|
| `NewReplicaSetCreated` | RS mới vừa tạo |
| `NewReplicaSetAvailable` | RS mới ready — rollout complete |
| `ProgressDeadlineExceeded` | Rollout quá lâu → fail |

> `progressDeadlineSeconds` (default 600s) — nếu rollout không complete trong 10 phút → condition `Progressing` = False, reason = `ProgressDeadlineExceeded`.

## Pause & Resume rollout

```bash
# Pause — dừng rolling update giữa chừng
kubectl rollout pause deployment/web

# Thay đổi nhiều field mà không trigger rollout liên tục
kubectl set image deployment/web nginx=nginx:1.26
kubectl set resources deployment/web -c=nginx --limits=cpu=500m
kubectl set env deployment/web FOO=bar

# Resume — trigger 1 rollout cho tất cả thay đổi
kubectl rollout resume deployment/web
```

> Pause cho phép thay đổi nhiều field, resume trigger 1 rolling update thay vì nhiều lần. Tiết kiệm resource + thời gian.

## Old ReplicaSet cleanup

Deployment giữ **10 ReplicaSet cũ** mặc định (revisionHistoryLimit):

```yaml
spec:
  revisionHistoryLimit: 10   # default
```

```bash
kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-def456    3         3         3       5m    ← current
# web-abc123    0         0         0       10m   ← old (kept for rollback)
# web-999888    0         0         0       20m   ← old
# ... (up to 10 old RS)
```

> RS cũ (replicas=0) không tốn resource (không pod). Nhưng tốn etcd storage. `revisionHistoryLimit: 0` → xóa hết RS cũ, **không rollback được**.

## Liên hệ với Kubernetes

- Deployment quản lý **ReplicaSet** — controller chain: Deployment → ReplicaSet → Pod.
- `RollingUpdate` (default) = tạo pod mới + xóa pod cũ dần. `Recreate` = xóa hết rồi tạo mới (downtime).
- `maxSurge` = pod vượt desired. `maxUnavailable` = pod unavailable. Production: `maxUnavailable=0` (zero downtime).
- Deployment giữ RS cũ (replicas=0) cho **rollback** — `kubectl rollout undo`.
- `revisionHistoryLimit` (default 10) — số RS cũ giữ. Giảm để tiết kiệm etcd storage.
- Rollback = rolling update ngược — reuse RS cũ, không tạo RS mới.
- `progressDeadlineSeconds` (default 600s) — rollout quá lâu → `ProgressDeadlineExceeded`.
- Pause/resume cho phép thay đổi nhiều field, trigger 1 rollout.
- Deployment controller **không tạo Pod** — tạo ReplicaSet. ReplicaSet controller tạo Pod.
