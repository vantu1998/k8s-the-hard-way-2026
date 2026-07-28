# 02 — ReplicaSet Controller

## ReplicaSet là gì

ReplicaSet đảm bảo **số pod replica** chạy đúng desired count. Nếu pod bị xóa/crash → ReplicaSet controller tạo pod mới.

```yaml
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx
```

| Field | Ý nghĩa |
|-------|---------|
| `replicas` | Số pod desired (default=1) |
| `selector` | Label selector — tìm pod thuộc ReplicaSet |
| `template` | Pod template — blueprint tạo pod mới |

> `selector` phải match `template.metadata.labels` — nếu không, ReplicaSet không bao giờ tìm thấy pod nó tạo.

## Reconcile logic

```
reconcile(ReplicaSet):
    desired = spec.replicas                    # 3
    pods = list pods matching selector         # [pod-1, pod-2]
    actual = len(pods)                         # 2

    if actual < desired:
        # Scale up — tạo pod mới
        for i in range(desired - actual):
            create pod from template

    elif actual > desired:
        # Scale down — xóa pod thừa
        victims = select pods to delete (actual - desired)
        delete victims

    update RS status: replicas=actual, readyReplicas=count_ready
```

## Scale up

```
RS: replicas=3, pods=[pod-1, pod-2]
reconcile: desired=3, actual=2 → create 1 pod
reconcile: desired=3, actual=3 → done
```

> Controller tạo pod **từng cái**, không tạo 3 cùng lúc. Mỗi reconcile cycle tạo 1 pod, đợi pod được scheduler bind, rồi reconcile tiếp.

### Pod naming

```
ReplicaSet: web-abc123 (hash of template)
Pod: web-abc123-xyz789 (RS name + random hash)
```

> Pod name = `<rs-name>-<random-5-char>`. ReplicaSet name = `<deployment-name>-<template-hash>` (nếu tạo bởi Deployment).

## Scale down — deletion policy

Khi scale down, controller chọn pod nào xóa:

### Deletion cost (v1.22+)

```yaml
# Pod với annotation deletion cost
apiVersion: v1
kind: Pod
metadata:
  name: web-1
  annotations:
    controller.kubernetes.io/pod-deletion-cost: "-100"
  labels:
    app: web
spec:
  containers:
  - name: nginx
    image: nginx
```

| Cost | Behavior |
|------|----------|
| Higher cost | Pod **giữ lại** lâu hơn (xóa sau) |
| Lower cost (negative) | Pod **xóa trước** |
| Default (0) | Normal deletion order |

> `pod-deletion-cost: -100` → pod này xóa trước khi scale down. Dùng cho pod "less important" (pod đang xử lý ít request, pod trên node sắp maintenance).

### Default deletion order

Khi không có `pod-deletion-cost`, controller xóa theo thứ tự:

1. **Pending** pod (chưa schedule) — xóa trước (không waste resource)
2. **Not Ready** pod (pod chưa ready hoặc readiness probe fail)
3. **Ready** pod — xóa theo thứ tự:
   - Pod mới nhất (youngest) trước — giữ pod cũ (đã warm cache)
   - Hoặc pod trên node nhiều pod nhất — spread remaining pod

```
RS: replicas=5 → 2, pods=[p1(Running,10m), p2(Running,8m), p3(Pending,1m), p4(Running,5m), p5(Running,2m)]
Deletion order: p3 (Pending) → p5 (youngest Ready) → p4 (next youngest)
Remaining: [p1, p2]
```

## Selector matching — pod adoption

ReplicaSet tìm pod bằng `selector`. Pod match selector **không thuộc RS nào** → được "adopt" (RS controller quản lý luôn):

```yaml
# ReplicaSet selector
selector:
  matchLabels:
    app: web

# Pod có label app=web, KHÔNG có ownerReference → được adopt
metadata:
  labels:
    app: web
# (no ownerReference)
```

> Nếu pod match selector và không có owner → ReplicaSet adopt. Nếu pod match selector nhưng thuộc RS khác → **không adopt** (owner conflict).

### Match expressions

```yaml
selector:
  matchLabels:
    app: web
  matchExpressions:
  - key: environment
    operator: In
    values: ["production", "staging"]
```

| Operator | Ý nghĩa |
|----------|---------|
| `In` | Label value trong danh sách |
| `NotIn` | Label value không trong danh sách |
| `Exists` | Label key tồn tại |
| `DoesNotExist` | Label key không tồnại |

