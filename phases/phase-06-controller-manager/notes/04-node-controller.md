# 04 — Node Controller

## Node Controller là gì

Node Controller quản lý **node lifecycle** — theo dõi node status, mark node NotReady khi heartbeat timeout, evict pod khi node down quá lâu.

```
Kubelet → heartbeat (node status update) → API Server → Node Controller watch
                                                         │
                                                         ├── Node Ready → OK
                                                         ├── Node NotReady (timeout) → mark NotReady
                                                         └── Node NotReady > pod-eviction-timeout → evict pod
```

## Node registration

### Kubelet register node

```bash
# Kubelet flag
--register-node=true   # default — kubelet tự register
```

```
1. Kubelet start → POST /api/v1/nodes (create Node object)
2. Node object: name, capacity, allocatable, addresses, OS, architecture
3. Kubelet update node status định kỳ (heartbeat)
```

### Manual registration

```bash
# Admin tạo Node object manually
kubectl apply -f - <<EOF
apiVersion: v1
kind: Node
metadata:
  name: worker-1
spec:
  podCIDR: 10.244.1.0/24
EOF

# Kubelet với --register-node=false → không tự register, chỉ update status
```

> Manual registration dùng cho on-prem hoặc khi cần control podCIDR. Kubelet vẫn update status (heartbeat) nhưng không tạo Node object.

## Heartbeat

Kubelet report node status qua 2 cơ chế:

| Mechanism | Frequency | Method |
|-----------|-----------|--------|
| Node Lease | 10s (default) | Update `Lease` object trong `kube-node-lease` namespace |
| Node Status | 60s (default) | PUT `/api/v1/nodes/<name>/status` |

### Node Lease

```bash
kubectl get lease -n kube-node-lease
# NAME       HOLDER     AGE
# worker-1   worker-1   10m
# worker-2   worker-2   10m
```

```yaml
# Lease object
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: worker-1
  namespace: kube-node-lease
spec:
  holderIdentity: worker-1
  renewTime: "2026-01-01T00:00:10.000000Z"
  leaseDurationSeconds: 40
```

> Lease nhẹ hơn node status update — chỉ 1 field (`renewTime`). Giảm API Server load. Node controller check lease để biết node alive.

### Node status update

```bash
kubectl describe node worker-1
# ...
# Conditions:
#   Type             Status  LastHeartbeatTime   Reason
#   Ready            True    2026-01-01T00:00:10  kubelet is posting ready status
#   MemoryPressure   False   2026-01-01T00:00:10  Kubelet has sufficient memory
#   DiskPressure     False   2026-01-01T00:00:10  Kubelet has no disk pressure
#   PIDPressure      False   2026-01-01T00:00:10  Kubelet has sufficient PID available
```

## Node conditions

| Condition | True meaning | False meaning |
|-----------|-------------|---------------|
| `Ready` | Node healthy, accepting pod | Node down hoặc kubelet not running |
| `MemoryPressure` | Node thiếu memory | Node đủ memory |
| `DiskPressure` | Node thiếu disk | Node đủ disk |
| `PIDPressure` | Node thiếu PID | Node đủ PID |
| `NetworkUnavailable` | Node network chưa sẵn sàng | Node network OK |

### Ready condition states

| Status | Meaning |
|--------|---------|
| `True` | Node healthy |
| `False` | Node down (kubelet không heartbeat) |
| `Unknown` | Node controller không nhận heartbeat trong grace period |

```
Node Ready=True → heartbeat OK
     │ (no heartbeat for 40s)
     ▼
Node Ready=Unknown → node controller mark NotReady
     │ (no heartbeat for 5m = pod-eviction-timeout)
     ▼
Node controller evict pod → pod reschedule to other node
```

## Node controller timing

| Parameter | Default | Ý nghĩa |
|-----------|---------|---------|
| `--node-monitor-period` | 5s | Node controller check node status mỗi 5s |
| `--node-monitor-grace-period` | 40s | Sau 40s không heartbeat → mark `Unknown` |
| `--pod-eviction-timeout` | 5m | Sau 5m NotReady → evict pod |
| `--node-startup-grace-period` | 60s | Grace period cho node mới join (chưa heartbeat ngay) |

### Timeline

```
t=0s:    Kubelet stop / node crash
t=5s:    Node controller check — lease still valid (renewTime < 40s ago)
t=10s:   Kubelet missed lease renewal
t=40s:   Node controller: lease expired → mark Ready=Unknown
         → Taint: node.kubernetes.io/unreachable:NoExecute
         → Pod có tolerationSeconds (default 300s) vẫn chạy
t=40s+:  Pod không có toleration → evict ngay
t=340s:  (40s + 300s tolerationSeconds) Pod có default toleration → evict
t=340s:  Pod evict → ReplicaSet controller tạo pod mới trên node khác
```

> Tổng thời gian từ node down đến pod reschedule: ~40s (mark Unknown) + 300s (tolerationSeconds) = ~340s = ~5.7 phút. **Production có thể giảm tolerationSeconds** để reschedule nhanh hơn.

## Pod eviction on NotReady node

```
Node Ready=Unknown (>40s)
    │
    ├── Taint: node.kubernetes.io/unreachable:NoExecute
    │
    ▼
Pod trên node:
    ├── Pod không có toleration → evict NGAY
    ├── Pod có toleration (default: 300s) → đợi 300s rồi evict
    └── Pod có toleration (no tolerationSeconds) → KHÔNG evict (chạy mãi)
```

