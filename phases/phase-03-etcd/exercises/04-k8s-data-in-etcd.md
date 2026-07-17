# Exercise 04 — Đọc Dữ liệu Kubernetes trong etcd

> **Mục tiêu**: Dùng `etcdctl get --prefix /registry/` trên cluster Kubernetes đang chạy, đếm số key, phân tích cấu trúc.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Kubernetes cluster đang chạy (kubeadm hoặc managed), `etcdctl` đã cài

## Bối cảnh

etcd lưu toàn bộ Kubernetes state dưới dạng key-value với prefix `/registry/`. Bài này đọc raw data trong etcd để hiểu Kubernetes lưu gì bên trong.

## Bước 1: Tìm etcd cert (kubeadm cluster)

```bash
# Trên master node:
ls /etc/kubernetes/pki/etcd/
# ca.crt  healthcheck-client.crt  healthcheck-client.key  peer.crt  peer.key  server.crt  server.key

# Setup etcdctl env vars
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key
```

> Nếu dùng external etcd, thay endpoint + cert path tương ứng.

**Kiểm tra**: `etcdctl endpoint health` trả về healthy.

## Bước 2: Đếm tổng số key

```bash
etcdctl get --prefix /registry/ --keys-only | grep -c '^/registry/'
# 342
```

**Kiểm tra**: Số key > 0.

## Bước 3: Liệt kê key theo resource type

```bash
# Tất cả pod
etcdctl get --prefix /registry/pods/ --keys-only | head -20
# /registry/pods/default/nginx-xxx
# /registry/pods/kube-system/coredns-xxx
# /registry/pods/kube-system/etcd-master
# /registry/pods/kube-system/kube-apiserver-master
# /registry/pods/kube-system/kube-controller-manager-master
# /registry/pods/kube-system/kube-proxy-xxx
# /registry/pods/kube-system/kube-scheduler-master

# Tất cả service
etcdctl get --prefix /registry/services/ --keys-only
# /registry/services/default/kubernetes
# /registry/services/kube-system/kube-dns

# Tất cả namespace
etcdctl get --prefix /registry/namespaces/ --keys-only
# /registry/namespaces/default
# /registry/namespaces/kube-node-lease
# /registry/namespaces/kube-public
# /registry/namespaces/kube-system

# Tất cả node
etcdctl get --prefix /registry/nodes/ --keys-only
# /registry/nodes/master
# /registry/nodes/worker-1
# /registry/nodes/worker-2
```

## Bước 4: Thống kê key theo resource type

```bash
#!/bin/bash
# etcd-key-stats.sh

ETCDCTL="etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key"

echo "=== etcd key distribution ==="
echo ""

total=0
for prefix in pods services deployments replicasets daemonsets \
  statefulsets jobs cronjobs secrets configmaps namespaces nodes \
  serviceaccounts clusterroles clusterrolebindings roles rolebindings \
  persistentvolumes persistentvolumeclaims leases events \
  ingresses networkpolicies poddisruptionbudgets; do
  count=$(${ETCDCTL} get --prefix "/registry/${prefix}/" --keys-only 2>/dev/null \
    | grep -c "^/registry/${prefix}/" || echo 0)
  if [ "${count}" -gt 0 ]; then
    printf "  %-30s %5d keys\n" "${prefix}" "${count}"
    total=$((total + count))
  fi
done

echo ""
printf "  %-30s %5d keys\n" "TOTAL" "${total}"
```

### Output ví dụ

```
=== etcd key distribution ===

  pods                              15 keys
  services                           3 keys
  deployments                        2 keys
  replicasets                        2 keys
  daemonsets                         2 keys
  secrets                           10 keys
  configmaps                         5 keys
  namespaces                         4 keys
  nodes                              3 keys
  serviceaccounts                    6 keys
  clusterroles                      15 keys
  clusterrolebindings               12 keys
  leases                             3 keys
  events                            45 keys
  TOTAL                            127 keys
```

**Kiểm tra**: Script chạy, hiện số key per resource type.

## Bước 5: Đọc raw value của 1 key

```bash
# Đọc namespace default
etcdctl get /registry/namespaces/default | strings
# default
# kube-system
# kubernetes.default.svc.cluster.local
# phaseActive

# Đọc pod
etcdctl get /registry/pods/default/nginx-xxx | strings | head -30
# default
# nginx-xxx
# nginx
# ...
# phasePending
# phaseRunning
```

