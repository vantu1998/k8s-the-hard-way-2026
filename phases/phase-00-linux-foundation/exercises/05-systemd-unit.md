# Exercise 05 — Viết systemd unit file cho script Python, enable & start

> **Mục tiêu**: Hiểu systemd đủ để quản lý service — viết unit file, enable, start, xem log, cấu hình restart.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Linux VM với systemd, root access, `python3`

## Bối cảnh

Kubelet chạy as systemd service. Control plane component (khi làm bằng tay) cũng chạy as systemd service. Bài này tập viết unit file, quản lý lifecycle, debug qua journalctl.

## Bước 1: Tạo script Python

```bash
sudo mkdir -p /opt/myapp
sudo tee /opt/myapp/app.py << 'EOF'
import os
import signal
import sys
import time

running = True

def handle_sigterm(signum, frame):
    global running
    print(f"Received signal {signum}, shutting down gracefully...", flush=True)
    running = False

signal.signal(signal.SIGTERM, handle_sigterm)
signal.signal(signal.SIGINT, handle_sigterm)

print(f"Starting app (PID={os.getpid()})", flush=True)
print(f"APP_ENV={os.environ.get('APP_ENV', 'not set')}", flush=True)

count = 0
while running:
    count += 1
    print(f"Heartbeat #{count}", flush=True)
    time.sleep(5)

print("App stopped.", flush=True)
sys.exit(0)
EOF

sudo chmod +x /opt/myapp/app.py
```

**Kiểm tra**: File `/opt/myapp/app.py` tồn tại, chạy được.

## Bước 2: Test script trước

```bash
python3 /opt/myapp/app.py
# Starting app (PID=1234)
# APP_ENV=not set
# Heartbeat #1
# Heartbeat #2
# ^C
# Received signal 2, shutting down gracefully...
# App stopped.
```

**Kiểm tra**: Script chạy, in heartbeat, Ctrl+C → graceful shutdown.

## Bước 3: Viết systemd unit file

```bash
sudo tee /etc/systemd/system/myapp.service << 'EOF'
[Unit]
Description=My Python Application
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/myapp/app.py
Restart=on-failure
RestartSec=3
User=root
WorkingDirectory=/opt/myapp
Environment=APP_ENV=production

# Resource limits (cgroup integration)
CPUQuota=10%
MemoryMax=50M

# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
```

**Kiểm tra**: File `/etc/systemd/system/myapp.service` tồn tại.

## Bước 4: Reload systemd + start service

```bash
# Reload systemd để nhận unit file mới
sudo systemctl daemon-reload

# Start service
sudo systemctl start myapp

# Kiểm tra status
sudo systemctl status myapp
# ● myapp.service - My Python Application
#      Loaded: loaded (/etc/systemd/system/myapp.service; disabled)
#      Active: active (running) since ... 10s ago
#    Main PID: 5678 (python3)
#       Tasks: 1 (limit: 4915)
#      Memory: 8.2M
#         CPU: 100ms
#      CGroup: /system.slice/myapp.service
#              └─5678 /usr/bin/python3 /opt/myapp/app.py
```

**Kiểm tra**: `Active: active (running)`, PID hiện.

## Bước 5: Xem log bằng journalctl

```bash
# Xem log
journalctl -u myapp --no-pager
# Starting app (PID=5678)
# APP_ENV=production
# Heartbeat #1
# Heartbeat #2

# Follow log
journalctl -u myapp -f
# Heartbeat #3
# Heartbeat #4
# (Ctrl+C để thoát)
```

**Kiểm tra**: Log hiện `APP_ENV=production` (environment từ unit file) + heartbeat.

## Bước 6: Test restart policy

```bash
# Kill process trực tiếp — systemd restart tự động
sudo kill -9 $(pgrep -f app.py)

# Kiểm tra — service tự restart
sudo systemctl status myapp
# Active: active (running) (auto-restart)
# Process: 5678 ExecStart=... (code=killed, signal=KILL)
# └─5679 /usr/bin/python3 /opt/myapp/app.py    ← PID mới

# Đợi 3s (RestartSec=3), service restart
journalctl -u myapp --since "1 min ago" --no-pager
# Heartbeat #1 (từ PID mới)
```

**Kiểm tra**: Service tự restart sau khi bị kill, PID mới.

## Bước 7: Test graceful shutdown

```bash
# Stop service — systemd gửi SIGTERM
sudo systemctl stop myapp

# Xem log — script nhận SIGTERM, shutdown gracefully
journalctl -u myapp --since "30 sec ago" --no-pager
# Received signal 15, shutting down gracefully...
# App stopped.

# Status
sudo systemctl status myapp
# Active: inactive (dead)
```

**Kiểm tra**: Log hiện "Received signal 15", "App stopped." — graceful shutdown.

## Bước 8: Enable service (start khi boot)

```bash
sudo systemctl enable myapp
# Created symlink /etc/systemd/system/multi-user.target.wants/myapp.service

# Kiểm tra
systemctl is-enabled myapp
# enabled

# Disable
sudo systemctl disable myapp
```

**Kiểm tra**: `is-enabled` trả về `enabled` sau khi enable.

## Bước 9: Xem cgroup resource limit

```bash
sudo systemctl start myapp

# Xem cgroup
cat /sys/fs/cgroup/system.slice/myapp.service/cpu.max
# 10000 100000    ← 10% CPU (CPUQuota=10%)

cat /sys/fs/cgroup/system.slice/myapp.service/memory.max
# 52428800       ← 50MB (MemoryMax=50M)

# Xem process trong cgroup
cat /sys/fs/cgroup/system.slice/myapp.service/cgroup.procs
# 5678
```

**Kiểm tra**: cgroup limit khớp với `CPUQuota` và `MemoryMax` trong unit file.

## Bước 10: Verify unit file syntax

```bash
systemd-analyze verify /etc/systemd/system/myapp.service
# (no output = OK, no errors)
```

**Kiểm tra**: Không có error output.

## Cleanup

```bash
sudo systemctl stop myapp
sudo systemctl disable myapp
sudo rm /etc/systemd/system/myapp.service
sudo systemctl daemon-reload
sudo rm -rf /opt/myapp
```

## Câu hỏi tự kiểm tra

1. `Type=simple` vs `Type=forking` — khác gì? Khi nào dùng cái nào?
2. `Restart=on-failure` vs `Restart=always` — khác gì?
3. Tại sao cần `daemon-reload` sau khi sửa unit file?
4. `systemctl stop` gửi signal gì? Làm sao đổi?
5. Nếu script không handle SIGTERM → `systemctl stop`会发生什么?

## Đáp án tham khảo

1. `simple` = process chạy foreground (systemd biết service started khi ExecStart chạy). `forking` = process fork và parent exit (daemon truyền thống, systemd biết started khi parent exit).
2. `on-failure` = restart khi exit code ≠ 0 hoặc bị kill. `always` = restart luôn, kể cả exit 0.
3. systemd cache unit file trong memory. `daemon-reload` đọc lại từ disk.
4. `SIGTERM` (mặc định). Đổi bằng `KillSignal=SIGINT` trong unit file. Hết `TimeoutStopSec` (mặc định 90s) → `SIGKILL`.
5. Script bị kill bằng SIGTERM (mặc định kernel action = terminate). Không graceful shutdown. Hết timeout → SIGKILL.
