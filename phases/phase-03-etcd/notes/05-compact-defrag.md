# 05 — Compact & Defrag

## MVCC — Multi-Version Concurrency Control

etcd v3 dùng **MVCC** — mỗi key giữ **nhiều version** (revision). Mỗi write tạo revision mới, revision cũ **không bị xóa ngay**.

```
etcdctl put /foo "v1"   → revision 1: /foo = "v1"
etcdctl put /foo "v2"   → revision 2: /foo = "v2"  (revision 1 vẫn còn)
etcdctl put /foo "v3"   → revision 3: /foo = "v3"  (revision 1, 2 vẫn còn)
etcdctl put /bar "x"    → revision 4: /bar = "x"

# Đọc version cũ:
etcdctl get /foo --rev=1
# "v1"

etcdctl get /foo --rev=2
# "v2"
```

### Tại sao cần MVCC?

- **Watch**: Client watch từ revision cũ — cần history để gửi event. `etcdctl watch /foo --rev=1` sẽ nhận tất cả thay đổi từ revision 1.
- **Transaction**: Compare-and-swap cần đọc giá trị cũ.
- **Concurrency**: Read không block write, write không block read.

### Bù lại: Data dir phình to

```
Revision 1: /foo = "v1"     ← cũ nhưng vẫn nằm trong boltdb
Revision 2: /foo = "v2"     ← cũ nhưng vẫn nằm trong boltdb
Revision 3: /foo = "v3"     ← current
Revision 4: /bar = "x"      ← current

→ boltdb giữ 4 entry, dù /foo chỉ cần revision 3
→ Sau 10000 write, boltdb phình — cần compact
```

## Compact — xóa revision cũ

**Compact** = xóa tất cả revision **cũ hơn** revision chỉ định. Giữ lại revision mới nhất + history từ compact point.

```bash
# Xem revision hiện tại
etcdctl endpoint status --write-out=table
# REVISION: 12345

# Compact đến revision 12300 (xóa revision 1 → 12299)
etcdctl compact 12300
# compacted revision 12300
```

### Trước compact:

```
Revision 1: /foo = "v1"
Revision 2: /foo = "v2"
...
Revision 12300: /foo = "v12300"
Revision 12301: /bar = "x"
...
Revision 12345: /baz = "y"  ← current
```

### Sau compact 12300:

```
Revision 12300: /foo = "v12300"   ← compact point (giữ)
Revision 12301: /bar = "x"
...
Revision 12345: /baz = "y"  ← current

→ Revision 1 → 12299 bị xóa khỏi boltdb
→ Watch từ revision < 12300 sẽ fail (compacted)
```

> **Cảnh báo**: Compact là **không thể undo**. Sau khi compact, không thể đọc revision cũ. Đảm bảo không có watcher nào cần revision cũ.

### Auto-compaction

Thay vì compact thủ công, etcd hỗ trợ auto-compaction:

```bash
# Compact theo giờ — giữ history 1 giờ
--auto-compaction-mode=periodic
--auto-compaction-retention=1h

# Compact theo revision — giữ 1000 revision gần nhất
--auto-compaction-mode=revision
--auto-compaction-retention=1000
```

| Mode | Retention | Ý nghĩa |
|------|-----------|---------|
| `periodic` | `1h` | Compact mỗi giờ, giữ revision trong 1 giờ gần nhất |
| `revision` | `1000` | Compact khi revision > 1000, giữ 1000 revision gần nhất |

> **Kubernetes recommendation**: `periodic` với `5m` hoặc `1h`. Kubernetes watch thường reconnect nhanh, không cần history lâu.

## Defrag — giải phóng disk space

**Compact xóa revision cũ khỏi boltdb logic, nhưng disk space không được giải phóng ngay.** boltdb (B+ tree) để lại free page trong file. **Defrag** reclaim free page → giảm file size.

```bash
# Trước defrag:
du -sh /var/lib/etcd/member/snap/db
# 500M

# Defrag
etcdctl defrag

# Sau defrag:
du -sh /var/lib/etcd/member/snap/db
# 150M  ← giảm 350M
```

### Compact vs Defrag

| | Compact | Defrag |
|---|---------|--------|
| Làm gì | Xóa revision cũ khỏi boltdb | Reclaim free space trong boltdb file |
| Giảm data logic | Có (revision cũ không đọc được) | Không |
| Giảm disk space | Không ngay (free page) | Có |
| Block cluster | Không | **Có** (node đang defrag không serve request) |
| Tần suất | Thường (auto hoặc manual) | Định kỳ (sau compact) |

### Defrag an toàn

Defrag **block** etcd node — node đang defrag không nhận request. Trong cluster, defrag từng node:

