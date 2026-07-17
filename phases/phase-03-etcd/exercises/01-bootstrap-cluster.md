# Exercise 01 — Bootstrap etcd Cluster 3 Node với mTLS

> **Mục tiêu**: Bootstrap etcd cluster 3 node trên 3 VM, cấu hình peer URL + client URL + mTLS.
>
> **Thời gian dự kiến**: 45 phút
>
> **Yêu cầu**: 3 Linux VMs (Ubuntu 22.04+), đã hoàn thành Phase 2 (có etcd CA + etcd peer cert)

## Bối cảnh

etcd là database phân tán lưu trữ toàn bộ Kubernetes state. Bài này bootstrap cluster 3 node từ đầu — hiểu chính xác mỗi flag làm gì, tại sao cần mTLS.

## Prerequisites

### 3 VMs với IP

| Node | IP | Hostname |
|------|-----|----------|
| controlplane01 | 192.168.56.11 | controlplane01 |
| controlplane02 | 192.168.56.12 | controlplane02 |
| controlplane03 | 192.168.56.13 | controlplane03 |

> Thay IP bằng IP thực tế của VMs. Có thể dùng `multipass` hoặc `vagrant` tạo 3 VMs.

### Cert từ Phase 2

Cần cert cho mỗi node (từ Phase 2 exercise 05 hoặc script `gen-etcd-cert.sh`):

```
certs/
├── etcd-ca.pem                        # CA cert (giống cho tất cả node)
├── etcd-ca-key.pem                    # CA key (chỉ trên CA machine)
├── etcd-server-controlplane01.pem     # Server cert cho controlplane01
├── etcd-server-controlplane01-key.pem
├── etcd-peer-controlplane01.pem       # Peer cert cho controlplane01
├── etcd-peer-controlplane01-key.pem
├── etcd-server-controlplane02.pem     # Server cert cho controlplane02
├── etcd-server-controlplane02-key.pem
├── etcd-peer-controlplane02.pem       # Peer cert cho controlplane02
├── etcd-peer-controlplane02-key.pem
├── etcd-server-controlplane03.pem     # Server cert cho controlplane03
├── etcd-server-controlplane03-key.pem
├── etcd-peer-controlplane03.pem       # Peer cert cho controlplane03
└── etcd-peer-controlplane03-key.pem
```

> Nếu chưa có cert, chạy script `phases/phase-02-pki-certificates/scripts/gen-etcd-cert.sh` để sinh.

## Bước 1: Cài etcd trên tất cả 3 node

Thực hiện trên **mỗi node** (controlplane01, controlplane02, controlplane03):

```bash
ETCD_VERSION="v3.6.8"
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
  | tar xz -C /tmp
sudo cp /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd /usr/local/bin/
sudo cp /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcdctl /usr/local/bin/

# Kiểm tra
etcd --version
# etcd Version: 3.6.8
```

**Kiểm tra**: `etcd --version` hiện 3.6.8 trên cả 3 node.

## Bước 2: Copy cert vào mỗi node

Trên **CA machine** (nơi có cert), copy cert cho mỗi node:

```bash
# Tạo thư mục cert trên mỗi node
ssh controlplane01 "sudo mkdir -p /etc/etcd"
ssh controlplane02 "sudo mkdir -p /etc/etcd"
ssh controlplane03 "sudo mkdir -p /etc/etcd"

# Copy CA cert (giống cho tất cả)
scp certs/etcd-ca.pem controlplane01:/tmp/etcd-ca.pem
scp certs/etcd-ca.pem controlplane02:/tmp/etcd-ca.pem
scp certs/etcd-ca.pem controlplane03:/tmp/etcd-ca.pem

# Copy server + peer cert cho controlplane01
scp certs/etcd-server-1.pem controlplane01:/tmp/etcd-server.pem
scp certs/etcd-server-1-key.pem controlplane01:/tmp/etcd-server-key.pem
scp certs/etcd-peer-1.pem controlplane01:/tmp/etcd-peer.pem
scp certs/etcd-peer-1-key.pem controlplane01:/tmp/etcd-peer-key.pem

# Copy server + peer cert cho controlplane02
scp certs/etcd-server-2.pem controlplane02:/tmp/etcd-server.pem
scp certs/etcd-server-2-key.pem controlplane02:/tmp/etcd-server-key.pem
scp certs/etcd-peer-2.pem controlplane02:/tmp/etcd-peer.pem
scp certs/etcd-peer-2-key.pem controlplane02:/tmp/etcd-peer-key.pem

# Copy server + peer cert cho controlplane03
scp certs/etcd-server-3.pem controlplane03:/tmp/etcd-server.pem
scp certs/etcd-server-3-key.pem controlplane03:/tmp/etcd-server-key.pem
scp certs/etcd-peer-3.pem controlplane03:/tmp/etcd-peer.pem
scp certs/etcd-peer-3-key.pem controlplane03:/tmp/etcd-peer-key.pem

# Trên mỗi node: move cert vào /etc/etcd/
ssh controlplane01 "sudo mv /tmp/etcd-*.pem /etc/etcd/ && sudo chmod 600 /etc/etcd/*-key.pem"
ssh controlplane02 "sudo mv /tmp/etcd-*.pem /etc/etcd/ && sudo chmod 600 /etc/etcd/*-key.pem"
ssh controlplane03 "sudo mv /tmp/etcd-*.pem /etc/etcd/ && sudo chmod 600 /etc/etcd/*-key.pem"
```

