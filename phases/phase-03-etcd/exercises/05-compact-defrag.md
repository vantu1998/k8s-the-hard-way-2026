# Exercise 05 — Compact & Defrag

> **Mục tiêu**: Compact + defrag etcd, quan sát disk usage trước/sau.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Hoàn thành Exercise 01+02 (etcd cluster đang chạy)

## Bối cảnh

etcd giữ history (MVCC) — data dir phình to theo thời gian. Compact xóa revision cũ, defrag reclaim disk space. Bài này thực hành cả hai và đo disk usage.

## Bước 1: Setup environment

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://192.168.56.11:2379,https://192.168.56.12:2379,https://192.168.56.13:2379
export ETCDCTL_CACERT=/etc/etcd/etcd-ca.pem
export ETCDCTL_CERT=/etc/etcd/etcd-server.pem
export ETCDCTL_KEY=/etc/etcd/etcd-server-key.pem
```

## Bước 2: Tạo data (simulate real usage)

```bash
# Ghi 500 key, mỗi key update 10 lần → 5000 revision
for i in $(seq 1 500); do
  for j in $(seq 1 10); do
    etcdctl put "/data/key-${i}" "value-${j}-$(date +%s%N)"
  done
done

# Kiểm tra revision
etcdctl endpoint status --write-out=table
# REVISION: ~5000+
```

## Bước 3: Đo disk usage TRƯỚC compact

```bash
# DB size từ etcdctl
etcdctl endpoint status --write-out=table
# +----------------+----------+---------+---------+
# |    ENDPOINT    | REVISION | DB SIZE | IS LEADER|
# +----------------+----------+---------+---------+
# | 192.168.56.11:2379  |   5003   |  2.5 MB |   true  |
# | 192.168.56.12:2379  |   5003   |  2.5 MB |  false  |
# | 192.168.56.13:2379  |   5003   |  2.5 MB |  false  |
# +----------------+----------+---------+---------+

# Disk usage thực tế
sudo du -sh /var/lib/etcd/member/snap/db
# 2.5M  /var/lib/etcd/member/snap/db
```

**Ghi lại**: DB size trước compact.

## Bước 4: Đọc revision cũ (MVCC hoạt động)

```bash
# Lấy revision hiện tại
REV=$(etcdctl endpoint status --write-out=json | jq -r '.[0].Status.header.revision')
echo "Current revision: ${REV}"

# Đọc value ở revision cũ (revision 100)
etcdctl get /data/key-1 --rev=100
# value-1-<timestamp>  ← vẫn đọc được revision cũ

# Đọc value ở revision 5000
etcdctl get /data/key-1 --rev=5000
# value-10-<timestamp>  ← value mới nhất
```

**Kiểm tra**: Đọc được value ở revision cũ — MVCC giữ history.

## Bước 5: Compact

```bash
# Compact đến revision hiện tại
etcdctl compact "${REV}"
# compacted revision 5003
```

## Bước 6: Verify — không đọc được revision cũ

```bash
# Đọc revision cũ (100) — sẽ fail
etcdctl get /data/key-1 --rev=100
# Error: etcdserver: mvcc: required revision has been compacted

# Đọc revision hiện tại — vẫn OK
etcdctl get /data/key-1
# value-10-<timestamp>
```

**Kiểm tra**: Revision cũ không đọc được sau compact.

## Bước 7: Đo disk usage SAU compact (chưa defrag)

```bash
etcdctl endpoint status --write-out=table
# DB SIZE vẫn ~2.5 MB — compact xóa logic nhưng disk space chưa giảm

sudo du -sh /var/lib/etcd/member/snap/db
# 2.5M  ← vẫn vậy
```

> Compact xóa revision khỏi boltdb logic, nhưng free page vẫn nằm trong file.

## Bước 8: Defrag — reclaim disk space

```bash
# Defrag từng node (an toàn — không ảnh hưởng cluster)
etcdctl defrag --endpoints=https://192.168.56.11:2379
# Finished defragmenting etcd(https://192.168.56.11:2379)

etcdctl defrag --endpoints=https://192.168.56.12:2379
# Finished defragmenting etcd(https://192.168.56.12:2379)

etcdctl defrag --endpoints=https://192.168.56.13:2379
# Finished defragmenting etcd(https://192.168.56.13:2379)

