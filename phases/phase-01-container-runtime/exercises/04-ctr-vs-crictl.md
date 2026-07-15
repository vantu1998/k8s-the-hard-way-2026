# Exercise 04 — So sánh ctr run vs crictl runp

> **Mục tiêu**: Hiểu khác biệt giữa containerd API (ctr) và CRI interface (crictl) — cùng tạo container nhưng qua 2 layer khác nhau.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Linux VM, containerd, `ctr`, `crictl`, đã làm Exercise 02 + 03

## Bối cảnh

`ctr` và `crictl` đều tạo container trên containerd, nhưng qua 2 API khác nhau. Bài này tạo cùng 1 container bằng cả 2 cách, so sánh kết quả.

## Bước 1: Tạo container bằng ctr (containerd API)

```bash
# Pull image (nếu chưa có)
sudo ctr images pull docker.io/library/nginx:1.25

# Run bằng ctr
sudo ctr run -d --env APP_ENV=ctr-test docker.io/library/nginx:1.25 ctr-nginx

# Kiểm tra
sudo ctr containers list
# CONTAINER    IMAGE    RUNTIME    STATUS
# ctr-nginx    nginx    runc       running

sudo ctr tasks list
# TASK        PID     STATUS
# ctr-nginx   12345   RUNNING
```

**Kiểm tra**: Container `ctr-nginx` running.

## Bước 2: Xem container từ góc nhìn crictl (CRI)

```bash
# crictl có thấy container do ctr tạo không?
crictl ps -a
# (không thấy ctr-nginx!)

# Lý do: ctr tạo trong namespace "default", crictl xem trong namespace "k8s.io"
# CRI chỉ thấy container do CRI tạo (trong k8s.io namespace)
```

**Kiểm tra**: `crictl ps` không thấy container do `ctr` tạo.

## Bước 3: Xem container trong namespace khác nhau

```bash
# Container trong default namespace (do ctr tạo)
sudo ctr -n default containers list
# CONTAINER    IMAGE    RUNTIME
# ctr-nginx    nginx    runc

# Container trong k8s.io namespace (do crictl/kubelet tạo)
sudo ctr -n k8s.io containers list
# (empty — chưa có container nào do CRI tạo)
```

**Kiểm tra**: Container `ctr-nginx` chỉ trong `default`, không trong `k8s.io`.

## Bước 4: Tạo container bằng crictl (CRI API)

```bash
# Pull image vào k8s.io namespace
crictl pull docker.io/library/nginx:1.25

# Tạo pod sandbox
cat > /tmp/pod.json << 'EOF'
{
  "metadata": {"name": "compare-pod", "namespace": "default", "attempt": 1, "uid": "test-uid"},
  "logDirectory": "/tmp/pod-logs",
  "linux": {}
}
EOF

POD_ID=$(crictl runp /tmp/pod.json)

# Tạo container config
cat > /tmp/ctr.json << 'EOF'
{
  "metadata": {"name": "cri-nginx"},
  "image": {"image": "docker.io/library/nginx:1.25"},
  "command": ["nginx", "-g", "daemon off;"],
  "log_path": "nginx.log",
  "linux": {}
}
EOF

CONTAINER_ID=$(crictl create $POD_ID /tmp/ctr.json /tmp/pod.json)
crictl start $CONTAINER_ID

# Kiểm tra bằng crictl
crictl ps
# CONTAINER ID    IMAGE    STATE     NAME        POD ID
# <id>            nginx    Running   cri-nginx   <pod-id>
```

**Kiểm tra**: Container `cri-nginx` running trong `crictl ps`.

## Bước 5: Xem container do crictl tạo từ góc nhìn ctr

```bash
# ctr trong k8s.io namespace
sudo ctr -n k8s.io containers list
# CONTAINER       IMAGE    RUNTIME
# <container-id>  nginx    runc
# <sandbox-id>    pause    runc       ← pause container (pod sandbox)

# ctr trong default namespace
sudo ctr -n default containers list
# CONTAINER       IMAGE    RUNTIME
# ctr-nginx       nginx    runc
```

