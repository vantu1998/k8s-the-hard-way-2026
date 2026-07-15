# Exercise 03 — Mount OverlayFS bằng tay, quan sát whiteout

> **Mục tiêu**: Hiểu OverlayFS — cách container image layer hoạt động, copy-up mechanism, whiteout.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Linux VM, root access, kernel hỗ trợ overlayfs

## Bối cảnh

Container image = nhiều layer read-only chồng nhau. Container chạy = thêm 1 layer read-write trên cùng. OverlayFS thực hiện "chồng" này. Bài này mô phỏng bằng tay.

## Bước 1: Tạo cấu trúc thư mục

```bash
mkdir -p /tmp/overlay/{lower,upper,work,merged}

# Tạo nội dung cho lower (giả lập image layer)
echo "base file from image layer 1" > /tmp/overlay/lower/base.txt
mkdir -p /tmp/overlay/lower/etc
echo "config from image" > /tmp/overlay/lower/etc/config.conf
echo "readme from image" > /tmp/overlay/lower/README.md

# Kiểm tra
find /tmp/overlay/lower -type f
# /tmp/overlay/lower/base.txt
# /tmp/overlay/lower/etc/config.conf
# /tmp/overlay/lower/README.md
```

**Kiểm tra**: 3 file trong lower.

## Bước 2: Mount overlayfs

```bash
sudo mount -t overlay overlay \
  -o lowerdir=/tmp/overlay/lower,upperdir=/tmp/overlay/upper,workdir=/tmp/overlay/work \
  /tmp/overlay/merged

# Kiểm tra
mount | grep overlay
# overlay on /tmp/overlay/merged type overlay (rw,relatime,lowerdir=...,upperdir=...,workdir=...)

# Xem merged — thấy tất cả file từ lower
ls -la /tmp/overlay/merged/
# base.txt  etc/  README.md
```

**Kiểm tra**: merged hiện tất cả file từ lower.

## Bước 3: Đọc file từ lower qua merged

```bash
cat /tmp/overlay/merged/base.txt
# base file from image layer 1

cat /tmp/overlay/merged/etc/config.conf
# config from image
```

**Kiểm tra**: Đọc được file từ lower qua merged.

## Bước 4: Tạo file mới trong merged → đi vào upper

```bash
echo "container wrote this" > /tmp/overlay/merged/new.txt

# File trong merged
ls /tmp/overlay/merged/
# base.txt  etc/  new.txt  README.md

# File trong upper (write layer)
ls /tmp/overlay/upper/
# new.txt

cat /tmp/overlay/upper/new.txt
# container wrote this

# Lower KHÔNG có file mới
ls /tmp/overlay/lower/
# base.txt  etc/  README.md    ← không có new.txt
```

**Kiểm tra**: File mới chỉ xuất hiện trong upper + merged, không trong lower.

## Bước 5: Sửa file từ lower → copy-up

```bash
echo "modified by container" > /tmp/overlay/merged/etc/config.conf

# Merged có nội dung mới
cat /tmp/overlay/merged/etc/config.conf
# modified by container

# Upper có file đã copy-up
ls /tmp/overlay/upper/etc/
# config.conf

cat /tmp/overlay/upper/etc/config.conf
# modified by container

# Lower VẪN GIỮ nguyên
cat /tmp/overlay/lower/etc/config.conf
# config from image    ← không đổi!
```

**Kiểm tra**: Upper có bản sao đã sửa, lower giữ nguyên.

## Bước 6: Xóa file → whiteout

```bash
rm /tmp/overlay/merged/base.txt

# Merged — file biến mất
ls /tmp/overlay/merged/
# etc/  new.txt  README.md    ← không có base.txt

# Lower — file vẫn còn
ls /tmp/overlay/lower/
# base.txt  etc/  README.md   ← vẫn có base.txt

# Upper — whiteout marker
ls -la /tmp/overlay/upper/
# total 24
# drwxr-xr-x  ...  .
# drwxr-xr-x  ...  ..
# c---------  root root 0, 0  base.txt    ← character device 0/0 = whiteout!
# drwxr-xr-x  ...  etc/
# -rw-r--r--  ...  new.txt
```

**Kiểm tra**: `base.txt` trong upper là character device `0, 0` (whiteout marker).

## Bước 7: Tạo nhiều lower layer

```bash
# Unmount trước
sudo umount /tmp/overlay/merged

# Tạo thêm lower layer 2
mkdir -p /tmp/overlay/lower2
echo "app code from layer 2" > /tmp/overlay/lower2/app.py
mkdir -p /tmp/overlay/lower2/lib
echo "library from layer 2" > /tmp/overlay/lower2/lib/util.py

# Mount với 2 lower layer (lower2 chồng lên lower)
# Cú pháp: lowerdir=lower2:lower (thứ tự từ trên xuống)
sudo mount -t overlay overlay \
  -o lowerdir=/tmp/overlay/lower2:/tmp/overlay/lower,upperdir=/tmp/overlay/upper,workdir=/tmp/overlay/work \
  /tmp/overlay/merged

# Xem merged — thấy file từ cả 2 layer
ls /tmp/overlay/merged/
# app.py  etc/  lib/  base.txt  README.md

cat /tmp/overlay/merged/app.py
# app code from layer 2

cat /tmp/overlay/merged/base.txt
# base file from image layer 1
```

**Kiểm tra**: merged hiện file từ cả lower2 và lower.

## Bước 8: Layer conflict — layer trên ghi đè layer dưới

```bash
# Tạo file cùng tên ở lower2 (ghi đè lower)
echo "OVERRIDE from layer 2" > /tmp/overlay/lower2/base.txt

# Unmount và mount lại
sudo umount /tmp/overlay/merged
sudo mount -t overlay overlay \
  -o lowerdir=/tmp/overlay/lower2:/tmp/overlay/lower,upperdir=/tmp/overlay/upper,workdir=/tmp/overlay/work \
  /tmp/overlay/merged

cat /tmp/overlay/merged/base.txt
# OVERRIDE from layer 2    ← layer trên (lower2) thắng
```

**Kiểm tra**: File cùng tên — layer trên (lower2) che layer dưới (lower).

## Cleanup

```bash
sudo umount /tmp/overlay/merged
rm -rf /tmp/overlay
```

## Câu hỏi tự kiểm tra

1. Tại sao container image dùng overlayfs thay vì copy toàn bộ file?
2. Copy-up xảy ra khi nào? Ảnh hưởng performance thế nào?
3. Whiteout là gì? Tại sao không xóa file khỏi lower luôn?
4. 10 container dùng cùng image → có bao nhiêu bản copy của base layer?
5. `docker pull nginx` tạo bao nhiêu layer? Làm sao xem?

## Đáp án tham khảo

1. Tiết kiệm disk — nhiều container chia sẻ lower layer read-only, chỉ upper layer riêng.
2. Khi ghi vào file đang ở lower. OverlayFS copy file từ lower → upper rồi ghi. Chậm hơn ghi trực tiếp (1 lần read + 1 lần write thay vì 1 write).
3. Whiteout = marker trong upper để "ẩn" file từ lower. Lower là read-only (image layer) — không thể xóa.
4. 1 bản copy của base layer (shared read-only) + 10 upper layer riêng.
5. `docker history nginx` hoặc `ctr images inspect nginx` → xem layer list.
