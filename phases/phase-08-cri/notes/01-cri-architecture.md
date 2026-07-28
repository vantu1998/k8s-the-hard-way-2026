# 01 — CRI Architecture

## CRI là gì

CRI (Container Runtime Interface) là **gRPC interface** giữa kubelet và container runtime. Kubelet không biết runtime là gì (containerd, CRI-O, docker) — chỉ biết CRI interface.

```
Kubelet
  │
  ├── gRPC (Unix socket)
  │     │
  │     ▼
  │   Container Runtime (containerd / CRI-O)
  │     │
  │     ├── RuntimeService    (sandbox + container lifecycle)
  │     └── ImageService      (pull, list, inspect image)
  │
  └── CNI (network setup, separate from CRI)
```

> CRI = abstraction layer. Kubelet gọi CRI gRPC, runtime implement CRI. Thay đổi runtime (containerd → CRI-O) không cần thay đổi kubelet.

## Tại sao cần CRI

```
Trước CRI (K8s < 1.6):
  Kubelet → Docker API (hardcoded)
  → Không dùng được runtime khác (rkt, containerd)
  → Mỗi runtime = custom integration code trong kubelet

Sau CRI (K8s >= 1.6):
  Kubelet → CRI gRPC → Runtime (containerd, CRI-O, docker-shim)
  → Runtime implement CRI interface
  → Kubelet không cần biết runtime là gì
```

> CRI tách kubelet khỏi runtime — pluggable architecture. Runtime chỉ cần implement CRI gRPC interface.

## CRI gRPC services

CRI định nghĩa 2 gRPC service:

### 1. RuntimeService

Quản lý **sandbox + container lifecycle**:

| Method | Ý nghĩa |
|--------|---------|
| `RunPodSandbox` | Tạo pod sandbox (network namespace + IPC namespace) |
| `StopPodSandbox` | Stop sandbox (network down) |
| `RemovePodSandbox` | Xóa sandbox (cleanup) |
| `PodSandboxStatus` | Trạng thái sandbox (IP, state, network) |
| `ListPodSandbox` | List tất cả sandbox |
| `CreateContainer` | Tạo container trong sandbox |
| `StartContainer` | Start container |
| `StopContainer` | Stop container (graceful) |
| `RemoveContainer` | Xóa container |
| `ListContainers` | List tất cả container |
| `ContainerStatus` | Trạng thái container (state, exit code) |
| `ExecSync` | Exec command in container (sync) |
| `Exec` | Exec command (stream) |
| `Attach` | Attach to container |
| `PortForward` | Port forward |
| `ReopenContainerLog` | Reopen log file |

### 2. ImageService

Quản lý **image**:

| Method | Ý nghĩa |
|--------|---------|
| `ListImages` | List tất cả image |
| `ImageStatus` | Trạng thái image (ID, size, digest) |
| `PullImage` | Pull image từ registry |
| `RemoveImage` | Xóa image |
| `ImageFsInfo` | Filesystem info (disk usage) |

> Kubelet gọi ImageService để pull image, RuntimeService để tạo/start container. 2 service tách riêng vì image management có thể delegate cho image store riêng.

## CRI socket

```
Kubelet → Unix socket → Container Runtime

containerd:  /run/containerd/containerd.sock
CRI-O:       /var/run/crio/crio.sock
docker-shim: /var/run/dockershim.sock (deprecated, removed in K8s 1.24)
```

### Kubelet flag

```bash
# Kubelet flag
--container-runtime-endpoint=unix:///run/containerd/containerd.sock

# Hoặc trong config file
# /var/lib/kubelet/config.yaml
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
```

> Kubelet connect đến CRI socket qua Unix socket (local, không network). gRPC over Unix socket — secure, low latency.

## CRI-compatible runtimes

| Runtime | CRI Socket | Notes |
|----------|-----------|-------|
| **containerd** | `/run/containerd/containerd.sock` | Phổ biến nhất, CNCF graduated |
| **CRI-O** | `/var/run/crio/crio.sock` | Red Hat, lightweight, K8s-specific |
| **docker-shim** | `/var/run/dockershim.sock` | Deprecated, removed K8s 1.24 |
| **kata-runtime** | `/run/kata-containers/containerd.sock` | VM-based, sandboxed |
| **gVisor (runsc)** | containerd + runsc | Google, kernel-level sandbox |

### containerd vs CRI-O

