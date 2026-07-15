# 03 — cgroups v2

## cgroup là gì

cgroup (control group) là cơ chế **giới hạn và theo dõi tài nguyên** cho nhóm process. Trong khi namespace cách ly "thấy gì", cgroup giới hạn "dùng bao nhiêu".

**Container = namespaces (isolation) + cgroups (limit resource)**

Không có cgroup → container ăn hết CPU/RAM của node → các container khác bị ảnh hưởng.

## cgroups v1 vs v2

| | cgroups v1 | cgroups v2 |
|---|-----------|-----------|
| Cấu trúc | Mỗi controller 1 hierarchy riêng | **Unified hierarchy** — tất cả controller trong 1 tree |
| Path | `/sys/fs/cgroup/cpu/`, `/sys/fs/cgroup/memory/` riêng | `/sys/fs/cgroup/` chung |
| Process gán | Gán process vào mỗi controller riêng | Gán process 1 lần, tất cả controller áp dụng |
| Mount | Nhiều mount point | 1 mount point |
| Kubernetes | Hỗ trợ từ lâu | Hỗ trợ từ K8s 1.25 (GA) |

Kiểm tra version:

```bash
# Kiểm tra cgroups v2
mount | grep cgroup
# Nếu chỉ thấy: cgroup2 on /sys/fs/cgroup type cgroup2 → đang dùng v2

# Hoặc:
cat /sys/fs/cgroup/cgroup.controllers
# Output: cpuset cpu io memory hugetlb pids rdma misc
```

## Cấu trúc cgroups v2

```
/sys/fs/cgroup/
├── cgroup.controllers          # Controller có sẵn (cpu, memory, io, pids...)
├── cgroup.subtree_control      # Controller enabled cho children
├── cpu.max                     # Limit CPU cho cgroup root
├── memory.max                  # Limit memory cho cgroup root
├── cgroup.procs                # PID của process trong cgroup này
├── myapp/                      # Sub-cgroup tự tạo
│   ├── cgroup.procs
│   ├── cpu.max
│   ├── memory.max
│   └── ...
```

## Tạo cgroup và giới hạn tài nguyên

### CPU limit

```bash
# Tạo sub-cgroup
sudo mkdir /sys/fs/cgroup/myapp

# Enable controller cho sub-cgroup
echo "+cpu +memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control

# Giới hạn CPU: 1 core = 100000 microsecond / 100000 period
# Format: "$MAX $PERIOD"
# 50000 100000 = 50% của 1 core
echo "50000 100000" | sudo tee /sys/fs/cgroup/myapp/cpu.max

# Chạy process trong cgroup này
echo $$ | sudo tee /sys/fs/cgroup/myapp/cgroup.procs

# Chạy CPU hog để test
dd if=/dev/zero of=/dev/null &

# Quan sát: top sẽ thấy dd chỉ dùng ~50% CPU
top -p $!
```

### Memory limit

```bash
# Giới hạn memory: 100MB
echo "104857600" | sudo tee /sys/fs/cgroup/myapp/memory.max

# Test: cố ăn hết memory
python3 -c "
data = []
while True:
    data.append(b'x' * 1024 * 1024)  # 1MB mỗi lần
"

# Process sẽ bị OOM killed khi vượt 100MB
# Xem log: dmesg | grep -i oom
```

### PIDs limit

```bash
# Giới hạn số process: 10
echo "10" | sudo tee /sys/fs/cgroup/myapp/pids.max

# Test: fork bomb sẽ fail
:(){ :|:& };:
# fork: retry: Resource temporarily unavailable
```

## Cgroup event: OOM kill

```bash
# Xem memory hiện tại của cgroup
cat /sys/fs/cgroup/myapp/memory.current

# Xem memory events (oom, oom_kill)
cat /sys/fs/cgroup/myapp/memory.events
# Output:
# low 0
# high 0
# max 0
# oom 1          ← đã trigger OOM 1 lần
# oom_kill 1     ← đã kill 1 process
```

## Cách Kubernetes dùng cgroup

### Kubelet quản lý cgroup

Kubelet tạo cgroup hierarchy cho pod và container:

```
/sys/fs/cgroup/
└── kubepods.slice/
    ├── pod<uid>.slice/
    │   ├── cpu.max          # Pod-level CPU limit (sum của container)
    │   ├── memory.max       # Pod-level memory limit
    │   └── <container-id>/
    │       ├── cpu.max      # Container-level CPU limit
    │       └── memory.max   # Container-level memory limit
```

### Resource requests vs limits

| YAML field | cgroup setting | Ý nghĩa |
|-----------|---------------|---------|
| `resources.requests.cpu` | `cpu.weight` | Relative weight, **không guarantee** cgroup |
| `resources.limits.cpu` | `cpu.max` | Hard limit — container không vượt quá |
| `resources.requests.memory` | — (scheduling) | Dùng cho scheduler chọn node |
| `resources.limits.memory` | `memory.max` | Hard limit — vượt → OOM killed |

### CPU throttling

Khi container vượt `cpu.max`, kernel **throttle** (tạm dừng) process cho đến khi period tiếp theo:

```bash
# Xem CPU throttling stats
cat /sys/fs/cgroup/kubepods.slice/pod<uid>.slice/<container>/cpu.stat
# Output:
# usage_usec 5000000
# user_usec 4800000
# system_usec 200000
# nr_periods 100
# nr_throttled 30       ← bị throttle 30 lần
# throttled_usec 500000 ← tổng thời gian bị throttle
```

CPU throttling là nguyên nhân phổ biến của **latency spike** trong Kubernetes — pod bị pause rồi resume, gây response time cao.

### Memory OOM

Khi container vượt `memory.max`:
1. Kernel OOM killer chọn process trong cgroup để kill.
2. Container chết, kubelet restart (tùy restartPolicy).
3. Xem `dmesg | grep -i oom` hoặc `kubectl describe pod` → `OOMKilled`.

## systemd cgroup integration

Trên systemd system, kubelet dùng **systemd cgroup driver** — cgroup được quản lý qua systemd unit thay vì tạo thư mục thủ công:

```bash
# Xem cgroup của một service
systemctl status <service>
# └─ cgroup: /system.slice/<service>.service

# systemd tạo cgroup tự động khi start service
# Giới hạn qua unit file:
# [Service]
# CPUQuota=50%
# MemoryMax=100M
```

Kubelet config: `--cgroup-driver=systemd` (mặc định trên hầu hết distro hiện nay).