**Kiểm tra**: `/etc/etcd/` trên mỗi node có 5 file: `etcd-ca.pem`, `etcd-server.pem`, `etcd-server-key.pem`, `etcd-peer.pem`, `etcd-peer-key.pem`.

## Bước 3: Tạo data dir

Trên **mỗi node**:

```bash
sudo mkdir -p /var/lib/etcd
```

## Bước 4: Bootstrap controlplane01 (node đầu tiên)

Giống kubeadm — bootstrap từng node một. Node đầu tiên start như single-node cluster, các node sau join qua `etcdctl member add`.

Trên **controlplane01**:

```bash
sudo tee /etc/systemd/system/etcd.service > /dev/null << 'EOF'
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
  --feature-gates=InitialCorruptCheck=true
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

> **Lưu ý**: `--initial-cluster` chỉ chứa `controlplane01` — giống kubeadm, node đầu tiên bootstrap như single-node cluster. Các node sau sẽ join qua `etcdctl member add`.

### Giải thích flags quan trọng

| Flag | Ý nghĩa |
|------|---------|
| `--name` | Unique name cho node |
| `--listen-peer-urls` | Bind peer listener vào IP cụ thể (không dùng `0.0.0.0` trong prod) |
| `--listen-client-urls` | Bind client listener vào `127.0.0.1` + IP cụ thể (localhost cho apiserver, IP cho external) |
| `--listen-metrics-urls` | Metrics endpoint trên port 2381 HTTP (cho Prometheus scrape) |
| `--initial-cluster-state=new` | Bootstrap cluster mới — chỉ dùng cho node đầu tiên |
| `--initial-cluster` | Chỉ chứa node này — cluster membership mở rộng qua `etcdctl member add` |
| `--initial-cluster-token` | Unique token — tránh cross-talk giữa cluster (chỉ node đầu tiên) |
| `--client-cert-auth=true` | Yêu cầu client trình cert (mTLS) |
| `--peer-client-cert-auth=true` | Yêu cầu peer trình cert (mTLS giữa etcd nodes) |
| `--snapshot-count=10000` | Số transaction trước khi tạo snapshot (default 10000) |
| `--watch-progress-notify-interval=5s` | Notify watcher về progress mỗi 5s |
| `--feature-gates=InitialCorruptCheck=true` | Kiểm tra data integrity khi start |

## Bước 5: Start controlplane01 + verify single-node

```bash
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

# Kiểm tra status
sudo systemctl status etcd
# active (running)
```

Verify single-node cluster:

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://192.168.56.11:2379
export ETCDCTL_CACERT=/etc/etcd/etcd-ca.pem
export ETCDCTL_CERT=/etc/etcd/etcd-server.pem
export ETCDCTL_KEY=/etc/etcd/etcd-server-key.pem

# Health check
etcdctl endpoint health
# https://192.168.56.11:2379 is healthy: successfully committed proposal

# Member list — chỉ 1 node
etcdctl member list --write-out=table
# +------------------+---------+----------------+------------------------+------------------------+
# |        ID        | STATUS  |      NAME      |       PEER ADDRS       |      CLIENT ADDRS      |
# +------------------+---------+----------------+------------------------+------------------------+
# | 8e9e05c52164694d | started | controlplane01 | https://192.168.56.11:2380 | https://192.168.56.11:2379 |
# +------------------+---------+----------------+------------------------+------------------------+
```

**Kiểm tra**: controlplane01 healthy, 1 member trong cluster.

## Bước 6: Add controlplane02 vào cluster

