# 06 — Priority & Preemption

## PriorityClass là gì

PriorityClass là resource định nghĩa **mức độ ưu tiên** của pod. Pod có priority cao hơn được:
1. **Schedule trước** — priority queue trong scheduler.
2. **Preempt** — evict pod priority thấp hơn nếu không đủ resource.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
description: "High priority for critical workloads"
```

```yaml
# Pod sử dụng PriorityClass
spec:
  priorityClassName: high-priority
  containers:
  - name: app
    image: nginx
```

## PriorityClass fields

| Field | Ý nghĩa |
|-------|---------|
| `value` | Priority value (int32) — cao hơn = ưu tiên hơn. Phải > 1 billion cho system pod. |
| `globalDefault` | `true` = default cho pod không chỉ định `priorityClassName`. Chỉ 1 PriorityClass có `globalDefault: true`. |
| `description` | Mô tả (human-readable). |
| `preemptionPolicy` | `PreemptLowerPriority` (default) hoặc `Never`. |
| `nodeAffinityPolicy` | (v1.30+) Control node affinity trong preemption. |
| `nodeTaintsPolicy` | (v1.30+) Control taint trong preemption. |

### Priority value range

| Range | Dành cho |
|-------|----------|
| < 0 | System pod rất thấp (chỉ evict khi tuyệt đối cần) |
| 0 – 1,000,000 | User-defined pod |
| > 1,000,000 | System pod (kube-system) — không bao giờ bị preempt bởi user pod |

> User pod priority **không bao giờ** vượt system pod. Kubernetes reserve range >1M cho system.

## Built-in PriorityClasses

```bash
kubectl get priorityclasses
NAME                      GLOBAL-DEFAULT   VALUE
system-cluster-critical   false            2000000000
system-node-critical      false            1000000000
```

| PriorityClass | Value | Use case |
|---------------|-------|----------|
| `system-node-critical` | 2,000,000,000 | Pod critical cho node (kubelet, CNI, CRI) |
| `system-cluster-critical` | 1,000,000,000 | Pod critical cho cluster (kube-apiserver, etcd, scheduler) |

> System pod (kube-proxy, CNI, DNS) thường dùng `system-cluster-critical`. Nếu pod này bị evict → cluster không hoạt động.

## Preemption process

Khi pod priority cao không đủ resource để schedule, scheduler **preempt** (evict) pod priority thấp hơn:

```
1. Pod HIGH (priority=1000) Pending — không node nào đủ resource
2. Scheduler chạy PostFilter phase:
   ├── Tìm node có pod LOW (priority=100) đang chạy
   ├── Tính tổng resource giải phóng nếu evict pod LOW
   ├── Nếu đủ cho pod HIGH → chọn pod LOW làm victim
   └── Evict pod LOW → resource giải phóng
3. Pod HIGH schedule lên node vừa giải phóng
4. Pod LOW bị evict → reschedule lên node khác (hoặc Pending)
```

### Preemption steps chi tiết

```
PostFilter (preemption) phase:
┌──────────────────────────────────────────┐
│ 1. Tìm node feasible nếu evict pod thấp  │
│ 2. Chọn node tối ưu (ít victim nhất)     │
│ 3. Chọn victim pod trên node đó          │
│    ├── 优先 evict pod priority thấp nhất  │
│    ├── Tie-break: evict pod mới nhất      │
│    └── Respect PodDisruptionBudget        │
│ 4. "Nominated" node cho pod HIGH          │
│ 5. API Server delete pod LOW (victim)     │
│ 6. Pod LOW graceful terminate             │
│ 7. Pod HIGH schedule lên nominated node   │
└──────────────────────────────────────────┘
```

### PodDisruptionBudget (PDB) protection

PDB ngăn preemption evict quá nhiều pod cùng lúc:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: web
```

> Scheduler **không** evict pod `app=web` nếu số pod available < 2. PDB bảo vệ availability — preemption không việt PDB.

> PDB **chỉ áp dụng cho voluntary disruption** (preemption, drain). **Không áp dụng cho involuntary disruption** (node crash, OOM kill).

### Nominated node

Khi preemption chọn node, pod HIGH được "nominated" cho node đó:

```bash
kubectl get pod high-priority-pod -o wide
# NAME                ...   Nominated Node
# high-priority-pod   ...   node-1
```

