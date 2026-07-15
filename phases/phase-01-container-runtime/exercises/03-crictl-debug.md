# Exercise 03 — Dùng crictl debug pod, container, image

> **Mục tiêu**: Dùng crictl để debug container trên node — list pod, container, image, log, exec.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Linux VM, containerd đang chạy, `crictl` (cri-tools)

## Bối cảnh

crictl là công cụ debug chính trên Kubernetes node. Bài này giả lập kubelet tạo pod bằng `crictl runp` + `crictl create` + `crictl start`.

## Bước 1: Cài crictl

```bash
sudo apt install -y cri-tools

# Kiểm tra
crictl --version
# crictl version v1.x.x

# Config
cat /etc/crictl.yaml
# runtime-endpoint: unix:///run/containerd/containerd.sock
```

**Kiểm tra**: `crictl --version` hiện version.

## Bước 2: Test CRI connection

```bash
# Test connection
crictl info | jq .
# {
#   "status": {"conditions": [{"type": "RuntimeReady", "status": true}]},
#   "config": {"containerd": {"snapshotter": "overlayfs", ...}}
# }

# Nếu lỗi:
# crictl --runtime-endpoint unix:///run/containerd/containerd.sock info
```

**Kiểm tra**: `crictl info` trả về JSON, `RuntimeReady: true`.

## Bước 3: Pull image bằng crictl

```bash
# Pull pause image (cần cho pod sandbox)
crictl pull registry.k8s.io/pause:3.9

# Pull nginx
crictl pull docker.io/library/nginx:1.25

# List image
crictl images
# IMAGE                       TAG      IMAGE ID       SIZE
# docker.io/library/nginx     1.25     abc123...      150MB
# registry.k8s.io/pause       3.9      def456...      500KB
```

**Kiểm tra**: 2 image trong list.

## Bước 4: Tạo pod sandbox bằng crictl

```bash
# Tạo pod config JSON
cat > /tmp/pod-config.json << 'EOF'
{
  "metadata": {
    "name": "nginx-sandbox",
    "namespace": "default",
    "attempt": 1,
    "uid": "abc12345-6789-def0-1234-567890abcdef"
  },
  "logDirectory": "/tmp/pod-logs",
  "linux": {}
}
EOF

# Run pod sandbox
crictl runp /tmp/pod-config.json
# abc123def456...    ← sandbox ID

# List pod
crictl pods
# POD ID              CREATED         STATE    NAME             NAMESPACE
# abc123def456...     1 min ago       Ready    nginx-sandbox    default
```

**Kiểm tra**: Pod sandbox `Ready` trong list.

## Bước 5: Inspect pod sandbox

```bash
# Lấy pod ID
POD_ID=$(crictl pods --name nginx-sandbox -q)

# Inspect
crictl inspectp $POD_ID | jq .
# {
#   "status": {
#     "id": "abc123...",
#     "state": "SANDBOX_READY",
#     "metadata": {"name": "nginx-sandbox", "namespace": "default"}
#   },
#   "info": {
#     "pid": 12345,
#     "netns": "/var/run/netns/abc123..."
#   }
# }

# Xem network namespace
crictl inspectp $POD_ID | jq .info.netns
```

**Kiểm tra**: Pod có `state: SANDBOX_READY`, có PID và netns.

## Bước 6: Tạo container trong pod

```bash
# Tạo container config JSON
cat > /tmp/container-config.json << 'EOF'
{
  "metadata": {
    "name": "nginx"
  },
  "image": {
    "image": "docker.io/library/nginx:1.25"
  },
  "command": ["nginx", "-g", "daemon off;"],
  "log_path": "nginx.log",
  "linux": {}
}
EOF

# Create container trong pod sandbox
crictl create $POD_ID /tmp/container-config.json /tmp/pod-config.json
# def456ghi789...    ← container ID

# List container
crictl ps -a
# CONTAINER ID        IMAGE              CREATED         STATE      NAME    POD ID
# def456ghi789...     nginx:1.25         10 sec ago      Created    nginx   abc123...

# Container ở state "Created" — chưa chạy
```