**Kiểm tra**: `k8s.io` có container cri-nginx + pause, `default` có ctr-nginx.

## Bước 6: So sánh chi tiết

```bash
# Inspect container do ctr tạo
sudo ctr -n default containers info ctr-nginx | jq .
# {
#   "id": "ctr-nginx",
#   "labels": {},
#   "image": "docker.io/library/nginx:1.25",
#   "runtime": "io.containerd.runc.v2"
# }

# Inspect container do crictl tạo
crictl inspect $CONTAINER_ID | jq .status
# {
#   "id": "...",
#   "metadata": {"name": "cri-nginx"},
#   "state": "CONTAINER_RUNNING",
#   "image": {"image": "docker.io/library/nginx:1.25"}
# }

# Inspect pod sandbox
crictl inspectp $POD_ID | jq .status
# {
#   "id": "...",
#   "metadata": {"name": "compare-pod", "namespace": "default"},
#   "state": "SANDBOX_READY"
# }
```

## Bước 7: Bảng so sánh

| Tiêu chí | ctr run | crictl runp + create + start |
|----------|---------|------------------------------|
| API layer | containerd gRPC | CRI gRPC |
| Namespace | `default` | `k8s.io` |
| Pod sandbox | Không có | Có (pause container + netns) |
| Network namespace | Tạo mới (runc default) | CNI plugin gán IP |
| Metadata | Chỉ container name | Pod name, namespace, UID, labels |
| Pause container | Không | Có |
| Kubelet quản lý | Không | Có (kubelet thấy qua CRI) |
| crictl thấy | Không | Có |
| ctr thấy | Có (trong đúng namespace) | Có (trong k8s.io namespace) |

## Bước 8: Verify — kubelet chỉ thấy CRI container

```bash
# Giả lập: nếu kubelet chạy, nó chỉ list pod qua CRI
crictl pods
# POD ID    NAME          STATE    NAMESPACE
# <id>      compare-pod   Ready    default

# Kubelet KHÔNG thấy ctr-nginx (không qua CRI)
# ctr-nginx là "orphan" từ góc nhìn Kubernetes
```

**Kiểm tra**: `crictl pods` chỉ thấy pod do CRI tạo, không thấy container do `ctr` tạo.

## Cleanup

```bash
# Cleanup crictl container
crictl stop $CONTAINER_ID
crictl rm $CONTAINER_ID
crictl stopp $POD_ID
crictl rmp $POD_ID

# Cleanup ctr container
sudo ctr tasks kill ctr-nginx
sudo ctr tasks delete ctr-nginx
sudo ctr containers delete ctr-nginx

# Cleanup files
rm -f /tmp/pod.json /tmp/ctr.json
rm -rf /tmp/pod-logs
```

## Câu hỏi tự kiểm tra

1. Tại sao `crictl ps` không thấy container do `ctr` tạo?
2. Container do `ctr` tạo có pod sandbox không? Ảnh hưởng gì?
3. Nếu kubelet restart — container do `ctr` tạo bị ảnh hưởng không?
4. Tại sao container do `ctr` tạo không có network namespace từ CNI?
5. Khi nào nên dùng `ctr`, khi nào dùng `crictl`?

## Đáp án tham khảo

1. Vì `ctr` tạo trong containerd namespace `default`, `crictl` chỉ xem trong `k8s.io`. CRI chỉ thấy container do CRI tạo.
2. Không. Không có pause container, không có CNI. Container dùng runc default network (chỉ loopback).
3. Không. Kubelet không biết container này tồn tại (không qua CRI). Container tiếp tục chạy nhưng không được quản lý.
4. Vì CNI chỉ được gọi qua CRI `RunPodSandbox`. `ctr` không gọi CRI → không gọi CNI.
5. `ctr`: debug containerd internals, test runtime, không liên quan K8s. `crictl`: debug pod/container trên K8s node, xem kubelet quản lý gì.
