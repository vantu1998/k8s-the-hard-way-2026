# Exercise 06 — Leader Election — Giết Leader, Quan Sat Election

> **Mục tiêu**: Giết leader etcd, quan sát election mới trong log, verify cluster tự recover.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Hoàn thành Exercise 01 (etcd cluster 3 node đang chạy)

## Bối cảnh

Raft leader election là cơ chế tự recover của etcd. Bài này mô phỏng leader crash, quan sát election mới, và verify cluster tiếp tục hoạt động.

## Bước 1: Setup environment

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://10.0.0.1:2379,https://10.0.0.2:2379,https://10.0.0.3:2379
export ETCDCTL_CACERT=/etc/etcd/etcd-ca.pem
export ETCDCTL_CERT=/etc/etcd/etcd-server.pem
export ETCDCTL_KEY=/etc/etcd/etcd-server-key.pem
```

## Bước 2: Xác định leader hiện tại

```bash
etcdctl endpoint status --write-out=table
# +----------------+------------------+---------+-----------+
# |    ENDPOINT    |        ID        | DB SIZE | IS LEADER |
# +----------------+------------------+---------+-----------+
# | 10.0.0.1:2379  | 8e9e05c52164694d |  30 KB  |      true |  ← LEADER
# | 10.0.0.2:2379  | 91bc3c398fb3c146 |  30 KB  |     false |
# | 10.0.0.3:2379  | fd422379fda50e85 |  30 KB  |     false |
# +----------------+------------------+---------+-----------+
```

**Ghi lại**: Node nào là leader (trong ví dụ: etcd-1 / 10.0.0.1).

## Bước 3: Ghi data trước khi kill leader

```bash
etcdctl put /pre-election "data-before-crash"
# OK

