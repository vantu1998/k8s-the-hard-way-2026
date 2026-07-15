# Exercise 05 — Kill containerd-shim, quan sát container

> **Mục tiêu**: Hiểu vai trò containerd-shim — kill shim, xem container bị ảnh hưởng thế nào.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Linux VM, containerd, `ctr`, đã làm Exercise 02

## Bối cảnh

containerd-shim là parent process của container. Bài này kill shim để hiểu: shim làm gì, container bị gì khi shim chết, containerd có tự khôi phục không.

## Bước 1: Tạo container

```bash
# Pull + run
sudo ctr images pull docker.io/library/nginx:1.25
sudo ctr run -d docker.io/library/nginx:1.25 shim-test

# Kiểm tra
sudo ctr tasks list
# TASK        PID     STATUS
# shim-test   12345   RUNNING
```

**Kiểm tra**: Container `shim-test` running.

## Bước 2: Xem process tree

```bash
# Xem containerd + shim + container
ps auxf | grep -E "containerd|nginx" | grep -v grep
# root  1000  containerd
# root  1234   └─ containerd-shim-runc-v2 -namespace default -id shim-test
# root  12345      └─ nginx: master process
# root  12346          └─ nginx: worker process

# Shim (PID 1234) là parent của nginx (PID 12345)
# containerd (PID 1000) là parent của shim
```

**Kiểm tra**: Thấy process tree: containerd → shim → nginx.

## Bước 3: Xem shim detail

```bash
# Tìm shim PID
SHIM_PID=$(pgrep -f "containerd-shim.*shim-test")
echo $SHIM_PID
# 1234

# Xem shim process
ps -p $SHIM_PID -o pid,ppid,cmd
# PID   PPID  CMD
# 1234  1000  containerd-shim-runc-v2 -namespace default -id shim-test ...
```

**Kiểm tra**: Shim PID xác định được.

## Bước 4: Kill shim — SIGKILL

```bash
# Kill shim
sudo kill -9 $SHIM_PID

# Đợi 2 giây
sleep 2

# Kiểm tra container process — vẫn chạy?
ps aux | grep "nginx" | grep -v grep
# root  12345  nginx: master process    ← vẫn chạy!
# root  12346  nginx: worker process    ← vẫn chạy!

# Container process vẫn chạy — shim chết nhưng container không chết
# (shim chỉ là parent, không phải container process)
```

**Kiểm tra**: nginx process vẫn chạy sau khi shim bị kill.

## Bước 5: Kiểm tra containerd có biết shim chết không

```bash
# ctr tasks list
sudo ctr tasks list
# TASK        PID     STATUS
# shim-test   12345   RUNNING    ← vẫn báo running!

# containerd chưa phát hiện shim đã chết
# (shim chết = containerd mất connection, nhưng container process vẫn chạy)
```

**Kiểm tra**: `ctr tasks list` vẫn báo `RUNNING`.

## Bước 6: Thử stop container qua ctr

```bash
# Thử stop — containerd gọi shim, nhưng shim đã chết
sudo ctr tasks kill shim-test
# (có thể lỗi hoặc timeout — shim không còn để forward signal)

# Container process vẫn chạy
ps aux | grep nginx | grep -v grep
# (vẫn thấy nginx)
```

**Kiểm tra**: `ctr tasks kill` không tác dụng được (shim chết, không ai forward signal).

## Bước 7: Dọn bằng tay

```bash
# Kill container process trực tiếp
sudo kill -9 12345   # nginx master
sleep 1

# Kiểm tra
ps aux | grep nginx | grep -v grep
# (nginx đã chết)

# Containerd vẫn nghĩ container running — cần cleanup
sudo ctr tasks delete shim-test
sudo ctr containers delete shim-test
```

**Kiểm tra**: Container process đã chết, containerd cleanup xong.

## Bước 8: Thử lại — kill shim + container cùng lúc

```bash
# Tạo container mới
sudo ctr run -d docker.io/library/nginx:1.25 shim-test2

# Lấy cả shim PID + container PID
SHIM_PID=$(pgrep -f "containerd-shim.*shim-test2")
CONTAINER_PID=$(sudo ctr tasks list | grep shim-test2 | awk '{print $2}')
echo "Shim PID: $SHIM_PID, Container PID: $CONTAINER_PID"

# Kill shim trước
sudo kill -9 $SHIM_PID
sleep 1

# Kill container
sudo kill -9 $CONTAINER_PID
sleep 1

# Kiểm tra
ps aux | grep -E "shim-test2|nginx" | grep -v grep
# (empty — cả shim và container đã chết)

# Containerd cleanup
sudo ctr tasks delete shim-test2 2>/dev/null || true
sudo ctr containers delete shim-test2 2>/dev/null || true
```

