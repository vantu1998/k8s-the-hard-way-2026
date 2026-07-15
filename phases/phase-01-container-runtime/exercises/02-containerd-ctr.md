# Exercise 02 — Cài containerd, dùng ctr pull/run/exec

> **Mục tiêu**: Hiểu containerd — pull image, unpack layer, run container, exec, xem snapshot.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Linux VM, root access, `containerd`, `runc`

## Bước 1: Cài containerd

```bash
sudo apt update && sudo apt install -y containerd runc jq

# Start + enable
sudo systemctl start containerd
sudo systemctl enable containerd

# Kiểm tra
sudo systemctl status containerd
# Active: active (running)

containerd --version
# containerd github.com/containerd/containerd v1.7.x
```

**Kiểm tra**: containerd `active (running)`.

## Bước 2: Kiểm tra socket

```bash
ls -la /run/containerd/containerd.sock
# srw-rw---- 1 root containerd ... /run/containerd/containerd.sock

# Test connection
ctr version
# Client: v1.7.x
# Server: v1.7.x
```

**Kiểm tra**: `ctr version` hiện cả Client và Server version.

## Bước 3: Pull image nginx

```bash
sudo ctr images pull docker.io/library/nginx:1.25
# (xem output: pulling layer by layer)

# Kiểm tra
sudo ctr images list
# REF                              TYPE   DIGEST      SIZE
# docker.io/library/nginx:1.25     application/vnd.oci.image.manifest.v1+json   sha256:abc...   150MB
```

**Kiểm tra**: Image nginx:1.25 trong list.

## Bước 4: Xem image layer

```bash
# Inspect image
sudo ctr images inspect docker.io/library/nginx:1.25 | jq .manifest.layers
# [
#   {"mediaType": "...layer.v1.tar+gzip", "digest": "sha256:layer1...", "size": 32654},
#   {"mediaType": "...layer.v1.tar+gzip", "digest": "sha256:layer2...", "size": 16724},
#   ...
# ]

# Xem config (entrypoint, env)
sudo ctr images inspect docker.io/library/nginx:1.25 | jq .config.config
# {
#   "Env": ["PATH=..."],
#   "Cmd": ["nginx", "-g", "daemon off;"],
#   "Entrypoint": ["/docker-entrypoint.sh"]
# }
```

**Kiểm tra**: Thấy danh sách layer + config (Cmd, Entrypoint).

## Bước 5: Xem snapshot — layer unpack

```bash
# List snapshot
sudo ctr snapshots list
# KEY                    PARENT                 KIND
# sha256:layer1...                              Committed
# sha256:layer2...       sha256:layer1...       Committed
# sha256:layer3...       sha256:layer2...       Committed

# Xem trên disk
ls /var/lib/containerd/io.containerd.snapshotter.overlay/snapshots/
# 1/  2/  3/  ...    ← mỗi số = 1 layer

# Xem nội dung 1 snapshot
sudo ls /var/lib/containerd/io.containerd.snapshotter.overlay/snapshots/1/fs/
# bin  boot  dev  etc  ...    ← rootfs của layer 1
```

**Kiểm tra**: Snapshot list có nhiều entry, mỗi snapshot có `fs/` chứa rootfs.

## Bước 6: Run container

```bash
# Run nginx detached
sudo ctr run -d docker.io/library/nginx:1.25 mynginx

# Kiểm tra container
sudo ctr containers list
# CONTAINER    IMAGE                          RUNTIME    STATUS
# mynginx      docker.io/library/nginx:1.25   runc       running

# Kiểm tra task (process)
sudo ctr tasks list
# TASK      PID     STATUS
# mynginx   12345   RUNNING
```

**Kiểm tra**: Container `mynginx` running, có PID.

## Bước 7: Kiểm tra container từ ngoài

