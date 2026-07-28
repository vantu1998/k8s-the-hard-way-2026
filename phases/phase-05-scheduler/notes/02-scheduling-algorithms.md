# 02 — Scheduling Algorithms

## Scheduling Framework

Từ Kubernetes 1.19+, scheduler dùng **Scheduling Framework** — kiến trúc plugin cho phép mở rộng scheduling cycle mà không cần sửa code scheduler.

```
Scheduling Cycle (synchronous, cho 1 pod)
┌─────────────────────────────────────────────────────┐
│ QueueSort │ Filter │ PostFilter │ Score │ Reserve │ │
│           │        │            │       │  Permit  │ │
└─────────────────────────────────────────────────────┘
                         │
                    Bind Cycle
┌─────────────────────────────────────────────────────┐
│ PreBind │ Bind │ PostBind                            │
└─────────────────────────────────────────────────────┘
```

| Extension point | Chức năng |
|-----------------|-----------|
| `QueueSort` | Sắp xếp pod trong scheduling queue |
| `PreFilter` | Kiểm tra precondition trước Filter (metadata, pod info) |
| `Filter` | Loại node không phù hợp |
| `PostFilter` | Chạy khi không node nào pass Filter — tìm preemption candidate |
| `PreScore` | Kiểm tra trước Score (có thể skip Score) |
| `Score` | Chấm điểm node (0–100) |
| `NormalizeScore` | Chuẩn hóa score về cùng scale |
| `Reserve` | "Đặt chỗ" resource trên node (race condition prevention) |
| `Permit` | Cho phép hoặc delay bind (gang scheduling, wait for volume) |
| `PreBind` | Chuẩn bị trước bind (attach volume, provision PVC) |
| `Bind` | Bind pod → node (gọi API Server) |
| `PostBind` | Callback sau bind (log, metrics) |

> Framework cho phép viết custom plugin bằng Go, compile thành scheduler binary riêng, hoặc dùng scheduler plugin (external gRPC).

## Filter plugins (Predicates)

### NodeResourcesFit

Kiểm tra node có đủ resource (CPU, Memory, ephemeral-storage, extended resources như GPU):

```
Pod request: CPU=500m, Memory=1Gi
Node-1: Allocatable CPU=2000m (used=1600m), Memory=4Gi (used=3Gi)
  → CPU available=400m < 500m → FAIL
Node-2: Allocatable CPU=4000m (used=1000m), Memory=8Gi (used=2Gi)
  → CPU available=3000m >= 500m, Memory available=6Gi >= 1Gi → PASS
```

> Scheduler dùng **allocatable** (capacity minus system reserved), không phải capacity. `kubectl describe node` hiển thị cả hai.

### PodFitsHostPorts

Kiểm tra host port có bị chiếm không:

```yaml
spec:
  containers:
  - name: app
    image: nginx
    ports:
    - containerPort: 80
      hostPort: 8080  # Scheduler kiểm tra port 8080 trên node
```

> `hostPort` chiếm port trên node — chỉ 1 pod/node có thể dùng cùng hostPort. Tránh dùng trừ khi cần (ingress, daemon).

### NodeAffinity / MatchNodeSelector

Kiểm tra node có match `nodeSelector` hoặc `nodeAffinity`:

```yaml
# nodeSelector — đơn giản, AND logic
spec:
  nodeSelector:
    disktype: ssd
    zone: a
# Node phải có CẢ HAI label: disktype=ssd AND zone=a

# nodeAffinity required — phức tạp hơn, hỗ trợ operator
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: In
            values: ["ssd", "nvme"]
```

> Xem chi tiết trong `03-node-selection.md`.

### PodToleratesNodeTaints

Kiểm tra pod có toleration cho taint trên node:

```
Node-1: taint = dedicated=gpu:NoSchedule
Pod: toleration cho key=dedicated, value=gpu, effect=NoSchedule → PASS
Pod: không có toleration → FAIL
```

> Xem chi tiết trong `05-taints-tolerations.md`.

### NoVolumeZoneConflict

Kiểm tra volume zone có match node zone:

```yaml
# PersistentVolume có nodeAffinity theo zone
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-zone-a
spec:
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["zone-a"]
```

> Pod dùng PV `pv-zone-a` chỉ schedule lên node ở `zone-a`. Scheduler kiểm tra để tránh pod schedule lên node không mount được volume.

### PodAntiAffinity

Kiểm tra có pod nào đã chạy trên node mà anti-affinity cấm không:

```yaml
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: web
        topologyKey: kubernetes.io/hostname
# Pod app=web không được chạy 2 cái trên cùng 1 node
```

> Xem chi tiết trong `04-affinity-anti-affinity.md`.

### NodeVolumeLimits

Kiểm tra số volume attach đến node có vượt limit không:

| Node type | Max volume attach |
|-----------|-------------------|
| AWS EBS | 39 |
| GCE PD | 16 |
| Azure Disk | 16 |
| vSphere | 59 (configurable) |

> Scheduler đếm volume đã attach + volume pod mới yêu cầu. Vượt limit → FAIL.

## Score plugins (Priorities)

### LeastRequestedPriority

