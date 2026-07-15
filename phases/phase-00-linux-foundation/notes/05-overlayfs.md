# 05 — OverlayFS

## OverlayFS là gì

OverlayFS là **union filesystem** — chồng nhiều thư mục lên nhau thành một view thống nhất. Container image dùng OverlayFS để:
- Image layer (read-only) = lowerdir.
- Container write layer = upperdir.
- View mà container thấy = mergeddir.

**Lợi ích**: nhiều container chia sẻ cùng base image (read-only), mỗi container chỉ có write layer riêng nhỏ → tiết kiệm disk.

## Cấu trúc OverlayFS

```
┌──────────────────────────────────────────────┐
│              mergeddir (view)                │  ← Container thấy thư mục này
├──────────────────────────────────────────────┤
│  upperdir (read-write)  │  lowerdir (RO)     │  ← Hai layer chồng nhau
│  Container write layer  │  Image layers      │
└──────────────────────────────────────────────┘
```

- **lowerdir**: Read-only, có thể nhiều layer (chồng từ dưới lên). Layer thấp nhất = base image.
- **upperdir**: Read-write, mọi thay đổi ghi vào đây.
- **mergeddir**: View thống nhất — đọc từ lower + upper, ghi vào upper.
- **workdir**: Thư mục nội bộ của overlayfs (cần có, không dùng trực tiếp).

## Thực hành mount bằng tay

```bash
# Tạo cấu trúc thư mục
mkdir -p /tmp/overlay/{lower,upper,work,merged}

# Tạo file trong lower (giả lập image layer)
echo "base file from image" > /tmp/overlay/lower/base.txt
mkdir -p /tmp/overlay/lower/etc
echo "config from image" > /tmp/overlay/lower/etc/config.conf

# Mount overlayfs
sudo mount -t overlay overlay \
  -o lowerdir=/tmp/overlay/lower,upperdir=/tmp/overlay/upper,workdir=/tmp/overlay/work \
  /tmp/overlay/merged

# Xem mergeddir — thấy file từ lower
ls /tmp/overlay/merged/
# base.txt  etc/

cat /tmp/overlay/merged/base.txt
# base file from image
```

### Ghi file mới — đi vào upperdir

```bash
# Tạo file mới trong merged
echo "container wrote this" > /tmp/overlay/merged/new.txt

# File xuất hiện trong upperdir, không trong lowerdir
ls /tmp/overlay/upper/
# new.txt

cat /tmp/overlay/upper/new.txt
# container wrote this
```

### Sửa file có sẵn — copy-up

```bash
# Sửa file từ lower
echo "modified config" > /tmp/overlay/merged/etc/config.conf

# OverlayFS copy file từ lower → upper, rồi ghi vào upper
ls /tmp/overlay/upper/etc/
# config.conf

cat /tmp/overlay/upper/etc/config.conf
# modified config

# Lower vẫn không đổi
cat /tmp/overlay/lower/etc/config.conf
# config from image
```

**Copy-up**: Khi ghi vào file đang ở lower, overlayfs copy file đó lên upper trước khi ghi. Lower không bao giờ bị sửa.

### Xóa file — whiteout

```bash
# Xóa file trong merged
rm /tmp/overlay/merged/base.txt

# File biến mất khỏi merged
ls /tmp/overlay/merged/
# etc/  new.txt

# Nhưng lower vẫn có file
ls /tmp/overlay/lower/
# base.txt  etc/

# Upper tạo "whiteout" — character device 0/0
ls -la /tmp/overlay/upper/
# c---------  root root  0, 0  base.txt  ← whiteout marker
```

**Whiteout**: OverlayFS đánh dấu file đã xóa bằng character device đặc biệt (0/0) trong upperdir. Khi đọc merged, overlayfs thấy whiteout → ẩn file từ lowerdir.

### Xóa thư mục — opaque

```bash
# Xóa toàn bộ thư mục etc
rm -rf /tmp/overlay/merged/etc

# Upper tạo whiteout cho từng file + đánh dấu opaque cho thư mục
# xattr "trusted.overlay.opaque" = "y" trên thư mục
```

## Cách containerd dùng OverlayFS

```bash
# Xem overlay mount của container đang chạy
mount | grep overlay

# Output ví dụ:
# overlay on /var/lib/containerd/io.containerd.runtime.v2.task/.../rootfs
#   type overlay (rw,relatime,
#     lowerdir=/var/lib/containerd/io.containerd.snapshotter/overlay/snapshots/1/fs:...
#     upperdir=/var/lib/containerd/io.containerd.snapshotter/overlay/snapshots/2/fs
#     workdir=/var/lib/containerd/io.containerd.snapshotter/overlay/snapshots/2/work
#   )

# Mỗi image layer = 1 snapshot trong /var/lib/containerd/.../snapshots/
# Container write layer = snapshot mới, upperdir
```

### Image layer → snapshot

```
Image: nginx:1.25
  Layer 1: base OS (ubuntu)      → snapshot/1/fs (lowerdir)
  Layer 2: apt install nginx     → snapshot/2/fs (lowerdir)
  Layer 3: COPY nginx.conf       → snapshot/3/fs (lowerdir)

Container chạy:
  Layer 4: write layer           → snapshot/4/fs (upperdir)
```

Nhiều container dùng cùng image → chia sẻ snapshot/1,2,3 (read-only). Mỗi container có snapshot riêng cho upperdir.

## Cleanup

```bash
# Unmount overlay
sudo umount /tmp/overlay/merged

# Xóa thư mục
rm -rf /tmp/overlay
```

## Liên hệ với Kubernetes

- **containerd** mặc định dùng `overlayfs` snapshotter.
- Kubelet report node capacity bao gồm overlayfs disk usage.
- `df -h /var/lib/containerd` cho biết disk usage của tất cả image + container.
- Khi node đầy disk → kubelet trigger **image garbage collection** — xóa unused image layer.
- OverlayFS cần kernel module `overlay` — hầu hết Linux distro hỗ trợ sẵn.
