# Exercise 01 — Configure containerd

> **Mục tiêu**: Cấu hình kubelet dùng containerd qua CRI socket, verify CRI connection hoạt động.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 7), SSH access vào worker node, `sudo` privilege

## Bối cảnh

Kubelet gọi CRI runtime qua Unix socket. Bài này verify containerd config, CRI socket, kubelet connection, `crictl` works.

## Prerequisites

```bash
# SSH vào worker node
ssh worker-1

# Check containerd running
sudo systemctl status containerd
# Active: active (running)

# Check containerd version
containerd --version
# containerd containerd.io 1.7.0
```

## Bước 1: Check CRI socket

```bash
# Check CRI socket exists
ls -la /run/containerd/containerd.sock
# srw-rw---- 1 root root 0 Jan 1 00:00 /run/containerd/containerd.sock

# Verify socket is Unix socket
sudo file /run/containerd/containerd.sock
# /run/containerd/containerd.sock: socket
```

> CRI socket = Unix socket. Kubelet connect qua Unix socket (local, không network). Permission `srw-rw----` — chỉ root access.

**Kiểm tra**: Socket `/run/containerd/containerd.sock` tồn tại, type = socket.

## Bước 2: Check containerd config

```bash
# Check containerd config
sudo cat /etc/containerd/config.toml | grep -E "(socket_path|sandbox_image|snapshotter|SystemdCgroup)"
# socket_path = "/run/containerd/containerd.sock"
# sandbox_image = "registry.k8s.io/pause:3.9"
# snapshotter = "overlayfs"
# SystemdCgroup = true
```

### Key config verify

| Config | Expected | Ý nghĩa |
|--------|----------|---------|
| `socket_path` | `/run/containerd/containerd.sock` | CRI gRPC socket |
| `sandbox_image` | `registry.k8s.io/pause:3.9` | Pause container image |
| `snapshotter` | `overlayfs` | Storage driver |
| `SystemdCgroup` | `true` | systemd cgroup driver (match kubelet) |

**Kiểm tra**: Config có đúng socket path, sandbox image, overlayfs, SystemdCgroup=true.

## Bước 3: Verify kubelet CRI endpoint

```bash
# Check kubelet config
cat /var/lib/kubelet/config.yaml | grep containerRuntimeEndpoint
# containerRuntimeEndpoint: unix:///run/containerd/containerd.sock

# Or check kubelet flags
ps aux | grep kubelet | grep -o '\--container-runtime-endpoint=[^ ]*'
# --container-runtime-endpoint=unix:///run/containerd/containerd.sock
```

> Kubelet `containerRuntimeEndpoint` phải match containerd `socket_path`. Mismatch = kubelet không connect được CRI.

**Kiểm tra**: Kubelet config `containerRuntimeEndpoint` = `unix:///run/containerd/containerd.sock`.

## Bước 4: Verify cgroup driver match

```bash
# Containerd cgroup driver
sudo grep SystemdCgroup /etc/containerd/config.toml
# SystemdCgroup = true

# Kubelet cgroup driver
cat /var/lib/kubelet/config.yaml | grep cgroupDriver
# cgroupDriver: systemd

# Both must match!
```

> Containerd `SystemdCgroup = true` + kubelet `cgroupDriver: systemd` = match. Mismatch (cgroupfs vs systemd) = pod create fail.

**Kiểm tra**: Cả 2 dùng `systemd` cgroup driver.

## Bước 5: Test crictl — CRI connection

```bash
# Configure crictl
sudo cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# Test crictl — list sandboxes
sudo crictl pods
# POD ID       CREATED     STATE    NAME              NAMESPACE
# xyz789       10m ago     Ready    kube-proxy        kube-system
# abc123       5m ago      Ready    nginx-default     default

# List containers
sudo crictl ps
# CONTAINER    IMAGE    CREATED   STATE    NAME    POD ID
# def456       nginx    5m ago    Running  nginx   abc123

# List images
sudo crictl images
# IMAGE                    TAG    IMAGE ID            SIZE
# docker.io/library/nginx  1.25   sha256:xxx...       70MB
# registry.k8s.io/pause    3.9    sha256:yyy...       650KB
```

> `crictl` connect trực tiếp đến CRI socket (không qua kubelet). Nếu `crictl` works → CRI socket hoạt động, containerd CRI plugin running.

**Kiểm tra**: `crictl pods`, `crictl ps`, `crictl images` return data — CRI connection works.

