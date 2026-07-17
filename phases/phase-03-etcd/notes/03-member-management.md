# 03 — Member Management

## Member là gì

Mỗi etcd node trong cluster là một **member**. Mỗi member có:
- **Member ID**: unique 64-bit hex (hash từ name + peer URLs).
- **Name**: human-readable identifier.
- **Peer URLs**: URL để member khác kết nối.
- **Client URLs**: URL để client kết nối.

```bash
etcdctl member list --write-out=table
# +------------------+---------+-------+------------------------+------------------------+
# |        ID        | STATUS  | NAME  |       PEER ADDRS       |      CLIENT ADDRS      |
# +------------------+---------+-------+------------------------+------------------------+
# | 8e9e05c52164694d | started |controlplane01 | https://192.168.56.11:2380  | https://192.168.56.11:2379  |
# | 91bc3c398fb3c146 | started |controlplane02 | https://192.168.56.12:2380  | https://192.168.56.12:2379  |
# | fd422379fda50e85 | started |controlplane03 | https://192.168.56.13:2380  | https://192.168.56.13:2379  |
# +------------------+---------+-------+------------------------+------------------------+
```

## Thêm member vào cluster đang chạy

### Bước 1: Inform cluster về member mới

```bash
etcdctl member add controlplane04 \
  --peer-urls=https://192.168.56.24:2380

# Output:
# Member 7b8a... added to cluster 3a2b...
#
# ETCD_NAME="controlplane04"
# ETCD_INITIAL_CLUSTER="controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380,controlplane04=https://192.168.56.24:2380"
# ETCD_INITIAL_ADVERTISE_PEER_URLS="https://192.168.56.24:2380"
# ETCD_INITIAL_CLUSTER_STATE="existing"
```

> **Quan trọng**: `etcdctl member add` output chứa `ETCD_INITIAL_CLUSTER` với tất cả members và `ETCD_INITIAL_CLUSTER_STATE=existing`. Bạn **phải dùng** đúng output này cho `--initial-cluster` và `--initial-cluster-state` khi start node mới. etcd tính cluster ID bằng cách hash member set trong `--initial-cluster` — nếu chỉ chứa node đó, cluster ID sẽ khác → peer connection bị reject (cluster ID mismatch).

### Bước 2: Start controlplane04 với config từ `member add` output

```bash
etcd \
  --name=controlplane04 \
  --data-dir=/var/lib/etcd \
  --listen-peer-urls=https://192.168.56.24:2380 \
  --listen-client-urls=https://127.0.0.1:2379,https://192.168.56.24:2379 \
  --listen-metrics-urls=http://127.0.0.1:2381 \
  --initial-advertise-peer-urls=https://192.168.56.24:2380 \
  --advertise-client-urls=https://192.168.56.24:2379 \
  --initial-cluster=controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380,controlplane04=https://192.168.56.24:2380 \
  --initial-cluster-state=existing \
  --client-cert-auth=true \
  --trusted-ca-file=/etc/etcd/etcd-ca.pem \
  --cert-file=/etc/etcd/etcd-server.pem \
  --key-file=/etc/etcd/etcd-server-key.pem \
  --peer-client-cert-auth=true \
  --peer-trusted-ca-file=/etc/etcd/etcd-ca.pem \
  --peer-cert-file=/etc/etcd/etcd-peer.pem \
  --peer-key-file=/etc/etcd/etcd-peer-key.pem
```

> **Giống kubeadm**: kubeadm cũng dùng full cluster list từ `AddMemberAsLearner` response khi tạo static pod manifest cho join nodes. `--initial-cluster-state=existing` báo etcd rằng cluster đã tồn tại — etcd sẽ join thay vì bootstrap cluster mới.

### Bước 3: Verify

```bash
etcdctl member list --write-out=table
# Bây giờ thấy 4 member, controlplane04 status = started
```

### Quá trình bên trong

```
1. etcdctl member add → Leader ghi config mới vào Raft log
2. Leader replicate "new member" cho follower
3. Quorum commit → member mới ở trạng thái "unstarted"
4. controlplane04 start → kết nối peer URL → Leader sync data cho controlplane04
5. controlplane04 nhận đủ data → status chuyển sang "started"
```

> **Cảnh báo**: Không thêm quá 1 member cùng lúc. Thêm member thay đổi quorum — nếu thêm 2 member cùng lúc và 1 fail, cluster có thể bị stuck.

## Xóa member khỏi cluster

### Bước 1: Lấy Member ID

