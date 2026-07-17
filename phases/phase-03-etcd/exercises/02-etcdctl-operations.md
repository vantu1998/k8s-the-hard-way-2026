# Exercise 02 — etcdctl Operations (Put/Get/Delete/Watch)

> **Mục tiêu**: Dùng `etcdctl` thực hiện CRUD operations, xem status, endpoint health.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Hoàn thành Exercise 01 (etcd cluster 3 node đang chạy)

## Bối cảnh

`etcdctl` là công cụ chính để tương tác với etcd. Bài này thực hành tất cả lệnh cơ bản — put, get, delete, watch, status, health.

## Bước 1: Setup environment

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://192.168.56.11:2379,https://192.168.56.12:2379,https://192.168.56.13:2379
export ETCDCTL_CACERT=/etc/etcd/etcd-ca.pem
export ETCDCTL_CERT=/etc/etcd/etcd-server.pem
export ETCDCTL_KEY=/etc/etcd/etcd-server-key.pem
```

**Kiểm tra**: `etcdctl endpoint health` trả về healthy cho tất cả endpoint.

## Bước 2: Put — ghi key-value

```bash
# Put đơn giản
etcdctl put /foo "bar"
# OK

# Put với key có prefix (giống Kubernetes style)
etcdctl put /registry/pods/default/nginx "pod-data"
# OK

# Put nhiều key
etcdctl put /config/database-url "postgres://localhost:5432"
etcdctl put /config/redis-url "redis://localhost:6379"
etcdctl put /config/api-key "secret123"
```

**Kiểm tra**: Mỗi lệnh `put` trả về `OK`.

## Bước 3: Get — đọc key-value

```bash
# Get đơn giản
etcdctl get /foo
# /foo
# bar

# Get chỉ key (không value)
etcdctl get /foo --keys-only
# /foo

# Get chỉ value (không key)
etcdctl get /foo --print-value-only
# bar

# Get với JSON output (xem metadata: revision, lease, etc.)
etcdctl get /foo -w json | jq .
# {
#   "header": {
#     "cluster_id": ...,
#     "member_id": ...,
#     "revision": 5,
#     "raft_term": 2
#   },
#   "kvs": [
#     {
#       "key": "L2Zvbw==",      ← base64 encoded "/foo"
#       "value": "YmFy",        ← base64 encoded "bar"
#       "create_revision": 3,
#       "mod_revision": 3,
#       "version": 1
#     }
#   ]
# }
```

### Giải thích metadata

| Field | Ý nghĩa |
|-------|---------|
| `revision` | Global revision — tăng mỗi write |
| `create_revision` | Revision lúc key được tạo |
| `mod_revision` | Revision lúc key bị modify lần cuối |
| `version` | Số lần key bị modify (từ lần create) |

## Bước 4: Get theo prefix

```bash
# Get tất cả key có prefix /config/
etcdctl get --prefix /config/
# /config/api-key
# secret123
# /config/database-url
# postgres://localhost:5432
# /config/redis-url
# redis://localhost:6379

# Get chỉ key
etcdctl get --prefix /config/ --keys-only
# /config/api-key
# /config/database-url
# /config/redis-url

# Get với limit
etcdctl get --prefix /config/ --limit=2
# /config/api-key
# secret123
# /config/database-url
# postgres://localhost:5432
```

## Bước 5: Get theo range

```bash
# Get key trong range [/config/a, /config/z)
etcdctl get /config/a /config/z
# /config/api-key
# secret123
# /config/database-url
# postgres://localhost:5432
# /config/redis-url
# redis://localhost:6379

# Range: key >= /config/a và key < /config/z
```

## Bước 6: Delete — xóa key

```bash
# Delete 1 key
etcdctl del /foo
# 1  ← số key đã xóa

# Delete theo prefix
etcdctl del --prefix /config/
# 3  ← số key đã xóa

# Delete theo range
etcdctl del /config/a /config/z
```

**Kiểm tra**: `etcdctl get /foo` không trả về gì (key đã xóa).

## Bước 7: Watch — theo dõi thay đổi

### Watch trong terminal 1

```bash
# Watch tất cả thay đổi trong prefix /registry/
etcdctl watch --prefix /registry/
```

### Put/Delete trong terminal 2

```bash
# Terminal 2:
etcdctl put /registry/pods/default/nginx "pod-v1"
# Terminal 1 output:
# PUT
# /registry/pods/default/nginx
# pod-v1

etcdctl put /registry/pods/default/nginx "pod-v2"
# Terminal 1 output:
# PUT
# /registry/pods/default/nginx
# pod-v2

