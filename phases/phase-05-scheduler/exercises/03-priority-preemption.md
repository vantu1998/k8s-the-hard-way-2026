# Exercise 03 — Priority & Preemption

> **Mục tiêu**: Tạo PriorityClass high/low, deploy high priority pod khi node full, quan sát preemption — high priority pod evict low priority pod.
>
> **Thời gian dự kiến**: 40 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), ít nhất 2 worker node

## Bối cảnh

Khi cluster hết resource, pod priority cao có thể preempt (evict) pod priority thấp. Bài này fill node với low priority pod, deploy high priority pod, quan sát preemption.

## Prerequisites

```bash
kubectl get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# master    Ready     control-plane   10d   v1.33.0
# worker-1  Ready     <none>          10d   v1.33.0
# worker-2  Ready     <none>          10d   v1.33.0

# Check allocatable resource
kubectl describe node worker-1 | grep -A 5 "Allocatable:"
# cpu:     2000m
# memory:  4Gi
```

## Bước 1: Tạo PriorityClass

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
description: "High priority — can preempt low priority pods"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority
value: 100
description: "Low priority — can be preempted"
EOF

# Verify
kubectl get priorityclasses
# NAME           GLOBAL-DEFAULT   VALUE
# high-priority  false            1000000
# low-priority   false            100
```

**Kiểm tra**: 2 PriorityClass `high-priority` (1M) và `low-priority` (100) tồn tại.

## Bước 2: Fill worker-1 với low priority pod

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: low-priority-fill
spec:
  replicas: 4
  selector:
    matchLabels:
      app: low-priority-fill
  template:
    metadata:
      labels:
        app: low-priority-fill
    spec:
      priorityClassName: low-priority
      nodeSelector:
        kubernetes.io/hostname: worker-1
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 500m
            memory: 512Mi
EOF
```

```bash
# Đợi pod chạy
kubectl wait --for=condition=Ready pod -l app=low-priority-fill --timeout=60s

# Quan sát — 4 pod trên worker-1, dùng 2000m CPU (full)
kubectl get pod -l app=low-priority-fill -o wide
# NAME                        READY   STATUS    NODE
# low-priority-fill-xxx-aaa   1/1     Running   worker-1
# low-priority-fill-xxx-bbb   1/1     Running   worker-1
# low-priority-fill-xxx-ccc   1/1     Running   worker-1
# low-priority-fill-xxx-ddd   1/1     Running   worker-1

# Check resource usage
kubectl describe node worker-1 | grep -A 5 "Allocated resources:"
# cpu: 2000m (100%)   ← full
```

**Kiểm tra**: 4 pod `low-priority-fill` chạy trên `worker-1`, CPU full (2000m/2000m).

## Bước 3: Deploy high priority pod lên worker-1 — quan sát preemption

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: high-priority-pod
spec:
  priorityClassName: high-priority
  nodeSelector:
    kubernetes.io/hostname: worker-1
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
EOF
```

```bash
# High priority pod Pending → scheduler preempt low priority pod
kubectl get pod high-priority-pod
# NAME                READY   STATUS    RESTARTS   AGE
# high-priority-pod   0/1     Pending   0          5s

# Xem event — preemption happening
kubectl describe pod high-priority-pod | tail -10
# Events:
#   Normal   Preempted          5s   kube-scheduler  Preempted pod default/low-priority-fill-xxx-ddd to fit pod default/high-priority-pod
#   Normal   Scheduled          3s   kube-scheduler  Successfully assigned default/high-priority-pod to worker-1
```

```bash
# Sau vài giây — low priority pod bị evict, high priority pod chạy
kubectl get pod -l app=low-priority-fill -o wide
# NAME                        READY   STATUS        NODE
# low-priority-fill-xxx-aaa   1/1     Running       worker-1
# low-priority-fill-xxx-bbb   1/1     Running       worker-1
# low-priority-fill-xxx-ccc   1/1     Running       worker-1
# low-priority-fill-xxx-ddd   0/1     Terminating   worker-1   ← bị preempt

kubectl get pod high-priority-pod -o wide
# NAME                READY   STATUS    RESTARTS   AGE   NODE
# high-priority-pod   1/1     Running   0          15s   worker-1
```

> Scheduler evict 1 pod `low-priority-fill` (giải phóng 500m CPU) → `high-priority-pod` schedule lên worker-1. Low priority pod bị evict → reschedule lên worker-2 hoặc Pending.

**Kiểm tra**: `high-priority-pod` Running trên `worker-1`, 1 pod `low-priority-fill` bị `Terminating`.

## Bước 4: Quan sát Nominated Node

```bash
# Trong lúc preemption đang diễn ra, check nominated node
kubectl get pod high-priority-pod -o jsonpath='{.status.nominatedNodeName}'
# worker-1

# Hoặc
kubectl get pod high-priority-pod -o wide
# Nominated Node: worker-1
```

> `nominatedNodeName` = node mà scheduler chọn sau preemption. Pod victim đang terminate trên node đó.

## Bước 5: Test PodDisruptionBudget — block preemption

```bash
# Cleanup bước trước
kubectl delete pod high-priority-pod
kubectl delete deployment low-priority-fill