**Kiểm tra**: Container state = `Created`.

## Bước 7: Start container

```bash
# Lấy container ID
CONTAINER_ID=$(crictl ps -a --name nginx -q)

# Start
crictl start $CONTAINER_ID

# Kiểm tra
crictl ps
# CONTAINER ID        IMAGE              CREATED         STATE      NAME    POD ID
# def456ghi789...     nginx:1.25         1 min ago       Running    nginx   abc123...
```

**Kiểm tra**: Container state = `Running`.

## Bước 8: Exec vào container

```bash
# Exec
crictl exec -it $CONTAINER_ID sh
# # ls /etc/nginx/
# # nginx -t
# # hostname
# # exit
```

**Kiểm tra**: Exec vào được, thấy filesystem nginx.

## Bước 9: Xem container log

```bash
# Tạo request
crictl exec $CONTAINER_ID curl -s localhost > /dev/null

# Xem log
crictl logs $CONTAINER_ID
# 10.0.0.1 - - [15/Jan/2026:10:00:00] "GET / HTTP/1.1" 200 ...

# Follow log
crictl logs -f $CONTAINER_ID
# (Ctrl+C)
```

**Kiểm tra**: Log hiện access log.

## Bước 10: Container stats

```bash
crictl stats
# CONTAINER   CPU %    MEM         DISK       INODES
# nginx       0.10%    25MiB       100MB      50

crictl stats -o json | jq .
```

**Kiểm tra**: Stats hiện CPU, MEM, DISK.

## Bước 11: Inspect container

```bash
crictl inspect $CONTAINER_ID | jq .info
# {
#   "pid": 12345,
#   "bundle": "/run/containerd/.../config.json",
#   "runtime": "runc",
#   ...
# }

# Xem PID
crictl inspect $CONTAINER_ID | jq .info.pid
# 12345

# Xem container state
crictl inspect $CONTAINER_ID | jq .status.state
# "CONTAINER_RUNNING"
```

**Kiểm tra**: Inspect hiện PID, bundle path, state.

## Bước 12: Stop + cleanup

```bash
# Stop container
crictl stop $CONTAINER_ID

# Remove container
crictl rm $CONTAINER_ID

# Stop pod sandbox
crictl stopp $POD_ID

# Remove pod sandbox
crictl rmp $POD_ID

# Kiểm tra
crictl pods
# (empty)
crictl ps -a
# (empty)

# Cleanup files
rm -f /tmp/pod-config.json /tmp/container-config.json
rm -rf /tmp/pod-logs
```

**Kiểm tra**: Pod và container đã xóa.

## Câu hỏi tự kiểm tra

1. `crictl runp` tạo gì? Pause container làm gì?
2. `crictl create` vs `crictl start` — tại sao tách 2 bước?
3. `crictl ps` vs `crictl pods` — khác gì?
4. Tại sao `crictl` không có lệnh tương tự `docker run` (tạo + start 1 lệnh)?
5. Nếu `crictl info` báo lỗi — nguyên nhân phổ biến là gì?

## Đáp án tham khảo

1. Tạo pod sandbox = network namespace + pause container. Pause giữ netns sống — nếu container chính chết, netns vẫn tồn tại cho container khác trong pod.
2. `create` = tạo container (runc create, state=Created). `start` = chạy (runc start). Tách bước cho phép kubelet set up container (mount, env) trước khi chạy.
3. `crictl ps` = list container. `crictl pods` = list pod sandbox. Pod có thể có nhiều container.
4. Vì CRI design tách 3 bước: RunPodSandbox → CreateContainer → StartContainer. crictl theo CRI spec. `docker run` gộp vì Docker không có pod concept.
5. Socket sai (`/run/containerd/containerd.sock` không tồn tại), containerd chưa chạy, hoặc CRI plugin chưa enable trong containerd config.