| | containerd | CRI-O |
|---|---|---|
| **Origin** | Docker, CNCF graduated | Red Hat, K8s-specific |
| **Scope** | General container runtime | K8s only (CRI only) |
| **Image store** | content store (snapshotter) | containers/storage |
| **Network** | CNI | CNI |
| **OCI runtime** | runc (default) | runc (default) |
| **Use case** | K8s, Docker, general | K8s only (OpenShift) |

> Cả 2 implement CRI — kubelet không phân biệt. containerd phổ biến hơn (kubeadm default). CRI-O dùng trong OpenShift.

## CRI protocol — gRPC + protobuf

```
CRI gRPC protocol:
  - Transport: Unix socket
  - Encoding: protobuf
  - API: gRPC (bidirectional streaming)

Proto file: k8s.io/cri-api/pkg/apis/runtime/v1
  - RuntimeService.proto
  - ImageService.proto
```

### gRPC call example

```
Kubelet → gRPC → containerd

Request (protobuf):
  method: RunPodSandbox
  PodSandboxConfig:
    metadata: { name: "web", namespace: "default", uid: "xxx" }
    hostname: "web"
    log_directory: "/var/log/pods/default_web/xxx"
    dns_config: { nameservers: ["10.96.0.10"] }
    port_mappings: [{ container_port: 80, host_port: 0 }]

Response (protobuf):
  pod_sandbox_id: "abc123def456"
```

> Kubelet serialize pod spec → protobuf → gRPC call → containerd receive → create sandbox → return sandbox ID. Kubelet không biết containerd internals — chỉ biết CRI interface.

## crictl — CRI CLI tool

`crictl` là CLI tool để tương tác trực tiếp với CRI runtime (không qua kubelet):

```bash
# List containers
crictl ps
# CONTAINER   IMAGE    CREATED    STATE    NAME    ATTEMPT
# abc123      nginx    10m ago    Running  nginx   1

# List sandboxes (pods)
crictl pods
# POD ID       CREATED    STATE    NAME    NAMESPACE
# xyz789       10m ago    Ready    web     default

# Inspect container
crictl inspect abc123

# Inspect sandbox
crictl inspectp xyz789

# Pull image
crictl pull nginx:1.25

# List images
crictl images

# Exec in container
crictl exec -it abc123 /bin/sh

# Logs
crictl logs abc123

# Stats
crictl stats
```

### crictl config

```bash
# /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
```

> `crictl` = debug tool. Không dùng để tạo container (kubelet quản lý). Dùng để inspect, debug, pull image, xem logs.

## CRI flow — pod creation

```
1. Kubelet detect pod assigned to node
2. Kubelet → CRI: RunPodSandbox
   ├── containerd: create network namespace
   ├── containerd: call CNI plugin (assign IP, setup route)
   └── return sandboxID
3. Kubelet → CRI: PullImage (if not cached)
   ├── containerd: pull image from registry
   └── return imageID
4. Kubelet → CRI: CreateContainer
   ├── containerd: create container spec (from pod spec)
   ├── containerd: mount volumes, set env, set command
   └── return containerID
5. Kubelet → CRI: StartContainer
   ├── containerd: containerd-shim → runc → start container
   └── container running
6. Kubelet → CRI: ContainerStatus (update pod status)
7. Kubelet → API Server: update pod status
```

> Kubelet gọi CRI cho mỗi step. CRI = gRPC call. Containerd thực hiện actual work (create namespace, pull image, start container via runc).

## Liên hệ với Kubernetes

- CRI = **gRPC interface** giữa kubelet và container runtime. Kubelet không biết runtime là gì.
- 2 service: **RuntimeService** (sandbox + container lifecycle) + **ImageService** (pull, list, inspect).
- CRI socket: containerd `/run/containerd/containerd.sock`, CRI-O `/var/run/crio/crio.sock`.
- `--container-runtime-endpoint` — kubelet flag để chỉ định CRI socket.
- CRI-compatible runtime: containerd (phổ biến), CRI-O (Red Hat), kata (VM sandbox), gVisor.
- `crictl` — CLI tool debug CRI runtime (inspect, logs, pull image). Không tạo container.
- docker-shim removed K8s 1.24 — Docker không còn supported runtime. Chuyển sang containerd.
- CRI flow: RunPodSandbox → PullImage → CreateContainer → StartContainer → ContainerStatus.
- CRI tách kubelet khỏi runtime — pluggable architecture, thay đổi runtime không cần thay đổi kubelet.
