# 02 — runc

## runc là gì

runc là **OCI runtime reference implementation** — CLI trực tiếp tạo và quản lý container từ OCI bundle. Đây là layer thấp nhất trong stack:

```
docker / ctr / crictl
       ↓
  containerd (daemon)
       ↓
containerd-shim (per container)
       ↓
     runc          ← bạn ở đây
       ↓
kernel (namespaces + cgroups)
```

runc **không pull image**, **không quản lý network**, **không có daemon** — nó chỉ nhận bundle (config.json + rootfs) và tạo container.

## Cài đặt

```bash
# Ubuntu/Debian
sudo apt install -y runc

# Hoặc build từ source
# https://github.com/opencontainers/runc

# Kiểm tra
runc --version
# runc version 1.1.5
# spec: 1.0.2-dev
```

## OCI Bundle — tạo bằng tay

```bash
# Tạo thư mục bundle
mkdir -p /tmp/mycontainer/rootfs

# Tạo rootfs — dùng busybox (nhỏ gọn)
# Cách 1: extract từ Docker image
docker export $(docker create busybox) | tar -C /tmp/mycontainer/rootfs -xvf -

# Cách 2: download busybox binary trực tiếp
mkdir -p /tmp/mycontainer/rootfs/bin
curl -fsSL https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox \
  -o /tmp/mycontainer/rootfs/bin/busybox
chmod +x /tmp/mycontainer/rootfs/bin/busybox
ln -s busybox /tmp/mycontainer/rootfs/bin/sh

# Tạo config.json
cd /tmp/mycontainer
runc spec
# → tạo config.json mặc định (chạy /bin/sh)

# Xem config
cat config.json | jq .process.args
# ["/bin/sh"]
```

## runc commands

### `runc run` — chạy container (foreground)

```bash
cd /tmp/mycontainer
sudo runc run mycontainer
# === Bạn đang ở trong container ===
# / # hostname
# mycontainer
# / # ps aux
# PID   USER     TIME  COMMAND
#   1   root     0:00  /bin/sh       ← PID 1
#   2   root     0:00  ps aux
# / # exit
# (container tự xóa khi exit)
```

### `runc create` + `runc start` — tách bước

```bash
# Tạo container (created state — process tồn tại nhưng chưa chạy)
sudo runc create mycontainer

# Xem state
sudo runc state mycontainer
# {
#   "ociVersion": "1.0.2",
#   "id": "mycontainer",
#   "status": "created",
#   "pid": 12345,
#   "bundle": "/tmp/mycontainer"
# }

# Start container
sudo runc start mycontainer
# (chạy /bin/sh trong container)
```

### `runc exec` — chạy lệnh trong container đang chạy

```bash
# Terminal 1: chạy container
sudo runc run mycontainer

# Terminal 2: exec vào
sudo runc exec mycontainer ls /
# bin   dev   etc   proc  sys   usr

sudo runc exec mycontainer echo "hello from container"
# hello from container
```

### `runc list` — liệt kê container

```bash
sudo runc list
# ID            PID         STATUS      BUNDLE              CREATED                     OWNER
# mycontainer   12345       running     /tmp/mycontainer    2026-01-15T10:00:00Z        root
```

### `runc kill` — gửi signal

```bash
# SIGTERM
sudo runc kill mycontainer TERM

# SIGKILL
sudo runc kill mycontainer KILL
```

### `runc delete` — xóa container

```bash
# Container phải stopped trước
sudo runc delete mycontainer
```

## Container lifecycle states

```
creating → created → running → stopped
                        ↓
                     paused (runc pause)
                        ↓
                     running (runc resume)
```

| State | Ý nghĩa |
|-------|---------|
| `creating` | Đang tạo namespace, cgroup |
| `created` | Đã tạo, process tồn tại nhưng chưa chạy (chờ `start`) |
| `running` | Process đang chạy |
| `paused` | Process bị freeze (cgroup freezer) |
| `stopped` | Process đã exit |

## Sửa config.json — chạy command khác

```bash
cd /tmp/mycontainer

# Sửa process.args thành nginx
cat config.json | jq '.process.args = ["nginx", "-g", "daemon off;"]' > config.json.tmp
mv config.json.tmp config.json

# Hoặc sửa thủ công
# "args": ["/bin/sh"]  →  "args": ["nginx", "-g", "daemon off;"]
```

## Sửa config.json — thêm resource limit

```json
{
  "linux": {
    "resources": {
      "memory": {
        "limit": 268435456
      },
      "cpu": {
        "quota": 50000,
        "period": 100000
      }
    }
  }
}
```

## Sửa config.json — thêm mount

```json
{
  "mounts": [
    {
      "destination": "/data",
      "type": "none",
      "source": "/tmp/mydata",
      "options": ["rbind", "ro"]
    }
  ]
}
```

## runc và containerd

containerd gọi runc để tạo container:

```bash
# Khi containerd tạo container, nó:
# 1. Tạo OCI bundle (config.json + rootfs) trong /run/containerd/...
# 2. Gọi: runc --root /run/containerd/runc/<namespace> create <container-id>
# 3. Gọi: runc start <container-id>

# Xem runc container do containerd quản lý
sudo runc --root /run/containerd/runc/default list
# ID: <container-id>  PID: 12345  STATUS: running
```

## Liên hệ với Kubernetes

- **kubelet** không gọi runc trực tiếp — gọi CRI → containerd → runc.
- **Debug**: nếu container không start, kiểm tra:
  1. `crictl logs <container>` — log từ container.
  2. `journalctl -u containerd` — log containerd.
  3. `runc --root /run/containerd/runc/default state <id>` — runc state.
  4. `cat /run/containerd/.../config.json` — OCI config thực tế.
- **runc exec** = cách `kubectl exec` hoạt động (qua CRI → containerd → runc exec).
- **runc delete** = cách `kubectl delete pod` dọn container (qua CRI → containerd → runc kill + delete).
