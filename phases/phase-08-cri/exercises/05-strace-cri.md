# Exercise 05 — strace CRI Calls

> **Mục tiêu**: Strace kubelet khi tạo pod, tìm gRPC call đến containerd socket. Hiểu kubelet → CRI gRPC flow bằng tay.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 7), SSH access vào worker node, `sudo` privilege, `strace` installed

## Bối cảnh

Kubelet gọi CRI qua gRPC over Unix socket. Bài này strace kubelet, deploy pod, tìm gRPC call đến containerd socket — thấy CRI flow bằng tay.

## Prerequisites

```bash
ssh worker-1

# Install strace if not present
sudo apt install -y strace 2>/dev/null || sudo yum install -y strace

# Verify
strace -V
# strace -- version 6.0

# Find kubelet PID
KUBELET_PID=$(pgrep -x kubelet)
echo "Kubelet PID: ${KUBELET_PID}"
```

## Bước 1: Strace kubelet — capture socket calls

```bash
# Terminal 1 — start strace on kubelet (capture connect + sendto + recvfrom)
sudo strace -p "${KUBELET_PID}" \
  -e trace=connect,sendto,recvfrom,sendmsg,recvmsg \
  -f -s 500 -tt 2>&1 | tee /tmp/kubelet-strace.log &
STRACE_PID=$!

echo "Strace PID: ${STRACE_PID}"
echo "Strace running — deploy pod in Terminal 2"
```

> strace attach to kubelet, trace network-related syscalls. `-f` = follow child processes. `-s 500` = capture 500 bytes of data. `-tt` = microsecond timestamps.

## Bước 2: Deploy pod (trên master)

```bash
# Terminal 2 — deploy pod
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: strace-demo
  labels:
    app: strace-demo
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
EOF
```

```bash
# Wait for pod ready
kubectl wait --for=condition=Ready pod strace-demo --timeout=60s

# Verify pod on worker-1
kubectl get pod strace-demo -o wide
# NAME          READY   STATUS    NODE
# strace-demo   1/1     Running   worker-1
```

## Bước 3: Analyze strace — find CRI socket connect

```bash
# Terminal 1 — stop strace
sudo kill "${STRACE_PID}" 2>/dev/null
wait "${STRACE_PID}" 2>/dev/null

# Find connect to containerd socket
grep "containerd.sock" /tmp/kubelet-strace.log | head -5
# 00:00:01.123456 connect(123, {sa_family=AF_UNIX, sun_path="/run/containerd/containerd.sock"}, 48) = 0
# 00:00:01.123567 connect(124, {sa_family=AF_UNIX, sun_path="/run/containerd/containerd.sock"}, 48) = 0
```

> `connect()` to `/run/containerd/containerd.sock` = kubelet connect to CRI socket (Unix socket, `AF_UNIX`). Multiple connections = multiple gRPC calls.

**Kiểm tra**: strace shows `connect()` to `/run/containerd/containerd.sock`.

## Bước 4: Find gRPC calls — sendmsg/recvmsg

```bash
# Find gRPC calls (sendmsg = request, recvmsg = response)
grep -E "(sendmsg|recvmsg)" /tmp/kubelet-strace.log | head -20
# 00:00:01.123567 sendmsg(123, {msg_name=NULL, msg_iov=[{iov_base="\0\0\0\4\0\0\0\0\x0a...", iov_len=100}], ...}, 0) = 100
# 00:00:01.123678 recvmsg(123, {msg_name=NULL, msg_iov=[{iov_base="\0\0\0\x1c\0\0\0\x01\x12...", iov_len=200}], ...}, 0) = 200
# 00:00:01.234567 sendmsg(123, {msg_name=NULL, msg_iov=[{iov_base="\0\0\0\4\0\0\0\0\x0a...", iov_len=150}], ...}, 0) = 150
# 00:00:01.234678 recvmsg(123, {msg_name=NULL, msg_iov=[{iov_base="\0\0\0\x20\0\0\0\x01\x12...", iov_len=300}], ...}, 0) = 300
```

> gRPC = HTTP/2 over Unix socket. `sendmsg` = kubelet send gRPC request. `recvmsg` = containerd send gRPC response. Binary data (protobuf encoded) — not human-readable.

**Kiểm tra**: `sendmsg`/`recvmsg` pairs = gRPC request/response to containerd.

## Bước 5: Count CRI calls during pod creation

```bash
# Count sendmsg calls to containerd socket
echo "=== CRI gRPC calls during pod creation ==="
echo "sendmsg (requests): $(grep -c 'sendmsg' /tmp/kubelet-strace.log)"
echo "recvmsg (responses): $(grep -c 'recvmsg' /tmp/kubelet-strace.log)"
echo "connect (new connections): $(grep -c 'connect.*containerd' /tmp/kubelet-strace.log)"

# Example output:
# sendmsg (requests): 15
# recvmsg (responses): 15
# connect (new connections): 3
```

> Pod creation = ~15 gRPC calls: RunPodSandbox, PullImage, CreateContainer, StartContainer, ContainerStatus (multiple). 3 new connections = gRPC stream multiplexing.

## Bước 6: Correlate with kubelet log

```bash
# Kubelet log — CRI calls
sudo journalctl -u kubelet --no-pager -n 50 | grep -iE "(RunPodSandbox|PullImage|CreateContainer|StartContainer|ContainerStatus)" | head -15
# 00:00:01 "RunPodSandbox" pod="default/strace-demo"
# 00:00:01 "PullImage" image="nginx:1.25"
# 00:00:03 "CreateContainer" container="nginx"
# 00:00:03 "StartContainer" containerID="abc123"
# 00:00:03 "ContainerStatus" containerID="abc123"
```

