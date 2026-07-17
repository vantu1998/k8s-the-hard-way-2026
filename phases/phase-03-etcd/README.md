# Phase 3 — etcd

> Hiểu etcd đủ để vận hành: bootstrap cluster 3 node, snapshot/restore, debug dữ liệu Kubernetes bên trong etcd.
>
> **Mục tiêu**: Bootstrap được etcd 3 node với mTLS. Snapshot + restore thành công. Đọc được dữ liệu Kubernetes trong etcd. Giải thích được Raft quorum.

## Cấu trúc thư mục

```
phase-03-etcd/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-etcd-architecture.md
│   ├── 02-raft-consensus.md
│   ├── 03-member-management.md
│   ├── 04-snapshot-restore.md
│   ├── 05-compact-defrag.md
│   └── 06-k8s-data-in-etcd.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-bootstrap-cluster.md
│   ├── 02-etcdctl-operations.md
│   ├── 03-snapshot-restore.md
│   ├── 04-k8s-data-in-etcd.md
│   ├── 05-compact-defrag.md
│   └── 06-leader-election.md
└── scripts/                   # Helper scripts
    ├── bootstrap-etcd.sh
    ├── snapshot-restore.sh
    └── etcd-ops.sh
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — Kiến trúc etcd: Raft protocol, leader election, log replication, etcd v3 API (gRPC), cấu hình URLs
- [ ] 02 — Raft Consensus: Term, log entry, commit index, leader/follower/candidate, quorum = (N/2)+1
- [ ] 03 — Member Management: `etcdctl member add/remove/list`, thêm/xóa node, rebalance
- [ ] 04 — Snapshot & Restore: `etcdctl snapshot save/restore`, disaster recovery, restore tạo data dir mới
- [ ] 05 — Compact & Defrag: MVCC history, compact xóa revision cũ, defrag giải phóng disk, auto-compaction
- [ ] 06 — Dữ liệu Kubernetes trong etcd: Key prefix `/registry/`, single source of truth, đọc raw data

### Thực hành (exercises/)

- [ ] 01 — Bootstrap etcd cluster 3 node với mTLS (peer URL + client URL)
- [ ] 02 — Dùng `etcdctl` put/get/delete key, xem status, endpoint health
- [ ] 03 — Snapshot etcd, kill 1 node, restore từ snapshot, rejoin cluster
- [ ] 04 — `etcdctl get --prefix /registry/` trên cluster K8s đang chạy, đếm số key
- [ ] 05 — Compact + defrag, quan sát disk usage trước/sau
- [ ] 06 — Giết leader, quan sát election mới trong log

### Checkpoint hoàn thành phase

- [ ] Bootstrap được etcd 3 node với mTLS
- [ ] Snapshot + restore thành công, cluster rejoin
- [ ] Đọc được dữ liệu Kubernetes trong etcd bằng `etcdctl get --prefix`
- [ ] Giải thích được Raft quorum và tại sao 3 node chịu được 1 failure

## Yêu cầu môi trường

- 3 Linux VMs (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên tất cả VMs
- Packages: `etcd`, `etcdctl` (v3.5+), `jq`, `curl`
- Đã hoàn thành Phase 2 (có etcd CA + etcd peer cert sẵn)
