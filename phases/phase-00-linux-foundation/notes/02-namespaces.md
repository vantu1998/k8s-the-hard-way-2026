# 02 — Linux Namespaces

## Namespace là gì

Namespace là cơ chế **cách ly (isolation)** tài nguyên kernel — khiến process bên trong namespace thấy một "bản sao riêng" của tài nguyên đó.

**Container = namespaces (isolation) + cgroups (limit resource) + overlayfs (filesystem layer)**

Không có namespace → container không thể cách ly. Không có cgroup → container ăn hết CPU/RAM.

## 7 loại namespace

| Namespace | Cách ly gì | Flag `unshare` | Liên hệ K8s |
|-----------|-----------|----------------|-------------|
| **PID** | Process ID — process bên trong thấy PID từ 1 | `--pid` | Container thấy mình là PID 1 |
| **NET** | Network stack — interface, IP, route, port | `--net` | Pod có IP riêng, riêng iptables |
| **MNT** | Mount point — filesystem view | `--mount` | Container có rootfs riêng |
| **IPC** | Inter-process communication — shared memory, semaphore | `--ipc` | Cách ly IPC giữa container |
| **UTS** | Hostname, domain name | `--uts` | Container có hostname riêng |
| **USER** | UID/GID mapping — UID 0 trong namespace ≠ UID 0 ngoài | `--user` | Container chạy root nhưng không phải host root |
| **CGROUP** | Cgroup view — thấy cgroup hierarchy riêng | `--cgroup` | Container thấy cgroup riêng |

## Cách xem namespace của process

```bash
# Xem tất cả namespace của process PID 1234
ls -la /proc/1234/ns/

# Output:
# lrwxrwxrwx  cgroup -> cgroup:[4026531835]
# lrwxrwxrwx  ipc    -> ipc:[4026531839]
# lrwxrwxrwx  mnt    -> mnt:[4026531840]
# lrwxrwxrwx  net    -> net:[4026531992]
# lrwxrwxrwx  pid    -> pid:[4026531836]
# lrwxrwxrwx  user   -> user:[4026531837]
# lrwxrwxrwx  uts    -> uts:[4026531838]

# Số trong ngoặc vuông là inode — 2 process có cùng inode = cùng namespace.
```

So sánh 2 process có cùng namespace không:

```bash
# Nếu inode giống → cùng namespace
ls -la /proc/<pid1>/ns/net /proc/<pid2>/ns/net
```

## Tạo namespace bằng `unshare`

`unshare` chạy một program trong namespace mới:

```bash
# Tạo UTS namespace mới — đổi hostname không ảnh hưởng host
sudo unshare --uts sh -c 'hostname mycontainer && hostname'
# Output: mycontainer
# Nhưng host vẫn giữ hostname cũ

# Tạo PID namespace — bên trong thấy PID 1
sudo unshare --pid --fork sh
# Trong shell mới:
ps aux
# Chỉ thấy rất ít process, PID bắt đầu từ 1

# Tạo NET namespace — có network stack riêng, không thấy interface host
sudo unshare --net sh
# Trong shell mới:
ip addr
# Chỉ thấy lo interface, không thấy eth0
```

### Tại sao cần `--fork` với PID namespace

PID namespace mới cần `fork()` để tạo PID 1 bên trong. Nếu không `--fork`, `unshare` bản thân nó chạy trong namespace cũ nhưng process mới sinh ra trong namespace mới — không có PID 1 → không hoạt động đúng.

## Tạo namespace bằng `ip netns` (Network Namespace)

```bash
# Tạo netns có tên
sudo ip netns add ns1
sudo ip netns add ns2

# Liệt kê
ip netns list

# Chạy lệnh trong netns
sudo ip netns exec ns1 ip addr

# Xóa
sudo ip netns del ns1
```

`ip netns add` tạo netns và bind mount vào `/var/run/netns/<name>` — giúp netns tồn tại ngay cả khi không có process nào chạy trong nó.

## `nsenter` — vào namespace của process đang chạy

```bash
# Vào tất cả namespace của container PID 5678
sudo nsenter -t 5678 -a sh

# Vào chỉ network namespace
sudo nsenter -t 5678 -n ip addr

# Vào chỉ mount namespace
sudo nsenter -t 5678 -m ls /
```

Đây chính là cách `docker exec` và `kubectl exec` hoạt động — dùng `nsenter` để vào namespace của container.

## Liên hệ với Kubernetes

### Pod = shared namespace

Container trong **cùng pod** chia sẻ:
- **NET namespace** → cùng IP, cùng port space.
- **IPC namespace** → giao tiếp shared memory.
- **UTS namespace** → cùng hostname.
- **MNT namespace** → chia sẻ volume mount (nếu khai báo).

Container trong cùng pod **không** chia sẻ:
- **PID namespace** → mỗi container có PID riêng (trừ khi `shareProcessNamespace: true`).

### CRI tạo namespace

Khi kubelet gọi CRI `RunPodSandbox`:
1. Tạo NET namespace cho pod.
2. CNI plugin gán IP, veth, route.
3. Mỗi container trong pod dùng NET namespace của pod.
4. Container có PID/MNT/IPC/UTS namespace riêng.

### Debug thực tế

```bash
# Tìm PID của container process trên node
crictl inspect <container_id> | grep pid

# Vào namespace của container
nsenter -t <pid> -a sh

# Xem network từ trong container
nsenter -t <pid> -n ip addr
nsenter -t <pid> -n iptables-save
```