Ưu tiên node **ít utilized** — spreading workload:

```
Score = ((capacity - request) / capacity) * 100

Node-1: CPU capacity=4000m, used=1000m, pod request=500m
  → ((4000 - 1500) / 4000) * 100 = 62.5

Node-2: CPU capacity=4000m, used=3000m, pod request=500m
  → ((4000 - 3500) / 4000) * 100 = 12.5

→ Node-1 được chọn (score cao hơn = ít utilized hơn)
```

> Mặc định weight = 1. Tăng weight nếu muốn spread mạnh hơn.

### BalancedResourceAllocation

Ưu tiên node **cân bằng** CPU/Memory utilization:

```
Node-1: CPU utilization=30%, Memory utilization=60% → |30-60|=30 → Score=70
Node-2: CPU utilization=40%, Memory utilization=45% → |40-45|=5  → Score=95

→ Node-2 được chọn (cân bằng hơn)
```

> Dùng cùng với LeastRequestedPriority — LeastRequested chọn node ít load, Balanced chọn node cân bằng.

### NodeAffinityPriority

Cho `preferredDuringScheduling` — node match preferred rule được score cao hơn:

```yaml
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
          - key: zone
            operator: In
            values: ["a"]
```

> Node `zone=a` được +80 điểm. Node không match vẫn pass Filter (nếu là preferred), nhưng score thấp hơn.

### PodTopologySpread

Spread pod đều across topology domains (zone, region, node):

```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
```

```
Zone A: 2 pod   Zone B: 1 pod   Zone C: 0 pod
→ maxSkew = 2-0 = 2 > 1 → FAIL (must spread to Zone C first)
```

> Xem chi tiết trong `04-affinity-anti-affinity.md`.

### InterPodAffinityPriority

Cho `preferredDuringScheduling` pod affinity — ưu tiên node có pod match affinity:

```yaml
spec:
  affinity:
    podAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 50
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: cache
          topologyKey: kubernetes.io/hostname
```

> Pod `app=web` prefer chạy cùng node với pod `app=cache` (co-locate for low latency).

### TaintTolerationPriority

Ưu tiên node **ít taint hơn** (cho `PreferNoSchedule`):

```
Node-1: taint = maintenance:PreferNoSchedule → Score giảm
Node-2: không taint → Score đầy đủ

→ Node-2 được ưu tiên
```

> `PreferNoSchedule` không cấm (khác `NoSchedule`), chỉ giảm score. Scheduler vẫn có thể schedule lên node đó nếu không có lựa chọn tốt hơn.

## Score weight

Mỗi Score plugin có **weight** — score cuối = Σ(plugin_score × weight):

```yaml
# KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
  plugins:
    score:
      enabled:
      - name: NodeResourcesFit
        weight: 10
      - name: PodTopologySpread
        weight: 5
      - name: NodeAffinityPriority
        weight: 2
```

```
Final score = (NodeResourcesFit_score × 10) + (PodTopologySpread_score × 5) + (NodeAffinityPriority_score × 2)
```

> Weight cao = plugin ảnh hưởng nhiều hơn đến decision. Tune weight để ưu tiên spread vs utilization vs affinity.

## Default scoring strategy (v1.33)

Default scheduler dùng `NodeResourcesFit` với strategy `Allocatable`:

```yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
  pluginConfig:
  - name: NodeResourcesFit
    args:
      scoringStrategy:
        type: Allocatable  # hoặc LeastAllocated
        resources:
        - name: cpu
          weight: 1
        - name: memory
          weight: 1
```

| Strategy | Behavior |
|----------|----------|
| `LeastAllocated` | Spread — ưu tiên node ít utilized (giống LeastRequestedPriority) |
| `MostAllocated` | Bin-pack — ưu tiên node nhiều utilized (để "đóng gói" pod vào node đã dùng) |
| `RequestedToCapacity` | Hybrid — cân bằng giữa spread và bin-pack |

> Cloud environment thường dùng `LeastAllocated` (spread). On-prem có thể dùng `MostAllocated` (bin-pack) để tiết kiệm node.

## Cách xem plugin nào đang chạy

```bash
# Scheduler log với v=5
kubectl logs -n kube-system kube-scheduler-<node> --v=5

# Tìm "Filter" và "Score" trong log
kubectl logs -n kube-system kube-scheduler-<node> --v=5 | grep -E "(Filter|Score|node-)"
```

> Xem exercise 05 để đọc scheduler log chi tiết.

## Liên hệ với Kubernetes

- Scheduling Framework thay thế **Predicates/Priorities** cũ — plugin architecture, extensible.
- Filter = **hard constraint** — fail = pod Unschedulable.
- Score = **soft preference** — fail = vẫn schedule, nhưng score thấp hơn.
- Weight quyết định **plugin nào quan trọng hơn** trong Score phase.
- `LeastAllocated` (default) = spread pod đều ra node. `MostAllocated` = bin-pack để tiết kiệm node.
- Custom plugin (Go hoặc gRPC) cho phép scheduler logic phức tạp (gang scheduling, GPU topology, NUMA).
- Scheduler log `--v=5+` cho thấy từng plugin pass/fail và score cho từng node.