> `Nominated Node` = node mà scheduler đã chọn sau preemption. Pod LOW trên node đó đang terminate. Khi resource giải phóng, pod HIGH schedule lên.

## preemptionPolicy

| Value | Behavior |
|-------|----------|
| `PreemptLowerPriority` (default) | Pod có thể preempt pod priority thấp hơn |
| `Never` | Pod không preempt — chờ resource (Pending) |

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: non-preempting
value: 500000
preemptionPolicy: Never
description: "High priority but does not preempt others"
```

> `Never` cho phép pod schedule trước (priority queue) nhưng không evict pod khác. Use case: batch job priority cao nhưng không được phá running workload.

## Graceful termination khi preemption

Khi pod bị preempt, nó nhận **SIGTERM** và có `terminationGracePeriodSeconds` (mặc định 30s):

```
1. Scheduler decide preempt pod LOW
2. API Server delete pod LOW
3. Kubelet nhận delete event
4. Kubelet gửi SIGTERM đến container
5. Container có 30s để graceful shutdown (preStop hook, save state...)
6. Sau 30s → SIGKILL nếu container chưa exit
7. Resource giải phóng
8. Pod HIGH schedule lên node
```

> Preemption **tôn trọng** `terminationGracePeriodSeconds`. Pod HIGH phải chờ pod LOW graceful shutdown xong mới schedule. Tổng preemption time = grace period + scheduling time.

## Use cases

### 1. Critical vs batch workload

```yaml
# Critical service — high priority, preempt
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical
value: 1000000
---
# Batch job — low priority, bị preempt
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch
value: 100
```

> Cluster full với batch job → critical service deploy → preempt batch job → critical service schedule. Batch job reschedule khi có resource.

### 2. Production vs development

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: production
value: 500000
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: development
value: 100
```

> Production pod preempt development pod khi cluster full. Development pod reschedule sau.

### 3. Non-preempting high priority

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: important-but-polite
value: 800000
preemptionPolicy: Never
description: "Schedule before others but don't evict running pods"
```

> Pod schedule trước (priority queue) nhưng không evict pod đang chạy. Use case: deploy service mới mà không muốn phá running workload.

### 4. Global default

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: default-priority
value: 100
globalDefault: true
description: "Default priority for all pods"
```

> Pod không chỉ định `priorityClassName` → nhận `default-priority` (value=100). Chỉ 1 PriorityClass có `globalDefault: true`.

## Quirks & edge cases

### Pod không có PriorityClass

Pod không chỉ định `priorityClassName` và không có `globalDefault` → priority = 0.

> Priority 0 = thấp nhất — bị preempt bởi mọi pod có priority > 0.

### Preemption không xảy ra nếu PDB block

Nếu mọi candidate victim đều có PDB block → pod HIGH ở Pending (không preempt được).

> Scheduler log: `PostFilter: no preemption victims found for pod`

### Preemption racing

Nếu 2 pod HIGH cùng preempt → scheduler xử lý tuần tự (priority queue). Pod HIGH priority cao hơn preempt trước.

### DaemonSet pod không bị preempt

DaemonSet pod thường có `system-node-critical` hoặc `system-cluster-critical` priority — user pod không bao giờ preempt.

> Trừ khi user tạo PriorityClass value > 1,000,000 — không recommend.

## Liên hệ với Kubernetes

- PriorityClass định nghĩa priority — pod cao hơn schedule trước + có thể preempt.
- `value` > 1,000,000 reserved cho system pod — user pod không vượt.
- `PreemptLowerPriority` (default) = evict pod thấp hơn. `Never` = chờ resource.
- Preemption tôn trọng PDB — không evict nếu việt minAvailable.
- Preemption tôn trọng `terminationGracePeriodSeconds` — pod có thời gian graceful shutdown.
- `globalDefault: true` = default cho pod không chỉ định priorityClassName (chỉ 1 class).
- Built-in: `system-node-critical` (2B), `system-cluster-critical` (1B).
- `Nominated Node` = node scheduler chọn sau preemption, hiển thị trong `kubectl get pod -o wide`.
- DaemonSet pod thường có system priority — không bị preempt bởi user pod.
- Non-preempting priority (`preemptionPolicy: Never`) = schedule trước nhưng không evict.
