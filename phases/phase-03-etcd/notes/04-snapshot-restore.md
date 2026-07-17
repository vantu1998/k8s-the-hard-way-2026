# 04 — Snapshot & Restore

## Snapshot là gì

Snapshot = **point-in-time dump** của toàn bộ etcd data. etcd tạo snapshot định kỳ (mỗi `--snapshot-count` transaction, mặc định 10000) hoặc thủ công bằng `etcdctl snapshot save`.

```
etcd data dir:
  WAL: [entry 1] [entry 2] ... [entry 10000]
                                    │
                                    ▼
                              Snapshot #1 (dump key-value store)
                                  
  WAL: [entry 10001] [entry 10002] ... [entry 20000]
                                              │
                                              ▼
                                        Snapshot #2
```

**Tại sao cần snapshot?**
- **Backup**: Snapshot = backup toàn bộ cluster state.
- **Recovery**: Khi etcd data hỏng, restore từ snapshot.
- **WAL replay nhanh hơn**: Snapshot thay vì replay toàn bộ WAL từ đầu.
- **Migrate**: Snapshot sang cluster mới (khác IP, khác cert).

## Snapshot save

### Lệnh cơ bản

```bash
etcdctl snapshot save /backup/etcd-snapshot.db

# Output:
# Snapshot saved at /backup/etcd-snapshot.db
```

### Với TLS

```bash
etcdctl \
  --endpoints=https://10.0.0.1:2379 \
  --cacert=/etc/etcd/etcd-ca.pem \
  --cert=/etc/etcd/etcd-client.pem \
  --key=/etc/etcd/etcd-client-key.pem \
  snapshot save /backup/etcd-snapshot.db
```

### Snapshot từ một node cụ thể

```bash
# Snapshot từ leader (đảm bảo data mới nhất)
etcdctl \
  --endpoints=https://10.0.0.1:2379 \
  --cacert=/etc/etcd/etcd-ca.pem \
  --cert=/etc/etcd/etcd-client.pem \
  --key=/etc/etcd/etcd-client-key.pem \
  snapshot save /backup/etcd-snapshot.db
```

> **Quan trọng**: Snapshot có thể lấy từ **bất kỳ node nào** — tất cả node đều có data giống nhau (Raft guarantee). Nhưng lấy từ leader đảm bảo data mới nhất (follower có thể slightly behind).

### Kiểm tra snapshot

```bash
etcdctl snapshot status /backup/etcd-snapshot.db --write-out=table

# +----------+----------+------------+------------+
# |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
# +----------+----------+------------+------------+
# | 0x2a3b...|   12345  |       342  |   2.1 MB   |
# +----------+----------+------------+------------+
```

| Field | Ý nghĩa |
|-------|---------|
| Hash | SHA hash của snapshot — verify integrity |
| Revision | Revision cao nhất trong snapshot |
| Total keys | Số key |
| Total size | Size snapshot file |

## Snapshot restore

### Khi nào cần restore?

- **Data corruption**: etcd data dir hỏng (disk failure, file system error).
- **Disaster recovery**: Mất toàn bộ etcd node.
- **Migrate cluster**: Chuyển etcd sang infrastructure mới.
- **Rollback**: Undo thay đổi không mong muốn (vd: xóa namespace nhầm).

### Restore — tạo data dir mới từ snapshot

```bash
# 1. Stop etcd trên tất cả node
sudo systemctl stop etcd

# 2. Xóa data dir cũ (cẩn thận!)
sudo rm -rf /var/lib/etcd

# 3. Restore từ snapshot
etcdctl snapshot restore /backup/etcd-snapshot.db \
  --name=etcd-1 \
  --initial-cluster=etcd-1=https://10.0.0.1:2380,etcd-2=https://10.0.0.2:2380,etcd-3=https://10.0.0.3:2380 \
  --initial-advertise-peer-urls=https://10.0.0.1:2380 \
  --initial-cluster-token=etcd-cluster \
  --data-dir=/var/lib/etcd

# Output:
# { "member": { "id": "..." }, "cluster": { "id": "..." } }
```

### Giải thích restore flags

| Flag | Ý nghĩa |
|------|---------|
| `--name` | Tên node — phải khớp với `--initial-cluster` |
| `--initial-cluster` | Danh sách tất cả member + peer URL |
| `--initial-advertise-peer-urls` | Peer URL của node này |
| `--initial-cluster-token` | Token — phải giống lúc bootstrap |
| `--data-dir` | Data dir mới (restore ghi data vào đây) |

> **Quan trọng**: Restore **không giữ** Raft metadata (term, vote, commit index). Nó tạo data dir mới với snapshot data + fresh Raft state. Cluster khởi động lại như bootstrap mới.

### Restore trên tất cả node

```bash
# Trên etcd-1:
etcdctl snapshot restore /backup/etcd-snapshot.db \
  --name=etcd-1 \
  --initial-cluster=etcd-1=https://10.0.0.1:2380,etcd-2=https://10.0.0.2:2380,etcd-3=https://10.0.0.3:2380 \
  --initial-advertise-peer-urls=https://10.0.0.1:2380 \
  --data-dir=/var/lib/etcd

# Trên etcd-2:
etcdctl snapshot restore /backup/etcd-snapshot.db \
  --name=etcd-2 \
  --initial-cluster=etcd-1=https://10.0.0.1:2380,etcd-2=https://10.0.0.2:2380,etcd-3=https://10.0.0.3:2380 \
  --initial-advertise-peer-urls=https://10.0.0.2:2380 \
  --data-dir=/var/lib/etcd

# Trên etcd-3:
etcdctl snapshot restore /backup/etcd-snapshot.db \
  --name=etcd-3 \
  --initial-cluster=etcd-1=https://10.0.0.1:2380,etcd-2=https://10.0.0.2:2380,etcd-3=https://10.0.0.3:2380 \
  --initial-advertise-peer-urls=https://10.0.0.3:2380 \
  --data-dir=/var/lib/etcd

# Start etcd trên tất cả node
sudo systemctl start etcd
```

