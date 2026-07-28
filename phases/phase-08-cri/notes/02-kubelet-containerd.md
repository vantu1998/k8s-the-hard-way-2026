# 02 — kubelet ↔ containerd

## containerd architecture

```
containerd
  │
  ├── containerd-shim (per container)
  │     │
  │     ├── runc (OCI runtime — create/start container)
  │     └── container process (nginx, app, etc.)
  │
  ├── content store (image layers)
  ├── snapshotter (overlayfs, btrfs)
  ├── image pull/push
  ├── CRI plugin (gRPC server on Unix socket)
  └── CNI plugin (network setup)
```

### containerd-shim

```
Kubelet → CRI gRPC → containerd
                            │
                            ├── containerd-shim-runc-v2 (per pod)
                            │     │
                            │     ├── runc create container
                            │     ├── runc start container
                            │     └── monitor container (exit code, OOM)
                            │
                            └── (containerd can restart without affecting container)
```

> containerd-shim = parent process của container. Nếu containerd restart, container vẫn chạy (shim giữ container alive). Shim report exit code/OOM cho containerd.

### runc — OCI runtime

```
runc: low-level OCI container runtime
  - Create container: setup namespace, cgroup, mount
  - Start container: exec container process
  - Container = Linux namespace + cgroup + rootfs

containerd → runc:
  containerd-shim calls: runc --root /run/containerd/runc/k8s.io create <container-id>
  containerd-shim calls: runc --root /run/containerd/runc/k8s.io start <container-id>
```

> runc = OCI runtime (Open Container Initiative). Tạo container = Linux namespace + cgroup + rootfs. containerd delegate cho runc. CRI-O cũng dùng runc.

## CRI call chain — pod creation detail

### Step 1: RunPodSandbox

```
Kubelet → CRI gRPC: RunPodSandbox(PodSandboxConfig)
  │
  ▼
containerd CRI plugin:
  1. Generate sandbox ID (random)
  2. Create network namespace:
     - /var/run/netns/cni-xxx (network namespace)
  3. Call CNI plugin:
     - CNI_COMMAND=ADD
     - CNI_CONTAINERID=xxx
     - CNI_NETNS=/var/run/netns/cni-xxx
     - CNI_IFNAME=eth0
     - CNI_PATH=/opt/cni/bin
     - CNI plugin: assign IP, create veth, setup route
  4. Create sandbox container:
     - runc create (pause container — just sleep infinity)
     - runc start
  5. Return sandboxID
```

> Sandbox = network namespace + pause container. Pause container giữ network namespace alive (không exit). Tất cả container trong pod share network namespace của sandbox.

### Pause container

```bash
# Pause container — giữ network namespace
crictl ps | grep pause
# CONTAINER   IMAGE                    NAME           ATTEMPT
# abc123      registry.k8s.io/pause:3.9  k8s_POD_web   0

# Pause container chỉ sleep infinity — không chạy app
crictl inspect abc123 | jq '.info.runtimeSpec.process.args'
# ["/pause"]
```

> Pause container (a.k.a. sandbox container) = container đặc biệt chỉ `sleep infinity`. Giữ network namespace alive. Nếu app container crash, pause container vẫn chạy → network namespace không bị destroy.

### Step 2: PullImage

```
Kubelet → CRI gRPC: PullImage(ImageSpec)
  │
  ▼
containerd:
  1. Check local cache (content store)
  2. If not cached → pull from registry:
     - Download manifest
     - Download layers (gzip tar)
     - Extract layers to snapshotter (overlayfs)
     - Store in content store (digest)
  3. Return imageID (sha256 digest)
```

```bash
# Check image in containerd
crictl images | grep nginx
# IMAGE                    TAG    IMAGE ID            SIZE
# docker.io/library/nginx  1.25   sha256:abc123...    70MB
```

### Step 3: CreateContainer

```
Kubelet → CRI gRPC: CreateContainer(sandboxID, ContainerConfig, PodSandboxConfig)
  │
  ▼
containerd:
  1. Generate container ID (random)
  2. Build OCI spec from ContainerConfig:
     - image → rootfs (snapshotter mount)
     - command, args → process.args
     - env vars → process.env
     - volume mounts → mounts
     - resources (CPU, memory) → cgroup path
     - security context → capabilities, user, readonly
  3. runc create:
     - Create namespace (pid, ipc, uts — network from sandbox)
     - Create cgroup (cpu, memory limit)
     - Mount rootfs (overlayfs from image layers)
     - Setup mounts (volumes, /proc, /sys)
  4. Return containerID
```

> Kubelet gửi pod spec → containerd build OCI spec → runc create container. Container share network namespace với sandbox (pod).

### Step 4: StartContainer

```
Kubelet → CRI gRPC: StartContainer(containerID)
  │
  ▼
containerd:
  1. containerd-shim → runc start:
     - exec container process (runc start)
     - Container process runs in namespace + cgroup
  2. Shim monitor container:
     - Wait for exit
     - Report exit code to containerd
  3. Container running
```