> etcd lưu Kubernetes object dưới dạng **protobuf** — không phải JSON. `strings` extract readable text, nhưng không parse được structure đầy đủ.

## Bước 6: Đọc value với JSON output

```bash
# JSON output cho metadata
etcdctl get /registry/namespaces/default -w json | jq .
# {
#   "header": {
#     "revision": 12345,
#     "raft_term": 3
#   },
#   "kvs": [
#     {
#       "key": "L3JlZ2lzdHJ5L25hbWVzcGFjZXMvZGVmYXVsdA==",
#       "value": "...",  ← base64 encoded protobuf
#       "create_revision": 2,
#       "mod_revision": 5,
#       "version": 3
#     }
#   ]
# }

# Decode key từ base64
echo "L3JlZ2lzdHJ5L25hbWVzcGFjZXMvZGVmYXVsdA==" | base64 -d
# /registry/namespaces/default
```

## Bước 7: Tạo resource và quan sát etcd

### Terminal 1: Watch etcd

```bash
etcdctl watch --prefix /registry/pods/default/ --keys-only
```

### Terminal 2: Tạo pod

```bash
kubectl run test-pod --image=nginx
# pod/test-pod created
```

### Terminal 1 output:

```
PUT
/registry/pods/default/test-pod
```

### Terminal 2: Xóa pod

```bash
kubectl delete pod test-pod
```

### Terminal 1 output:

```
DELETE
/registry/pods/default/test-pod
```

**Kiểm tra**: Watch nhận event PUT khi tạo, DELETE khi xóa.

## Bước 8: Kiểm tra Secret encryption

```bash
# Tạo secret
kubectl create secret generic test-secret \
  --from-literal=password=supersecret123

# Đọc secret trong etcd
etcdctl get --prefix /registry/secrets/default/test-secret | strings
# Nếu KHÔNG có encryption:
#   test-secret
#   default
#   password
#   supersecret123    ← plaintext!

# Nếu CÓ encryption at rest:
#   k8s:enc:aes-gcm:v1:key1
#   <binary data>     ← encrypted, không đọc được
```

**Kiểm tra**: Xác định cluster có bật encryption at rest hay không.

## Bước 9: So sánh etcd key vs kubectl output

```bash
# Đếm pod bằng kubectl
kubectl get pods --all-namespaces --no-headers | wc -l
# 15

# Đếm pod trong etcd
etcdctl get --prefix /registry/pods/ --keys-only | grep -c '^/registry/pods/'
# 15  ← giống nhau

# Đếm namespace
kubectl get namespaces --no-headers | wc -l
# 4

etcdctl get --prefix /registry/namespaces/ --keys-only | grep -c '^/registry/namespaces/'
# 4  ← giống nhau
```

**Kiểm tra**: Số lượng resource trong kubectl = số key trong etcd.

## Câu hỏi tự kiểm tra

1. Key `/registry/pods/default/nginx` lưu gì? Tại sao không phải JSON?
2. Tại sao số pod trong `kubectl get` = số key `/registry/pods/` trong etcd?
3. Event chiếm nhiều key nhất — tại sao? Event có TTL không?
4. Secret trong etcd có mã hóa mặc định không? Làm sao kiểm tra?
5. Nếu xóa key `/registry/nodes/node-1` trực tiếp bằng `etcdctl del`, điều gì xảy ra?

## Đáp án tham khảo

1. Lưu Pod object dạng protobuf (compact hơn JSON). API Server decode protobuf → JSON khi trả về cho client.
2. Vì API Server đọc từ etcd — mỗi pod trong etcd = 1 pod trong kubectl. etcd là single source of truth.
3. Mỗi event là 1 key. Event có TTL (mặc định 1 giờ) — kubelet/manager tự xóa event cũ.
4. Mặc định KHÔNG mã hóa. Kiểm tra bằng `etcdctl get /registry/secrets/... | strings` — nếu thấy plaintext thì không encryption.
5. Node biến mất khỏi cluster ngay lập tức — `kubectl get nodes` không thấy node-1. Pod trên node-1 vẫn chạy nhưng API Server không biết. Đây là lý do **không bao giờ** xóa key trực tiếp trong etcd.
