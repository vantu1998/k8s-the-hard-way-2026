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
# Production (như kubeadm):
--listen-client-urls=https://127.0.0.1:2379,https://192.168.56.11:2379
--advertise-client-urls=https://192.168.56.11:2379
```

> `127.0.0.1` cho phép kube-apiserver trên cùng node kết nối qua localhost — nhanh hơn, không qua network stack. IP cụ thể cho external access. **Không dùng `0.0.0.0` trong production** — mở trên tất cả interface, kém an toàn.

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
# Production (như kubeadm):
--listen-peer-urls=https://192.168.56.11:2380
--initial-advertise-peer-urls=https://192.168.56.11:2380
```

> Bind vào IP cụ thể — chỉ interface đó nhận peer traffic. **Không dùng `0.0.0.0`** trong production, đặc biệt khi node có nhiều interface (public + private).

### 3. Metrics URL (`--listen-metrics-urls`)

etcd expose Prometheus metrics tại `/metrics`. Production tách metrics ra port riêng (HTTP, không TLS):

```bash
--listen-metrics-urls=http://127.0.0.1:2381
```

> Port 2381 HTTP — Prometheus scrape qua localhost, không cần TLS overhead. Bind `127.0.0.1` = chỉ scrape từ localhost (hoặc qua proxy).

### Tóm tắt URL config

| Flag | Dùng cho | Port | Protocol |
|------|----------|------|----------|
| `--listen-client-urls` | etcd lắng nghe client | 2379 | HTTPS |
| `--advertise-client-urls` | Client kết nối đến | 2379 | HTTPS |
| `--listen-peer-urls` | etcd lắng nghe peer | 2380 | HTTPS |
| `--initial-advertise-peer-urls` | Peer kết nối đến | 2380 | HTTPS |
| `--initial-cluster` | Danh sách tất cả peer URL | 2380 | HTTPS |
| `--listen-metrics-urls` | Prometheus scrape | 2381 | HTTP |

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
ETCD_VERSION="v3.6.8"
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
  | tar xz -C /tmp
sudo cp /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd /usr/local/bin/
sudo cp /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcdctl /usr/local/bin/

# Kiểm tra
etcd --version
# etcd Version: 3.6.8

etcdctl version
# etcdctl Version: 3.6.8
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
  --endpoints=https://192.168.56.11:2379 \
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
export ETCDCTL_ENDPOINTS=https://192.168.56.11:2379
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
# /etc/kubernetes/manifests/etcd.yaml (full manifest như kubeadm generate)
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubeadm.kubernetes.io/etcd.advertise-client-urls: https://192.168.56.11:2379
  labels:
    component: etcd
    tier: control-plane
  name: etcd
  namespace: kube-system
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=https://192.168.56.11:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --client-cert-auth=true
    - --data-dir=/var/lib/etcd
    - --feature-gates=InitialCorruptCheck=true
    - --initial-advertise-peer-urls=https://192.168.56.11:2380
    - --initial-cluster=controlplane01=https://192.168.56.11:2380
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --listen-client-urls=https://127.0.0.1:2379,https://192.168.56.11:2379
    - --listen-metrics-urls=http://127.0.0.1:2381
    - --listen-peer-urls=https://192.168.56.11:2380
    - --name=controlplane01
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-client-cert-auth=true
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --snapshot-count=10000
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --watch-progress-notify-interval=5s
    image: registry.k8s.io/etcd:3.6.8-0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 127.0.0.1
        path: /livez
        port: probe-port
        scheme: HTTP
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: etcd
    ports:
    - containerPort: 2381
      name: probe-port
      protocol: TCP
    readinessProbe:
      failureThreshold: 3
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: probe-port
        scheme: HTTP
      periodSeconds: 1
      timeoutSeconds: 15
    resources:
      requests:
        cpu: 100m
        memory: 100Mi
    startupProbe:
      failureThreshold: 24
      httpGet:
        host: 127.0.0.1
        path: /readyz
        port: probe-port
        scheme: HTTP
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    volumeMounts:
    - mountPath: /var/lib/etcd
      name: etcd-data
    - mountPath: /etc/kubernetes/pki/etcd
      name: etcd-certs
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
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

### Giải thích các thành phần trong manifest

| Thành phần | Ý nghĩa |
|-----------|---------|
| `annotations: kubeadm.kubernetes.io/etcd.advertise-client-urls` | Metadata cho kubeadm quản lý |
| `labels: component, tier` | Labels cho control-plane component |
| `--listen-metrics-urls=http://127.0.0.1:2381` | Metrics trên port 2381 HTTP (cho Prometheus) |
| `--feature-gates=InitialCorruptCheck=true` | Kiểm tra data integrity khi start |
| `--snapshot-count=10000` | Snapshot threshold (mặc định 10000) |
| `--watch-progress-notify-interval=5s` | Notify watcher về progress mỗi 5s |
| `livenessProbe: /livez` | Health check — kill pod nếu fail 8 lần |
| `readinessProbe: /readyz` | Ready check — remove từ endpoints nếu fail |
| `startupProbe: /readyz` | Startup check — chờ 24 retries trước khi consider fail |
| `hostNetwork: true` | Dùng host network — etcd cần reach được từ other nodes |
| `priorityClassName: system-node-critical` | Priority cao nhất — không bị evict |
| `seccompProfile: RuntimeDefault` | Security profile — giới hạn syscalls |
| `resources: requests` | CPU 100m, memory 100Mi — minimum guarantee |
| `image: registry.k8s.io/etcd:3.6.8-0` | etcd image từ Kubernetes registry |