**Kiểm tra**: Cả shim và container đã chết.

## Bước 9: Quan sát với container do CRI tạo

```bash
# Tạo pod qua crictl (giống exercise 03)
crictl pull registry.k8s.io/pause:3.9
crictl pull docker.io/library/nginx:1.25

cat > /tmp/pod.json << 'EOF'
{"metadata": {"name": "shim-test-pod", "namespace": "default", "attempt": 1, "uid": "test"}, "logDirectory": "/tmp/pod-logs", "linux": {}}
EOF

POD_ID=$(crictl runp /tmp/pod.json)

cat > /tmp/ctr.json << 'EOF'
{"metadata": {"name": "nginx"}, "image": {"image": "docker.io/library/nginx:1.25"}, "command": ["nginx", "-g", "daemon off;"], "log_path": "nginx.log", "linux": {}}
EOF

CONTAINER_ID=$(crictl create $POD_ID /tmp/ctr.json /tmp/pod.json)
crictl start $CONTAINER_ID

# Tìm shim
ps auxf | grep "containerd-shim" | grep -v grep
# Có thể có 2 shim: 1 cho pause, 1 cho nginx

# Kill shim của nginx container
NGINX_PID=$(crictl inspect $CONTAINER_ID | jq -r .info.pid)
SHIM_PID=$(pgrep -f "containerd-shim" | while read p; do
  if grep -q "$(cat /proc/$p/cmdline | tr '\0' ' ' | grep -o 'id=[^ ]*')" <<< "$(cat /proc/$p/cmdline 2>/dev/null)"; then
    PPID_CHECK=$(ps -o ppid= -p $NGINX_PID 2>/dev/null | tr -d ' ')
    if [ "$PPID_CHECK" = "$p" ]; then echo $p; fi
  fi
done)

# Hoặc đơn giản hơn: tìm shim có parent = container PID
cat /proc/$NGINX_PID/status | grep PPid
# PPid: <shim_pid>

SHIM_PID=$(cat /proc/$NGINX_PID/status | grep PPid | awk '{print $2}')
echo "Shim PID: $SHIM_PID, Container PID: $NGINX_PID"

# Kill shim
sudo kill -9 $SHIM_PID
sleep 2

# Container vẫn chạy?
ps -p $NGINX_PID -o pid,cmd
# (container vẫn chạy — shim chết nhưng container không chết)

# crictl vẫn báo running
crictl ps
# (vẫn Running)

# Kubelet sẽ phát hiện khi poll ContainerStatus — shim chết → CRI trả về error
# Kubelet sẽ restart container (tùy restartPolicy)
```

**Kiểm tra**: Container vẫn chạy sau khi shim chết, crictl vẫn báo running.

## Cleanup

```bash
# Kill container trực tiếp
sudo kill -9 $NGINX_PID 2>/dev/null || true

# crictl cleanup
crictl stop $CONTAINER_ID 2>/dev/null || true
crictl rm $CONTAINER_ID 2>/dev/null || true
crictl stopp $POD_ID 2>/dev/null || true
crictl rmp $POD_ID 2>/dev/null || true

# Files
rm -f /tmp/pod.json /tmp/ctr.json
rm -rf /tmp/pod-logs
```

## Câu hỏi tự kiểm tra

1. Shim chết → container chết không? Tại sao?
2. Containerd phát hiện shim chết khi nào?
3. Nếu kubelet quản lý container và shim chết → kubelet làm gì?
4. Tại sao `ctr tasks kill` không hoạt động khi shim đã chết?
5. Shim tồn tại để làm gì (3 lý do chính)?

## Đáp án tham khảo

1. Không. Shim là parent process, không phải container process. Container (child) vẫn chạy. Shim chỉ quản lý, không chạy container.
2. Khi containerd gọi shim (poll status, stop, exec) → connection refused → phát hiện shim chết. Không có heartbeat tự động.
3. Kubelet poll `ContainerStatus` qua CRI → containerd gọi shim → fail → kubelet biết container "unknown" → restart (tùy restartPolicy).
4. Vì `ctr tasks kill` gửi signal qua shim (shim forward signal đến container). Shim chết = không ai forward.
5. (1) Tách container khỏi containerd daemon — containerd restart không kill container. (2) Reap zombie child. (3) Report exit status + forward stdio.
