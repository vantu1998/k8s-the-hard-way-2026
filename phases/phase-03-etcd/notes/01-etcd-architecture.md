# 01 — Kiến trúc etcd

## etcd là gì

etcd = **distributed key-value store** — cơ sở dữ liệu phân tán, strongly consistent, dùng để lưu trữ **toàn bộ state** của Kubernetes cluster. Mọi thay đổi (tạo pod, xóa service, update deployment) đều ghi vào etcd.

```
kubectl create deployment nginx
       │
       ▼
  API Server
       │
       ▼
    etcd  ← single source of truth
       │
       ▼
  (watch event)
       │
       ▼
  Controller/Kubelet react
```

**Tại sao Kubernetes chọn etcd?**
- **Consistent** (CP trong CAP) — luôn trả data đúng, không trả data cũ.
- **Highly available** — cluster 3+ node, chịu được failure.
- **Watch API** — client subscribe thay đổi (K8s controller pattern dựa vào cái này).
- **Fast** — Go + gRPC, ~10k writes/sec trên hardware tốt.

## Kiến trúc tổng quan

```
┌─────────────────────────────────────────────┐
│                etcd Node                     │
│                                              │
│  ┌──────────────┐    ┌──────────────┐       │
│  │  gRPC Server │    │  Raft Engine │       │
│  │  (port 2379) │◄──►│  (port 2380) │       │
│  │              │    │              │       │
│  │  Client API  │    │  Leader Elect│       │
│  │  (put/get/   │    │  Log Replicate│      │
│  │   watch)     │    │              │       │
│  └──────┬───────┘    └──────┬───────┘       │
│         │                     │              │
│         ▼                     ▼              │
│  ┌─────────────────────────────────┐        │
│  │         Storage (WAL + Snap)    │        │
│  │  /var/lib/etcd/                 │        │
│  │  ├── member/wal/ (write-ahead)  │        │
│  │  └── member/snap/ (snapshot)    │        │
│  └─────────────────────────────────┘        │
└─────────────────────────────────────────────┘
```

### Các thành phần chính

| Thành phần | Vai trò |
|-----------|---------|
| **gRPC Server** | Nhận client request (port 2379). Xử lý put/get/delete/watch. |
| **Raft Engine** | Đồng bộ state giữa các node (port 2380). Leader election, log replication. |
| **WAL (Write-Ahead Log)** | Mọi write ghi vào WAL trước khi apply. Crash recovery — replay WAL. |
| **Snapshot** | Point-in-time dump của data. Giảm thời gian replay WAL khi restart. |
| **Storage (boltdb)** | Embedded key-value store (B+ tree). Lưu data đã commit. |

## Hai loại URL — quan trọng

etcd có **2 loại connection**, mỗi loại có URL riêng:

### 1. Client URL (`--listen-client-urls`, `--advertise-client-urls`)

Client (kube-apiserver, etcdctl) kết nối đến etcd qua URL này.

```
kube-apiserver ──► etcd:2379 (client URL)
etcdctl        ──► etcd:2379 (client URL)
```

- `--listen-client-urls`: etcd lắng nghe ở đâu (interface:port).
- `--advertise-client-urls`: URL mà client dùng để kết nối (thường là IP node).

```bash
# Ví dụ:
--listen-client-urls=https://0.0.0.0:2379
--advertise-client-urls=https://10.0.0.1:2379
```

### 2. Peer URL (`--listen-peer-urls`, `--initial-advertise-peer-urls`)

etcd node kết nối với nhau qua URL này (Raft communication).

```
etcd-1 ◄──► etcd-2  (peer URL, port 2380)
etcd-1 ◄──► etcd-3  (peer URL, port 2380)
etcd-2 ◄──► etcd-3  (peer URL, port 2380)
```

- `--listen-peer-urls`: etcd lắng nghe peer connection ở đâu.
- `--initial-advertise-peer-urls`: URL mà peer khác dùng để kết nối.

```bash
# Ví dụ:
--listen-peer-urls=https://0.0.0.0:2380
--initial-advertise-peer-urls=https://10.0.0.1:2380
```

### Tóm tắt URL config

| Flag | Dùng cho | Port |
|------|----------|------|
| `--listen-client-urls` | etcd lắng nghe client | 2379 |
| `--advertise-client-urls` | Client kết nối đến | 2379 |
| `--listen-peer-urls` | etcd lắng nghe peer | 2380 |
| `--initial-advertise-peer-urls` | Peer kết nối đến | 2380 |
| `--initial-cluster` | Danh sách tất cả peer URL | 2380 |

## etcd v2 vs etcd v3

| | etcd v2 | etcd v3 |
|---|---------|---------|
| API | REST/JSON | gRPC (+ REST gateway) |
| Data model | Hierarchical keys | Flat key-value + prefix |
| Watch | Long polling | gRPC stream (efficient) |
| Transactions | No | Compare-and-swap (Txn) |
| MVCC | No | Yes — giữ revision history |
| TTL | Per-key TTL | Lease (renewable) |
| Kubernetes | ≤ 1.11 | ≥ 1.12 (current) |