# Deploy low priority với PDB
cat <<'EOF' | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: low-pdb
spec:
  minAvailable: 3
  selector:
    matchLabels:
      app: low-priority-fill
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: low-priority-fill
spec:
  replicas: 3
  selector:
    matchLabels:
      app: low-priority-fill
  template:
    metadata:
      labels:
        app: low-priority-fill
    spec:
      priorityClassName: low-priority
      nodeSelector:
        kubernetes.io/hostname: worker-1
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.9
        resources:
          requests:
            cpu: 600m
            memory: 512Mi
EOF
```

```bash
# 3 pod × 600m = 1800m. Worker-1 allocatable = 2000m. Còn 200m.
kubectl get pod -l app=low-priority-fill -o wide
# NAME                        READY   STATUS    NODE
# low-priority-fill-xxx-aaa   1/1     Running   worker-1
# low-priority-fill-xxx-bbb   1/1     Running   worker-1
# low-priority-fill-xxx-ccc   1/1     Running   worker-1
```

```bash
# Deploy high priority pod cần 600m (phải preempt 1 low pod)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: high-with-pdb
spec:
  priorityClassName: high-priority
  nodeSelector:
    kubernetes.io/hostname: worker-1
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: 600m
        memory: 512Mi
EOF

# PDB minAvailable=3 → không được evict pod → preemption fail
kubectl get pod high-with-pdb
# NAME             READY   STATUS    RESTARTS   AGE
# high-with-pdb    0/1     Pending   0          10s

kubectl describe pod high-with-pdb | tail -5
# Events:
#   Warning  FailedScheduling  ...  0/1 nodes are available: 1 node(s) had untolerated taint, 1 Insufficient cpu.
#   (PDB blocks preemption — scheduler không tìm được victim)
```

> PDB `minAvailable: 3` chặn preemption — scheduler không evict pod vì sẽ việt minAvailable. High priority pod ở Pending.

**Kiểm tra**: `high-with-pdb` Pending, PDB chặn preemption.

## Bước 6: Test preemptionPolicy: Never

```bash
# Cleanup
kubectl delete pod high-with-pdb
kubectl delete pdb low-pdb
kubectl delete deployment low-priority-fill

# Tạo PriorityClass non-preempting
cat <<'EOF' | kubectl apply -f -
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: non-preempting-high
value: 900000
preemptionPolicy: Never
description: "High priority but does not preempt"
EOF
```

```bash
# Fill worker-1 với low priority pod
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: low-pod-1
spec:
  priorityClassName: low-priority
  nodeSelector:
    kubernetes.io/hostname: worker-1
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: 1000m
        memory: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: low-pod-2
spec:
  priorityClassName: low-priority
  nodeSelector:
    kubernetes.io/hostname: worker-1
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: 1000m
        memory: 1Gi
EOF

# Worker-1 full (2000m/2000m)
```

```bash
# Deploy non-preempting high priority pod
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: non-preempting-pod
spec:
  priorityClassName: non-preempting-high
  nodeSelector:
    kubernetes.io/hostname: worker-1
  containers:
  - name: pause
    image: registry.k8s.io/pause:3.9
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
EOF

# Pod Pending — không preempt (preemptionPolicy: Never)
kubectl get pod non-preempting-pod
# NAME                  READY   STATUS    RESTARTS   AGE
# non-preempting-pod    0/1     Pending   0          10s

# Low priority pod vẫn chạy — không bị evict
kubectl get pod low-pod-1 low-pod-2
# NAME        READY   STATUS    RESTARTS
# low-pod-1   1/1     Running   0
# low-pod-2   1/1     Running   0
```

> `preemptionPolicy: Never` = pod priority cao (schedule trước trong queue) nhưng không evict pod đang chạy. Pod Pending cho đến khi có resource.

**Kiểm tra**: `non-preempting-pod` Pending, low priority pod vẫn Running.

## Cleanup

```bash
kubectl delete pod --all
kubectl delete priorityclass high-priority low-priority non-preempting-high
kubectl delete pdb --all
```

## Câu hỏi tự kiểm tra

1. Preemption xảy ra trong phase nào của scheduling cycle?
2. Scheduler chọn victim nào để evict? Tiêu chí gì?
3. PDB chặn preemption như thế nào? Pod vẫn bị evict nếu PDB block?
4. `preemptionPolicy: Never` khác gì `PreemptLowerPriority`?
5. `nominatedNodeName` trong pod status có ý nghĩa gì?

## Đáp án tham khảo

1. **PostFilter** phase — chạy sau khi Filter fail (không node feasible). PostFilter tìm preemption candidate: node nào có pod priority thấp hơn mà nếu evict thì đủ resource cho pod mới.
2. Scheduler chọn victim priority thấp nhất. Tie-break: pod mới nhất (youngest). Scheduler cũng respect PDB — không evict nếu việt minAvailable. Scheduler chọn node cần evict ít victim nhất.
3. PDB quy định `minAvailable` hoặc `maxUnavailable`. Scheduler kiểm tra: nếu evict victim → số available có < minAvailable không? Nếu có → không evict, tìm victim khác. Nếu tất cả victim đều bị PDB block → preemption fail, pod Pending.
4. `PreemptLowerPriority` (default): pod có thể evict pod priority thấp hơn khi không đủ resource. `Never`: pod không evict — chờ resource (Pending). `Never` cho phép schedule trước (priority queue) nhưng không phá running workload.
5. `nominatedNodeName` = node mà scheduler chọn sau preemption. Pod victim đang terminate trên node đó. Khi resource giải phóng, pod schedule lên nominated node. Giúp scheduler tránh scheduling pod khác lên node đang chờ preemption.
