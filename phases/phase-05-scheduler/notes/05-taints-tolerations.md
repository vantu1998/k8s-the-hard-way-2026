# 05 — Taints & Tolerations

## Taints & Tolerations là gì

- **Taint**: Đánh dấu node "repel" pod — pod không có toleration sẽ không schedule lên.
- **Toleration**: Pod "chịu được" taint — vẫn schedule lên node có taint.

```
Node-1: taint dedicated=gpu:NoSchedule
  ├── Pod A (không toleration)  → Không schedule lên node-1
  └── Pod B (toleration dedicated=gpu) → Schedule lên node-1 được
```

> Taints & Tolerations **đẩy pod ra khỏi node**. NodeAffinity **kéo pod vào node**. Dùng cùng nhau để control chặt chẽ.

## Taint — đánh dấu node

### Tạo taint

```bash
kubectl taint nodes node-1 dedicated=gpu:NoSchedule
# node/node-1 tainted
```

### Xem taint

```bash
kubectl describe node node-1 | grep -i taint
# Taints:  dedicated=gpu:NoSchedule
```

### Xóa taint

```bash
kubectl taint nodes node-1 dedicated=gpu:NoSchedule-
# node/node-1 untainted
```

> Dấu `-` ở cuối để xóa taint.

### Taint structure

```
<key>=<value>:<effect>

dedicated=gpu:NoSchedule
│        │    │
│        │    └── Effect: NoSchedule | NoExecute | PreferNoSchedule
│        └── Value (optional)
└── Key
```

### Taint effects

| Effect | Behavior |
|--------|----------|
| `NoSchedule` | Pod mới không schedule lên node. Pod đang chạy **không bị evict**. |
| `NoExecute` | Pod mới không schedule. Pod đang chạy **không có toleration bị evict** ngay. |
| `PreferNoSchedule` | Pod mới **prefer** không schedule (soft — scheduler cố tránh, nhưng vẫn schedule nếu không có lựa chọn). |

> `NoSchedule` vs `NoExecute`: `NoSchedule` không evict pod đang chạy. `NoExecute` evict pod đang chạy nếu không có toleration.

### NoExecute với tolerationSeconds

```yaml
spec:
  tolerations:
  - key: "node.kubernetes.io/unreachable"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 300
```

> Pod chịu được taint `unreachable` trong **300 giây**. Sau 300s, pod bị evict. Dùng cho graceful degradation — đợi node recover trước khi evict.

## Toleration — pod chịu taint

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "gpu"
    effect: "NoSchedule"
  containers:
  - name: app
    image: nginx
```

### Operators

| Operator | Ý nghĩa |
|----------|---------|
| `Equal` | `key=value` phải match chính xác taint |
| `Exists` | Key phải tồn tại (không quan tâm value) |

### Toleration examples

```yaml
# Match exact taint: dedicated=gpu:NoSchedule
tolerations:
- key: "dedicated"
  operator: "Equal"
  value: "gpu"
  effect: "NoSchedule"

# Match any taint with key=dedicated (any value, any effect)
tolerations:
- key: "dedicated"
  operator: "Exists"

# Match any taint with effect=NoExecute (any key, any value)
tolerations:
- operator: "Exists"
  effect: "NoExecute"
```

> `operator: Exists` + không có `value` = match bất kỳ value. `effect` trống = match bất kỳ effect.

## Built-in taints

Kubernetes tự động add taint cho node trong các tình huống sau:

| Taint | Effect | Khi nào | Mục đích |
|-------|--------|---------|----------|
| `node.kubernetes.io/not-ready` | `NoExecute` | Node status `Ready=False` | Pod evict sau `tolerationSeconds` (mặc định 300s) |
| `node.kubernetes.io/unreachable` | `NoExecute` | Node unreachable (heartbeat timeout) | Pod evict sau `tolerationSeconds` (mặc định 300s) |
| `node.kubernetes.io/memory-pressure` | `NoSchedule` | Node thiếu memory | Không schedule pod mới lên node sắp OOM |
| `node.kubernetes.io/disk-pressure` | `NoSchedule` | Node thiếu disk | Không schedule pod mới |
| `node.kubernetes.io/pid-pressure` | `NoSchedule` | Node thiếu PID | Không schedule pod mới |
| `node.kubernetes.io/network-unavailable` | `NoSchedule` | Node network chưa sẵn sàng | Không schedule pod cần network |
| `node.kubernetes.io/unschedulable` | `NoSchedule` | Node cordoned | Không schedule pod mới lên cordoned node |
| `node.cloudprovider.kubernetes.io/uninitialized` | `NoSchedule` | Node chưa được cloud provider init | Đợi cloud provider setup |

### Taint-based eviction flow

```
1. Node gặp vấn đề (memory-pressure, not-ready...)
2. Kubelet hoặc controller add taint (NoExecute)
3. Pod không có toleration → evict ngay
4. Pod có toleration + tolerationSeconds → đợi N giây, sau đó evict
5. Node recover → taint removed → pod có thể schedule lại
```

> Default pod (không chỉ định toleration) có toleration ngầm cho `not-ready` và `unreachable` với `tolerationSeconds: 300` — đợi 5 phút trước khi evict.

## Use cases

### 1. Dedicated node (GPU)

```bash
# Taint GPU node
kubectl taint nodes gpu-node-1 dedicated=gpu:NoSchedule
```

```yaml
# Pod cần GPU — có toleration
spec:
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "gpu"
    effect: "NoSchedule"
  nodeSelector:
    accelerator: nvidia
  containers:
  - name: ml-training
    image: tensorflow/tensorflow:latest-gpu
