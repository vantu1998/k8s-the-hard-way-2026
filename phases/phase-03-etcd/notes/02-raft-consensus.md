# 02 — Raft Consensus Protocol

## Raft là gì

Raft là **consensus algorithm** — giúp nhiều node đồng ý về cùng một state. etcd dùng Raft để đảm bảo **tất cả node có data giống nhau**.

**Bài toán Raft giải quyết**: Nếu 3 node lưu data, và 1 node bị lỗi, làm sao 2 node còn lại biết data gì là "đúng"?

```
Client: PUT /foo = "bar"
       │
       ▼
    Leader (etcd-1)
       │
       ├── Replicate log entry to etcd-2  ✓
       ├── Replicate log entry to etcd-3  ✓
       │
       │  Quorum (2/3) acked → commit
       │
       ▼
    etcd-1: foo=bar (committed)
    etcd-2: foo=bar (replicated)
    etcd-3: foo=bar (replicated)
```

## Ba vai trò trong Raft

```
┌─────────┐   ┌─────────┐   ┌─────────┐
│ Leader   │   │Follower │   │Follower │
│ (etcd-1) │   │(etcd-2) │   │(etcd-3) │
│          │──►│         │   │         │
│          │──►│         │   │         │
│  Receive │   │  Passive│   │  Passive│
│  all     │   │  Listen │   │  Listen │
│  writes  │   │  Heartbeat│  │  Heartbeat│
└─────────┘   └─────────┘   └─────────┘
```

| Vai trò | Số lượng | Vai trò |
|---------|----------|---------|
| **Leader** | 1 | Nhận tất cả write request. Replicate log entry cho follower. Gửi heartbeat định kỳ. |
| **Follower** | N-1 | Passive. Respond leader's append/log request. Nếu không nhận heartbeat trong timeout → trở thành Candidate. |
| **Candidate** | Tạm thời | Request vote từ các node. Nếu thắng → Leader. Nếu thua → Follower. |

### State machine

```
                    ┌──────────┐
                    │ Follower  │
                    │           │
                    └─────┬─────┘
                          │ timeout
                          │ (no heartbeat)
                          ▼
                    ┌──────────┐
          ┌────────│ Candidate │────────┐
          │         │           │         │
          │  win    └─────┬─────┘  lose   │
          │  vote         │              │
          ▼               │ timeout       ▼
    ┌──────────┐          │         ┌──────────┐
    │  Leader   │          └────────►│ Follower │
    │           │                    │           │
    └─────┬─────┘                    └──────────┘
          │
          │  higher term
          │  found
          ▼
    ┌──────────┐
    │ Follower  │
    └──────────┘
```

## Term — khái niệm cốt lõi

**Term** = khoảng thời gian một leader tại vị. Mỗi lần election mới, term tăng lên 1.

```
Term 1          Term 2          Term 3
│               │               │
▼               ▼               ▼
Leader etcd-1   Leader etcd-2   Leader etcd-3
(crashed)       (stepped down)  (current)

Time ─────────────────────────────────────────►
```

- Term là **logical clock** — monotonically increasing.
- Mỗi entry trong log có term tương ứng.
- Nếu node nhận message với term cao hơn mình → tự chuyển sang Follower.
- Nếu Leader nhận message với term cao hơn → step down (trở thành Follower).

## Log Replication — chi tiết

### Bước 1: Client gửi write

```
Client ──► Leader: PUT /foo = "bar"
```

### Bước 2: Leader append log entry (chưa commit)

```
Leader log:
  Index 1: Term 1: PUT /foo = "bar"   ← uncommitted
```

### Bước 3: Leader gửi AppendEntries RPC cho follower

```
Leader ──► Follower 1: AppendEntries(index=1, term=1, entry=PUT /foo="bar")
Leader ──► Follower 2: AppendEntries(index=1, term=1, entry=PUT /foo="bar")
```

### Bước 4: Follower append + ack

```
Follower 1: append log entry → ack
Follower 2: append log entry → ack
```

### Bước 5: Leader nhận quorum ack → commit

```
Leader: 2/3 acked (quorum) → commit index 1
        → apply to key-value store
        → return success to client
```

