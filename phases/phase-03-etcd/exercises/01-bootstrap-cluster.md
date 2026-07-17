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
ETCD_VERSION="v3.5.12"
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" \
  | tar xz -C /tmp
sudo cp /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcd /usr/local/bin/
sudo cp /tmp/etcd-${ETCD_VERSION}-linux-amd64/etcdctl /usr/local/bin/

# Kiểm tra
etcd --version
# etcd Version: 3.5.12
```

**Kiểm tra**: `etcd --version` hiện 3.5.12 trên cả 3 node.

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
scp certs/etcd-server-controlplane01.pem controlplane01:/tmp/etcd-server.pem
scp certs/etcd-server-controlplane01-key.pem controlplane01:/tmp/etcd-server-key.pem
scp certs/etcd-peer-controlplane01.pem controlplane01:/tmp/etcd-peer.pem
scp certs/etcd-peer-controlplane01-key.pem controlplane01:/tmp/etcd-peer-key.pem

# Copy server + peer cert cho controlplane02
scp certs/etcd-server-controlplane02.pem controlplane02:/tmp/etcd-server.pem
scp certs/etcd-server-controlplane02-key.pem controlplane02:/tmp/etcd-server-key.pem
scp certs/etcd-peer-controlplane02.pem controlplane02:/tmp/etcd-peer.pem
scp certs/etcd-peer-controlplane02-key.pem controlplane02:/tmp/etcd-peer-key.pem

# Copy server + peer cert cho controlplane03
scp certs/etcd-server-controlplane03.pem controlplane03:/tmp/etcd-server.pem
scp certs/etcd-server-controlplane03-key.pem controlplane03:/tmp/etcd-server-key.pem
scp certs/etcd-peer-controlplane03.pem controlplane03:/tmp/etcd-peer.pem
scp certs/etcd-peer-controlplane03-key.pem controlplane03:/tmp/etcd-peer-key.pem

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

## Bước 4: Tạo systemd unit file

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
  --listen-peer-urls=https://0.0.0.0:2380 \
  --listen-client-urls=https://0.0.0.0:2379 \
  --initial-advertise-peer-urls=https://192.168.56.11:2380 \
  --advertise-client-urls=https://192.168.56.11:2379 \
  --initial-cluster=controlplane01=https://192.168.56.11:2380,controlplane02=https://192.168.56.12:2380,controlplane03=https://192.168.56.13:2380 \
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
  --election-timeout=1000
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

Trên **controlplane02** — đổi `--name=controlplane02`, `--initial-advertise-peer-urls=https://192.168.56.12:2380`, `--advertise-client-urls=https://192.168.56.12:2379`. Giữ `--initial-cluster` giống nhau.

Trên **controlplane03** — đổi `--name=controlplane03`, `--initial-advertise-peer-urls=https://192.168.56.13:2380`, `--advertise-client-urls=https://192.168.56.13:2379`. Giữ `--initial-cluster` giống nhau.

### Giải thích flags quan trọng

| Flag | Ý nghĩa |
|------|---------|
| `--name` | Unique name cho node |
| `--initial-cluster-state=new` | Bootstrap cluster mới (không phải join cluster đang chạy) |
| `--initial-cluster` | Tất cả member + peer URL — phải giống trên mọi node |
| `--initial-cluster-token` | Unique token — tránh cross-talk giữa cluster |
| `--client-cert-auth=true` | Yêu cầu client trình cert (mTLS) |
| `--peer-client-cert-auth=true` | Yêu cầu peer trình cert (mTLS giữa etcd nodes) |

## Bước 5: Start etcd trên tất cả node

```bash
# Trên mỗi node:
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

# Kiểm tra status
sudo systemctl status etcd
# active (running)
```

**Kiểm tra**: `systemctl status etcd` = active (running) trên cả 3 node.

## Bước 6: Verify cluster health

Từ **bất kỳ node nào**:

```bash
# Tạo etcdctl env vars
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://192.168.56.11:2379,https://192.168.56.12:2379,https://192.168.56.13:2379
export ETCDCTL_CACERT=/etc/etcd/etcd-ca.pem
export ETCDCTL_CERT=/etc/etcd/etcd-server.pem
export ETCDCTL_KEY=/etc/etcd/etcd-server-key.pem

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
# | 192.168.56.11:2379  | 8e9e05c52164694d |  3.5.12 |  20 KB  |      true |      false |
# | 192.168.56.12:2379  | 91bc3c398fb3c146 |  3.5.12 |  20 KB  |     false |      false |
# | 192.168.56.13:2379  | fd422379fda50e85 |  3.5.12 |  20 KB  |     false |      false |
# +----------------+------------------+---------+---------+-----------+------------+
```

**Kiểm tra**: 3 endpoint healthy, 3 member started, 1 leader.

## Bước 7: Test write replication

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

## Bước 8: Kiểm tra log

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
2. Tại sao `--initial-cluster` phải giống nhau trên tất cả node?
3. `--initial-cluster-state=new` vs `existing` — khi nào dùng cái nào?
4. Tại sao cần `--peer-client-cert-auth=true`? Nếu tắt thì có rủi ro gì?
5. Nếu controlplane01 không start được, làm sao debug?

## Đáp án tham khảo

1. `--listen-client-urls` = etcd lắng nghe ở interface nào (thường `0.0.0.0`). `--advertise-client-urls` = URL client dùng để kết nối (thường IP node).
2. Vì `--initial-cluster` định nghĩa cluster topology — tất cả node phải đồng ý về topology khi bootstrap.
3. `new` = bootstrap cluster mới (lần đầu). `existing` = join cluster đang chạy (add member).
4. Nếu tắt peer mTLS, bất kỳ ai reach port 2380 có thể join cluster giả mạo. mTLS đảm bảo chỉ etcd node có cert mới kết nối được.
5. `journalctl -u etcd` xem log. Thường lỗi: cert sai, IP sai trong `--initial-cluster`, port bị firewall block.