> **Quan trọng**: `etcdctl` mặc định dùng v3 API. Nếu cần v2, set `ETCDCTL_API=2`. Kubernetes hiện tại **chỉ dùng v3**.

```bash
# etcdctl v3 (default)
etcdctl put foo bar
etcdctl get foo

# etcdctl v2 (legacy)
ETCDCTL_API=2 etcdctl set foo bar
ETCDCTL_API=2 etcdctl get foo
```

## Cài đặt etcd

### Cài từ binary

```bash
ETCD_VERSION="v3.5.12"
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
  | tar xz -C /tmp
sudo cp /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd /usr/local/bin/
sudo cp /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcdctl /usr/local/bin/

# Kiểm tra
etcd --version
# etcd Version: 3.5.12

etcdctl version
# etcdctl Version: 3.5.12
```

### Cài qua package manager (Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y etcd-server etcd-client
```

> **Lưu ý**: Package `etcd` từ Ubuntu repo thường cũ hơn. Khuyến nghị dùng binary từ GitHub release để có version mới nhất.

## etcdctl — công cụ chính

`etcdctl` là CLI giao tiếp với etcd qua gRPC. Cần chỉ định **endpoint** và **cert** khi etcd dùng TLS.

### Cú pháp cơ bản

```bash
etcdctl \
  --endpoints=https://10.0.0.1:2379 \
  --cacert=etcd-ca.pem \
  --cert=etcd-client.pem \
  --key=etcd-client-key.pem \
  <command>
```

### Các lệnh thường dùng

```bash
# Health check
etcdctl endpoint health

# Cluster status
etcdctl endpoint status --write-out=table

# Member list
etcdctl member list --write-out=table

# CRUD
etcdctl put /foo "bar"
etcdctl get /foo
etcdctl del /foo

# Get theo prefix
etcdctl get --prefix /registry/ --keys-only

# Snapshot
etcdctl snapshot save backup.db
etcdctl snapshot status backup.db --write-out=table

# Compact + Defrag
etcdctl compact <revision>
etcdctl defrag
```

### Environment variables

Thay vì truyền flags mỗi lần, dùng env vars:

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://10.0.0.1:2379
export ETCDCTL_CACERT=etcd-ca.pem
export ETCDCTL_CERT=etcd-client.pem
export ETCDCTL_KEY=etcd-client-key.pem

# Sau đó gọi ngắn gọn
etcdctl put foo bar
etcdctl get foo
```

## mTLS — mutual TLS

etcd trong Kubernetes **luôn** dùng mTLS cho cả client và peer connection.

```
                    mTLS
Client ─────────────────────► etcd
       cert + key              verify client cert

                    mTLS
etcd-1 ─────────────────────► etcd-2
       peer cert + key         verify peer cert
```

### Cert cần cho etcd

| Cert | Dùng cho | Ký bởi |
|------|----------|--------|
| `etcd-server.pem` | Server cert cho client connection | etcd CA |
| `etcd-server-key.pem` | Private key cho server cert | |
| `etcd-peer.pem` | mTLS giữa etcd members | etcd CA |
| `etcd-peer-key.pem` | Private key cho peer cert | |
| `etcd-ca.pem` | CA cert — verify tất cả etcd cert | self-signed |
| `etcd-healthcheck-client.pem` | Client cert cho kube-apiserver health check | etcd CA |
| `apiserver-etcd-client.pem` | Client cert cho kube-apiserver gọi etcd | etcd CA |

### Config flags cho mTLS

```bash
# Client TLS
--client-cert-auth=true \
--trusted-ca-file=etcd-ca.pem \
--cert-file=etcd-server.pem \
--key-file=etcd-server-key.pem \

# Peer TLS
--peer-client-cert-auth=true \
--peer-trusted-ca-file=etcd-ca.pem \
--peer-cert-file=etcd-peer.pem \
--peer-key-file=etcd-peer-key.pem \
```

| Flag | Ý nghĩa |
|------|---------|
| `--client-cert-auth=true` | Yêu cầu client trình cert (mTLS) |
| `--trusted-ca-file` | CA để verify client cert |
| `--cert-file` | Server cert trình cho client |
| `--key-file` | Private key cho server cert |
| `--peer-client-cert-auth=true` | Yêu cầu peer trình cert (mTLS giữa etcd nodes) |
| `--peer-trusted-ca-file` | CA để verify peer cert |
| `--peer-cert-file` | Cert trình cho peer khác |
| `--peer-key-file` | Private key cho peer cert |

## Data directory

etcd lưu data trong `--data-dir` (mặc định: `/var/lib/etcd/` hoặc `default.etcd/`).

```
/var/lib/etcd/
└── member/
    ├── wal/                # Write-Ahead Log
    │   ├── 0000000000000000-0000000000000000.wal
    │   └── 0.lock
    ├── snap/               # Snapshot
    │   ├── 0000000000000001-0000000000000001.snap
    │   └── db              # boltdb file (data đã commit)
    └── id                  # File chứa cluster ID + member ID
```

