# 06 — systemd

## systemd là gì

systemd là init system (PID 1) của hầu hết Linux distro hiện đại. Nó quản lý:
- **Service** — start/stop/restart daemon.
- **Dependency** — start service A sau khi network ready.
- **Resource** — cgroup integration (limit CPU/memory per service).
- **Logging** — journald (structured logging, query bằng `journalctl`).

## Unit file

Mỗi service/resource được quản lý bởi một **unit file** nằm trong:
- `/etc/systemd/system/` — admin custom (override).
- `/usr/lib/systemd/system/` — package installed.

### Service unit file — ví dụ

```ini
[Unit]
Description=My Python Service
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/myapp/app.py
ExecStop=/bin/kill -TERM $MAINPID
Restart=on-failure
RestartSec=5
User=appuser
Group=appuser

# Resource limit (cgroup integration)
CPUQuota=50%
MemoryMax=200M

# Environment
Environment=APP_ENV=production
EnvironmentFile=/etc/myapp/env

# Working directory
WorkingDirectory=/opt/myapp

[Install]
WantedBy=multi-user.target
```

### Giải thích từng phần

| Phần | Ý nghĩa |
|------|---------|
| `[Unit]` | Metadata + dependency |
| `Description` | Mô tả human-readable |
| `After=` | Start sau unit này (không phải đợi xong — chỉ thứ tự start) |
| `Wants=` | Dependency mềm — nếu fail thì vẫn start |
| `Requires=` | Dependency cứng — nếu fail thì cũng fail |
| `[Service]` | Cấu hình service |
| `Type=` | `simple` (foreground), `forking` (daemon fork), `oneshot` (chạy 1 lần), `notify` (SD notification) |
| `ExecStart=` | Lệnh start |
| `ExecStop=` | Lệnh stop (mặc định: SIGTERM) |
| `Restart=` | `no`, `on-failure`, `always`, `on-abnormal` |
| `RestartSec=` | Chờ bao lâu trước khi restart |
| `CPUQuota=` | cgroup CPU limit (50% = nửa core) |
| `MemoryMax=` | cgroup memory limit |
| `[Install]` | Cấu hình enable |
| `WantedBy=` | Target nào enable service này (multi-user = runlevel 3) |

### Các loại unit khác

| Type | File extension | Ví dụ |
|------|---------------|-------|
| Service | `.service` | nginx.service, kubelet.service |
| Timer | `.timer` | Cron replacement — chạy định kỳ |
| Socket | `.socket` | Socket activation |
| Target | `.target` | Group of units (multi-user.target) |
| Mount | `.mount` | Filesystem mount |

## systemctl — quản lý service

```bash
# Start / stop / restart
sudo systemctl start myapp
sudo systemctl stop myapp
sudo systemctl restart myapp

# Enable / disable (start khi boot)
sudo systemctl enable myapp
sudo systemctl disable myapp

# Xem status
systemctl status myapp

# Xem tất cả service
systemctl list-units --type=service
systemctl list-units --type=service --state=running
systemctl list-unit-files --type=service    # tất cả, kể cả chưa enable

# Reload systemd sau khi sửa unit file
sudo systemctl daemon-reload
```

## journalctl — xem log

```bash
# Log của service
journalctl -u myapp

# Follow log (như tail -f)
journalctl -u myapp -f

# Log từ boot hiện tại
journalctl -b

# Log từ boot trước
journalctl -b -1

# Log theo thời gian
journalctl --since "2026-01-15 10:00" --until "2026-01-15 12:00"
journalctl --since "1 hour ago"

# Log theo priority
journalctl -p err              # chỉ error trở lên
journalctl -p warning

# Log theo PID
journalctl _PID=1234

# JSON format
journalctl -u myapp -o json
```

## systemd-analyze

```bash
# Thời gian boot
systemd-analyze time

# Boot breakdown per unit
systemd-analyze blame

# Critical chain — cái gì chậm nhất
systemd-analyze critical-chain

# Verify unit file syntax
systemd-analyze verify /etc/systemd/system/myapp.service
```

## systemd cgroup integration

systemd tạo cgroup cho mỗi service tự động:

```bash
# Xem cgroup của service
systemctl status myapp
# └─ cgroup: /system.slice/myapp.service
#   ├─ 1234 /usr/bin/python3 /opt/myapp/app.py

# Xem cgroup limit
cat /sys/fs/cgroup/system.slice/myapp.service/cpu.max
cat /sys/fs/cgroup/system.slice/myapp.service/memory.max

# systemd quản lý cgroup lifecycle:
# - Start service → tạo cgroup, gán process
# - Stop service → kill process, xóa cgroup
# - Restart → tạo cgroup mới
```

### Kubernetes + systemd cgroup driver

Kubelet cần `--cgroup-driver=systemd` (mặc định trên distro hiện đại) để:
- systemd quản lý cgroup cho kubelet + container.
- Kubelet đọc cgroup stats từ systemd hierarchy.
- Container runtime (containerd) cũng phải dùng systemd cgroup driver.

```toml
# /etc/containerd/config.toml
[plugins."io.containerd.grpc.v1.cri".cgroup]
  systemd_cgroup = true
```

## Liên hệ với Kubernetes

### Kubelet chạy as systemd service

```bash
# Xem kubelet unit file
cat /etc/systemd/system/kubelet.service
# hoặc
cat /usr/lib/systemd/system/kubelet.service

# Typical kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
After=network.target

[Service]
ExecStart=/usr/bin/kubelet --config=/etc/kubernetes/kubelet.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Control plane chạy as static pod HOẶC systemd service

- **kubeadm** → static pod (kubelet quản lý).
- **Làm bằng tay** → systemd service (admin quản lý).

### Debug kubelet qua systemd

```bash
# Xem kubelet status
systemctl status kubelet

# Xem kubelet log
journalctl -u kubelet -f

# Restart kubelet
sudo systemctl restart kubelet

# Debug kubelet không start
journalctl -u kubelet --since "5 min ago" -p err
```