# Hoặc defrag tất cả (etcdctl làm tuần tự)
# etcdctl defrag --cluster
```

## Bước 9: Đo disk usage SAU defrag

```bash
etcdctl endpoint status --write-out=table
# +----------------+----------+---------+---------+
# |    ENDPOINT    | REVISION | DB SIZE | IS LEADER|
# +----------------+----------+---------+---------+
# | 192.168.56.11:2379  |   5003   |  300 KB |   true  |
# | 192.168.56.12:2379  |   5003   |  300 KB |  false  |
# | 192.168.56.13:2379  |   5003   |  300 KB |  false  |
# +----------------+----------+---------+---------+

sudo du -sh /var/lib/etcd/member/snap/db
# 300K  ← giảm từ 2.5MB → 300KB
```

**Kiểm tra**: DB size giảm đáng kể sau defrag.

## Bước 10: Verify cluster health sau defrag

```bash
etcdctl endpoint health
# Cả 3 healthy

# Write vẫn hoạt động
etcdctl put /post-defrag "test"
# OK

etcdctl get /post-defrag
# test
```

**Kiểm tra**: Cluster healthy, write/read hoạt động bình thường.

## Bước 11: Auto-compaction config

```bash
# Kiểm tra config hiện tại
sudo journalctl -u etcd --no-pager | grep "auto-compaction"
# Nếu không có → auto-compaction đang off

# Bật auto-compaction (thêm vào systemd unit)
# --auto-compaction-mode=periodic
# --auto-compaction-retention=1h

# Ví dụ: sửa /etc/systemd/system/etcd.service
# Thêm vào ExecStart:
#   --auto-compaction-mode=periodic \
#   --auto-compaction-retention=1h \

# Reload + restart
sudo systemctl daemon-reload
sudo systemctl restart etcd
```

### Giải thích auto-compaction

| Mode | Retention | Behavior |
|------|-----------|----------|
| `periodic` | `1h` | Compact mỗi giờ, giữ revision trong 1 giờ gần nhất |
| `revision` | `1000` | Compact khi revision > 1000, giữ 1000 revision gần nhất |

> **Kubernetes recommendation**: `periodic` với `5m` hoặc `1h`.

## Bước 12: Quota — mô phỏng vượt quota

```bash
# Kiểm tra quota hiện tại (mặc định 2GB)
etcdctl endpoint status --write-out=json | jq '.[].Status.dbSize'

# Nếu muốn test quota (KHÔNG làm trên production):
# Set --quota-backend-bytes=10485760 (10MB) trong systemd
# Ghi data đến khi vượt quota
# etcd sẽ vào read-only mode

# Recovery:
# 1. etcdctl compact <revision>
# 2. etcdctl defrag --cluster
# 3. Restart etcd
```

## Tóm tắt before/after

```
=== BEFORE ===
Revision: 5003
DB Size:  2.5 MB

=== AFTER COMPACT ===
Revision: 5003 (không đổi)
DB Size:  2.5 MB (không giảm — chỉ xóa logic)

=== AFTER DEFRAG ===
Revision: 5003 (không đổi)
DB Size:  300 KB (giảm 88% — reclaim free page)
```

## Câu hỏi tự kiểm tra

1. Compact xóa gì? Defrag xóa gì? Khác nhau thế nào?
2. Tại sao sau compact, DB size không giảm?
3. Tại sao phải defrag từng node, không defrag tất cả cùng lúc?
4. Auto-compaction `periodic` vs `revision` — nên dùng cái nào cho Kubernetes?
5. etcd vượt quota → điều gì xảy ra? Cách recovery?

## Đáp án tham khảo

1. Compact xóa revision cũ khỏi boltdb (logic). Defrag reclaim free page trong boltdb file (disk space).
2. Vì boltdb (B+ tree) để lại free page trong file khi xóa. Compact xóa data nhưng free page vẫn chiếm space.
3. Defrag block node đang defrag (không serve request). Defrag tất cả cùng lúc = toàn bộ cluster down. `etcdctl defrag --cluster` làm tuần tự, an toàn.
4. `periodic` — Kubernetes watch thường reconnect nhanh, không cần history lâu. `1h` retention là hợp lý.
5. etcd vào read-only mode — write fail, API Server không ghi được. Recovery: compact + defrag để giảm DB size dưới quota, restart etcd.
