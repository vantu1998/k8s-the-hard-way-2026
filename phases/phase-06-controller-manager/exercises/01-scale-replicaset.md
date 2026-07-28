# Exercise 01 — Scale ReplicaSet

> **Mục tiêu**: Scale Deployment từ 1 → 5, xem ReplicaSet controller tạo pod từng cái trong event log. Hiểu reconcile loop hoạt động.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4)

## Bối cảnh

ReplicaSet controller đảm bảo số pod = desired. Bài này scale Deployment, quan sát controller tạo pod từng cái, xem event log.

## Bước 1: Deploy 1 replica

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
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
        image: nginx:1.25
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
# Đợi pod ready
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Verify
kubectl get deploy web
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    1/1     1            1           10s

kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    1         1         1       10s

kubectl get pod -l app=web
# NAME               READY   STATUS    RS
# web-abc123-xxx     1/1     Running   web-abc123
```

**Kiểm tra**: 1 Deployment → 1 ReplicaSet → 1 Pod.

## Bước 2: Scale lên 5 — quan sát event

```bash
# Scale
kubectl scale deployment web --replicas=5

# Xem event realtime
kubectl get events --sort-by='.lastTimestamp' --watch | grep web
```

Event log:
```
NORMAL  Scheduled    pod/web-abc123-yyy  Successfully assigned default/web-abc123-yyy to worker-2
NORMAL  Pulling      pod/web-abc123-yyy  Pulling image "nginx:1.25"
NORMAL  Pulled       pod/web-abc123-yyy  Successfully pulled image "nginx:1.25"
NORMAL  Created      pod/web-abc123-yyy  Created container nginx
NORMAL  Started      pod/web-abc123-yyy  Started container nginx
NORMAL  SuccessfulCreate  replicaset/web-abc123  (combined from similar events): Created pod: web-abc123-zzz
```

> ReplicaSet controller tạo pod **từng cái** — mỗi reconcile cycle tạo 1 pod, đợi pod được schedule, rồi tạo tiếp.

```bash
# Verify — 5 pod running
kubectl get pod -l app=web -o wide
# NAME               READY   STATUS    NODE
# web-abc123-aaa     1/1     Running   worker-1
# web-abc123-bbb     1/1     Running   worker-1
# web-abc123-ccc     1/1     Running   worker-2
# web-abc123-ddd     1/1     Running   worker-2
# web-abc123-eee     1/1     Running   worker-3

kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    5         5         5       2m
```

**Kiểm tra**: 5 pod running, ReplicaSet `DESIRED=5, CURRENT=5, READY=5`.

## Bước 3: Xóa 1 pod — quan sát controller tạo lại

```bash
# Xóa 1 pod manually
kubectl delete pod -l app=web | head -1
# pod/web-abc123-aaa deleted

# Quan sát — controller tạo pod mới ngay
kubectl get pod -l app=web -w
# web-abc123-aaa   1/1   Terminating   0   2m
# web-abc123-fff   0/1   Pending       0   0s   ← pod mới tạo
# web-abc123-fff   0/1   ContainerCreating   0   1s
# web-abc123-fff   1/1   Running              0   5s
```

> ReplicaSet controller detect pod bị xóa (watch event) → reconcile → actual=4 < desired=5 → tạo pod mới.

**Kiểm tra**: Pod bị xóa → pod mới tạo ngay, vẫn 5 pod total.

## Bước 4: Scale xuống 2 — quan sát deletion order

```bash
# Scale xuống 2
kubectl scale deployment web --replicas=2