# Lấy revision hiện tại
REV_BEFORE=$(etcdctl endpoint status --write-out=json \
  --endpoints=https://10.0.0.1:2379 | jq -r '.[0].Status.header.revision')
echo "Revision before: ${REV_BEFORE}"
```

## Bước 4: Bắt đầu watch trong terminal 2

```bash
# Terminal 2 — watch liên tục
etcdctl watch --prefix /
```

## Bước 5: Kill leader

```bash
# Trên etcd-1 (leader):
sudo systemctl stop etcd

# Hoặc kill process:
# sudo pkill -9 etcd
```

## Bước 6: Quan sát election — nhanh!

```bash
# Từ etcd-2 hoặc etcd-3 (trong ~1-2 giây):
etcdctl endpoint status --write-out=table \
  --endpoints=https://10.0.0.2:2379,https://10.0.0.3:2379
# +----------------+------------------+---------+-----------+
# |    ENDPOINT    |        ID        | DB SIZE | IS LEADER |
# +----------------+------------------+---------+-----------+
# | 10.0.0.2:2379  | 91bc3c398fb3c146 |  30 KB  |     false |  ← đang elect
# | 10.0.0.3:2379  | fd422379fda50e85 |  30 KB  |      true |  ← NEW LEADER!
# +----------------+------------------+---------+-----------+
```

> Election diễn ra trong ~1 giây (`election-timeout=1000ms`). Có thể cần chạy lệnh nhiều lần để bắt kịp.

**Kiểm tra**: Leader mới được elect (etcd-2 hoặc etcd-3).

## Bước 7: Verify cluster vẫn hoạt động (2/3 node)

```bash
# Health check
etcdctl endpoint health \
  --endpoints=https://10.0.0.2:2379,https://10.0.0.3:2379
# Cả 2 healthy

# Write vẫn hoạt động
etcdctl put /post-election "data-after-crash" \
  --endpoints=https://10.0.0.3:2379
# OK

# Read
etcdctl get /pre-election \
  --endpoints=https://10.0.0.3:2379
# data-before-crash  ← data cũ vẫn còn (Raft replication)

etcdctl get /post-election \
  --endpoints=https://10.0.0.3:2379
# data-after-crash
```

**Kiểm tra**: Cluster 2 node vẫn write/read thành công. Data trước crash vẫn còn.

## Bước 8: Xem election log

```bash
# Trên etcd-2 hoặc etcd-3:
sudo journalctl -u etcd --no-pager | grep -E "(election|leader|term)" | tail -20

# Output ví dụ:
# {"level":"info","msg":"raft: starting election at term 1","node":"..."}
# {"level":"info","msg":"raft: became candidate at term 2","node":"..."}
# {"level":"info","msg":"raft: received vote from ...","node":"..."}
# {"level":"info","msg":"raft: became leader at term 2","node":"..."}
# {"level":"info","msg":"published local member to cluster","node":"..."}
```

### Giải thích log

| Log message | Ý nghĩa |
|-------------|---------|
| `starting election at term 1` | Follower timeout, bắt đầu election term mới |
| `became candidate at term 2` | Node trở thành candidate, request vote |
| `received vote from ...` | Node khác vote cho candidate |
| `became leader at term 2` | Đủ quorum vote, trở thành leader |
| `published local member` | Leader thông báo cho cluster |

## Bước 9: Restart etcd-1 (cũ leader)

```bash
# Trên etcd-1:
sudo systemctl start etcd

# Đợi vài giây
sleep 3

# Kiểm tra — etcd-1 rejoin as follower
etcdctl endpoint status --write-out=table
# +----------------+------------------+---------+-----------+
# |    ENDPOINT    |        ID        | DB SIZE | IS LEADER |
# +----------------+------------------+---------+-----------+
# | 10.0.0.1:2379  | 8e9e05c52164694d |  30 KB  |     false |  ← follower (rejoined)
# | 10.0.0.2:2379  | 91bc3c398fb3c146 |  30 KB  |     false |
# | 10.0.0.3:2379  | fd422379fda50e85 |  30 KB  |      true |  ← vẫn leader
# +----------------+------------------+---------+-----------+
```

**Kiểm tra**: etcd-1 rejoin cluster as follower. Leader không đổi (etcd-3 vẫn leader).

> **Quan trọng**: Cũ leader rejoin as **follower**, không lấy lại leadership. Leader chỉ đổi khi current leader crash. Điều này tránh unnecessary election.

## Bước 10: Verify data đầy đủ trên etcd-1

```bash
# etcd-1 đã sync data từ leader
etcdctl get /pre-election --endpoints=https://10.0.0.1:2379
# data-before-crash

etcdctl get /post-election --endpoints=https://10.0.0.1:2379
# data-after-crash
```

**Kiểm tra**: etcd-1 có đầy đủ data (Raft sync sau rejoin).

## Bước 11: Đo election time

```bash
# Cách đo thời gian election:
# 1. Ghi timestamp trước khi kill leader
BEFORE=$(date +%s%N)
sudo systemctl stop etcd

# 2. Poll cho đến khi leader mới
while true; do
  LEADER=$(etcdctl endpoint status --write-out=json \
    --endpoints=https://10.0.0.2:2379,https://10.0.0.3:2379 2>/dev/null \
    | jq -r '.[] | select(.Status.header.leader == .Status.header.member_id) | .Endpoint' 2>/dev/null)
  if [ -n "${LEADER}" ]; then
    AFTER=$(date +%s%N)
    ELAPSED=$(( (AFTER - BEFORE) / 1000000 ))
    echo "Election took: ${ELAPSED}ms"
    break
  fi
  sleep 0.1
done

# Output:
# Election took: 1100ms  ← ~election-timeout (1000ms) + overhead
```

**Kiểm tra**: Election time ≈ `election-timeout` (1000ms) + overhead.

## Bước 12: Test multiple leader changes

```bash
# Kill current leader (etcd-3)
sudo systemctl stop etcd  # trên etcd-3

# Wait for new election
sleep 2

# Check new leader
etcdctl endpoint status --write-out=table \
  --endpoints=https://10.0.0.1:2379,https://10.0.0.2:2379

# Restart etcd-3
sudo systemctl start etcd  # trên etcd-3

# Kill new leader
# ... lặp lại
```

> Mỗi lần kill leader, term tăng lên 1. Quan sát trong log: `term 2 → term 3 → term 4`.

## Câu hỏi tự kiểm tra

1. Kill leader → bao lâu cluster có leader mới? Phụ thuộc vào gì?
2. Cũ leader restart → có lấy lại leadership không? Tại sao?
3. Trong quá trình election (không có leader), write có hoạt động không?
4. Tại sao `election-timeout` nên ≥ 10× `heartbeat-interval`?
5. Cluster 5 node, kill 2 node (không phải leader) → cluster vẫn hoạt động? Kill leader + 1 node → sao?

## Đáp án tham khảo

1. ~`election-timeout` (1000ms mặc định). Phụ thuộc vào `election-timeout` + network latency.
2. Không. Cũ leader rejoin as follower. Tránh unnecessary election — chỉ elect khi leader thực sự chết.
3. Không. Write cần leader → commit. Không có leader = không write. Nhưng read vẫn hoạt động (read từ follower).
4. Nếu `election-timeout` quá gần `heartbeat-interval`, follower có thể tưởng leader chết khi heartbeat bị delay nhẹ → unnecessary election → cluster không ổn định.
5. Kill 2 non-leader: 3/5 node sống = quorum 3 → OK. Kill leader + 1: 3/5 node sống = quorum 3 → OK, election mới thành công. Kill leader + 2: 2/5 node sống < quorum 3 → cluster die.