> **Lưu ý**: Mỗi node restore với `--name` và `--initial-advertise-peer-urls` của chính nó. `--initial-cluster` giống nhau trên tất cả.

### Restore chỉ 1 node (không cần stop cluster)

Nếu chỉ 1 node hỏng, không cần restore toàn cluster:

```bash
# 1. Remove member khỏi cluster (từ node khác)
etcdctl member remove <etcd-3-id>

# 2. Trên etcd-3: stop etcd, xóa data dir
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd

# 3. Restore snapshot
etcdctl snapshot restore /backup/etcd-snapshot.db \
  --name=etcd-3 \
  --initial-cluster=etcd-1=https://10.0.0.1:2380,etcd-2=https://10.0.0.2:2380,etcd-3=https://10.0.0.3:2380 \
  --initial-advertise-peer-urls=https://10.0.0.3:2380 \
  --data-dir=/var/lib/etcd

# 4. Start etcd với --initial-cluster-state=existing
sudo systemctl start etcd

# 5. Re-add member nếu cần
etcdctl member add etcd-3 --peer-urls=https://10.0.0.3:2380
```

## Backup strategy cho Kubernetes

### Cron job backup

```bash
#!/bin/bash
# /etc/cron.d/etcd-backup
# Backup mỗi 1 giờ

BACKUP_DIR="/backup/etcd"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RETENTION=24  # giữ 24 backup (24 giờ)

mkdir -p "${BACKUP_DIR}"

etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  snapshot save "${BACKUP_DIR}/etcd-${TIMESTAMP}.db"

# Xóa backup cũ
ls -t "${BACKUP_DIR}"/etcd-*.db | tail -n +$((RETENTION + 1)) | xargs -r rm

echo "Backup saved: ${BACKUP_DIR}/etcd-${TIMESTAMP}.db"
```

### Verify backup

```bash
# Luôn verify sau khi backup
etcdctl snapshot status /backup/etcd/etcd-latest.db --write-out=table

# Verify hash (integrity)
etcdctl snapshot status /backup/etcd/etcd-latest.db --write-out=json | jq .hash
```

### Backup ra ngoài node

```bash
# Sync backup ra S3/GCS
aws s3 sync /backup/etcd/ s3://my-bucket/etcd-backup/

# Hoặc rsync ra backup server
rsync -avz /backup/etcd/ backup-server:/backup/etcd/
```

> **Best practice**: Backup không chỉ nằm trên etcd node — nếu node chết, backup cũng mất. Luôn copy ra ngoài.

## Restore scenario cho Kubernetes

### Scenario 1: Mất 1 etcd node

```
Cluster: etcd-1 (Leader), etcd-2, etcd-3
etcd-3 disk failure → data lost

→ Không cần restore snapshot!
→ etcd-1, etcd-2 vẫn có data
→ Remove etcd-3, re-add → Raft sync data cho etcd-3
```

### Scenario 2: Mất 2 etcd node (quorum lost)

```
Cluster: etcd-1 (Leader), etcd-2, etcd-3
etcd-2 + etcd-3 crash → chỉ còn etcd-1 → quorum lost

→ etcd-1 vào read-only (1 < 2 quorum)
→ Cần restore toàn cluster từ snapshot
→ Stop etcd-1, restore snapshot, start tất cả
```

### Scenario 3: Mất toàn bộ cluster

```
Cluster: etcd-1, etcd-2, etcd-3 — tất cả crash, disk destroyed

→ Restore từ backup external
→ Restore trên 3 node mới (hoặc 3 node cũ với disk mới)
→ Start etcd → cluster mới với data từ snapshot
```

### Scenario 4: Xóa namespace nhầm

```
kubectl delete namespace production (oops!)

→ Option 1: Restore snapshot cũ (rollback toàn cluster — có thể mất data mới)
→ Option 2: Dùng `etcdctl get --prefix /registry/namespaces/production` 
  để xem data cũ (nếu chưa compact)
→ Option 3: Tạo namespace lại + re-apply YAML (nếu có GitOps)
```

> **Lưu ý**: Restore snapshot = rollback **toàn bộ cluster** về thời điểm snapshot. Không thể restore riêng 1 resource. Đây là lý do cần backup thường xuyên (giảm data loss).

## Liên hệ với Kubernetes

- **kubeadm**: `kubeadm etcd snapshot save` — wrapper quanh `etcdctl snapshot save`.
- **Velero**: Backup Kubernetes resource (YAML) + PV — không backup etcd trực tiếp, nhưng có thể restore resource.
- **etcdctl** là **cách duy nhất** backup/restore etcd data — không có K8s native way.
- **Backup frequency**: Production nên backup mỗi 1-5 phút (dùng etcdctl hoặc tool như `etcd-backup-operator`).
- **Test restore**: Luôn test restore trong môi trường lab — backup không test = không có backup.
