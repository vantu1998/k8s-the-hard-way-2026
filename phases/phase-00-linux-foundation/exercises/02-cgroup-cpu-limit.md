# Exercise 02 — Tạo cgroup v2, giới hạn CPU, quan sát throttling

> **Mục tiêu**: Hiểu cgroups v2 bằng tay — tạo cgroup, giới hạn CPU, quan sát throttling.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Linux VM với cgroups v2, root access

## Bối cảnh

Kubernetes dùng cgroup để giới hạn CPU/memory của container. Bài này mô phỏng `resources.limits.cpu` bằng tay — hiểu chính xác kernel throttling hoạt động thế nào.

## Bước 1: Kiểm tra cgroups v2

```bash
mount | grep cgroup
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)

cat /sys/fs/cgroup/cgroup.controllers
# cpuset cpu io memory hugetlb pids rdma misc
```

**Kiểm tra**: Thấy `cgroup2` mount và danh sách controller có `cpu`, `memory`.

## Bước 2: Tạo sub-cgroup

```bash
sudo mkdir /sys/fs/cgroup/lab

# Enable cpu controller cho sub-cgroup
echo "+cpu" | sudo tee /sys/fs/cgroup/cgroup.subtree_control

# Kiểm tra
cat /sys/fs/cgroup/lab/cgroup.controllers
# cpu
```

**Kiểm tra**: `lab` cgroup có `cpu` controller enabled.

## Bước 3: Giới hạn CPU 50%

```bash
# Format: "$MAX $PERIOD" (microseconds)
# 50000 100000 = 50ms / 100ms = 50% của 1 core
echo "50000 100000" | sudo tee /sys/fs/cgroup/lab/cpu.max

# Kiểm tra
cat /sys/fs/cgroup/lab/cpu.max
# 50000 100000
```

**Kiểm tra**: `cpu.max` = `50000 100000`.

## Bước 4: Chạy CPU hog KHÔNG cgroup — baseline

```bash
# Chạy dd ăn 100% CPU, không cgroup
dd if=/dev/zero of=/dev/null &
DD_PID=$!

# Quan sát — 100% CPU
top -p $DD_PID -b -n 3
# %CPU = 100.0

# Kill
kill $DD_PID
```

**Kiểm tra**: `%CPU` = ~100%.

## Bước 5: Chạy CPU hog TRONG cgroup — throttled

```bash
# Chạy dd trong cgroup lab
echo $$ | sudo tee /sys/fs/cgroup/lab/cgroup.procs

dd if=/dev/zero of=/dev/null &
DD_PID=$!

# Quan sát — chỉ 50% CPU
top -p $DD_PID -b -n 5
# %CPU = ~50.0

# Xem throttling stats
cat /sys/fs/cgroup/lab/cpu.stat
# usage_usec 5000000
# user_usec 4800000
# system_usec 200000
# nr_periods 50
# nr_throttled 25       ← bị throttle 25/50 period
# throttled_usec 2500000 ← tổng thời gian bị pause
```

**Kiểm tra**: `%CPU` = ~50%, `nr_throttled` > 0.

## Bước 6: Thay đổi limit → 25%

```bash
kill $DD_PID

echo "25000 100000" | sudo tee /sys/fs/cgroup/lab/cpu.max

dd if=/dev/zero of=/dev/null &
DD_PID=$!

top -p $DD_PID -b -n 3
# %CPU = ~25.0

kill $DD_PID
```

**Kiểm tra**: `%CPU` giảm xuống ~25%.

## Bước 7: Giới hạn memory + OOM kill

```bash
# Enable memory controller
echo "+memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control

# Giới hạn 50MB
echo "52428800" | sudo tee /sys/fs/cgroup/lab/memory.max

# Chạy script ăn memory
python3 -c "
data = []
while True:
    data.append(b'x' * 1024 * 1024)
    print(f'Allocated {len(data)}MB')
" &

# Đợi vài giây → process bị OOM killed
# Xem log
dmesg | grep -i "oom\|killed" | tail -5

# Xem memory events
cat /sys/fs/cgroup/lab/memory.events
# oom 1
# oom_kill 1
```

**Kiểm tra**: Process bị kill khi vượt 50MB, `memory.events` hiện `oom_kill 1`.

## Cleanup

```bash
# Xóa process khỏi cgroup (chuyển về root cgroup)
echo $$ | sudo tee /sys/fs/cgroup/cgroup.procs

# Xóa cgroup (phải rỗng — không có process)
sudo rmdir /sys/fs/cgroup/lab
```

## Câu hỏi tự kiểm tra

1. `cpu.max` format `50000 100000` nghĩa là gì? Đổi ra % CPU?
2. `nr_throttled` > 0 nghĩa là gì? Container bị throttle ảnh hưởng gì?
3. Nếu node có 4 core, `cpu.max = 200000 100000` = bao nhiêu % CPU?
4. Tại sao OOM kill thay vì chỉ "đợi" khi memory vượt limit?
5. `resources.limits.cpu: 500m` trong Kubernetes = `cpu.max` gì?

## Đáp án tham khảo

1. 50ms / 100ms = 50% của 1 core.
2. Process bị kernel tạm dừng (throttle) trong phần còn lại của period → latency spike.
3. 200000/100000 = 2 cores = 200% = 2 full cores.
4. Kernel không thể "đợi" — memory đã vượt, không có cách nào thu hồi trừ khi kill process.
5. `500m` = 500 millicores = 0.5 core → `cpu.max = 50000 100000`.