etcdctl del /registry/pods/default/nginx
# Terminal 1 output:
# DELETE
# /registry/pods/default/nginx
```

### Watch từ revision cụ thể

```bash
# Xem revision hiện tại
etcdctl endpoint status --write-out=json | jq '.[0].Status.header.revision'
# 10

# Watch từ revision 10
etcdctl watch --prefix /registry/ --rev=10
# Sẽ nhận lại tất cả event từ revision 10 trở đi
```

**Kiểm tra**: Watch nhận event PUT và DELETE realtime.

## Bước 8: Endpoint health

```bash
# Health check tất cả endpoint
etcdctl endpoint health
# https://192.168.56.11:2379 is healthy: successfully committed proposal
# https://192.168.56.12:2379 is healthy: successfully committed proposal
# https://192.168.56.13:2379 is healthy: successfully committed proposal

# Health check 1 endpoint
etcdctl endpoint health --endpoints=https://192.168.56.11:2379
```

## Bước 9: Endpoint status

```bash
# Status tất cả endpoint
etcdctl endpoint status --write-out=table
# +----------------+------------------+---------+---------+-----------+------------+
# |    ENDPOINT    |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER |
# +----------------+------------------+---------+---------+-----------+------------+
# | 192.168.56.11:2379  | 8e9e05c52164694d |  3.5.12 |  25 KB  |      true |      false |
# | 192.168.56.12:2379  | 91bc3c398fb3c146 |  3.5.12 |  25 KB  |     false |      false |
# | 192.168.56.13:2379  | fd422379fda50e85 |  3.5.12 |  25 KB  |     false |      false |
# +----------------+------------------+---------+---------+-----------+------------+

# JSON output
etcdctl endpoint status --write-out=json | jq '.[].Status'
```

### Các field quan trọng

| Field | Ý nghĩa |
|-------|---------|
| `ID` | Member ID (hex) |
| `VERSION` | etcd version |
| `DB SIZE` | Size boltdb file |
| `IS LEADER` | true = leader node |
| `IS LEARNER` | true = learner (non-voting) |
| `REVISION` | Revision hiện tại |
| `RAFT TERM` | Raft term hiện tại |
| `RAFT INDEX` | Raft log index hiện tại |

## Bước 10: Member list

```bash
# Table format
etcdctl member list --write-out=table

# JSON format
etcdctl member list --write-out=json | jq .

# Simple format (default)
etcdctl member list
```

## Bước 11: Lease — TTL cho key

```bash
# Tạo lease 60 giây
etcdctl lease grant 60
# lease 694d78... granted with TTL(60s)

# Put key với lease
etcdctl put /temp "ephemeral" --lease=694d78...
# OK

# Kiểm tra key
etcdctl get /temp
# /temp
# ephemeral

# Đợi 60 giây...
# Key tự động bị xóa khi lease hết hạn

# Hoặc revoke lease sớm
etcdctl lease revoke 694d78...
# Key gắn với lease bị xóa ngay
```

**Kiểm tra**: Key có lease tự xóa sau khi lease hết hạn.

## Bước 12: Transaction — compare-and-swap

```bash
# Transaction: chỉ put nếu key không tồn tại
etcdctl txn << 'EOF'
mod("/foo") > "0"

put /foo "new-value"

EOF
# SUCCESS

# Nếu key tồn tại (mod_revision > 0), put không thực hiện
# Nếu key không tồn tạo (mod_revision = 0), put thực hiện
```

> Transaction là cơ chế etcd đảm bảo atomicity — dùng cho leader election, distributed lock.

## Câu hỏi tự kiểm tra

1. `etcdctl get --prefix /registry/` trả về key nào? Tại sao dùng prefix?
2. `revision` vs `version` khác nhau thế nào?
3. Watch từ revision cũ có hoạt động không? Khi nào không?
4. Lease khác gì so với TTL trong etcd v2?
5. Tại sao `etcdctl endpoint health` cần quorum để trả về healthy?

## Đáp án tham khảo

1. Trả về tất cả key bắt đầu bằng `/registry/`. Prefix dùng để group key theo resource type (giống Kubernetes).
2. `revision` = global counter, tăng mỗi write trên bất kỳ key. `version` = per-key counter, tăng mỗi write trên key đó.
3. Hoạt động nếu revision chưa bị compact. Sau compact, revision cũ bị xóa → watch fail với error "compacted".
4. Lease là object riêng, có thể renew (gia hạn), attach nhiều key vào 1 lease. TTL v2 gắn trực tiếp vào key, không renew được.
5. Health check thực hiện một write (proposal) — cần quorum để commit. Nếu không đủ quorum, proposal fail → unhealthy.
