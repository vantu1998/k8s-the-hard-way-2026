# Exercise 06 — unshare tạo process với PID namespace riêng

> **Mục tiêu**: Hiểu PID namespace — process bên trong thấy PID từ 1, cách ly process tree.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Linux VM, root access, `util-linux` (lệnh `unshare`)

## Bối cảnh

Container có PID namespace riêng — bên trong container, process thấy mình là PID 1. Bài này mô phỏng bằng `unshare`, hiểu tại sao PID 1 đặc biệt trong container.

## Bước 1: unshare PID namespace cơ bản

```bash
# Tạo PID namespace mới, chạy sh
sudo unshare --pid --fork sh

# Trong shell mới, thử ps
ps aux
# USER  PID  ...  COMMAND
# root  1    ...  sh           ← sh là PID 1!
# root  2    ...  ps aux

# Thoát
exit
```

**Kiểm tra**: `ps aux` chỉ thấy vài process, PID bắt đầu từ 1.

## Bước 2: Tại sao ps vẫn thấy process host?

```bash
sudo unshare --pid --fork sh

# ps aux vẫn thấy tất cả process host???
ps aux | wc -l
# 150    ← vẫn thấy nhiều process

# Lý do: ps đọc /proc, nhưng /proc vẫn là của host
# PID namespace cách ly PID number, nhưng /proc mount vẫn share
ls /proc | head
# 1  10  100  101  ...    ← /proc của host

exit
```

**Kiểm tra**: `ps aux` vẫn thấy host process vì `/proc` chưa được cách ly.

## Bước 3: unshare PID + mount /proc mới

```bash
# Tạo PID namespace + mount namespace (cần để mount /proc mới)
sudo unshare --pid --fork --mount sh

# Trong shell mới:
# Mount /proc mới cho namespace này
mount -t proc proc /proc

# Bây giờ ps chỉ thấy process trong namespace
ps aux
# USER  PID  ...  COMMAND
# root  1    ...  sh           ← chỉ thấy sh + ps
# root  2    ...  ps aux

# /proc chỉ có PID trong namespace
ls /proc
# 1  2  ...    ← chỉ PID trong namespace

exit
```

**Kiểm tra**: `ps aux` chỉ thấy process trong namespace, `/proc` chỉ có PID local.

## Bước 4: PID 1 đặc biệt — thử kill PID 1

```bash
sudo unshare --pid --fork --mount sh
mount -t proc proc /proc

# PID 1 = sh. Thử kill PID 1
kill -9 1
# sh: can't kill pid 1: Operation not permitted    ← không kill được!

# Nhưng kill PID 2 (process khác) thì được
sleep 100 &
kill $!
# (thành công)

exit
```

**Kiểm tra**: Không kill được PID 1 bằng SIGKILL từ bên trong namespace.

## Bước 5: PID 1 chết → namespace chết

```bash
sudo unshare --pid --fork --mount sh
mount -t proc proc /proc

# Chạy background process
sleep 1000 &

# Exit sh (PID 1) → toàn bộ namespace bị destroy
exit

# sleep 1000 cũng bị kill theo
ps aux | grep "sleep 1000"
# (không thấy — đã bị kill khi PID 1 exit)
```

**Kiểm tra**: Khi PID 1 exit, tất cả process trong namespace bị kill.

## Bước 6: Container truth — PID 1 và signal

```bash
# Tạo script không handle signal
sudo tee /tmp/no-signal.sh << 'EOF'
#!/bin/bash
echo "PID=$$ — I don't handle signals"
while true; do
    echo "alive..."
    sleep 2
done
EOF
chmod +x /tmp/no-signal.sh

# Chạy trong PID namespace
sudo unshare --pid --fork --mount /tmp/no-signal.sh &
APP_PID=$!

# Đợi mount /proc
sleep 1

# Gửi SIGTERM — PID 1 trong namespace KHÔNG nhận (kernel không forward signal đến PID 1 nếu không explicit handler)
sudo kill -TERM $APP_PID

# Đợi xem
sleep 3

# Process vẫn chạy! PID 1 không nhận SIGTERM nếu không install handler
ps aux | grep no-signal
# (vẫn thấy)

# Phải SIGKILL
sudo kill -9 $APP_PID
```

**Kiểm tra**: SIGTERM không kill được PID 1 (không handler), phải dùng SIGKILL.

> **Đây là lý do container cần `tini` hoặc `dumb-init` làm PID 1** — init process nhận signal, forward đến child, reap zombie.

## Bước 7: Zombie reaping trong PID namespace

```bash
sudo unshare --pid --fork --mount sh
mount -t proc proc /proc

# Tạo zombie: child exit, parent không wait
python3 -c "
import os, time
pid = os.fork()
if pid == 0:
    os._exit(42)
else:
    print(f'Child PID={pid}')
    time.sleep(30)
" &

sleep 2

# Xem zombie
ps aux
# USER  PID  ...  STAT  COMMAND
# root  1    ...  S     sh
# root  2    ...  S     python3
# root  3    ...  Z     [python3] <defunct>    ← zombie!

# Zombie tồn tại cho đến khi PID 1 wait() hoặc PID 1 chết
# Trong container: nếu PID 1 không reap zombie → zombie tích lũy

exit
```

**Kiểm tra**: Thấy process với STAT `Z` (zombie) trong namespace.

## Bước 8: unshare nhiều namespace cùng lúc

```bash
# Tạo container-like isolation: PID + MNT + NET + UTS + IPC
sudo unshare --pid --fork --mount --net --uts --ipc sh

# Trong shell mới:
mount -t proc proc /proc
hostname mycontainer

# Kiểm tra isolation
hostname              # mycontainer (riêng)
ps aux                # chỉ PID trong namespace
ip addr               # chỉ lo (netns riêng)
ls /proc              # chỉ PID trong namespace

exit
```

**Kiểm tra**: Mỗi namespace cách ly đúng — hostname riêng, process riêng, network riêng.

## Cleanup

```bash
# Không cần cleanup — unshare tự cleanup khi exit
# Kill mọi process còn sót
sudo pkill -f no-signal.sh 2>/dev/null
```

## Câu hỏi tự kiểm tra

1. Tại sao cần `--fork` với `--pid`? Điều gì xảy ra nếu không có?
2. Tại sao PID 1 không nhận SIGTERM nếu không có explicit handler?
3. Zombie trong container ai responsible cho việc reap?
4. Tại sao cần mount `/proc` mới sau khi unshare PID?
5. Nếu PID 1 trong container crash → điều gì xảy ra với các process khác?

## Đáp án tham khảo

1. PID namespace cần PID 1 bên trong. Không `--fork`, `unshare` chạy trong namespace cũ, process mới sinh ra trong namespace mới nhưng không có PID 1 → lỗi.
2. Kernel thiết kế: signal từ ngoài gửi đến PID 1 bị drop nếu PID 1 không install handler (không `signal(SIGTERM, handler)`). Tránh init process bị kill do signal stray.
3. PID 1 trong container. Nếu PID 1 không reap (không `wait()`) → zombie tích lũy. Đó là lý do dùng `tini`/`dumb-init`.
4. `/proc` mặc định là mount của host → `ps` đọc host process. Mount `/proc` mới trong MNT namespace → chỉ thấy PID trong namespace.
5. Toàn bộ process trong namespace bị kill. PID 1 chết = namespace destroy = tất cả process bên trong bị cleanup.
