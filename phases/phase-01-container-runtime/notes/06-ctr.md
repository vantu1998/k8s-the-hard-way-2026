# 06 — ctr (containerd CLI)

## ctr là gì

ctr là **CLI trực tiếp cho containerd** — giao tiếp với containerd API, **không qua CRI**. Dùng để debug containerd ở mức thấp hơn crictl.

```
crictl → CRI gRPC → containerd     ← CRI layer (Kubernetes)
ctr    → containerd gRPC            ← Direct containerd API (bypass CRI)
```

## Khi nào dùng ctr vs crictl

| | ctr | crictl |
|---|-----|--------|
| Layer | containerd API trực tiếp | CRI interface |
| Namespace | containerd namespace (`default`, `k8s.io`) | CRI namespace (= K8s namespace) |
| Pod sandbox | Không có | Có (`crictl pods`) |
| Tạo container | `ctr run` — tạo trực tiếp | Không hỗ trợ |
| Image pull | `ctr images pull` | `crictl pull` |
| Debug | containerd internals | K8s pod/container |
| Dùng khi | Debug containerd, test runtime | Debug K8s pod |

## Namespace

```bash
# List namespace
ctr namespaces list
# default
# k8s.io    ← Kubernetes dùng

# Container/image trong namespace k8s.io
ctr -n k8s.io containers list
ctr -n k8s.io images list

# Mặc định = default namespace
ctr containers list    # = ctr -n default containers list
```

## Image commands

```bash
# Pull image
ctr images pull docker.io/library/nginx:1.25

# Pull vào namespace k8s.io
ctr -n k8s.io images pull docker.io/library/nginx:1.25

# List image
ctr images list
ctr -n k8s.io images list

# Image detail
ctr images inspect docker.io/library/nginx:1.25

# Xem image layer (manifest)
ctr images inspect docker.io/library/nginx:1.25 | jq .manifest

# Push image
ctr images push docker.io/myrepo/myapp:v1

# Remove image
ctr images rm docker.io/library/nginx:1.25

# Export image ra tar
ctr images export nginx.tar docker.io/library/nginx:1.25

# Import image từ tar
ctr images import nginx.tar
```

## Container commands

```bash
# Run container (tạo + start)
ctr run docker.io/library/nginx:1.25 mynginx

# Run với args khác
ctr run --rm docker.io/library/nginx:1.25 mynginx nginx -T

# Run detached
ctr run -d docker.io/library/nginx:1.25 mynginx

# Run với env
ctr run --env APP_ENV=production -d nginx:1.25 mynginx

# Run với mount
ctr run --mount type=bind,src=/tmp/data,dst=/data,options=ro -d nginx:1.25 mynginx

# List container
ctr containers list
ctr -n k8s.io containers list

# Container task (running process)
ctr tasks list
# TASK     PID     STATUS
# mynginx  12345   RUNNING

# Exec vào container
ctr tasks exec --exec-id exec1 -t mynginx sh

# Container log
ctr tasks logs mynginx
ctr tasks logs -f mynginx

# Stop container
ctr tasks kill mynginx
ctr tasks kill mynginx --signal SIGKILL

# Delete container
ctr containers delete mynginx
```

## Snapshot commands

```bash
# List snapshot
ctr snapshots list
# KEY                                                              PARENT                                                            KIND
# sha256:abc123...                                                                                                                   Active
# sha256:def456...                                                 sha256:abc123...                                                  Committed

# Xem snapshot detail
ctr snapshots info sha256:abc123...

# Xem content trên disk
ls /var/lib/containerd/io.containerd.snapshotter.overlay/snapshots/
# 1/  2/  3/  ...
```

## Content commands

```bash
# List content (blob)
ctr content list
# DIGEST                                                            SIZE    LABELS
# sha256:abc123...                                                  12345   containerd.io/snapshot/refs=...
# sha256:def456...                                                  67890   ...

# Xem content info
ctr content info sha256:abc123...

# Xem content trên disk
ls /var/lib/containerd/io.containerd.content.v1.blobs/sha256/
# abc123...  def456...  (raw blob files)
```

## So sánh: ctr run vs crictl runp

### ctr run — tạo container trực tiếp

```bash
ctr -n default run -d docker.io/library/nginx:1.25 mynginx

# ctr tạo:
# 1. Pull image (nếu chưa có)
# 2. Unpack layers → rootfs (snapshot)
# 3. Tạo OCI bundle
# 4. Gọi runc create + start
# Không tạo pod sandbox, không gọi CNI
```

### crictl runp — tạo pod sandbox qua CRI

```bash
# Cần pod config JSON
cat > /tmp/pod.json << 'EOF'
{
  "metadata": {"name": "nginx-pod", "namespace": "default"},
  "logDirectory": "/tmp/logs"
}
EOF

crictl runp /tmp/pod.json

# crictl tạo:
# 1. RunPodSandbox → tạo netns, pause container, CNI
# 2. Trả về sandboxID
# (Sau đó cần CreateContainer + StartContainer riêng)
```

### Khác biệt

| | ctr run | crictl runp |
|---|---------|-------------|
| Pod sandbox | Không | Có (pause container + netns) |
| CNI | Không gọi | Gọi CNI gán IP |
| Container | Tạo + start 1 lệnh | Cần CreateContainer + StartContainer riêng |
| Namespace | containerd namespace | CRI namespace |
| Metadata | Không có | Có pod metadata (name, namespace, labels) |

## Debug: xem container do kubelet tạo

```bash
# Container do kubelet tạo nằm trong namespace k8s.io
ctr -n k8s.io containers list
# CONTAINER   IMAGE    RUNTIME    STATUS
# <id>        nginx    runc       running
# <id>        pause    runc       running    ← pause container

# Task (process)
ctr -n k8s.io tasks list
# TASK     PID     STATUS
# <id>     12345   RUNNING

# Image
ctr -n k8s.io images list | grep nginx
# docker.io/library/nginx:1.25    sha256:abc...    150MB
```

## Liên hệ với Kubernetes

- **ctr** = debug tool, không dùng trong production.
- Khi `crictl` không hoạt động (CRI plugin lỗi), `ctr` vẫn truy cập được containerd.
- `ctr -n k8s.io` cho thấy mọi thứ kubelet tạo — container, image, snapshot.
- `ctr` không hiểu pod — chỉ hiểu container. Pod là khái niệm CRI/Kubernetes.
- Debug image pull issue: `ctr -n k8s.io images pull <image>` cho error message chi tiết hơn `crictl pull`.
