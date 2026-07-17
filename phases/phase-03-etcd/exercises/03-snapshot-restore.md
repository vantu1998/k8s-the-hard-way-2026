# Exercise 03 — Snapshot, Kill Node, Restore, Rejoin

> **Mục tiêu**: Snapshot etcd, kill 1 node, restore từ snapshot, rejoin cluster.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Hoàn thành Exercise 01 + 02 (etcd cluster đang chạy, có data)

## Bối cảnh

Disaster recovery là kỹ năng quan trọng nhất với etcd. Bài này mô phỏng: backup → node chết → restore → cluster hoạt động lại.

## Bước 1: Ghi data test

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://192.168.56.11:2379,https://192.168.56.12:2379,https://192.168.56.13:2379
export ETCDCTL_CACERT=/etc/etcd/etcd-ca.pem
export ETCDCTL_CERT=/etc/etcd/etcd-server.pem
export ETCDCTL_KEY=/etc/etcd/etcd-server-key.pem

# Ghi data test
etcdctl put /app/config "production-settings"
etcdctl put /app/version "v1.0.0"
etcdctl put /app/features "feature-a,feature-b"

# Verify
etcdctl get --prefix /app/
# /app/config
# production-settings
# /app/features
# feature-a,feature-b
# /app/version
# v1.0.0
```

**Kiểm tra**: 3 key `/app/*` tồn tại.

## Bước 2: Snapshot — backup toàn bộ cluster

```bash
# Save snapshot
etcdctl snapshot save /tmp/etcd-backup.db
# Snapshot saved at /tmp/etcd-backup.db

# Verify snapshot
etcdctl snapshot status /tmp/etcd-backup.db --write-out=table
# +----------+----------+------------+------------+
# |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
# +----------+----------+------------+------------+
# | 0x2a3b...|    8     |     5      |   25 KB    |
# +----------+----------+------------+------------+
```

**Kiểm tra**: Snapshot file tồn tại, status hiện revision + key count.

## Bước 3: Copy snapshot ra nơi an toàn

```bash
# Copy snapshot ra ngoài node (trong thực tế)
scp /tmp/etcd-backup.db backup-server:/backup/

# Hoặc giữ tạm trên node hiện tại
cp /tmp/etcd-backup.db /tmp/etcd-backup-copy.db
```

## Bước 4: Mô phỏng disaster — kill controlplane03

```bash
# Trên controlplane03:
sudo systemctl stop etcd

# Xóa data dir (mô phỏng disk failure)
sudo rm -rf /var/lib/etcd
```

## Bước 5: Kiểm tra cluster vẫn hoạt động (2/3 node)

```bash
# Từ controlplane01 hoặc controlplane02:
etcdctl endpoint health \
  --endpoints=https://192.168.56.11:2379,https://192.168.56.12:2379,https://192.168.56.13:2379
# https://192.168.56.11:2379 is healthy
# https://192.168.56.12:2379 is healthy
# https://192.168.56.13:2379 is unhealthy: failed to connect

# Cluster vẫn có quorum (2/3) → write vẫn hoạt động
etcdctl put /app/status "still-working"
# OK

etcdctl get /app/status
# still-working
```

**Kiểm tra**: Cluster 2 node vẫn healthy, write thành công.

## Bước 6: Restore controlplane03 từ snapshot

### Cách 1: Rejoin cluster (không cần restore — Raft sync)

```bash
# Trên controlplane03: chỉ cần start lại etcd — Raft sẽ sync data từ leader
sudo mkdir -p /var/lib/etcd
sudo systemctl start etcd

# Kiểm tra
etcdctl endpoint status --write-out=table
# 3 node đều started, controlplane03 đã sync data
```

> **Cách này đơn giản nhất** — chỉ cần restart etcd, Raft tự đồng bộ.

### Cách 2: Restore từ snapshot (khi cần recover data cũ)

```bash
# Trên controlplane03:
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd

# Restore từ snapshot
etcdctl snapshot restore /tmp/etcd-backup.db \
  --name=controlplane03 \
  --initial-cluster=controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380 \
  --initial-advertise-peer-urls=https://192.168.56.13:2380 \
  --initial-cluster-token=etcd-cluster-2026 \
  --data-dir=/var/lib/etcd

# Start etcd với --initial-cluster-state=existing
# (Sửa systemd unit hoặc start trực tiếp)
sudo systemctl start etcd
```

**Kiểm tra**: controlplane03 start, join cluster, data đồng bộ.

## Bước 7: Verify cluster 3 node

```bash
etcdctl endpoint status --write-out=table
# +----------------+------------------+---------+---------+-----------+
# |    ENDPOINT    |        ID        | VERSION | DB SIZE | IS LEADER |
# +----------------+------------------+---------+---------+-----------+
# | 192.168.56.11:2379  | 8e9e05c52164694d |  3.5.12 |  30 KB  |      true |
# | 192.168.56.12:2379  | 91bc3c398fb3c146 |  3.5.12 |  30 KB  |     false |
# | 192.168.56.13:2379  | fd422379fda50e85 |  3.5.12 |  30 KB  |     false |
# +----------------+------------------+---------+---------+-----------+

etcdctl endpoint health
# Cả 3 healthy

# Verify data
etcdctl get --prefix /app/
# /app/config
# production-settings
# /app/features
# feature-a,feature-b
# /app/status
# still-working
# /app/version
# v1.0.0
```

**Kiểm tra**: 3 node healthy, data đầy đủ.

## Bước 8: Mô phỏng quorum loss — kill 2 node

```bash
# Kill controlplane02 và controlplane03
# Trên controlplane02:
sudo systemctl stop etcd

# Trên controlplane03:
sudo systemctl stop etcd

# Từ controlplane01:
etcdctl endpoint health --endpoints=https://192.168.56.11:2379
# https://192.168.56.11:2379 is unhealthy: failed to commit proposal

# Write fail — quorum lost (1 < 2)
etcdctl put /test "quorum-lost"
# Error: etcdserver: request timed out
```

**Kiểm tra**: controlplane01 unhealthy, write fail (quorum lost).

## Bước 9: Restore toàn cluster từ snapshot

```bash
# Trên controlplane01:
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd

# Restore từ snapshot
etcdctl snapshot restore /tmp/etcd-backup.db \
  --name=controlplane01 \
  --initial-cluster=controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380 \
  --initial-advertise-peer-urls=https://192.168.56.11:2380 \
  --initial-cluster-token=etcd-cluster-2026 \
  --data-dir=/var/lib/etcd

# Restore trên controlplane02 (copy snapshot sang controlplane02 trước)
scp /tmp/etcd-backup.db controlplane02:/tmp/
# Trên controlplane02:
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd
etcdctl snapshot restore /tmp/etcd-backup.db \
  --name=controlplane02 \
  --initial-cluster=controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380 \
  --initial-advertise-peer-urls=https://192.168.56.12:2380 \
  --initial-cluster-token=etcd-cluster-2026 \
  --data-dir=/var/lib/etcd

# Restore trên controlplane03
scp /tmp/etcd-backup.db controlplane03:/tmp/
# Trên controlplane03:
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd
etcdctl snapshot restore /tmp/etcd-backup.db \
  --name=controlplane03 \
  --initial-cluster=controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380 \
  --initial-advertise-peer-urls=https://192.168.56.13:2380 \
  --initial-cluster-token=etcd-cluster-2026 \
  --data-dir=/var/lib/etcd

# Start etcd trên tất cả node (gần như đồng thời)
# Trên mỗi node:
sudo systemctl start etcd
```

## Bước 10: Verify cluster sau full restore

```bash
# Đợi ~5 giây cho cluster elect leader
etcdctl endpoint health
# Cả 3 healthy

etcdctl get --prefix /app/
# Data từ snapshot đã restore

# Lưu ý: /app/status = "still-working" (ghi sau snapshot) KHÔNG còn
# Vì snapshot được save trước khi ghi /app/status
```

**Kiểm tra**: Cluster 3 node healthy, data từ snapshot có, data ghi sau snapshot mất.

## Câu hỏi tự kiểm tra

1. Kill 1 node trong cluster 3 → cluster vẫn hoạt động. Kill 2 node → cluster die. Tại sao?
2. Khi restore 1 node, có cần restore từ snapshot không? Tại sao Raft sync là đủ?
3. Khi restore toàn cluster, tại sao cần restore trên **tất cả** node?
4. Data ghi **sau** snapshot có còn sau restore không? Tại sao?
5. `--initial-cluster-state` khi restore toàn cluster là `new` hay `existing`? Tại sao?

## Đáp án tham khảo

1. Quorum = (3/2)+1 = 2. Kill 1 node → 2 node sống = đủ quorum. Kill 2 node → 1 node sống < 2 = không đủ quorum → read-only.
2. Không cần. Raft tự sync data từ leader cho node mới join. Restore chỉ cần khi toàn cluster mất data.
3. Vì restore tạo data dir mới với fresh Raft state. Nếu chỉ restore 1 node, Raft state không khớp với node khác → conflict.
4. Không. Snapshot là point-in-time. Data ghi sau snapshot không có trong snapshot file.
5. `new` — vì restore tạo data dir mới, etcd khởi động như bootstrap cluster mới (fresh Raft term, fresh log).