```bash
# Defrag từng node — không ảnh hưởng cluster
etcdctl defrag --endpoints=https://10.0.0.1:2379
# Wait for completion

etcdctl defrag --endpoints=https://10.0.0.2:2379
# Wait for completion

etcdctl defrag --endpoints=https://10.0.0.3:2379
# Wait for completion

# Hoặc defrag tất cả (etcdctl sẽ làm từng cái):
etcdctl defrag --cluster
```

> **Quan trọng**: Không defrag tất cả node cùng lúc. `etcdctl defrag --cluster` làm tuần tự — an toàn. Nhưng nếu defrag thủ công, phải làm từng node.

## Quy trình maintenance chuẩn

```bash
#!/bin/bash
# etcd-maintenance.sh

# 1. Kiểm tra status trước
echo "=== Before maintenance ==="
etcdctl endpoint status --write-out=table
du -sh /var/lib/etcd/member/snap/db

# 2. Lấy revision hiện tại
REV=$(etcdctl endpoint status --write-out=json | jq -r '.[0].Status.header.revision')
echo "Current revision: ${REV}"

# 3. Compact
echo "Compacting to revision ${REV}..."
etcdctl compact "${REV}"

# 4. Defrag từng node
echo "Defragmenting..."
etcdctl defrag --cluster

# 5. Kiểm tra status sau
echo "=== After maintenance ==="
etcdctl endpoint status --write-out=table
du -sh /var/lib/etcd/member/snap/db
```

### Output ví dụ

```
=== Before maintenance ===
+----------+----------+---------+---------+
| ENDPOINT | REVISION | DB SIZE | IS LEADER|
+----------+----------+---------+---------+
| 10.0.0.1 |  123456  |  500 MB |   true  |
| 10.0.0.2 |  123456  |  500 MB |  false  |
| 10.0.0.3 |  123456  |  500 MB |  false  |
+----------+----------+---------+---------+
500M  /var/lib/etcd/member/snap/db

Current revision: 123456
Compacting to revision 123456...
compacted revision 123456
Defragmenting...

=== After maintenance ===
+----------+----------+---------+---------+
| ENDPOINT | REVISION | DB SIZE | IS LEADER|
+----------+----------+---------+---------+
| 10.0.0.1 |  123456  |  150 MB |   true  |
| 10.0.0.2 |  123456  |  150 MB |  false  |
| 10.0.0.3 |  123456  |  150 MB |  false  |
+----------+----------+---------+---------+
150M  /var/lib/etcd/member/snap/db
```

## Quota — etcd data dir giới hạn

etcd có **backend quota** — nếu data dir vượt quota, etcd vào **read-only mode** (chỉ read, không write).

```bash
# Default quota: 2GB
--quota-backend-bytes=2147483648  # 2GB

# Production Kubernetes: 8GB
--quota-backend-bytes=8589934592  # 8GB
```

### Khi vượt quota

```
etcd log:
  "etcdserver: mvcc: database space exceeded"

etcdctl put /foo "bar"
# Error: etcdserver: mvcc: database space exceeded

# Cluster ở read-only — API Server không ghi được
# kubectl create → Error
```

### Recovery khi vượt quota

```bash
# 1. Compact
etcdctl compact <current-revision>

# 2. Defrag
etcdctl defrag --cluster

# 3. Kiểm tra size
etcdctl endpoint status --write-out=table
# DB SIZE giảm → dưới quota

# 4. etcd tự thoát read-only mode
# (hoặc restart etcd nếu cần)
```

> **Best practice**: Monitor `etcd_mvcc_db_total_size_in_bytes` metric. Alert khi > 70% quota. Compact + defrag khi > 80%.

## Metric quan trọng

```bash
# Size
etcd_mvcc_db_total_size_in_bytes       # Tổng size boltdb
etcd_mvcc_db_total_size_in_use_in_bytes # Size đang dùng (sau compact)

# Compact
etcd_mvcc_hash_compact_total           # Số lần compact

# Quota
etcd_server_quota_backend_bytes        # Quota limit

# Defrag
etcd_server_defrag_total               # Số lần defrag
```

```bash
# Prometheus alert rule:
# alert: EtcdDatabaseSpace
# expr: (etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes) > 0.8
# for: 10m
# labels:
#   severity: critical
```

## Liên hệ với Kubernetes

- **kubeadm** set `--auto-compaction-retention=5m` mặc định (từ K8s 1.15+).
- **Large cluster** (nhiều namespace, nhiều pod) → etcd data phình nhanh → cần compact/defrag thường xuyên hơn.
- **Namespace deletion** tạo nhiều revision (xóa tất cả resource trong namespace) → compact sau khi cleanup.
- **Watch** từ controller — nếu compact xóa revision mà controller đang watch, controller nhận `compacted` error → reconnect từ revision mới (K8s client library tự xử lý).
- **etcd space exceeded** là lỗi nghiêm trọng — cluster read-only, mọi `kubectl` command fail. Monitor + alert là bắt buộc.
