# 01 — Process & Thread

## Process là gì

Process là một chương trình đang chạy. Mỗi process có:

- **PID** (Process ID) — số nguyên duy nhất.
- **PPID** (Parent Process ID) — PID của process cha.
- **Memory space** riêng — không chia sẻ với process khác.
- **File descriptor table** riêng.
- **Kernel stack** riêng.

Xem process tree:

```bash
ps auxf          # tree view
pstree -p        # tree với PID
cat /proc/<pid>/status   # chi tiết 1 process
```

## fork / exec / wait — 3 syscall cốt lõi

### fork()

Tạo process con bằng cách **copy** process hiện tại:

```
Parent PID=100
  ├── fork() → Child PID=101
  │             └── copy của parent (memory, fd, ...)
  └── tiếp tục chạy
```

- Child nhận PID mới, PPID = PID parent.
- Child inherit copy của memory (copy-on-write — chỉ copy thật khi ghi).
- Return value của `fork()`: > 0 cho parent (PID child), 0 cho child.

### exec()

Thay thế image hiện tại bằng chương trình mới — **không tạo process mới**, PID giữ nguyên:

```bash
# Shell chạy `ls`:
# 1. fork() → child shell
# 2. child gọi exec("ls") → image shell bị thay bằng ls
# 3. ls chạy, kết thúc, exit
# 4. parent (shell) wait() → nhận exit code
```

### wait()

Parent chờ child kết thúc, thu thập exit status:

```bash
# Nếu parent không wait() → child trở thành zombie
# Nếu parent chết trước child → child trở thành orphan (reparent cho PID 1)
```

## Zombie & Orphan Process

### Zombie (Defunct)

Child đã exit nhưng parent **chưa wait()** — kernel giữ PID + exit status cho parent đọc:

```bash
# Tạo zombie:
python3 -c "
import os, time
pid = os.fork()
if pid == 0:
    os._exit(42)       # child exit ngay
else:
    time.sleep(30)     # parent không wait → child là zombie trong 30s
"

# Trong terminal khác:
ps aux | grep defunct
# USER  PID  ...  Z    [python3] <defunct>
```

Kernel giữ zombie cho đến khi parent gọi `wait()` hoặc parent chết. Khi parent chết, zombie được reparent cho PID 1 (init), PID 1 tự động `wait()` → cleanup.

### Orphan

Parent chết trước child → child trở thành orphan, reparent cho PID 1 (systemd/init):

```bash
# Tạo orphan:
python3 -c "
import os, time
pid = os.fork()
if pid == 0:
    time.sleep(60)     # child sống 60s
    print('orphan done')
else:
    os._exit(0)        # parent chết ngay → child orphan
"

# Child vẫn chạy, PPID = 1
ps -o pid,ppid,cmd -p <child_pid>
# PID  PPID  CMD
# 123  1     python3 ...
```

## Signal — cách giao tiếp với process

Signal là thông báo async từ kernel hoặc process khác đến process của bạn.

| Signal | Số | Ý nghĩa | Có thể catch? |
|--------|-----|---------|---------------|
| `SIGTERM` | 15 | Yêu cầu terminate gracefully | Có |
| `SIGKILL` | 9 | Kill ngay lập tức | **Không** |
| `SIGINT` | 2 | Ctrl+C | Có |
| `SIGHUP` | 1 | Terminal đóng / reload config | Có |
| `SIGSTOP` | 19 | Dừng process (không kill) | **Không** |
| `SIGCONT` | 18 | Tiếp tục process đã stop | Có |
| `SIGCHLD` | 17 | Child thay đổi state (exit/stop) | Có |

### Quan trọng cho Kubernetes

- `kubectl delete pod` gửi **SIGTERM** → pod có `terminationGracePeriodSeconds` (mặc định 30s) để shutdown gracefully.
- Hết grace period → **SIGKILL** → process bị kill ngay.
- `preStop` hook chạy **trước** SIGTERM.
- Container runtime gửi SIGTERM đến PID 1 trong container.

### Thực hành signal

```bash
# SIGTERM — process có thể catch và cleanup
kill -15 <pid>     # hoặc: kill <pid> (mặc định SIGTERM)

# SIGKILL — không thể catch, kernel kill ngay
kill -9 <pid>

# Ctrl+C gửi SIGINT
# Ctrl+Z gửi SIGSTOP (suspend)
# bg/fg gửi SIGCONT
```

## Thread vs Process

| | Process | Thread |
|---|---------|--------|
| Memory | Riêng biệt | **Chia sẻ** với process |
| Tạo mới | `fork()` — đắt | `pthread_create()` — rẻ |
| Context switch | Chậm (TLB flush) | Nhanh (cùng address space) |
| Giao tiếp | IPC (pipe, socket, shm) | Shared memory trực tiếp |
| PID | Riêng | Cùng PID, khác TID |

Xem thread:

```bash
ps -eLf           # hiển thị tất cả thread (LWP)
cat /proc/<pid>/task/<tid>/status
```

## Liên hệ với Kubernetes

- Mỗi **container** = 1 process (hoặc nhóm process) trong namespace.
- PID 1 trong container = entrypoint command.
- PID 1 đặc biệt: nếu PID 1 chết → container chết.
- PID 1 cũng đặc biệt: kernel gửi signal không mặc định đến PID 1 (cần explicit handler).
- `tini` / `dumb-init` thường dùng làm PID 1 init process trong container để xử lý signal + reap zombie đúng cách.