```

> Taint đuổi pod thường ra khỏi GPU node. Toleration + nodeSelector đảm bảo chỉ GPU pod schedule lên. **Taint đẩy ra, nodeSelector kéo vào** — dùng cả hai.

### 2. Maintenance mode

```bash
# Taint node để maintenance
kubectl taint nodes node-1 maintenance=true:NoExecute

# Pod không có toleration bị evict → reschedule lên node khác
# Sau khi maintenance xong:
kubectl taint nodes node-1 maintenance=true:NoExecute-
```

> `NoExecute` evict pod đang chạy. Dùng cho maintenance — di dời pod trước khi sửa node.

### 3. Special hardware node

```bash
# Taint node có hardware đặc biệt
kubectl taint nodes arm-node-1 arch=arm64:NoSchedule
```

```yaml
# Pod build cho ARM64
spec:
  tolerations:
  - key: "arch"
    operator: "Equal"
    value: "arm64"
    effect: "NoSchedule"
  nodeSelector:
    kubernetes.io/arch: arm64
```

### 4. Control plane node (kubeadm)

kubeadm tự động taint control plane node:

```bash
kubectl describe node node-1 | grep -i taint
# Taints:  node-role.kubernetes.io/control-plane:NoSchedule
```

> Control plane node bị taint `NoSchedule` — pod thường không schedule lên. Chỉ pod system (kube-proxy, CNI) có toleration mới chạy. Dùng `node-role.kubernetes.io/control-plane:NoSchedule` để reserve control plane node.

### 5. Node draining

```bash
# Cordon = taint unschedulable
kubectl cordon node-1

# Drain = cordon + evict pod
kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data
```

> `kubectl drain` = cordon (add taint) + evict pod (gọi API Server delete pod, deployment controller tạo pod mới trên node khác). DaemonSet pod không bị evict (`--ignore-daemonsets`).

## Taint vs nodeAffinity — dùng cả hai

```
Taint:        Đẩy pod KHÔNG mong muốn ra khỏi node
nodeAffinity: Kéo pod MONG MUỐN vào node

Chỉ Taint:         Pod có toleration nhưng không cần node → vẫn schedule lên node khác
Chỉ nodeAffinity:  Pod không match affinity → vẫn schedule lên node nếu có resource

Cả hai:             Chỉ pod MONG MUỐN (nodeAffinity) + có toleration → schedule lên node
```

> Best practice cho dedicated node: **Taint + nodeAffinity**. Taint chặn pod không mong muốn, nodeAffinity đảm bảo pod mong muốn schedule đúng node.

## Liên hệ với Kubernetes

- Taint = **đẩy ra** (repel), Toleration = **chịu được** taint.
- `NoSchedule` = chặn pod mới, không evict pod đang chạy.
- `NoExecute` = chặn pod mới + evict pod đang chạy (có `tolerationSeconds`).
- `PreferNoSchedule` = soft — scheduler cố tránh, nhưng vẫn schedule nếu cần.
- Built-in taints (`not-ready`, `memory-pressure`...) tự động add khi node gặp vấn đề.
- Default pod có toleration ngầm cho `not-ready`/`unreachable` với 300s timeout.
- Taint + nodeAffinity = dedicated node best practice.
- `kubectl drain` = cordon + evict — dùng cho maintenance.
- Control plane node bị taint `node-role.kubernetes.io/control-plane:NoSchedule` mặc định.
