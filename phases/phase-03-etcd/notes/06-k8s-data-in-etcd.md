# 06 — Dữ liệu Kubernetes trong etcd

## etcd là single source of truth

Mọi Kubernetes resource (Pod, Service, Deployment, Namespace, Secret, ConfigMap...) đều được lưu trong etcd dưới dạng **key-value pair**. API Server là client duy nhất đọc/ghi etcd.

```
kubectl get pods
       │
       ▼
  API Server
       │
       ▼
  etcd: GET /registry/pods/default/nginx-pod
       │
       ▼
  etcd returns: <protobuf encoded Pod object>
       │
       ▼
  API Server decode protobuf → JSON → return to kubectl
```

## Key structure — prefix-based

etcd dùng **flat key-value** (không có hierarchy thật), nhưng key được tổ chức theo **prefix** giống filesystem path:

```
/registry/
├── pods/
│   ├── default/
│   │   ├── nginx-pod          → Pod object (protobuf)
│   │   └── redis-pod
│   ├── kube-system/
│   │   ├── coredns-xxx
│   │   └── kube-proxy-xxx
│   └── production/
│       └── api-server-xxx
├── services/
│   ├── default/
│   │   ├── kubernetes         → Service object
│   │   └── nginx-service
│   └── kube-system/
│       └── kube-dns
├── deployments/
│   ├── default/
│   │   └── nginx-deployment
│   └── production/
│       └── api-deployment
├── namespaces/
│   ├── default
│   ├── kube-system
│   └── production
├── secrets/
│   ├── default/
│   │   └── db-password        → Secret object (encrypted if encryption at rest)
│   └── kube-system/
│       └── default-token-xxx
├── configmaps/
│   ├── default/
│   │   └── nginx-config
│   └── kube-system/
│       └── coredns
├── replicasets/
│   ├── default/
│   │   └── nginx-deployment-xxx
│   └── ...
├── nodes/
│   ├── node-1                 → Node object
│   ├── node-2
│   └── node-3
├── clusterrolebindings/
│   └── ...
├── clusterroles/
│   └── ...
├── serviceaccounts/
│   └── ...
├── leases/
│   └── kube-node-lease/
│       └── node-1             → Node heartbeat lease
└── ...
```

### Key format

```
/registry/<resource-type>/<namespace>/<resource-name>
```

| Ví dụ key | Resource |
|-----------|----------|
| `/registry/pods/default/nginx` | Pod tên `nginx` trong namespace `default` |
| `/registry/services/kube-system/kube-dns` | Service `kube-dns` trong `kube-system` |
| `/registry/namespaces/production` | Namespace `production` |
| `/registry/nodes/node-1` | Node `node-1` (cluster-scoped, không có namespace) |
| `/registry/secrets/default/db-password` | Secret `db-password` trong `default` |

### Cluster-scoped vs Namespace-scoped

| Loại | Key format | Ví dụ |
|------|------------|-------|
| Namespace-scoped | `/registry/<type>/<namespace>/<name>` | Pod, Service, Deployment, Secret |
| Cluster-scoped | `/registry/<type>/<name>` | Node, Namespace, ClusterRole, PersistentVolume |

## Đọc data từ etcd

### etcdctl get — xem key cụ thể

```bash
# Cần cert của API Server để connect etcd
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  get /registry/namespaces/default
```

### Output — protobuf (không đọc được trực tiếp)

```
/registry/namespaces/default
        default"kube-system-kubernetes.default.svc.cluster.localz
                                        phaseActive
```

etcd lưu Kubernetes object dưới dạng **protobuf** (không phải JSON). Đọc raw sẽ thấy binary data lẫn text.

### etcdctl get --prefix — xem tất cả key theo prefix

```bash
# Đếm số key trong etcd
etcdctl get --prefix /registry/ --keys-only | wc -l
# 342

# Liệt kê tất cả pod key
etcdctl get --prefix /registry/pods/ --keys-only
# /registry/pods/default/nginx-pod
# /registry/pods/default/redis-pod
# /registry/pods/kube-system/coredns-xxx
# /registry/pods/kube-system/kube-proxy-xxx

# Liệt kê tất cả namespace
etcdctl get --prefix /registry/namespaces/ --keys-only
# /registry/namespaces/default
# /registry/namespaces/kube-system
# /registry/namespaces/production

# Liệt kê tất cả node
etcdctl get --prefix /registry/nodes/ --keys-only
# /registry/nodes/node-1
# /registry/nodes/node-2
# /registry/nodes/node-3
```

### etcdctl get với value (JSON-ish)

```bash
# Xem value (protobuf — khó đọc nhưng có thể thấy field)
etcdctl get /registry/namespaces/default | hexdump -C | head -20

# Xem value dạng string (grep readable text)
etcdctl get /registry/namespaces/default | strings
# default
# kube-system
# kubernetes.default.svc.cluster.local
# phaseActive
```

### Đếm key theo resource type