```bash
etcdctl member list
# 8e9e05c52164694d, started, controlplane01, https://192.168.56.11:2380, https://192.168.56.11:2379
# 91bc3c398fb3c146, started, controlplane02, https://192.168.56.12:2380, https://192.168.56.12:2379
# fd422379fda50e85, started, controlplane03, https://192.168.56.13:2380, https://192.168.56.13:2379
```

### Bước 2: Remove

```bash
etcdctl member remove 91bc3c398fb3c146
# Member 91bc3c398fb3c146 removed from cluster
```

### Bước 3: Stop controlplane02 (nếu chưa)

```bash
# Trên controlplane02:
sudo systemctl stop etcd
```

### Quá trình bên trong

```
1. etcdctl member remove → Leader ghi "remove member" vào Raft log
2. Quorum commit → member bị remove, cluster shrink từ 3 → 2
3. controlplane02 bị kick — nhận Raft message "you're not a member" → tự shutdown
4. Quorum mới = (2/2)+1 = 2 → cluster 2 node (chỉ chịu 0 failure!)
```

> **Cảnh báo**: Xóa member làm giảm quorum. Cluster 3 → 2 = không chịu failure. Nếu cần xóa 2 node, xóa 1 → add 1 mới → xóa 1 cũ (luôn giữ 3).

## Learner mode — thêm member an toàn

etcd 3.4+ hỗ trợ **learner** — member mới join như learner (không tính vào quorum), sync data xong rồi promote lên voting member.

```bash
# Add as learner
etcdctl member add controlplane04 \
  --peer-urls=https://192.168.56.24:2380 \
  --learner=true

# etcd-4 start, sync data, không ảnh hưởng quorum

# Check status — IS LEARNER = true
etcdctl endpoint status --write-out=table

# Promote learner → voting member
etcdctl member promote <member-id>
```

### Lợi ích của learner

| | Không learner | Có learner |
|---|---------------|------------|
| Quorum khi add | Tăng ngay (3→4, quorum 2→3) | Không đổi (learner không tính) |
| Risk | Member mới chậm → cluster chậm | Member mới chậm → không ảnh hưởng |
| Auto promote | Không | Có thể promote khi sync xong |

## Update member config

### Đổi peer URL

```bash
etcdctl member update <member-id> --peer-urls=https://192.168.56.11:2381
```

### Đổi client URL

Client URL không cần update qua `etcdctl` — chỉ cần restart etcd với `--advertise-client-urls` mới.

## Cluster reconfiguration — best practices

### Mở rộng cluster 3 → 5

```bash
# 1. Add controlplane04 (chỉ 1 lúc)
etcdctl member add controlplane04 --peer-urls=https://192.168.56.24:2380
# Start controlplane04 với --initial-cluster-state=existing
# Wait: etcdctl member list → controlplane04 = started

# 2. Add controlplane05 (sau khi controlplane04 đã sync)
etcdctl member add controlplane05 --peer-urls=https://192.168.56.25:2380
# Start controlplane05 với --initial-cluster-state=existing
# Wait: etcdctl member list → controlplane05 = started

# 3. Verify quorum = 3/5
etcdctl endpoint status --write-out=table
```

### Thu hẹp cluster 5 → 3

```bash
# 1. Remove etcd-5
etcdctl member remove <etcd-5-id>
# Stop etcd-5

# 2. Remove etcd-4
etcdctl member remove <etcd-4-id>
# Stop etcd-4

# 3. Verify quorum = 2/3
etcdctl endpoint status --write-out=table
```

> **Quan trọng**: Khi remove member, etcd trên node đó phải stop. Nếu không, nó sẽ liên tục retry kết nối và log error.

## Backup trước khi thay đổi membership

```bash
# Luôn snapshot trước khi add/remove member
etcdctl snapshot save pre-change.db
etcdctl snapshot status pre-change.db --write-out=table
```

## Liên hệ với Kubernetes

- **kubeadm** không hỗ trợ dynamic etcd membership — etcd chạy as static pod, thêm/xóa node cần `kubeadm` + manual etcdctl.
- **kubespray** hỗ trợ dynamic etcd membership — tự động `etcdctl member add` khi thêm master node.
- **Managed K8s** (EKS, GKE, AKS) — etcd được manage, user không cần quan tâm membership.
- Khi **xóa master node**, cần remove etcd member trước, rồi mới xóa node — nếu không etcd cluster bị stuck (member chết nhưng vẫn trong list).
- **etcd defrag** sau khi remove member — data dir có thể có fragmented space.
