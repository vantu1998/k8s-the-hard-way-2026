# 01 — Node Registration

## Kubelet là gì

Kubelet là agent chạy trên **mỗi node** trong cluster Kubernetes. Nhiệm vụ chính:

1. **Register node** với API Server
2. **Watch pod** assigned cho node → tạo/stop container
3. **Report status** (heartbeat) định kỳ
4. **Health check** container (liveness/readiness probe)

```
API Server ←→ Kubelet (trên mỗi node) ←→ Container Runtime (containerd/CRI-O)
                   │
                   ├── Watch Pod (assigned to this node)
                   ├── CRI: CreateContainer, StartContainer, StopContainer
                   ├── Report Node Status (capacity, conditions, heartbeat)
                   └── Run probes (liveness, readiness, startup)
```

> Kubelet là **duy nhất** trên mỗi node. Không chạy nhiều kubelet trên cùng node. Kubelet = "node agent".

## Node registration

### Auto-registration (default)

```bash
# Kubelet flags
--register-node=true              # default — tự register
--node-ip=192.168.1.10            # IP node (primary)
--node-labels="zone=a,disk=ssd"  # Label khi register
--register-with-taints="dedicated=gpu:NoSchedule"  # Taint khi register
```

```
1. Kubelet start
2. POST /api/v1/nodes (create Node object)
   ├── metadata.name = hostname (hoặc --hostname-override)
   ├── spec.podCIDR = (assigned by controller manager)
   ├── status.capacity = CPU, memory, pod count
   ├── status.allocatable = capacity - system reserve
   └── status.addresses = hostname, InternalIP, ExternalIP
3. API Server create Node object
4. Controller Manager assign podCIDR
5. Kubelet start heartbeat (Lease + status update)
```

### Node object

```yaml
apiVersion: v1
kind: Node
metadata:
  name: worker-1
  labels:
    kubernetes.io/hostname: worker-1
    kubernetes.io/os: linux
    kubernetes.io/arch: amd64
    zone: a
spec:
  podCIDR: 10.244.1.0/24
  taints: []
status:
  capacity:
    cpu: "4"
    memory: 16Gi
    pods: "110"
  allocatable:
    cpu: "3500m"        # 4 CPU - 500m system reserve
    memory: 14Gi        # 16Gi - 2Gi system reserve
    pods: "110"
  addresses:
  - type: Hostname
    address: worker-1
  - type: InternalIP
    address: 192.168.1.10
  conditions:
  - type: Ready
    status: "True"
  - type: MemoryPressure
    status: "False"
  - type: DiskPressure
    status: "False"
  - type: PIDPressure
    status: "False"
```

### Manual registration

```bash
# Admin tạo Node object
kubectl apply -f - <<EOF
apiVersion: v1
kind: Node
metadata:
  name: worker-1
spec:
  podCIDR: 10.244.1.0/24
EOF

# Kubelet với --register-node=false → chỉ update status, không tạo Node
kubelet --register-node=false --node-ip=192.168.1.10
```

> Manual registration dùng cho on-prem hoặc khi cần control podCIDR/labels. Kubelet vẫn update status (heartbeat).

## Capacity vs Allocatable

```
Capacity = tổng resource physical trên node
Allocatable = Capacity - System Reserved - Kube Reserved - Eviction Threshold

Example:
  Capacity:         cpu=4000m  memory=16Gi
  System Reserved:  cpu=500m   memory=1Gi    (cho OS process)
  Kube Reserved:    cpu=200m   memory=1Gi    (cho kubelet, CNI, etc.)
  Eviction Threshold:          memory=100Mi  (buffer trước khi evict)
  ─────────────────────────────────────────
  Allocatable:      cpu=3300m  memory=13.9Gi (pod có thể dùng)
```

### Kubelet flags cho reservation

```bash
--system-reserved=cpu=500m,memory=1Gi
--kube-reserved=cpu=200m,memory=1Gi
--eviction-hard=memory.available<100Mi,nodefs.available<10%
--eviction-soft=memory.available<200Mi
```

> Pod chỉ schedule nếu request ≤ allocatable. Scheduler dùng `allocatable` (không phải `capacity`) để quyết định node có đủ resource không.

## Heartbeat

Kubelet report node status qua 2 cơ chế:

| Mechanism | Default frequency | Method |
|-----------|-------------------|--------|
| **Node Lease** | 10s | Update `Lease` object trong `kube-node-lease` namespace |
| **Node Status** | 60s (or when status changes) | PUT `/api/v1/nodes/<name>/status` |

### Node Lease

```yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: worker-1
  namespace: kube-node-lease
spec:
  holderIdentity: worker-1
  renewTime: "2026-01-01T00:00:10Z"
  leaseDurationSeconds: 40
```

> Lease rất nhẹ — chỉ 1 field `renewTime`. Node controller check lease để biết node alive. Lease update 10s → node down detected trong ~40s.

### Node status update

