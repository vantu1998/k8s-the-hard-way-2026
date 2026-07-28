# 01 — Scheduling Process

## Scheduler là gì

kube-scheduler là component chạy trên control plane, chịu trách nhiệm **quyết định pod chạy trên node nào**. Scheduler watch API Server để tìm pod ở trạng thái `Pending` (chưa có `nodeName`), chạy scheduling algorithm, rồi bind pod đến node được chọn.

```
Pod tạo (Pending, nodeName=null)
       │
       ▼
  Scheduler watch
  ├── 1. Filter: loại node không phù hợp (thiếu CPU, không match label...)
  ├── 2. Score: rank node còn lại (chọn node "tốt nhất")
  ├── 3. Bind: gán pod.spec.nodeName = node được chọn
  └── 4. Kubelet thấy pod assigned cho mình → tạo container
```

> Scheduler **không chạy pod** — chỉ quyết định pod chạy **ở đâu**. Kubelet mới tạo/dừng container.

## Scheduler architecture

```
         API Server
        ┌────┬────┐
        │    │    │
   scheduler  controller  kubelet...
        │
   ├── Informer: watch Pod (Pending), Node, PersistentVolume, CSINode...
   ├── Queue: pod Pending xếp hàng chờ schedule
   ├── Filter phase: loại node không đủ điều kiện
   ├── Score phase: rank node còn lại
   └── Bind: gọi API Server bind pod → node
```

### Scheduler là singleton (leader election)

Scheduler chạy **1 instance active** tại một thời điểm — dù có nhiều instance (HA), chỉ leader mới schedule. Leader election qua lease object trong `kube-system` namespace.

```bash
# Xem leader election
kubectl get lease -n kube-system kube-scheduler
# NAME             HOLDER                          AGE
# kube-scheduler   node-1_abc123def456              10m
```

> Nếu leader crash, standby instance trở thành leader (within seconds). Pod Pending không bị mất — scheduler mới tiếp tục watch và schedule.

### Scheduler chạy như static pod (kubeadm)

```yaml
# /etc/kubernetes/manifests/kube-scheduler.yaml (kubeadm generated)
apiVersion: v1
kind: Pod
metadata:
  labels:
    component: kube-scheduler
    tier: control-plane
  name: kube-scheduler
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-scheduler
    - --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
    - --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
    - --bind-address=127.0.0.1
    - --kubeconfig=/etc/kubernetes/scheduler.conf
    - --leader-elect=true
    - --secure-port=10259
    - --v=2
    image: registry.k8s.io/kube-scheduler:v1.33.0
    name: kube-scheduler
    livenessProbe:
      httpGet:
        path: /healthz
        port: 10259
        scheme: HTTPS
    volumeMounts:
    - mountPath: /etc/kubernetes/scheduler.conf
      name: kubeconfig
      readOnly: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/scheduler.conf
      type: FileOrCreate
    name: kubeconfig
  hostNetwork: true
  priorityClassName: system-node-critical
```

## 2 phase: Filter + Score

### Phase 1 — Filter (Predicates)

Scheduler kiểm tra **tất cả node** và loại những node không thỏa điều kiện:

```
Tất cả node: [node-1, node-2, node-3, node-4]
       │
       ▼ Filter
  node-1: CPU đủ? ✓  Memory đủ? ✓  → PASS
  node-2: CPU đủ? ✓  Memory đủ? ✗  → FAIL
  node-3: CPU đủ? ✗  → FAIL
  node-4: Taint NoSchedule, pod không toleration → FAIL
       │
       ▼
  Feasible nodes: [node-1]
```

Filter plugins kiểm tra:
- **PodFitsResources**: Node có đủ CPU/Memory/Ephemeral storage?
- **PodFitsHostPorts**: Host port có bị chiếm không?
- **MatchNodeSelector / NodeAffinity**: Node có match `nodeSelector`/`nodeAffinity`?
- **PodToleratesNodeTaints**: Pod có toleration cho taint trên node?
- **NoVolumeZoneConflict**: Volume zone có match node zone?
- **PodAntiAffinity**: Có pod nào đã chạy trên node mà anti-affinity cấm?
- **NodeVolumeLimits**: Số volume attach đến node có vượt limit?

> Nếu **không node nào** pass Filter → pod ở `Pending` với condition `Unschedulable`.

### Phase 2 — Score (Priorities)

Sau Filter, scheduler **chấm điểm** mỗi feasible node (0–100), chọn node có điểm cao nhất:

```
Feasible nodes: [node-1, node-3]
       │
       ▼ Score
  node-1: LeastRequestedPriority = 80  +  BalancedResourceAllocation = 70  → Total: 150
  node-3: LeastRequestedPriority = 60  +  BalancedResourceAllocation = 90  → Total: 150
       │
       ▼ Tie-break
  Chọn node-1 (first by name)
```

Score plugins:
- **LeastRequestedPriority**: Ưu tiên node ít utilized (spreading)
- **BalancedResourceAllocation**: Ưu tiên node cân bằng CPU/Memory
- **NodeAffinityPriority**: Ưu tiên node match preferred affinity
- **PodTopologySpread**: Ưu tiên spread pod across topology domains
- **InterPodAffinityPriority**: Ưu tiên node match pod affinity
- **TaintTolerationPriority**: Ưu tiên node ít taint hơn (PreferNoSchedule)