### Bước 6: Leader notify follower (qua heartbeat)

```
Leader ──► Follower 1: commit_index = 1 (trong heartbeat)
Leader ──► Follower 2: commit_index = 1 (trong heartbeat)

Follower: apply committed entries to key-value store
```

### Quan trọng: Commit ≠ Applied

- **Commit**: Entry được majority replicate. An toàn — không bị mất.
- **Apply**: Entry được ghi vào key-value store (boltdb). Client có thể đọc.
- Leader commit trước, rồi notify follower apply sau.

## Quorum — (N/2) + 1

Quorum = số node tối thiểu phải ack để commit.

| Cluster size | Quorum | Chịu được failure | Đề xuất |
|-------------|--------|-------------------|---------|
| 1 | 1 | 0 | Chỉ cho dev |
| 2 | 2 | 0 | **Không khuyến nghị** — mất 1 node = không write được |
| 3 | 2 | 1 | **Tối thiểu cho production** |
| 5 | 3 | 2 | Production cao |
| 7 | 4 | 3 | Large cluster |

### Tại sao cluster 3 node chịu được 1 failure?

```
Cluster 3 node: etcd-1 (Leader), etcd-2, etcd-3

etcd-1 crash!
       │
       ▼
etcd-2 + etcd-3: 2 node sống = quorum 2
       │
       ▼
Election: etcd-2 hoặc etcd-3 trở thành Leader mới
       │
       ▼
Cluster vẫn hoạt động (2/3 = quorum)
```

### Tại sao cluster 2 node KHÔNG chịu được failure?

```
Cluster 2 node: etcd-1 (Leader), etcd-2

etcd-1 crash!
       │
       ▼
etcd-2: 1 node sống = cần quorum 2
       │
       ▼
1 < 2 → không đủ quorum → etcd-2 vào read-only
       │
       ▼
Cluster DOWN (không write được)
```

> **Kết luận**: Luôn dùng cluster **lẻ** (3, 5, 7). Cluster chẵn không tăng fault tolerance mà chỉ tốn thêm resource.

## Leader Election — chi tiết

### Trigger

Follower không nhận heartbeat từ Leader trong `election-timeout` (mặc định 1000ms).

### Quá trình

```
etcd-2 (Follower)
    │ timeout (no heartbeat from etcd-1)
    │
    ▼
    Current term: 1 → 2 (increment)
    State: Follower → Candidate
    Vote: vote cho chính mình
    │
    ├──► RequestVote(term=2, lastLogIndex=5, lastLogTerm=1) ──► etcd-1
    ├──► RequestVote(term=2, lastLogIndex=5, lastLogTerm=1) ──► etcd-3
    │
    │  etcd-1: "term 2 > my term 1" → step down, vote yes
    │  etcd-3: "term 2 > my term 1" → vote yes
    │
    ▼
    Got 2/3 votes (quorum) → become Leader
    │
    ▼
    Send heartbeat to all followers
    "I am Leader for term 2"
```

### Split vote

Khi 2 candidate cùng lúc request vote → không ai đủ quorum → timeout → election mới (term tiếp theo). Randomized election timeout tránh split vote lặp lại.

```bash
# etcd dùng random election timeout trong range:
# [election-timeout, 2×election-timeout]
# Ví dụ: [1000ms, 2000ms] — mỗi node timeout random khác nhau
```

## Log consistency — sao cho mọi node giống nhau

Raft đảm bảo **Log Matching Property**:
- Nếu 2 entry ở cùng index và cùng term → entry giống nhau (giá trị + command).
- Nếu 2 entry ở cùng index và cùng term → tất cả entry trước đó cũng giống nhau.

### Leader force follower đồng bộ

Khi follower bị behind (hoặc có conflicting entries), leader gửi `AppendEntries` với `prevLogIndex` và `prevLogTerm`:

```
Leader: [1:tx] [2:tx] [3:tx] [4:tx]   ← log entries (index:term)

Follower: [1:tx] [2:tx] [3:tx]        ← behind 1 entry

Leader sends AppendEntries:
  prevLogIndex=3, prevLogTerm=tx, entries=[4:tx]

Follower: check index 3, term matches → append entry 4
Follower: [1:tx] [2:tx] [3:tx] [4:tx]   ← synced!
```