```bash
# Kubelet update node status định kỳ hoặc khi condition thay đổi
kubectl get node worker-1 -o yaml | grep -A 10 conditions
```

```
Kubelet update status khi:
  - Condition thay đổi (Ready, MemoryPressure, DiskPressure, PIDPressure)
  - Cứ 60s (default --node-status-update-frequency)
  - Capacity/allocatable thay đổi
```

### Kubelet flags cho heartbeat

```bash
--node-status-update-frequency=10s    # Update node status mỗi 10s
--node-lease-duration-seconds=40      # Lease timeout (node controller)
```

> Tương quan với node controller:
> - `--node-status-update-frequency` (kubelet) = 10s → kubelet update mỗi 10s
> - `--node-monitor-grace-period` (controller manager) = 40s → sau 40s không heartbeat → mark Unknown

## Node conditions

Kubelet report conditions dựa trên node state:

| Condition | True khi | Kubelet action |
|-----------|----------|----------------|
| `Ready` | Kubelet healthy, CRI running | Report True |
| `MemoryPressure` | Node memory thấp (< eviction threshold) | Report True, evict pod |
| `DiskPressure` | Node disk thấp (< eviction threshold) | Report True, evict pod |
| `PIDPressure` | Node PID thấp | Report True, evict pod |

### Eviction thresholds

```bash
# Hard eviction — evict pod ngay khi vượt threshold
--eviction-hard=memory.available<100Mi,nodefs.available<10%,nodefs.inodesFree<5%,imagefs.available<15%

# Soft eviction — evict pod sau grace period khi vượt threshold
--eviction-soft=memory.available<200Mi,nodefs.available<15%
--eviction-soft-grace-period=memory.available=1m30s,nodefs.available=2m30s
```

> Hard eviction = evict ngay. Soft eviction = đợi grace period, nếu vẫn vượt → evict. Kubelet evict pod priority thấp nhất trước (BestEffort → Burstable → Guaranteed).

## Kubelet configuration

### Config file (v1.33+)

```yaml
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1
kind: KubeletConfiguration
address: 0.0.0.0
port: 10250
readOnlyPort: 0
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
cgroupDriver: systemd
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
evictionHard:
  memory.available: "100Mi"
  nodefs.available: "10%"
  nodefs.inodesFree: "5%"
  imagefs.available: "15%"
failSwapOn: true
imageGCHighThresholdPercent: 85
imageGCLowThresholdPercent: 80
kubeReserved:
  cpu: "200m"
  memory: "1Gi"
systemReserved:
  cpu: "500m"
  memory: "1Gi"
rotateCertificates: true
serverTLSBootstrap: true
staticPodPath: /etc/kubernetes/manifests
```

### Kubelet flags vs config file

| Method | Usage |
|--------|-------|
| Flags (`--flag=value`) | Deprecated cho nhiều flags, vẫn dùng cho bootstrap |
| Config file (`config.yaml`) | Preferred — structured, validated, versioned |

```bash
# Kubelet đọc config file
kubelet --config=/var/lib/kubelet/config.yaml

# Vẫn dùng flags cho bootstrap
kubelet --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \
        --kubeconfig=/etc/kubernetes/kubelet.conf \
        --config=/var/lib/kubelet/config.yaml
```

## Kubelet port

| Port | Protocol | Purpose |
|------|----------|---------|
| 10250 | HTTPS | Kubelet API (auth via webhook) — exec, logs, port-forward |
| 10255 | HTTP | Read-only API (deprecated, `readOnlyPort: 0` disable) |
| 4194 | HTTP | cAdvisor UI (deprecated) |

```bash
# Kubelet API (requires auth)
kubectl exec -it pod -- /bin/sh    # → kubelet API → CRI exec
kubectl logs pod                   # → kubelet API → CRI logs
kubectl port-forward pod 8080:80   # → kubelet API → port-forward
```

> Kubelet API (10250) yêu cầu authentication (webhook → API Server authorize). Không expose ra ngoài — chỉ API Server và kubectl proxy truy cập.

## Liên hệ với Kubernetes

- Kubelet là agent trên **mỗi node** — register node, watch pod, tạo/stop container, report status.
- Auto-registration (`--register-node=true`) — kubelet POST Node object khi start.
- **Capacity** = tổng resource. **Allocatable** = capacity - reserved. Scheduler dùng allocatable.
- Heartbeat: **Lease** (10s, nhẹ) + **Node Status** (60s, chi tiết).
- Node conditions: Ready, MemoryPressure, DiskPressure, PIDPressure — kubelet report, node controller react.
- Eviction: hard (evict ngay) vs soft (evict sau grace period). Kubelet evict pod priority thấp nhất trước.
- Config file (`config.yaml`) preferred over flags — structured, validated.
- Kubelet API port 10250 (HTTPS, auth) — exec, logs, port-forward.
- `--register-node=false` = manual registration, kubelet chỉ update status.