### Default toleration

Mọi pod (kể cả không chỉ định toleration) có **ngầm** toleration cho `not-ready` và `unreachable`:

```yaml
# Implicit toleration (added by API Server)
tolerations:
- key: "node.kubernetes.io/not-ready"
  operator: "Exists"
  effect: "NoExecute"
  tolerationSeconds: 300
- key: "node.kubernetes.io/unreachable"
  operator: "Exists"
  effect: "NoExecute"
  tolerationSeconds: 300
```

> Default 300s = 5 phút. Pod đợi 5 phút trước khi evict — cho node time để recover. Nếu node recover trong 5 phút → pod không bị evict.

### Custom tolerationSeconds

```yaml
spec:
  tolerations:
  - key: "node.kubernetes.io/unreachable"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 30   # Evict sau 30s thay vì 300s
```

> Production critical workload: giảm `tolerationSeconds` để reschedule nhanh. Batch workload: tăng `tolerationSeconds` để tránh reschedule không cần thiết.

## podCIDR allocation

Node controller (với `--allocate-node-cidrs=true`) cấp podCIDR cho mỗi node:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
# worker-1   10.244.1.0/24
# worker-2   10.244.2.0/24
# worker-3   10.244.3.0/24
```

```
cluster-cidr: 10.244.0.0/16
node-cidr-mask-size: 24

Node-1: podCIDR=10.244.1.0/24  → 254 pod IP
Node-2: podCIDR=10.244.2.0/24  → 254 pod IP
Node-3: podCIDR=10.244.3.0/24  → 254 pod IP
```

> Mỗi node nhận 1 /24 subnet. Pod trên node nhận IP từ subnet đó. CNI (Calico, Flannel) dùng podCIDR để route pod traffic.

### Node join → podCIDR allocation

```
1. Kubelet register node (POST /api/v1/nodes)
2. Node controller detect new node
3. Node controller allocate podCIDR from cluster-cidr
4. Update node.spec.podCIDR
5. CNI detect podCIDR → configure networking
```

> Nếu `--allocate-node-cidrs=false` → CNI tự cấp podCIDR (ví dụ: Calico IPAM). Controller Manager không quản lý podCIDR.

## Node controller & cloud provider

Cloud provider node controller (external) bổ sung:
- Auto-register node từ cloud instance
- Set node label (zone, region, instance-type)
- Delete node khi cloud instance terminated
- Set providerID để identify cloud instance

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
# worker-1   aws:///us-east-1a/i-abc123def456
# worker-2   gce://my-project/us-east1-b/instance-2
```

> Cloud node controller xóa node object khi instance terminated. On-prem: admin phải xóa node manually (`kubectl delete node`).

## Cordon & Drain

### Cordon — mark node unschedulable

```bash
kubectl cordon worker-1
# node/worker-1 cordoned

kubectl get node worker-1
# NAME       STATUS                     ROLES    AGE
# worker-1   Ready,SchedulingDisabled   <none>   10d
```

> Cordon = add taint `node.kubernetes.io/unschedulable:NoSchedule`. Pod mới không schedule lên node. Pod đang chạy không bị evict.

### Drain — cordon + evict pod

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data
# node/worker-1 cordoned
# evicting pod default/web-abc123-xxx
# evicting pod default/web-abc123-yyy
# node/worker-1 drained
```

| Flag | Ý nghĩa |
|------|---------|
| `--ignore-daemonsets` | Không evict DaemonSet pod (DaemonSet pod chạy trên mọi node) |
| `--delete-emptydir-data` | Evict pod dùng emptyDir (data sẽ mất) |
| `--force` | Evict pod không thuộc ReplicaSet/Deployment (standalone pod) |
| `--grace-period=30` | Grace period cho pod shutdown |
| `--timeout=60s` | Timeout đợi pod evict |

> Drain = cordon + evict. Pod bị evict → ReplicaSet controller tạo pod mới trên node khác. DaemonSet pod không bị evict (ignore-daemonsets).

### Uncordon — mark node schedulable again

```bash
kubectl uncordon worker-1
# node/worker-1 uncordoned
```

> Sau khi maintenance xong, uncordon để node nhận pod mới. Pod đã evict không tự return — ReplicaSet tạo pod mới trên node khác, pod cũ không migrate.

## Liên hệ với Kubernetes

- Node Controller watch node status — mark `Unknown` khi heartbeat timeout (40s default).
- Pod evict sau `pod-eviction-timeout` (5m default) — pod reschedule lên node khác.
- Default pod có toleration ngầm `unreachable:NoExecute` với 300s — đợi 5 phút trước evict.
- `tolerationSeconds` tune reschedule speed — critical workload giảm, batch workload tăng.
- Node Lease (10s) nhẹ hơn node status update (60s) — giảm API Server load.
- `--allocate-node-cidrs=true` → Controller Manager cấp podCIDR cho node. CNI dùng podCIDR route.
- Cordon = unschedulable (no new pod). Drain = cordon + evict (move pod away).
- DaemonSet pod không bị drain evict (`--ignore-daemonsets`).
- Cloud node controller auto-delete node khi instance terminated. On-prem: manual delete.