### External etcd

Khi chạy etcd ngoài cluster (không phải static pod), etcd chạy như **systemd service**. Giống kubeadm, bootstrap từng node một — node đầu start như single-node cluster, các node sau join qua `etcdctl member add`.

#### Node đầu tiên (controlplane01) — bootstrap single-node cluster

```ini
# /etc/systemd/system/etcd.service — controlplane01
[Unit]
Description=etcd
After=network.target

[Service]
Type=notify
User=root
ExecStart=/usr/local/bin/etcd \
  --name=controlplane01 \
  --data-dir=/var/lib/etcd \
  --listen-peer-urls=https://192.168.56.11:2380 \
  --listen-client-urls=https://127.0.0.1:2379,https://192.168.56.11:2379 \
  --listen-metrics-urls=http://127.0.0.1:2381 \
  --initial-advertise-peer-urls=https://192.168.56.11:2380 \
  --advertise-client-urls=https://192.168.56.11:2379 \
  --initial-cluster=controlplane01=https://192.168.56.11:2380 \
  --initial-cluster-state=new \
  --initial-cluster-token=etcd-cluster-2026 \
  --client-cert-auth=true \
  --trusted-ca-file=/etc/etcd/etcd-ca.pem \
  --cert-file=/etc/etcd/etcd-server.pem \
  --key-file=/etc/etcd/etcd-server-key.pem \
  --peer-client-cert-auth=true \
  --peer-trusted-ca-file=/etc/etcd/etcd-ca.pem \
  --peer-cert-file=/etc/etcd/etcd-peer.pem \
  --peer-key-file=/etc/etcd/etcd-peer-key.pem \
  --heartbeat-interval=100 \
  --election-timeout=1000 \
  --snapshot-count=10000 \
  --watch-progress-notify-interval=5s \
  --feature-gates=InitialCorruptCheck=true \
  --auto-compaction-mode=periodic \
  --auto-compaction-retention=1h
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

#### Node 2, 3 (controlplane02, controlplane03) — join cluster

Trước khi start node mới, chạy `etcdctl member add`:

```bash
# Trên controlplane01:
etcdctl member add controlplane02 \
  --peer-urls=https://192.168.56.12:2380
```

Sau đó tạo systemd unit trên node mới:

```ini
# /etc/systemd/system/etcd.service — controlplane02
[Unit]
Description=etcd
After=network.target

[Service]
Type=notify
User=root
ExecStart=/usr/local/bin/etcd \
  --name=controlplane02 \
  --data-dir=/var/lib/etcd \
  --listen-peer-urls=https://192.168.56.12:2380 \
  --listen-client-urls=https://127.0.0.1:2379,https://192.168.56.12:2379 \
  --listen-metrics-urls=http://127.0.0.1:2381 \
  --initial-advertise-peer-urls=https://192.168.56.12:2380 \
  --advertise-client-urls=https://192.168.56.12:2379 \
  --initial-cluster=controlplane02=https://192.168.56.12:2380 \
  --client-cert-auth=true \
  --trusted-ca-file=/etc/etcd/etcd-ca.pem \
  --cert-file=/etc/etcd/etcd-server.pem \
  --key-file=/etc/etcd/etcd-server-key.pem \
  --peer-client-cert-auth=true \
  --peer-trusted-ca-file=/etc/etcd/etcd-ca.pem \
  --peer-cert-file=/etc/etcd/etcd-peer.pem \
  --peer-key-file=/etc/etcd/etcd-peer-key.pem \
  --heartbeat-interval=100 \
  --election-timeout=1000 \
  --snapshot-count=10000 \
  --watch-progress-notify-interval=5s \
  --feature-gates=InitialCorruptCheck=true \
  --auto-compaction-mode=periodic \
  --auto-compaction-retention=1h
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

> **Khác biệt so với node đầu**:
> - `--initial-cluster` chỉ chứa node đó (không liệt kê tất cả)
> - Không có `--initial-cluster-state` (default `new` — etcd nhận Raft messages từ leader và join)
> - Không có `--initial-cluster-token` (chỉ cần cho node đầu bootstrap)
> - Phải chạy `etcdctl member add` trước khi start etcd

## Các flag quan trọng khác

| Flag | Mặc định | Ý nghĩa |
|------|----------|---------|
| `--name` | `default` | Tên node — phải unique trong cluster |
| `--data-dir` | `default.etcd` | Thư mục lưu data |
| `--initial-cluster-state` | `new` | `new` (bootstrap node đầu) — các node sau không cần set (default `new` + `member add` = join) |
| `--initial-cluster-token` | `etcd-cluster` | Token unique cho cluster — chỉ cần cho node đầu bootstrap |
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