> `matchLabels` = shorthand cho `matchExpressions` với operator `In`. `matchLabels: app=web` = `matchExpressions: [{key: app, operator: In, values: [web]}]`.

## Owner reference

Pod thuộc ReplicaSet có `ownerReference`:

```yaml
# Pod created by ReplicaSet
metadata:
  ownerReferences:
  - apiVersion: apps/v1
    kind: ReplicaSet
    name: web-abc123
    uid: xxx-xxx-xxx
    controller: true    # RS là controller của pod này
    blockOwnerDeletion: true
```

> `controller: true` = RS là "controller" của pod. Garbage collector dùng ownerReference để cascade delete — xóa RS → xóa tất cả pod thuộc RS.

### Cascade vs Orphan delete

```bash
# Cascade (default) — xóa RS + tất cả pod
kubectl delete rs web
# RS deleted + 3 pod deleted

# Orphan — xóa RS, giữ pod
kubectl delete rs web --cascade=orphan
# RS deleted, 3 pod vẫn chạy (ownerReference removed)
```

| Mode | Behavior |
|------|----------|
| `Foreground` | Xóa pod trước, xóa RS sau. Pod bị grace period. |
| `Background` (default) | Xóa RS trước, garbage collector xóa pod sau. |
| `Orphan` | Xóa RS, giữ pod (ownerReference removed). Pod trở thành "orphan". |

## ReplicaSet status

```yaml
status:
  replicas: 3              # Tổng số pod tạo bởi RS
  readyReplicas: 2         # Pod đã ready (readiness probe pass)
  availableReplicas: 2     # Pod ready + minReadySeconds passed
  fullyLabeledReplicas: 3  # Pod match tất cả label trong selector
  observedGeneration: 1    # Generation mà controller đã reconcile
```

| Field | Ý nghĩa |
|-------|---------|
| `replicas` | Số pod hiện tại (đã tạo, đang tạo, đang xóa) |
| `readyReplicas` | Pod có `Ready` condition = True |
| `availableReplicas` | Pod ready + đã qua `minReadySeconds` |
| `fullyLabeledReplicas` | Pod match tất cả label (selector có thể có nhiều label) |
| `observedGeneration` | Generation của spec mà controller đã xử lý |

> `readyReplicas` vs `availableReplicas`: `available` = ready + `minReadySeconds` passed. `minReadySeconds` = thời gian pod phải ready trước khi tính "available".

## ReplicaSet vs ReplicationController

| | ReplicaSet (apps/v1) | ReplicationController (v1, deprecated) |
|---|---|---|
| **Selector** | Label selector với operator (In, NotIn, Exists...) | Chỉ equality-based (=) |
| **API** | `apps/v1` — stable | `v1` — deprecated, sẽ xóa |
| **Use** | **Dùng ReplicaSet** | Không dùng mới |

> ReplicationController là predecessor của ReplicaSet — deprecated. Không tạo ReplicationController mới.

## Thường dùng qua Deployment

ReplicaSet hiếm khi tạo trực tiếp — thường tạo qua **Deployment**:

```yaml
# Deployment tạo ReplicaSet tự động
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template: ...
```

```bash
kubectl get deploy web
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    3/3     3            3           10m

kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    3         3         3       10m

kubectl get pods -l app=web
# NAME                READY   STATUS    RS
# web-abc123-xxx      1/1     Running   web-abc123
```

> Deployment quản lý ReplicaSet. ReplicaSet quản lý Pod. **Không sửa ReplicaSet trực tiếp** — sửa Deployment, Deployment controller tạo ReplicaSet mới.

## Liên hệ với Kubernetes

- ReplicaSet đảm bảo **số pod replica** — scale up (tạo pod), scale down (xóa pod).
- `selector` phải match `template.metadata.labels` — nếu không, RS không tìm thấy pod.
- Pod match selector + không owner → **adopt** bởi ReplicaSet.
- `ownerReference` + `controller: true` → RS là controller của pod. Cascade delete khi xóa RS.
- `pod-deletion-cost` annotation control thứ tự xóa khi scale down.
- `readyReplicas` (ready) vs `availableReplicas` (ready + minReadySeconds).
- ReplicaSet thường tạo qua **Deployment** — không tạo trực tiếp.
- ReplicationController deprecated — dùng ReplicaSet.
- Reconcile loop: compare desired vs actual → create/delete pod → update status.