> **⚠️ Thứ tự BẮT BUỘC**: Phải làm theo đúng thứ tự 6a → 6b → 6c. Nếu start etcd trên controlplane02 (6c) TRƯỚC khi `etcdctl member add` (6a), controlplane02 sẽ bootstrap như cluster mới (vì `--initial-cluster-state` default = `new`), tạo ra 2 cluster riêng biệt → split-brain. Nếu bị lỗi này, stop etcd trên controlplane02, xóa `/var/lib/etcd`, rồi làm lại từ 6a.

### 6a. Register controlplane02 as member

Trên **controlplane01** (hoặc bất kỳ node nào đã chạy):

```bash
# etcdctl env vars đã set từ Bước 5
etcdctl member add controlplane02 \
  --peer-urls=https://192.168.56.12:2380
# Member 91bc3c398fb3c146 added to cluster etcd-cluster-2026
```

> `etcdctl member add` thông báo cho leader về node mới. Leader ghi "add member" vào Raft log, commit, rồi bắt đầu gửi Raft messages đến peer URL của node mới.

### 6b. Create systemd unit cho controlplane02

Trên **controlplane02**:

```bash
sudo tee /etc/systemd/system/etcd.service > /dev/null << 'EOF'
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
  --initial-cluster=controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380 \
  --initial-cluster-state=existing \
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
  --feature-gates=InitialCorruptCheck=true
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

> **Khác biệt so với node đầu**:
> - `--initial-cluster` chứa tất cả members hiện có (từ `etcdctl member add` output) — đảm bảo cluster ID khớp
> - `--initial-cluster-state=existing` (không phải `new` — cluster đã tồn tại)
> - Không có `--initial-cluster-token` (chỉ cần cho node đầu bootstrap)

### 6c. Start controlplane02

```bash
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

# Kiểm tra status
sudo systemctl status etcd
# active (running)
```

Verify 2-node cluster (từ controlplane01):

```bash
etcdctl member list --write-out=table
# +------------------+---------+----------------+------------------------+------------------------+
# |        ID        | STATUS  |      NAME      |       PEER ADDRS       |      CLIENT ADDRS      |
# +------------------+---------+----------------+------------------------+------------------------+
# | 8e9e05c52164694d | started | controlplane01 | https://192.168.56.11:2380 | https://192.168.56.11:2379 |
# | 91bc3c398fb3c146 | started | controlplane02 | https://192.168.56.12:2380 | https://192.168.56.12:2379 |
# +------------------+---------+----------------+------------------------+------------------------+
```

**Kiểm tra**: 2 member started, cả 2 healthy.

## Bước 7: Add controlplane03 vào cluster

> **⚠️ Thứ tự BẮT BUỘC**: Tương tự Bước 6 — phải `etcdctl member add` (7a) TRƯỚC khi start etcd (7c).

### 7a. Register controlplane03 as member

```bash
etcdctl member add controlplane03 \
  --peer-urls=https://192.168.56.13:2380
# Member fd422379fda50e85 added to cluster etcd-cluster-2026
```

### 7b. Create systemd unit cho controlplane03

Trên **controlplane03**:

```bash
sudo tee /etc/systemd/system/etcd.service > /dev/null << 'EOF'
[Unit]
Description=etcd
After=network.target

[Service]
Type=notify
User=root
ExecStart=/usr/local/bin/etcd \
  --name=controlplane03 \
  --data-dir=/var/lib/etcd \
  --listen-peer-urls=https://192.168.56.13:2380 \
  --listen-client-urls=https://127.0.0.1:2379,https://192.168.56.13:2379 \
  --listen-metrics-urls=http://127.0.0.1:2381 \
  --initial-advertise-peer-urls=https://192.168.56.13:2380 \
  --advertise-client-urls=https://192.168.56.13:2379 \
  --initial-cluster=controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380 \
  --initial-cluster-state=existing \
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
  --feature-gates=InitialCorruptCheck=true
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

### 7c. Start controlplane03

```bash
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

# Kiểm tra status
sudo systemctl status etcd
# active (running)
```

**Kiểm tra**: `systemctl status etcd` = active (running) trên controlplane03.

## Bước 8: Verify cluster health (3 node)

Từ **bất kỳ node nào** — cập nhật endpoints để bao gồm tất cả 3 node:

```bash
export ETCDCTL_ENDPOINTS=https://192.168.56.11:2379,https://192.168.56.12:2379,https://192.168.56.13:2379

# Health check
etcdctl endpoint health
# https://192.168.56.11:2379 is healthy: successfully committed proposal
# https://192.168.56.12:2379 is healthy: successfully committed proposal
# https://192.168.56.13:2379 is healthy: successfully committed proposal

# Member list
etcdctl member list --write-out=table
# +------------------+---------+--------+------------------------+------------------------+
# |        ID        | STATUS  | NAME   |       PEER ADDRS       |      CLIENT ADDRS      |
# +------------------+---------+--------+------------------------+------------------------+
# | 8e9e05c52164694d | started | controlplane01 | https://192.168.56.11:2380  | https://192.168.56.11:2379  |
# | 91bc3c398fb3c146 | started | controlplane02 | https://192.168.56.12:2380  | https://192.168.56.12:2379  |
# | fd422379fda50e85 | started | controlplane03 | https://192.168.56.13:2380  | https://192.168.56.13:2379  |
# +------------------+---------+--------+------------------------+------------------------+

# Endpoint status — xem leader
etcdctl endpoint status --write-out=table
# +----------------+------------------+---------+---------+-----------+------------+
# |    ENDPOINT    |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER |
# +----------------+------------------+---------+---------+-----------+------------+
# | 192.168.56.11:2379  | 8e9e05c52164694d |  3.6.8  |  20 KB  |      true |      false |
# | 192.168.56.12:2379  | 91bc3c398fb3c146 |  3.6.8  |  20 KB  |     false |      false |
# | 192.168.56.13:2379  | fd422379fda50e85 |  3.6.8  |  20 KB  |     false |      false |
# +----------------+------------------+---------+---------+-----------+------------+
```

**Kiểm tra**: 3 endpoint healthy, 3 member started, 1 leader.

## Bước 9: Test write replication

```bash
# Write trên controlplane01
etcdctl --endpoints=https://192.168.56.11:2379 put /test "hello-etcd"

# Read từ controlplane02
etcdctl --endpoints=https://192.168.56.12:2379 get /test
# hello-etcd

# Read từ controlplane03
etcdctl --endpoints=https://192.168.56.13:2379 get /test
# hello-etcd
```

**Kiểm tra**: Data ghi trên 1 node, đọc được trên tất cả node (Raft replication hoạt động).

## Bước 10: Kiểm tra log

```bash
# Trên controlplane01:
sudo journalctl -u etcd --no-pager | tail -30

# Tìm:
# "became leader at term 1"  ← leader election
# "established a TCP stream" ← peer connection
# "published local member to cluster" ← cluster ready
```

## Cleanup (sau khi hoàn thành tất cả exercises)

```bash
# Giữ cluster chạy cho exercise 02+
# Nếu cần cleanup:
# sudo systemctl stop etcd
# sudo rm -rf /var/lib/etcd
# sudo rm /etc/systemd/system/etcd.service
```

## Câu hỏi tự kiểm tra

1. `--listen-client-urls` vs `--advertise-client-urls` khác nhau thế nào?
2. Tại sao `--initial-cluster` trên controlplane02 phải liệt kê tất cả members hiện có (không chỉ `controlplane02`)?
3. Tại sao controlplane02 cần `--initial-cluster-state=existing` khi join cluster?
4. Tại sao cần `--peer-client-cert-auth=true`? Nếu tắt thì có rủi ro gì?
5. Nếu controlplane02 không join được sau `etcdctl member add`, làm sao debug?

## Đáp án tham khảo

1. `--listen-client-urls` = etcd lắng nghe ở interface nào (production: `127.0.0.1` + IP cụ thể, không dùng `0.0.0.0`). `--advertise-client-urls` = URL client dùng để kết nối (IP node). `127.0.0.1` cho phép kube-apiserver trên cùng node kết nối qua localhost — nhanh hơn, không qua network stack.
2. etcd tính cluster ID bằng cách hash member set trong `--initial-cluster`. Nếu controlplane02 chỉ chứa chính nó, cluster ID sẽ khác controlplane01 → peer connection bị reject (cluster ID mismatch). Phải dùng full cluster list từ `etcdctl member add` output để cluster ID khớp. kubeadm cũng dùng full cluster list (lấy từ `AddMemberAsLearner` response) khi tạo static pod manifest cho join nodes.
3. `--initial-cluster-state=existing` báo etcd rằng cluster đã tồn tại — etcd sẽ join thay vì bootstrap cluster mới. Nếu dùng default `new`, etcd sẽ tạo cluster mới với cluster ID riêng → split-brain.
4. Nếu tắt peer mTLS, bất kỳ ai reach port 2380 có thể join cluster giả mạo. mTLS đảm bảo chỉ etcd node có cert mới kết nối được.
5. `journalctl -u etcd` xem log trên controlplane02. Kiểm tra: cert sai, IP sai trong `--listen-peer-urls`, firewall block port 2380, hoặc `etcdctl member add` chưa được commit trước khi start node mới.
