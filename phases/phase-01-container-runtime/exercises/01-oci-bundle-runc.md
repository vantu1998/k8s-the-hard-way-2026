# Exercise 01 — Tạo OCI bundle bằng tay, chạy runc

> **Mục tiêu**: Tạo container từ đầu — không Docker, không containerd, chỉ runc + rootfs + config.json.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Linux VM, root access, `runc`, `jq`

## Bối cảnh

`docker run` và `ctr run` đều cuối cùng gọi `runc`. Bài này bỏ qua mọi layer phía trên — tự tạo OCI bundle, tự viết config.json, chạy runc trực tiếp.

## Bước 1: Cài runc

```bash
sudo apt update && sudo apt install -y runc jq
runc --version
# runc version 1.1.x
```

**Kiểm tra**: `runc --version` hiện version.

## Bước 2: Tạo cấu trúc bundle

```bash
mkdir -p /tmp/mycontainer/rootfs
cd /tmp/mycontainer
```

## Bước 3: Tạo rootfs — cách thủ công

```bash
# Download busybox static binary
curl -fsSL https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox \
  -o /tmp/busybox
chmod +x /tmp/busybox

# Copy vào rootfs
mkdir -p rootfs/bin rootfs/proc rootfs/sys rootfs/dev rootfs/tmp rootfs/etc
cp /tmp/busybox rootfs/bin/busybox

# Tạo symlink cho các lệnh phổ biến
cd rootfs/bin
for cmd in sh ls cat echo ps hostname mkdir sleep mount umount env true false; do
    ln -s busybox $cmd
done
cd /tmp/mycontainer

# Tạo /etc/passwd (cần cho một số lệnh)
echo "root:x:0:0:root:/root:/bin/sh" > rootfs/etc/passwd
echo "root:x:0:" > rootfs/etc/group

# Kiểm tra
ls rootfs/bin/
# busybox  sh  ls  cat  echo  ps  hostname  mkdir  sleep  mount  umount  env  true  false
```

**Kiểm tra**: rootfs có `bin/busybox` + symlink.

## Bước 4: Tạo config.json

```bash
runc spec
cat config.json | jq .process.args
# ["/bin/sh"]
```

**Kiểm tra**: `config.json` tồn tại, `process.args` = `["/bin/sh"]`.

## Bước 5: Chạy container!

```bash
sudo runc run mycontainer
```

Bạn đang ở trong container:

```text
/ # hostname
mycontainer

/ # ps aux
PID   USER     TIME  COMMAND
    1 root      0:00 /bin/sh         ← PID 1
    2 root      0:00 ps aux           ← chỉ 2 process!

/ # ls /
bin   dev   etc   proc  sys   tmp

/ # cat /etc/passwd
root:x:0:0:root:/root:/bin/sh

/ # mount | head
proc on /proc type proc (rw,nosuid,nodev,noexec,relatime)

/ # exit
```

**Kiểm tra**: Container chạy, chỉ thấy 2 process, hostname = `mycontainer`.

## Bước 6: Xem container từ ngoài (terminal 2)

```bash
# Terminal 2 (trong khi container đang chạy ở terminal 1)
sudo runc list
# ID            PID         STATUS      BUNDLE
# mycontainer   12345       running     /tmp/mycontainer

# Xem state
sudo runc state mycontainer
# {
#   "ociVersion": "1.0.2",
#   "id": "mycontainer",
#   "status": "running",
#   "pid": 12345,
#   "bundle": "/tmp/mycontainer"
# }

# Xem namespace của container process
ls -la /proc/12345/ns/
# pid, net, mnt, ipc, uts — tất cả khác host

# Exec vào container
sudo runc exec mycontainer sh
# / # echo "hello from exec"
```

**Kiểm tra**: `runc list` hiện container, `runc exec` vào được.

## Bước 7: Sửa config — chạy command khác

```bash
# Thoát container trước (exit trong terminal 1)
# Xóa container cũ
sudo runc delete mycontainer

# Sửa args thành echo
cat config.json | jq '.process.args = ["/bin/echo", "Hello from runc container"]' > config.json.tmp
mv config.json.tmp config.json

# Chạy
sudo runc run mycontainer
# Hello from runc container
# (container tự exit sau khi echo xong)
```

**Kiểm tra**: Container chạy echo rồi exit.

## Bước 8: Sửa config — thêm memory limit

```bash
sudo runc delete mycontainer 2>/dev/null

# Thêm memory limit 10MB
cat config.json | jq '.linux.resources.memory.limit = 10485760' > config.json.tmp
mv config.json.tmp config.json

# Sửa args lại thành sh
cat config.json | jq '.process.args = ["/bin/sh"]' > config.json.tmp
mv config.json.tmp config.json

# Chạy và cố ăn hết memory
sudo runc run mycontainer
# / # echo "$(head -c 10000000 /dev/urandom)" > /tmp/big
# (container bị OOM killed — runc exit)
```

**Kiểm tra**: Container bị kill khi vượt memory limit.

## Bước 9: Sửa config — thêm hostname

```bash
sudo runc delete mycontainer 2>/dev/null

cat config.json | jq '.hostname = "myapp-container"' > config.json.tmp
mv config.json.tmp config.json

sudo runc run mycontainer
# / # hostname
# myapp-container
# / # exit
```

**Kiểm tra**: `hostname` = `myapp-container`.

## Cleanup

```bash
sudo runc delete mycontainer 2>/dev/null
rm -rf /tmp/mycontainer /tmp/busybox
```

## Câu hỏi tự kiểm tra

1. `runc spec` tạo gì? Có cần sửa gì trước khi chạy?
2. Rootfs phải chứa tối thiểu gì để container chạy được?
3. `runc run` vs `runc create` + `runc start` — khác gì?
4. Nếu xóa `namespaces` khỏi config.json → điều gì xảy ra?
5. So sánh rootfs bạn tạo bằng tay vs rootfs từ `docker export` — khác gì?

## Đáp án tham khảo

1. Tạo `config.json` mặc định (chạy `/bin/sh`, 5 namespace, mount /proc /dev /sys). Có thể chạy ngay nếu rootfs có `/bin/sh`.
2. Ít nhất binary mà `process.args` gọi (ví dụ `/bin/sh`). Cần `/proc`, `/sys`, `/dev` mount.
3. `run` = create + start + đợi exit (foreground). `create` + `start` = tách bước, có thể exec trước khi start.
4. Container chạy nhưng không có namespace isolation — process thấy host process, host network, host mount.
5. `docker export` cho rootfs đầy đủ (có /bin, /lib, /usr, /etc đầy đủ). Tạo bằng tay chỉ có busybox — tối thiểu, hiểu rõ từng file.
