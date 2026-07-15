# 04 — Linux Capabilities

## Vấn đề

Truyền thống Linux chia process thành 2 loại:
- **root** (UID 0) — làm được mọi thứ.
- **non-root** — bị giới hạn.

Container thường cần một số quyền root (bind port < 1024, set hostname, tạo network namespace...) nhưng **không cần toàn bộ quyền root**. Nếu chạy container với full root → rủi ro bảo mật lớn.

## Giải pháp: Capabilities

Linux capabilities **chia nhỏ quyền root** thành các đơn vị riêng biệt. Thay vì "root hoặc không root", process có thể có một số capability cụ thể.

## Các capability quan trọng cho container

| Capability | Ý nghĩa | Container cần khi nào |
|-----------|---------|----------------------|
| `CAP_NET_BIND_SERVICE` | Bind port < 1024 | Web server bind 80/443 |
| `CAP_NET_ADMIN` | Quản lý network (iptables, route, interface) | CNI plugin, kube-proxy |
| `CAP_NET_RAW` | Tạo raw socket (ping, traceroute) | Pod cần ping |
| `CAP_SYS_ADMIN` | Quản lý system (mount, namespace) | Rất mạnh — hạn chế dùng |
| `CAP_CHOWN` | Đổi file owner | Container cần chown |
| `CAP_SETUID` | Đổi UID | Container cần setuid |
| `CAP_KILL` | Gửi signal | Container cần kill process |
| `CAP_AUDIT_WRITE` | Ghi audit log | Container ghi log |
| `CAP_DAC_OVERRIDE` | Bypass file permission | Đọc/ghi file bất kể permission |

## Xem capability của process

```bash
# Xem capability của process hiện tại
cat /proc/self/status | grep Cap

# Output:
# CapInh: 0000000000000000   (inheritable)
# CapPrm: 0000003fffffffff   (permitted)
# CapEff: 0000003fffffffff   (effective)
# CapBnd: 0000003fffffffff   (bounding)
# CapAmb: 0000000000000000   (ambient)

# Decode hex sang tên capability
capsh --decode=0000003fffffffff
# 0x0000003fffffffff=cap_chown,cap_dac_override,...,cap_sys_admin,...
```

```bash
# Xem capability của process PID 1234
getpcaps 1234
# Output: 1234: cap_chown,cap_dac_override,cap_fowner,...
```

## Container và capability

### Docker mặc định cấp 14 capability

```
cap_chown, cap_dac_override, cap_fsetid, cap_fowner,
cap_mknod, cap_net_raw, cap_setgid, cap_setuid,
cap_setfcap, cap_sepcap, cap_net_bind_service,
cap_sys_chroot, cap_kill, cap_audit_write
```

**Không cấp** `CAP_SYS_ADMIN`, `CAP_NET_ADMIN` mặc định — container không thể mount, không thể sửa iptables.

### Thêm / bớt capability trong Kubernetes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
spec:
  containers:
  - name: app
    image: nginx
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]      # thêm capability
        drop: ["ALL"]            # bỏ hết trước, rồi add lại cần gì
```

### Privileged container = tất cả capability

```yaml
spec:
  containers:
  - name: app
    securityContext:
      privileged: true    # = tất cả capability + không namespace isolation
```

Privileged container = **bypass gần hết security** — chỉ dùng khi cần (CNI plugin, CSI driver, monitoring agent).

## Drop capability — best practice

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
  runAsNonRoot: true
  runAsUser: 1000
```

Principle of least privilege — chỉ cấp capability thực sự cần.

## Liên hệ với Kubernetes

- **Cilium** cần `CAP_NET_ADMIN`, `CAP_SYS_ADMIN` (hoặc privileged) để quản lý network.
- **kube-proxy** cần `CAP_NET_ADMIN` để sửa iptables.
- Pod thường chỉ cần `CAP_NET_BIND_SERVICE` (bind port thấp) — drop hết còn lại.
- `CAP_SYS_ADMIN` thường bị nhắc đến trong lỗi "Operation not permitted" — container thiếu capability này.