## Bước 6: Check CRI version

```bash
# CRI version
sudo crictl version
# Version: 0.1.0
# RuntimeName: containerd
# RuntimeVersion: 1.7.0
# RuntimeApiVersion: v1
# RuntimeApiVersion: v1alpha1   (deprecated)

# Check CRI info
sudo crictl info
# {
#   "status": {
#     "conditions": [
#       {"type": "RuntimeReady", "status": true},
#       {"type": "NetworkReady", "status": true}
#     ]
#   },
#   "config": {
#     "containerd": {
#       "snapshotter": "overlayfs",
#       "defaultRuntime": "runc"
#     }
#   }
# }
```

> `RuntimeReady: true` = CRI runtime ready. `NetworkReady: true` = CNI ready. Cả 2 phải true để pod create works.

**Kiểm tra**: `RuntimeReady: true`, `NetworkReady: true`.

## Bước 7: Test CRI info via gRPC (advanced)

```bash
# Install crictl if not present
if ! command -v crictl &>/dev/null; then
  wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.33.0/crictl-v1.33.0-linux-amd64.tar.gz
  sudo tar zxvf crictl-v1.33.0-linux-amd64.tar.gz -C /usr/local/bin
  rm crictl-v1.33.0-linux-amd64.tar.gz
fi

# Check CRI stats
sudo crictl stats
# CONTAINER    CPU %       MEM         DISK        INODES
# def456       0.5%        50Mi        100MB       100

# Check pod sandbox stats
sudo crictl statsp
# POD ID       CPU %       MEM
# xyz789       0.1%        20Mi
```

## Bước 8: Restart containerd — verify kubelet reconnect

```bash
# Restart containerd
sudo systemctl restart containerd
sleep 3

# Check kubelet — should reconnect to CRI
sudo journalctl -u kubelet --no-pager -n 10 | grep -i "cri\|containerd"
# ... "Connect CRI socket" socket="/run/containerd/containerd.sock"
# ... "CRI connection established"

# Verify pods still running (containerd-shim keeps container alive)
sudo crictl ps
# CONTAINER    IMAGE    CREATED   STATE    NAME
# def456       nginx    10m ago   Running  nginx   ← still running!

# Check node still Ready
kubectl get node worker-1
# NAME       STATUS   ROLES    AGE
# worker-1   Ready    <none>   10d
```

> Containerd restart → kubelet reconnect CRI. Container vẫn chạy (containerd-shim giữ alive). Node vẫn Ready. **No downtime**.

**Kiểm tra**: Containerd restart → kubelet reconnect, container still running, node Ready.

## Cleanup

```bash
# No cleanup needed — this exercise is verification only
```

## Câu hỏi tự kiểm tra

1. Kubelet connect đến containerd qua gì? TCP hay Unix socket? Tại sao?
2. `SystemdCgroup = true` trong containerd phải match gì trong kubelet? Hậu quả nếu mismatch?
3. `crictl` khác `kubectl` thế nào? `crictl` connect đến đâu?
4. Containerd restart — container có bị kill không? Tại sao?
5. `RuntimeReady` và `NetworkReady` trong `crictl info` — cái nào liên quan CNI?

## Đáp án tham khảo

1. **Unix socket** (`/run/containerd/containerd.sock`). Unix socket = local, không network overhead, secure (filesystem permission). Kubelet và containerd trên cùng node — không cần TCP.
2. Phải match kubelet `cgroupDriver: systemd`. Mismatch (containerd=systemd, kubelet=cgroupfs) → container create fail — kubelet không tìm thấy cgroup, pod stuck in ContainerCreating.
3. `kubectl` → API Server (cluster-level). `crictl` → CRI socket (node-level, direct to containerd). `crictl` = debug tool, không tạo container (kubelet quản lý). `crictl` inspect container/sandbox/image trên 1 node cụ thể.
4. **Không bị kill** — containerd-shim là parent process của container, tách biệt containerd. Containerd restart → shim vẫn chạy → container alive. Kubelet reconnect CRI. **No downtime**. Đây là lý do containerd-shim tồn tại.
5. `RuntimeReady` = CRI runtime ready (containerd running). `NetworkReady` = CNI ready (network plugin configured). Cả 2 phải true. `NetworkReady: false` = CNI chưa setup → pod create fail (no IP). `RuntimeReady: false` = containerd down → no container.
