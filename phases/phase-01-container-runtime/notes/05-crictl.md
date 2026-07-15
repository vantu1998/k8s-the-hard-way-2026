# 05 — crictl

## crictl là gì

crictl là **CLI giao tiếp với CRI runtime** — tương tự `docker` CLI nhưng cho CRI. Dùng để debug pod, container, image trên Kubernetes node.

```
crictl → CRI gRPC → containerd/CRI-O
```

## Cài đặt

```bash
# Ubuntu/Debian
sudo apt install -y cri-tools

# Hoặc download binary
# wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/crictl-v1.28.0-linux-amd64.tar.gz
# tar xvf crictl-v1.28.0-linux-amd64.tar.gz -C /usr/local/bin/

# Kiểm tra
crictl --version
# crictl version v1.28.0
```

## Config

```bash
# File config: /etc/crictl.yaml
cat /etc/crictl.yaml
# runtime-endpoint: unix:///run/containerd/containerd.sock
# image-endpoint: unix:///run/containerd/containerd.sock
# timeout: 10
# debug: false

# Hoặc set qua flag
crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods
```

## Pod commands

```bash
# List pod sandbox
crictl pods
# POD ID              CREATED         STATE    NAME                NAMESPACE      ATTEMPT
# abc123...           10 min ago      Ready    nginx-pod           default        1

# List pod với filter
crictl pods --name nginx-pod
crictl pods --namespace default
crictl pods --state Ready

# Pod detail
crictl inspectp <pod-id>
# JSON output: metadata, status, network (IP), labels, annotations

# Pod status (compact)
crictl inspectp <pod-id> | jq .status
```

## Container commands

```bash
# List container
crictl ps
# CONTAINER ID        IMAGE              CREATED         STATE    NAME      POD ID
# def456...           nginx:1.25         5 min ago       Running  nginx     abc123...

# List tất cả (kể cả stopped)
crictl ps -a

# Container detail
crictl inspect <container-id>
# JSON: state, info (pid, bundle path), runtime, mounts, log path

# Container log
crictl logs <container-id>
crictl logs -f <container-id>     # follow

# Container stats
crictl stats
crictl stats <container-id>
# CONTAINER  CPU %   MEM        DISK       INODES
# nginx      0.50%   25MiB      100MB      50

# Exec vào container
crictl exec -it <container-id> sh

# Container status
crictl inspect <container-id> | jq .status.state
# "CONTAINER_RUNNING"
```

## Image commands

```bash
# List image
crictl images
# IMAGE                       TAG      IMAGE ID       SIZE
# docker.io/library/nginx     1.25     sha256:abc...  150MB
# registry.k8s.io/pause       3.9      sha256:def...  500KB

# Pull image
crictl pull nginx:1.25

# Image detail
crictl inspecti nginx:1.25

# Remove image
crictl rmi nginx:1.25
```

## Info & version

```bash
# Runtime info
crictl info
# {
#   "status": {...},
#   "config": {
#     "containerd": {
#       "snapshotter": "overlayfs",
#       "defaultRuntime": "runc"
#     }
#   }
# }

# CRI version
crictl version
# Version:  0.1.0
# RuntimeName: containerd
# RuntimeVersion: v1.7.0
# RuntimeApiVersion: v1
```

## Debug flow — "pod không start"

```bash
# 1. Xem pod sandbox
crictl pods --name <pod-name>
# POD ID    STATE    NAME
# abc123    NotReady <pod-name>    ← NotReady = có vấn đề

# 2. Xem container
crictl ps -a --pod <pod-id>
# CONTAINER   STATE      NAME     REASON
# def456      Exited     nginx    Error    ← container exit

# 3. Xem log
crictl logs def456
# nginx: [emerg] bind() to 0.0.0.0:80 failed (98: Address already in use)

# 4. Xem container detail
crictl inspect def456 | jq .status
# {
#   "state": "CONTAINER_EXITED",
#   "reason": "Error",
#   "exitCode": 1,
#   "finishedAt": "2026-01-15T10:05:00Z"
# }

# 5. Exec vào container đang chạy
crictl exec -it <container-id> sh
# / # ls /etc/nginx/
# / # nginx -t
```

## crictl vs docker CLI

| docker CLI | crictl | Ghi chú |
|-----------|--------|---------|
| `docker ps` | `crictl ps` | Container list |
| `docker images` | `crictl images` | Image list |
| `docker run` | — | crictl **không** run container trực tiếp |
| `docker exec` | `crictl exec` | Exec vào container |
| `docker logs` | `crictl logs` | Container log |
| `docker inspect` | `crictl inspect` | Container detail |
| `docker pull` | `crictl pull` | Pull image |
| `docker rm` | `crictl rm` | Remove container |
| `docker rmi` | `crictl rmi` | Remove image |
| — | `crictl pods` | **Pod sandbox** — docker không có |

**Khác biệt chính**: crictl có `pods` (pod sandbox) — docker không có khái niệm pod.

## Liên hệ với Kubernetes

- `crictl` là **debug tool** — không dùng để tạo pod (dùng `kubectl`).
- Trên node, `crictl` cho thấy container thực tế đang chạy.
- `crictl ps` = xem container từ góc nhìn runtime (khác `kubectl get pods` = xem từ API server).
- Pod có thể `Running` trên API server nhưng container `Exited` trên node → `crictl` phát hiện.
- `crictl exec` = cách `kubectl exec` hoạt động ở mức node.
- `crictl logs` = cách `kubectl logs` lấy log.