```bash
# Đếm pod
etcdctl get --prefix /registry/pods/ --keys-only | grep -c '^/registry/pods/'
# 15

# Đếm service
etcdctl get --prefix /registry/services/ --keys-only | grep -c '^/registry/services/'
# 5

# Đếm secret
etcdctl get --prefix /registry/secrets/ --keys-only | grep -c '^/registry/secrets/'
# 8

# Đếm tất cả
etcdctl get --prefix /registry/ --keys-only | grep -c '^/registry/'
# 342
```

## Phân tích key distribution

```bash
#!/bin/bash
# etcd-key-stats.sh — thống kê key theo resource type

ETCDCTL="etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key"

echo "=== etcd key distribution ==="
echo ""

for prefix in pods services deployments replicasets secrets configmaps \
  namespaces nodes serviceaccounts clusterroles clusterrolebindings \
  roles rolebindings leases events; do
  count=$(${ETCDCTL} get --prefix "/registry/${prefix}/" --keys-only 2>/dev/null | grep -c "^/registry/${prefix}/" || echo 0)
  printf "  %-25s %5d keys\n" "${prefix}" "${count}"
done
```

### Output ví dụ

```
=== etcd key distribution ===

  pods                        15 keys
  services                     5 keys
  deployments                  3 keys
  replicasets                  3 keys
  secrets                      8 keys
  configmaps                   4 keys
  namespaces                   3 keys
  nodes                        3 keys
  serviceaccounts              6 keys
  clusterroles                12 keys
  clusterrolebindings         10 keys
  roles                        2 keys
  rolebindings                 2 keys
  leases                       3 keys
  events                      45 keys
```

> **Events** thường chiếm nhiều key nhất — mỗi event là 1 key. Events có TTL (mặc định 1 giờ) nên tự xóa.

## Encryption at rest

Mặc định, Secret trong etcd lưu **plaintext** (protobuf encoded, nhưng không mã hóa). Bật **encryption at rest** để mã hóa Secret.

### Không có encryption:

```bash
# Secret value trong etcd — có thể đọc được
etcdctl get /registry/secrets/default/db-password | strings
# db-password
# password123       ← plaintext!
```

### Có encryption (AES-GCM):

```bash
# Secret value đã mã hóa
etcdctl get /registry/secrets/default/db-password | strings
# k8s:enc:aes-gcm:v1:key1
# <binary encrypted data>   ← không đọc được
```

### Cấu hình encryption at rest

```yaml
# /etc/kubernetes/encryption-provider.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aesgcm:
      keys:
      - name: key1
        secret: <base64-encoded-32-byte-key>
  - identity: {}  # fallback: không mã hóa resource khác
```

```bash
# kube-apiserver flag:
--encryption-provider-config=/etc/kubernetes/encryption-provider.yaml
```

## Watch — cách controller theo dõi thay đổi

etcd **watch API** cho phép client subscribe thay đổi trên key prefix. Đây là cơ chế cốt lõi của Kubernetes controller pattern.

```
API Server: etcdctl watch --prefix /registry/pods/default/
       │
       ▼
  etcd: "PUT /registry/pods/default/nginx → <Pod object>"
  etcd: "DELETE /registry/pods/default/nginx"
       │
       ▼
  API Server forward watch event to controller
       │
       ▼
  Controller: "Pod nginx created/deleted → react!"
```

### etcdctl watch

```bash
# Watch tất cả thay đổi trong namespace default
etcdctl watch --prefix /registry/pods/default/

# Output khi tạo pod:
# PUT
# /registry/pods/default/nginx
# <protobuf data>

# Output khi xóa pod:
# DELETE
# /registry/pods/default/nginx
```

> **Lưu ý**: Trong thực tế, controller không watch etcd trực tiếp — watch qua API Server. API Server proxy watch request đến etcd.

## etcd và Kubernetes API version

Mỗi key trong etcd có thể có **resource version** (revision):

```bash
# Xem revision của key
etcdctl get /registry/pods/default/nginx -w json | jq .header.revision
# 12345

# Sau khi update pod:
etcdctl get /registry/pods/default/nginx -w json | jq .header.revision
# 12346  ← tăng 1
```

Kubernetes `resourceVersion` = etcd revision. Khi `kubectl get pod -o yaml`, field `resourceVersion` chính là etcd revision lúc pod được ghi.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: default
  resourceVersion: "12345"   ← etcd revision
```

## Liên hệ với Kubernetes

- **etcd là brain của cluster** — mất etcd = mất state = cluster không biết pod nào chạy ở đâu.
- **API Server là firewall** — không ai ghi trực tiếp etcd ngoài API Server (qua cert `apiserver-etcd-client.pem`).
- **etcd key count** ≈ cluster complexity — cluster lớn có hàng nghìn key. Monitor key count + DB size.
- **etcd performance** ảnh hưởng trực tiếp API Server latency — etcd chậm → `kubectl` chậm → controller reconcile chậm.
- **Backup etcd = backup cluster** — restore etcd = restore toàn bộ cluster state.
- **Encryption at rest** bảo vệ Secret khi attacker truy cập etcd data dir — nhưng không bảo vệ khi attacker có API Server access.
- **etcd là lý do K8s cần奇 quorum** — nếu etcd mất quorum, API Server read-only, cluster "freeze".