### Conflicting entries

```
Follower: [1:tx] [2:tx] [3:tx] [4:OLD] [5:OLD]   ← stale entries

Leader sends AppendEntries:
  prevLogIndex=3, prevLogTerm=tx, entries=[4:NEW]

Follower: check index 3, term matches
           → delete entries from index 4 onwards
           → append [4:NEW]

Follower: [1:tx] [2:tx] [3:tx] [4:NEW]   ← consistent!
```

## etcd Raft implementation

etcd dùng **etcd-raft** library (không phải Hashicorp Raft). Một số điểm khác biệt:

| | etcd-raft | Hashicorp Raft |
|---|-----------|-----------------|
| Transport | Custom (gRPC) | Custom interface |
| Storage | WAL + Snapshot | BoltDB log |
| Membership | Runtime reconfig | Joint consensus |
| Optimizations | ReadIndex, Lease read | N/A |

### ReadIndex / Lease read — tối ưu read

Mặc định Raft yêu cầu read đi qua leader → log entry → commit. etcd tối ưu:

- **ReadIndex**: Leader ghi nhận current commit index, heartbeat quorum, trả data tại index đó. Không cần log entry.
- **Lease read**: Leader dựa vào lease (heartbeat) — nếu leader vẫn còn lease (chưa timeout), trả data trực tiếp. Không cần quorum check.

```bash
# etcd mặc định dùng linearizable read (ReadIndex)
# Có thể chuyển sang serializable read (đọc local, không guarantee linearizable):
--linearizable-read=false  # hoặc qua etcdctl --consistency=s
```

## Quan sát Raft trong etcd

### Xem leader

```bash
etcdctl endpoint status --write-out=table
# +----------------+------------------+---------+---------+-----------+------------+
# |    ENDPOINT    |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER |
# +----------------+------------------+---------+---------+-----------+------------+
# | 192.168.56.11:2379  | 8e9e05c52164694d |  3.6.8  |  100 KB |      true |      false |
# | 192.168.56.12:2379  | 91bc3c398fb3c146 |  3.6.8  |  100 KB |     false |      false |
# | 192.168.56.13:2379  | fd422379fda50e85 |  3.6.8  |  100 KB |     false |      false |
# +----------------+------------------+---------+---------+-----------+------------+
```

### Xem Raft log trong etcd

```bash
# etcdctl không có lệnh xem Raft log trực tiếp
# Nhưng có thể xem qua etcd --debug hoặc log file

# Log entry khi write:
# {"level":"info","msg":"raft: received message","from":1,"to":2,"type":"MsgApp"}

# Election:
# {"level":"info","msg":"raft: beginning election","term":2}
# {"level":"info","msg":"raft: became leader","term":2}
```

### Metric Raft

```bash
# etcd expose Prometheus metric tại /metrics
curl -s https://192.168.56.11:2379/metrics --cert etcd-client.pem --key etcd-client-key.pem --cacert etcd-ca.pem \
  | grep raft

# etcd_server_leader_changes_seen_total — số lần leader change
# etcd_server_proposals_committed_total — số entry committed
# etcd_server_proposals_pending — entry đang chờ commit
# etcd_server_proposals_failed_total — entry commit fail
```

## Liên hệ với Kubernetes

- **API Server write → etcd Leader → Raft replicate → commit**. Nếu Leader chết giữa chừng, entry uncommitted bị drop — client nhận error, retry.
- **Quorum loss = cluster freeze**: Nếu 2/3 etcd node chết, API Server không write được → `kubectl create` hang → nhưng pod đang chạy vẫn tiếp tục (kubelet dùng cached data).
- **Leader change**: Khi etcd Leader đổi, có thể thấy **ngắn gián** latency tăng (election ~1s). API Server retry tự động.
- **etcd performance = cluster performance**: Nếu etcd chậm (disk I/O bottleneck), toàn bộ `kubectl` command chậm theo.