| File | Vai trò |
|------|---------|
| `wal/*.wal` | Write-ahead log — mọi write ghi đây trước |
| `snap/*.snap` | Snapshot metadata |
| `snap/db` | boltdb — key-value store thực tế |
| `id` | Member ID + cluster ID |

## etcd chạy như thế nào trong Kubernetes

### Static Pod (kubeadm)

kubeadm chạy etcd như **static pod** — manifest trong `/etc/kubernetes/manifests/etcd.yaml`:

```yaml
# /etc/kubernetes/manifests/etcd.yaml (rút gọn)
apiVersion: v1
kind: Pod
metadata:
  name: etcd
  namespace: kube-system
spec:
  containers:
  - name: etcd
    command:
    - etcd
    - --advertise-client-urls=https://10.0.0.1:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --client-cert-auth=true
    - --data-dir=/var/lib/etcd
    - --initial-advertise-peer-urls=https://10.0.0.1:2380
    - --initial-cluster=master1=https://10.0.0.1:2380
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --listen-client-urls=https://127.0.0.1:2379,https://10.0.0.1:2379
    - --listen-peer-urls=https://10.0.0.1:2380
    - --name=master1
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-client-cert-auth=true
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    volumeMounts:
    - mountPath: /var/lib/etcd
      name: etcd-data
    - mountPath: /etc/kubernetes/pki/etcd
      name: etcd-certs
  volumes:
  - hostPath:
      path: /etc/kubernetes/pki/etcd
      type: DirectoryOrCreate
    name: etcd-certs
  - hostPath:
      path: /var/lib/etcd
      type: DirectoryOrCreate
    name: etcd-data
```

### External etcd

Khi chạy etcd ngoài cluster (không phải static pod), etcd chạy như **systemd service**:

```ini
# /etc/systemd/system/etcd.service
[Unit]
Description=etcd
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \
  --name=etcd-1 \
  --data-dir=/var/lib/etcd \
  --listen-client-urls=https://0.0.0.0:2379 \
  --advertise-client-urls=https://10.0.0.1:2379 \
  --listen-peer-urls=https://0.0.0.0:2380 \
  --initial-advertise-peer-urls=https://10.0.0.1:2380 \
  --initial-cluster=etcd-1=https://10.0.0.1:2380,etcd-2=https://10.0.0.2:2380,etcd-3=https://10.0.0.3:2380 \
  --initial-cluster-state=new \
  --client-cert-auth=true \
  --trusted-ca-file=/etc/etcd/etcd-ca.pem \
  --cert-file=/etc/etcd/etcd-server.pem \
  --key-file=/etc/etcd/etcd-server-key.pem \
  --peer-client-cert-auth=true \
  --peer-trusted-ca-file=/etc/etcd/etcd-ca.pem \
  --peer-cert-file=/etc/etcd/etcd-peer.pem \
  --peer-key-file=/etc/etcd/etcd-peer-key.pem
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Các flag quan trọng khác

| Flag | Mặc định | Ý nghĩa |
|------|----------|---------|
| `--name` | `default` | Tên node — phải unique trong cluster |
| `--data-dir` | `default.etcd` | Thư mục lưu data |
| `--initial-cluster-state` | `new` | `new` (bootstrap) hoặc `existing` (join cluster đang chạy) |
| `--initial-cluster-token` | `etcd-cluster` | Token unique cho cluster — tránh cross-talk giữa các cluster |
| `--heartbeat-interval` | `100ms` | Khoảng thời gian leader gửi heartbeat |
| `--election-timeout` | `1000ms` | Timeout chờ heartbeat — quá thời gian thì election mới |
| `--snapshot-count` | `10000` | Số transaction trước khi tạo snapshot |
| `--quota-backend-bytes` | `2GB` | Giới hạn size data dir — quá thì etcd vào read-only |
| `--auto-compaction-retention` | `0` (off) | Auto compact sau N revision hoặc N giờ |
| `--auto-compaction-mode` | `periodic` | `periodic` (theo giờ) hoặc `revision` (theo revision count) |

### Election timeout — quan trọng

```bash
--heartbeat-interval=100     # leader gửi heartbeat mỗi 100ms
--election-timeout=1000      # follower chờ 1000ms, không nhận heartbeat → election
```

> **Rule of thumb**: `election-timeout` nên ≥ 10× `heartbeat-interval`. Nếu network latency cao, tăng cả hai.

## Liên hệ với Kubernetes

- etcd là **single source of truth** — mất etcd = mất cluster state.
- kube-apiserver là **client duy nhất** ghi vào etcd (qua `apiserver-etcd-client.pem`).
- Controller/Kubelet **không ghi trực tiếp** vào etcd — chỉ đọc qua API Server (watch).
- etcd failure → API Server không đọc/ghi được → cluster "freeze" (nhưng pod vẫn chạy).
- etcd data loss → toàn bộ cluster state mất — phải restore từ backup.
- **Backup etcd thường xuyên!** Đây là bài học quan trọng nhất phase này.
