# 03 — containerd

## containerd là gì

containerd là **high-level container runtime** — daemon quản lý toàn bộ container lifecycle:

- **Image pull/push** — từ registry.
- **Image unpack** — layer → rootfs (snapshotter).
- **Container lifecycle** — create/start/stop/delete.
- **Snapshot management** — overlayfs, native, btrfs.
- **Execution** — gọi runc để tạo container.

```
┌─────────────────────────────────────────────────┐
│                  containerd                      │
│                                                  │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────┐ │
│  │ Image       │  │ Snapshot     │  │ CRI     │ │
│  │ Puller      │  │ Manager      │  │ Plugin  │ │
│  │ (Distribution)│ │ (overlayfs) │  │ (gRPC)  │ │
│  └─────────────┘  └──────────────┘  └─────────┘ │
│                                                  │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────┐ │
│  │ Container   │  │ Metadata     │  │ Events  │ │
│  │ Manager     │  │ Store        │  │         │ │
│  └─────────────┘  └──────────────┘  └─────────┘ │
└──────────┬──────────────────────────────────────┘
           │
           ↓ per container
┌──────────────────────┐
│ containerd-shim      │     ← parent của container process
│  └── runc create     │
│       └── container  │     ← actual container process
└──────────────────────┘
```

## containerd-shim — tại sao cần

Khi containerd tạo container, nó **không** là parent process trực tiếp. Thay vào đó, tạo `containerd-shim` per container:

```
containerd (daemon)
  ├── containerd-shim (container A)
  │   └── runc
  │       └── container A process (PID 1 trong ns)
  ├── containerd-shim (container B)
  │   └── runc
  │       └── container B process
  └── containerd-shim (container C)
      └── runc
          └── container C process
```

**Lý do cần shim**:
1. **containerd restart không kill container** — shim là parent, không phải containerd.
2. **Reap zombie** — shim reaps zombie child của container.
3. **Report exit status** — shim báo exit code cho containerd khi container chết.
4. **Stdio forwarding** — shim pipe stdout/stderr đến containerd.

## Cài đặt

```bash
# Ubuntu/Debian
sudo apt install -y containerd

# Hoặc install binary
# wget https://github.com/containerd/containerd/releases/download/v1.7.0/containerd-1.7.0-linux-amd64.tar.gz
# tar xvf containerd-1.7.0-linux-amd64.tar.gz -C /usr/local/

# Kiểm tra
containerd --version
# containerd github.com/containerd/containerd v1.7.0

# Start service
sudo systemctl start containerd
sudo systemctl enable containerd
sudo systemctl status containerd
```

## containerd config

```bash
# File config mặc định
cat /etc/containerd/config.toml

# Generate default config
containerd config default | sudo tee /etc/containerd/config.toml

# Restart sau khi đổi config
sudo systemctl restart containerd
```

### Config quan trọng cho Kubernetes

```toml
[plugins."io.containerd.grpc.v1.cri"]
  # CRI socket
  sandbox_image = "registry.k8s.io/pause:3.9"

  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
    runtime_type = "io.containerd.runc.v2"

    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = true    # ← dùng systemd cgroup driver (match kubelet)

  [plugins."io.containerd.grpc.v1.cri".cgroup]
    systemd_cgroup = true

# Snapshotter
[plugins."io.containerd.grpc.v1.cri".containerd]
  default_runtime_name = "runc"
  snapshotter = "overlayfs"
```

## Socket

```bash
# containerd socket
ls -la /run/containerd/containerd.sock
# srw-rw---- 1 root containerd ... /run/containerd/containerd.sock

# CRI socket (kubelet kết nối qua đây)
ls -la /run/containerd/containerd.sock
# (cùng socket — containerd expose cả CRI + ctr API trên 1 socket)
```

## Snapshotter — image layer → rootfs

```bash
# Xem snapshot
ctr snapshots list

# Xem snapshot detail
ctr snapshots info <snapshot-id>

# Cấu trúc trên disk
ls /var/lib/containerd/io.containerd.snapshotter.overlay/snapshots/
# 1/  2/  3/  ...    ← mỗi số = 1 layer

# Mỗi snapshot có:
# /var/lib/containerd/.../snapshots/1/fs/    ← actual filesystem content
# /var/lib/containerd/.../snapshots/1/parent ← parent snapshot id
```

### Overlayfs snapshotter

```
Image: nginx:1.25
  Layer 1 (base OS)   → snapshot/1/fs (lowerdir)
  Layer 2 (nginx)     → snapshot/2/fs (lowerdir, parent=1)
  Layer 3 (config)    → snapshot/3/fs (lowerdir, parent=2)

Container chạy:
  Write layer          → snapshot/4/fs (upperdir, parent=3)
  merged = overlay(lowerdir=3:2:1, upperdir=4)
```

## Image management

```bash
# Containerd lưu image metadata + content (blob)
ls /var/lib/containerd/io.containerd.content.v1.blobs/
# sha256/
#   abc123...   ← layer 1 blob (tar.gz)
#   def456...   ← layer 2 blob (tar.gz)
#   ghi789...   ← config blob (JSON)

# Image index/manifest
ls /var/lib/containerd/io.containerd.metadata.v1.bolt/
# meta.db    ← BoltDB — image metadata, snapshot metadata
```

## Events

```bash
# containerd phát event khi container lifecycle change
ctr events

# Output khi tạo container:
# 2026-01-15T10:00:00Z /snapshot/prepare   <snapshot-id>
# 2026-01-15T10:00:01Z /containers/create   <container-id>
# 2026-01-15T10:00:02Z /tasks/create        <task-id>
# 2026-01-15T10:00:02Z /tasks/start         <task-id>
```

## Debug containerd

```bash
# Log
journalctl -u containerd -f

# Config check
containerd config dump | head -50

# Socket check
sudo ctr --address /run/containerd/containerd.sock version

# Namespace
sudo ctr namespaces list
# default
# k8s.io    ← Kubernetes dùng namespace này

# Container trong namespace k8s.io
sudo ctr -n k8s.io containers list
```

## Liên hệ với Kubernetes

### Kubelet ↔ containerd qua CRI

```bash
# Kubelet config
# /etc/kubernetes/kubelet.yaml
# runtimeEndpoint: unix:///run/containerd/containerd.sock

# Kubelet gọi CRI gRPC:
# 1. ImageService.PullImage → containerd pull image
# 2. RuntimeService.RunPodSandbox → tạo netns, CNI
# 3. RuntimeService.CreateContainer → tạo container (gọi runc)
# 4. RuntimeService.StartContainer → start container
```

### Namespace

containerd có **namespace** (không phải K8s namespace) — tách biệt metadata:

| Namespace | Dùng cho |
|-----------|----------|
| `default` | `ctr` mặc định |
| `k8s.io` | Kubernetes (kubelet) |
| `moby` | Docker (nếu cài Docker) |

```bash
# Container do kubelet tạo nằm trong namespace k8s.io
sudo ctr -n k8s.io containers list

# Image do kubelet pull nằm trong k8s.io
sudo ctr -n k8s.io images list
```

### containerd-shim trong thực tế

```bash
# Xem shim process
ps aux | grep containerd-shim
# root  1234  containerd-shim-runc-v2 -namespace k8s.io -id <container-id> ...

# Kill shim → container bị orphan hoặc chết
# Đây là cách debug "container disappeared" issue
```