> Kubelet log shows CRI method names. Correlate timestamps with strace `sendmsg` — each `sendmsg` = one CRI gRPC call (RunPodSandbox, PullImage, etc.).

**Kiểm tra**: Kubelet log shows CRI method names matching strace gRPC calls.

## Bước 7: Strace with grpcurl (advanced)

```bash
# Install grpcurl if available
if ! command -v grpcurl &>/dev/null; then
  echo "grpcurl not installed — skipping"
  echo "Install: go install github.com/fullstorydev/grpcurl/cmd/grpcurl@latest"
else
  # List CRI gRPC services
  sudo grpcurl -plaintext -unix /run/containerd/containerd.sock list
  # grpc.health.v1.Health
  # runtime.v1.ImageService
  # runtime.v1.RuntimeService

  # List RuntimeService methods
  sudo grpcurl -plaintext -unix /run/containerd/containerd.sock list runtime.v1.RuntimeService
  # runtime.v1.RuntimeService.Version
  # runtime.v1.RuntimeService.RunPodSandbox
  # runtime.v1.RuntimeService.StopPodSandbox
  # runtime.v1.RuntimeService.CreateContainer
  # runtime.v1.RuntimeService.StartContainer
  # ...

  # Call Version
  sudo grpcurl -plaintext -unix /run/containerd/containerd.sock \
    runtime.v1.RuntimeService.Version
  # {
  #   "version": "1.7.0",
  #   "runtimeName": "containerd",
  #   "runtimeApiVersion": "v1"
  # }
fi
```

> `grpcurl` = gRPC CLI. List CRI services/methods, call directly. Verify CRI gRPC interface — same interface kubelet uses.

## Bước 8: Strace containerd — runc calls

```bash
# Find containerd PID
CONTAINERD_PID=$(pgrep -x containerd)
echo "Containerd PID: ${CONTAINERD_PID}"

# Strace containerd — find runc exec
sudo strace -p "${CONTAINERD_PID}" \
  -e trace=execve,clone \
  -f -s 200 -tt 2>&1 | grep -E "(runc|exec)" | head -10 &
CONTAINERD_STRACE_PID=$!

# Deploy another pod (trên master)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: strace-runc
spec:
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sleep", "3600"]
EOF

kubectl wait --for=condition=Ready pod strace-runc --timeout=60s

# Stop strace
sudo kill "${CONTAINERD_STRACE_PID}" 2>/dev/null
wait "${CONTAINERD_STRACE_PID}" 2>/dev/null
```

Strace output:
```
00:00:05.123456 execve("/usr/local/bin/runc", ["runc", "--root", "/run/containerd/runc/k8s.io", "create", "abc123"], ...) = 0
00:00:05.234567 execve("/usr/local/bin/runc", ["runc", "--root", "/run/containerd/runc/k8s.io", "start", "abc123"], ...) = 0
```

> Containerd calls `runc create` then `runc start` — OCI runtime. Containerd → runc = execve (spawn process). runc creates namespace + cgroup, starts container process.

**Kiểm tra**: strace shows `execve("runc", [..., "create", ...])` and `execve("runc", [..., "start", ...])`.

## Bước 9: Full CRI flow summary

```
Kubelet (strace: sendmsg to containerd.sock)
  │
  ├── RunPodSandbox (gRPC)
  │     └── containerd: clone → runc create pause → runc start pause
  │
  ├── PullImage (gRPC)
  │     └── containerd: download layers → extract to overlayfs
  │
  ├── CreateContainer (gRPC)
  │     └── containerd: execve runc create (namespace + cgroup + rootfs)
  │
  ├── StartContainer (gRPC)
  │     └── containerd: execve runc start (start container process)
  │
  └── ContainerStatus (gRPC)
        └── containerd: return state (RUNNING)
```

## Cleanup

```bash
# (trên master)
kubectl delete pod strace-demo strace-runc

# (trên worker-1)
rm -f /tmp/kubelet-strace.log
```

## Câu hỏi tự kiểm tra

1. Strace kubelet — tìm syscall nào để thấy CRI gRPC call? Connect đến socket nào?
2. `sendmsg` và `recvmsg` trong strace — cái nào là request, cái nào là response?
3. Containerd gọi gì để tạo container? `runc create` hay `runc start`? Khác nhau thế nào?
4. Pod creation cần bao nhiêu gRPC call? Liệt kê các CRI method.
5. Tại sao gRPC data trong strace không đọc được (binary)?

## Đáp án tham khảo

1. `connect()` với `sa_family=AF_UNIX, sun_path="/run/containerd/containerd.sock"` = kubelet connect CRI socket. `sendmsg`/`recvmsg` = gRPC request/response. `sendto`/`recvfrom` cho non-MSG more. Socket = Unix socket (local, không TCP).
2. `sendmsg` = **request** (kubelet send gRPC request to containerd). `recvmsg` = **response** (containerd send gRPC response to kubelet). Mỗi `sendmsg` + `recvmsg` pair = 1 gRPC call.
3. Cả 2: `runc create` = tạo container (namespace, cgroup, rootfs mount — container ở trạng thái created, chưa chạy). `runc start` = start container process (exec container entrypoint — container running). Containerd gọi `runc create` trước, `runc start` sau.
4. ~5-15 gRPC calls: `RunPodSandbox` (create sandbox), `PullImage` (if not cached), `CreateContainer` (per container), `StartContainer` (per container), `ContainerStatus` (update status, multiple times). Pod 1 container = ~5 calls. Pod 2 container = ~8 calls.
5. gRPC = HTTP/2 + **protobuf** (binary encoding). Protobuf = binary format (không text như JSON). `sendmsg` data = protobuf encoded message — không human-readable. Dùng `grpcurl` hoặc `protoc --decode_raw` để decode.