> Nếu nhiều node có **cùng điểm cao nhất**, scheduler chọn ngẫu nhiên (round-robin).

### Full scheduling cycle

```
1. Pod tạo → API Server → etcd (status=Pending, nodeName=null)
2. Scheduler informer nhận event "Pod Added"
3. Pod vào scheduling queue (priority queue, sorted by PriorityClass)
4. Filter phase: loại node không phù hợp
5. Score phase: rank node còn lại
6. Reserve phase: "đặt chỗ" resource trên node (racing condition)
7. Permit phase: cho phép bind (hoặc delay cho gang scheduling)
8. Bind phase: gọi API Server PATCH pod.spec.nodeName = "node-1"
9. Kubelet informer nhận event "Pod Updated" → tạo container
```

## Scheduling queue

Scheduler dùng **priority queue** — pod có PriorityClass cao hơn được schedule trước:

```
Scheduling Queue (priority queue)
├── Active queue: pod chờ schedule, sort theo priority
├── Backoff queue: pod fail schedule, đợi retry với exponential backoff
└── Unschedulable queue: pod không thể schedule (thiếu resource), retry khi node thay đổi
```

| Queue | Khi nào pod vào | Khi nào pod ra |
|-------|-----------------|----------------|
| Active | Pod mới tạo hoặc retry | Scheduler pop để schedule |
| Backoff | Pod fail schedule lần đầu | Sau backoff duration (1s, 2s, 4s...) |
| Unschedulable | Pod fail vì không node phù hợp | Khi node add/update, pod update, hoặc sau 30s |

> Pod trong Unschedulable queue không retry liên tục — tiết kiệm CPU. Chỉ retry khi có event mới (node join, node label change, pod delete giải phóng resource).

## Bind mechanism

Sau khi chọn node, scheduler gọi API Server để **bind** pod:

```bash
# Scheduler gọi (thường qua API, không phải CLI)
kubectl patch pod <pod-name> -n <ns> --type=merge -p '{"spec":{"nodeName":"node-1"}}'
```

> Bind là **API call** — scheduler không ghi trực tiếp etcd. Nếu API Server down, scheduler không bind được → pod ở Pending.

### Bind timeout

Scheduler có timeout cho mỗi scheduling cycle (mặc định 15s). Nếu không bind trong thời gian này, pod bị retry.

## Scheduler flags quan trọng

```bash
kube-scheduler \
  --kubeconfig=/etc/kubernetes/scheduler.conf \
  --leader-elect=true \
  --secure-port=10259 \
  --bind-address=127.0.0.1 \
  --v=2
```

| Flag | Mặc định | Ý nghĩa |
|------|----------|---------|
| `--kubeconfig` | — | Kubeconfig để connect API Server |
| `--leader-elect` | `true` | Bật leader election (HA) |
| `--secure-port` | `10259` | HTTPS port cho metrics + healthz |
| `--bind-address` | `127.0.0.1` | Bind address cho HTTPS listener |
| `--policy-config-file` | — | Custom scheduling policy (deprecated, dùng config thay) |
| `--config` | — | Path đến scheduler config (KubeSchedulerConfiguration) |
| `--v` | `2` | Log verbosity (v=5+ thấy scheduling decision) |

## Custom scheduler

Có thể chạy **nhiều scheduler** trong cùng cluster — mỗi scheduler quản lý pod khác nhau:

```yaml
# Pod chỉ định scheduler
apiVersion: v1
kind: Pod
metadata:
  name: custom-pod
spec:
  schedulerName: my-custom-scheduler
  containers:
  - name: app
    image: nginx
```

```bash
# Chạy custom scheduler
kube-scheduler --scheduler-name=my-custom-scheduler \
  --kubeconfig=/etc/kubernetes/scheduler.conf \
  --leader-elect=false
```

> Pod có `schedulerName: my-custom-scheduler` sẽ bị ignore bởi default scheduler. Nếu custom scheduler không chạy → pod ở Pending forever.

## Scheduler profiles (KubeSchedulerConfiguration)

```yaml
# /etc/kubernetes/scheduler-config.yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
  plugins:
    filter:
      enabled:
      - name: NodeResourcesFit
      - name: NodeAffinity
      - name: TaintToleration
      disabled:
      - name: "*"
    score:
      enabled:
      - name: NodeResourcesFit
        weight: 10
      - name: PodTopologySpread
        weight: 5
      disabled:
      - name: "*"
```

> `disabled: [*]` tắt tất cả plugin mặc định, chỉ giữ plugin trong `enabled`. Dùng để customize scheduling behavior.

## Liên hệ với Kubernetes

- Scheduler **chỉ quyết định node** — không tạo/dừng container (kubelet làm).
- Scheduler **watch API Server** — không đọc etcd trực tiếp.
- Scheduler **bind qua API Server** — nếu API Server down, pod ở Pending.
- Pod `Pending` + `Unschedulable` condition = không node nào pass Filter.
- Pod `Pending` không có `Unschedulable` = scheduler chưa xử lý (vừa tạo hoặc đang trong queue).
- Scheduler **stateless** — restart không mất scheduling decision (pod đã bind nằm trong etcd).
- `schedulerName` cho phép nhiều scheduler cùng chạy — mỗi scheduler quản lý pod riêng.
- `--v=5+` trong scheduler log thấy chi tiết Filter/Score decision cho từng pod.