### Step 5: ContainerStatus

```
Kubelet → CRI gRPC: ContainerStatus(containerID)
  │
  ▼
containerd:
  - Return state: RUNNING / EXITED / CREATED
  - Return exit code, startedAt, finishedAt
  - Return image ID, image ref
  │
  ▼
Kubelet → API Server: update pod status
```

## containerd config

```toml
# /etc/containerd/config.toml

version = 2

[plugins."io.containerd.grpc.v1.cri"]
  # CRI socket
  socket_path = "/run/containerd/containerd.sock"
  # Sandbox image (pause container)
  sandbox_image = "registry.k8s.io/pause:3.9"
  # CNI config
  [plugins."io.containerd.grpc.v1.cri".cni]
    bin_dir = "/opt/cni/bin"
    conf_dir = "/etc/cni/net.d"

  # Container runtime
  [plugins."io.containerd.grpc.v1.cri".containerd]
    # Snapshotter
    snapshotter = "overlayfs"
    # Default runtime
    default_runtime_name = "runc"
    # Runtime config
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v2"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        SystemdCgroup = true    # Use systemd cgroup driver

  # Image registry
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
```

### Key config

| Config | Ý nghĩa |
|--------|---------|
| `socket_path` | CRI gRPC socket path |
| `sandbox_image` | Pause container image |
| `snapshotter` | Storage driver (overlayfs default) |
| `SystemdCgroup` | Use systemd cgroup driver (must match kubelet) |
| `bin_dir` | CNI plugin binary path |
| `conf_dir` | CNI config directory |

> `SystemdCgroup = true` — containerd dùng systemd cgroup driver. Kubelet cũng phải dùng `cgroupDriver: systemd`. Mismatch = pod create fail.

## containerd CLI — ctr / nerdctl

```bash
# ctr — containerd CLI (low-level)
sudo ctr -n k8s.io images list | grep nginx
# REF                            TYPE   DIGEST    SIZE
# docker.io/library/nginx:1.25  application/vnd.docker.distribution.manifest.list.v2+json  sha256:xxx  70MB

# ctr namespaces
sudo ctr namespaces list
# NAME       DESCRIPTION
# default    default namespace
# k8s.io     Kubernetes containerd namespace

# nerdctl — Docker-compatible CLI for containerd
sudo nerdctl --namespace=k8s.io ps
# CONTAINER ID   IMAGE   COMMAND   CREATED   STATUS   PORTS   NAMES
```

| Tool | Level | Use case |
|------|-------|----------|
| `crictl` | CRI | K8s debugging (sandbox, container, image) |
| `ctr` | containerd | Low-level containerd (namespace, content, snapshot) |
| `nerdctl` | containerd | Docker-compatible CLI (build, compose) |

> `crictl` = CRI level (K8s). `ctr` = containerd level (low-level). `nerdctl` = Docker-compatible (user-friendly). K8s debugging → `crictl`.

## CRI call — pod stop

```
Kubelet detect pod delete:
  1. Kubelet → CRI: StopContainer(containerID, timeout)
     ├── containerd: send SIGTERM to container
     ├── Wait for container exit (or timeout)
     ├── If timeout → SIGKILL
     └── Container stopped
  2. Kubelet → CRI: RemoveContainer(containerID)
     ├── containerd: cleanup container (cgroup, namespace)
     └── Container removed
  3. Kubelet → CRI: StopPodSandbox(sandboxID)
     ├── containerd: stop pause container
     ├── CNI: teardown network (remove veth, release IP)
     └── Sandbox stopped
  4. Kubelet → CRI: RemovePodSandbox(sandboxID)
     ├── containerd: cleanup sandbox (network namespace)
     └── Sandbox removed
```

> Stop order: container first, sandbox last. CNI teardown khi stop sandbox (release IP, remove veth).

## Liên hệ với Kubernetes

- containerd = container runtime, implement CRI. containerd-shim quản lý container (survive containerd restart). runc = OCI runtime (create namespace + cgroup + rootfs).
- **Pause container** (sandbox container) = `sleep infinity`, giữ network namespace alive. App container crash → pause vẫn chạy → network không mất.
- CRI call chain: RunPodSandbox (CNI setup) → PullImage → CreateContainer (OCI spec) → StartContainer (runc start) → ContainerStatus.
- `SystemdCgroup = true` — containerd + kubelet phải cùng cgroup driver (systemd). Mismatch = pod create fail.
- `ctr` = low-level containerd CLI. `crictl` = CRI CLI (K8s debugging). `nerdctl` = Docker-compatible.
- Container share network namespace với sandbox (pod). Mỗi container có riêng PID namespace (trong pod), UTS namespace.
- Stop order: container stop → container remove → sandbox stop (CNI teardown) → sandbox remove.
