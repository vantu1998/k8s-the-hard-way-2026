# 01 — OCI Spec

## OCI là gì

OCI (Open Container Initiative) là **specification** định nghĩa chuẩn cho container:

1. **Runtime Specification** — cách chạy container (config.json + rootfs).
2. **Image Specification** — cấu trúc container image (manifest, layers, config).
3. **Distribution Specification** — cách push/pull image từ registry.

OCI **không phải runtime** — nó là spec. Runtime (runc, crun, kata) implement spec này.

## Tại sao cần OCI

Trước OCI, Docker là de facto standard. Nếu Docker thay đổi internal → mọi tool phụ thuộc bị vỡ. OCI tách spec khỏi implementation:

```
OCI Spec (chuẩn)          Implementations
├── Runtime Spec          ├── runc (Docker, containerd)
├── Image Spec            ├── crun (Red Hat, C)
└── Distribution Spec     ├── runsc (gVisor)
                          └── kata-runtime (VM-based)
```

## OCI Runtime Specification

Định nghĩa **cấu trúc bundle** — thư mục chứa mọi thứ cần để chạy container:

```
my-bundle/
├── config.json    # Cấu hình container (process, namespaces, cgroups, mounts)
└── rootfs/        # Filesystem gốc của container (chứa /bin, /lib, /usr...)
    ├── bin/
    ├── lib/
    ├── usr/
    └── ...
```

### config.json — cấu trúc chính

```json
{
  "ociVersion": "1.0.2",
  "process": {
    "terminal": true,
    "user": {
      "uid": 0,
      "gid": 0
    },
    "args": ["/bin/sh"],
    "env": ["PATH=/bin:/usr/bin", "TERM=xterm"],
    "cwd": "/",
    "capabilities": {
      "bounding": ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
      "effective": ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
      "permitted": ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"]
    }
  },
  "root": {
    "path": "rootfs",
    "readonly": false
  },
  "hostname": "mycontainer",
  "mounts": [
    {
      "destination": "/proc",
      "type": "proc",
      "source": "proc"
    },
    {
      "destination": "/dev",
      "type": "tmpfs",
      "source": "tmpfs",
      "options": ["nosuid", "strictatime", "mode=755", "size=65536k"]
    },
    {
      "destination": "/sys",
      "type": "sysfs",
      "source": "sysfs",
      "options": ["nosuid", "noexec", "nodev", "ro"]
    }
  ],
  "linux": {
    "namespaces": [
      {"type": "pid"},
      {"type": "network"},
      {"type": "mount"},
      {"type": "ipc"},
      {"type": "uts"}
    ],
    "resources": {
      "memory": {
        "limit": 536870912
      },
      "cpu": {
        "quota": 50000,
        "period": 100000
      }
    }
  }
}
```

### Các phần quan trọng

| Phần | Ý nghĩa | Liên hệ Phase 0 |
|------|---------|-----------------|
| `process.args` | Lệnh chạy (entrypoint) | — |
| `process.env` | Environment variables | — |
| `process.capabilities` | Linux capabilities | Notes 04-capabilities |
| `root.path` | Đường dẫn rootfs (relative hoặc absolute) | — |
| `mounts` | Mount point — /proc, /dev, /sys, /tmp | Notes 02-namespaces (MNT ns) |
| `linux.namespaces` | Namespace cần tạo | Notes 02-namespaces |
| `linux.resources` | cgroup limit (CPU, memory) | Notes 03-cgroups |

### Tạo config.json bằng `runc spec`

```bash
# Tạo config.json template
runc spec

# Tạo cho rootless container
runc spec --rootless
```

## OCI Image Specification

Container image (trước khi unpack thành rootfs) có cấu trúc:

```
Image
├── Manifest      # Danh sách layer + config digest
├── Config        # Image config (entrypoint, env, layers order)
├── Layer 1       # tar.gz — base OS (ubuntu)
├── Layer 2       # tar.gz — apt install nginx
└── Layer 3       # tar.gz — COPY nginx.conf
```

### Image manifest (ví dụ đơn giản)

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:abc123...",
    "size": 7023
  },
  "layers": [
    {"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": "sha256:layer1...", "size": 32654},
    {"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": "sha256:layer2...", "size": 16724},
    {"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": "sha256:layer3...", "size": 73109}
  ]
}
```

### Image config (ví dụ đơn giản)

```json
{
  "architecture": "amd64",
  "os": "linux",
  "config": {
    "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "Cmd": ["nginx", "-g", "daemon off;"],
    "Entrypoint": ["/docker-entrypoint.sh"]
  },
  "rootfs": {
    "type": "layers",
    "diff_ids": ["sha256:layer1-uncompressed...", "sha256:layer2-uncompressed...", "sha256:layer3-uncompressed..."]
  }
}
```

### Flow: Image → Runtime bundle

```
1. Pull image từ registry (Distribution Spec)
   docker.io/library/nginx:1.25 → manifest + config + layers

2. Unpack layers thành rootfs (Image Spec → Runtime Spec)
   Layer 1 (tar.gz) → extract → snapshot/1/fs
   Layer 2 (tar.gz) → extract → snapshot/2/fs (overlay trên 1)
   Layer 3 (tar.gz) → extract → snapshot/3/fs (overlay trên 2)
   → rootfs = merged view của snapshot 1+2+3

3. Tạo config.json từ image config (Runtime Spec)
   image.config.Cmd → process.args
   image.config.Env → process.env
   + default namespaces, mounts, capabilities

4. runc đọc config.json + rootfs → tạo container
```

## Liên hệ với Kubernetes

- **containerd** implement cả 3 OCI spec: pull image (Distribution), unpack (Image), chạy (Runtime).
- **runc** implement chỉ Runtime Spec — nhận bundle, tạo container.
- **CRI** (Kubernetes) là layer **trên** OCI — kubelet không biết OCI, chỉ biết CRI gRPC.
- Khi `kubectl run nginx`:
  1. kubelet → CRI gRPC → containerd.
  2. containerd pull image (OCI Distribution).
  3. containerd unpack layers → rootfs (OCI Image → Runtime).
  4. containerd tạo OCI bundle (config.json + rootfs).
  5. containerd gọi runc với bundle (OCI Runtime).
  6. runc tạo namespaces + cgroups → container chạy.