# Quan sát event
kubectl get events --sort-by='.lastTimestamp' | grep -E "(SuccessfulDelete|web)"
# NORMAL  SuccessfulDelete  replicaset/web-abc123  Deleted pod: web-abc123-eee
# NORMAL  SuccessfulDelete  replicaset/web-abc123  Deleted pod: web-abc123-ddd
# NORMAL  SuccessfulDelete  replicaset/web-abc123  Deleted pod: web-abc123-ccc
```

```bash
# Verify — 2 pod còn lại
kubectl get pod -l app=web
# NAME               READY   STATUS    AGE
# web-abc123-aaa     1/1     Running   5m    ← pod cũ nhất (giữ lại)
# web-abc123-bbb     1/1     Running   5m    ← pod cũ thứ 2
```

> Controller xóa pod **mới nhất trước** (youngest first) — giữ pod cũ (đã warm cache, live connection).

**Kiểm tra**: 2 pod running, pod mới nhất bị xóa trước.

## Bước 5: Test pod-deletion-cost

```bash
# Scale lên 3
kubectl scale deployment web --replicas=3
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Add deletion cost cho 1 pod (low cost = xóa trước)
POD_NAME=$(kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl annotate pod "${POD_NAME}" controller.kubernetes.io/pod-deletion-cost="-100"

# Scale xuống 1
kubectl scale deployment web --replicas=1

# Verify — pod có deletion-cost=-100 bị xóa trước
kubectl get pod -l app=web
# NAME               READY   STATUS    AGE
# web-abc123-bbb     1/1     Running   8m    ← pod không có annotation, giữ lại
```

```bash
# Check event
kubectl get events --sort-by='.lastTimestamp' | grep SuccessfulDelete
# NORMAL  SuccessfulDelete  replicaset/web-abc123  Deleted pod: web-abc123-aaa  ← pod có deletion-cost=-100
```

> `pod-deletion-cost: -100` → pod này xóa trước khi scale down. Dùng cho pod "less important".

**Kiểm tra**: Pod có `deletion-cost=-100` bị xóa trước pod không có annotation.

## Bước 6: Xem ReplicaSet ownerReference

```bash
# Pod ownerReference
kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.ownerReferences}' | jq .
# [
#   {
#     "apiVersion": "apps/v1",
#     "kind": "ReplicaSet",
#     "name": "web-abc123",
#     "uid": "xxx-xxx-xxx",
#     "controller": true,
#     "blockOwnerDeletion": true
#   }
# ]

# ReplicaSet ownerReference
kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.ownerReferences}' | jq .
# [
#   {
#     "apiVersion": "apps/v1",
#     "kind": "Deployment",
#     "name": "web",
#     "uid": "yyy-yyy-yyy",
#     "controller": true,
#     "blockOwnerDeletion": true
#   }
# ]
```

> Chain: Deployment → ReplicaSet → Pod. Mỗi level có `ownerReference` trỏ đến parent. `controller: true` = parent là controller.

**Kiểm tra**: Pod có ownerReference → ReplicaSet, ReplicaSet có ownerReference → Deployment.

## Cleanup

```bash
kubectl delete deployment web
```

## Câu hỏi tự kiểm tra

1. Scale từ 1 → 5, controller tạo 5 pod cùng lúc hay từng cái? Tại sao?
2. Xóa 1 pod manually, điều gì xảy ra? Controller nào tạo pod mới?
3. Scale down, controller xóa pod nào trước? Tiêu chí gì?
4. `pod-deletion-cost` ảnh hưởng deletion order thế nào?
5. `ownerReference` trong pod trỏ đến ai? `controller: true` có ý nghĩa gì?

## Đáp án tham khảo

1. **Từng cái** — mỗi reconcile cycle tạo 1 pod, đợi pod được schedule/bind, rồi reconcile tiếp tạo pod tiếp. Rate limited để tránh burst API Server.
2. ReplicaSet controller detect pod delete (watch event) → reconcile → actual < desired → tạo pod mới. ReplicaSet controller (không phải Deployment controller) quản lý pod.
3. Pod mới nhất (youngest) trước — giữ pod cũ (đã warm cache, live connection). Pending pod xóa trước Ready pod. Pod có `pod-deletion-cost` thấp xóa trước.
4. `pod-deletion-cost` annotation — cost thấp (negative) = xóa trước, cost cao = giữ lại. Default cost=0. Dùng cho pod "less important" (ít request, node sắp maintenance).
5. `ownerReference` trỏ đến ReplicaSet (parent). `controller: true` = ReplicaSet là controller của pod. Garbage collector dùng ownerReference cho cascade delete — xóa RS → xóa pod.