```bash
# Xem process
ps aux | grep nginx
# root  12345  nginx: master process nginx -g daemon off;
# root  12346  nginx: worker process

# Xem namespace
ls -la /proc/12345/ns/
# net, pid, mnt, ipc, uts — tất cả khác host

# Xem containerd-shim
ps aux | grep containerd-shim
# root  12340  containerd-shim-runc-v2 -namespace default -id mynginx ...
```

**Kiểm tra**: nginx process chạy, có shim process.

## Bước 8: Exec vào container

```bash
# Exec sh vào container
sudo ctr tasks exec --exec-id exec1 -t mynginx sh

# Trong container:
# # ls /etc/nginx/
# conf.d  fastcgi_params  mime.types  modules  nginx.conf

# # nginx -t
# nginx: the configuration file /etc/nginx/nginx.conf syntax is ok

# # cat /etc/nginx/conf.d/default.conf | head
# server {
#     listen 80;
#     ...

# # exit
```

**Kiểm tra**: Exec vào được, thấy filesystem nginx.

## Bước 9: Xem container log

```bash
# Trước tiên: tạo request để nginx ghi log
# Tìm IP của container
sudo ctr tasks exec --exec-id exec2 mynginx ip addr show eth0
# inet 10.88.0.2/16

# Curl từ host (cần vào cùng netns hoặc dùng container IP)
sudo ctr tasks exec --exec-id exec3 mynginx curl -s localhost

# Xem log
sudo ctr tasks logs mynginx
# 10.0.0.1 - - [15/Jan/2026:10:00:00] "GET / HTTP/1.1" 200 ...
```

**Kiểm tra**: Log hiện access log entry.

## Bước 10: Stop + delete container

```bash
# Stop
sudo ctr tasks kill mynginx
sudo ctr tasks delete mynginx

# Delete container
sudo ctr containers delete mynginx

# Kiểm tra
sudo ctr containers list
# (empty)
```

**Kiểm tra**: Container đã xóa.

## Bước 11: Run với env + mount

```bash
# Tạo data trên host
mkdir -p /tmp/mydata
echo "hello from host" > /tmp/mydata/test.txt

# Run với env + mount
sudo ctr run -d \
  --env APP_ENV=production \
  --mount type=bind,src=/tmp/mydata,dst=/data,options=ro \
  docker.io/library/nginx:1.25 mynginx2

# Exec vào, kiểm tra
sudo ctr tasks exec --exec-id exec4 -t mynginx2 sh
# # cat /data/test.txt
# hello from host
# # echo $APP_ENV
# production
# # exit

# Cleanup
sudo ctr tasks kill mynginx2
sudo ctr tasks delete mynginx2
sudo ctr containers delete mynginx2
```

**Kiểm tra**: Env + mount hoạt động.

## Cleanup

```bash
sudo ctr images rm docker.io/library/nginx:1.25
rm -rf /tmp/mydata
```

## Câu hỏi tự kiểm tra

1. `ctr run` tự động pull image không? Nếu image chưa có thì sao?
2. Snapshot và image layer khác nhau thế nào?
3. `containerd-shim` làm gì? Tại sao cần?
4. Nếu kill `containerd-shim` process → container bị gì?
5. `ctr -n k8s.io` vs `ctr -n default` — khác gì? Container do kubelet tạo ở namespace nào?

## Đáp án tham khảo

1. Không tự pull. Nếu image chưa có → error "image not found". Cần `ctr images pull` trước.
2. Image layer = blob tar.gz trong content store. Snapshot = layer đã unpack thành filesystem trong snapshotter. Nhiều snapshot chồng nhau = rootfs.
3. Shim là parent process của container. Tách container khỏi containerd daemon — containerd restart không kill container. Shim reap zombie, forward stdio, report exit status.
4. Container bị orphan — process vẫn chạy nhưng không ai quản lý. Containerd mất control. (Sẽ thực hành trong Exercise 05.)
5. `k8s.io` = namespace cho Kubernetes (kubelet tạo container ở đây). `default` = namespace mặc định cho ctr. Container do kubelet tạo nằm trong `k8s.io`.
