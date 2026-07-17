# Exercise 01 — Chạy kube-apiserver Standalone

> **Mục tiêu**: Chạy `kube-apiserver` standalone (không kubelet, không controller-manager), dùng `kubectl` gọi API.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: etcd cluster đang chạy (Phase 3), cert từ Phase 2 (Kubernetes CA + apiserver cert)

## Bối cảnh

kube-apiserver thường chạy như static pod qua kubeadm. Bài này chạy binary trực tiếp để hiểu chính xác mỗi flag làm gì, và thấy API Server chỉ cần etcd + cert để hoạt động.

## Prerequisites

### etcd đang chạy

```bash
# Verify etcd health
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key

etcdctl endpoint health
# 127.0.0.1:2379 is healthy: successfully committed proposal
```

### Cert từ Phase 2

```bash
ls /etc/kubernetes/pki/
# ca.crt  ca.key  apiserver.crt  apiserver.key
# apiserver-etcd-client.crt  apiserver-etcd-client.key
# apiserver-kubelet-client.crt  apiserver-kubelet-client.key
# sa.pub  sa.key

ls /etc/kubernetes/pki/etcd/
# ca.crt  healthcheck-client.crt  healthcheck-client.key
```

> Nếu chưa có cert, chạy script `phases/phase-02-pki-certificates/scripts/gen-all-certs.sh`.

## Bước 1: Cài kube-apiserver + kubectl

```bash
K8S_VERSION="v1.33.0"

# kube-apiserver
curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-apiserver" \
  -o /usr/local/bin/kube-apiserver
sudo chmod +x /usr/local/bin/kube-apiserver

# kubectl
curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl
sudo chmod +x /usr/local/bin/kubectl

# Kiểm tra
kube-apiserver --version
# Kubernetes v1.33.0

kubectl version --client
# Client Version: v1.33.0
```

**Kiểm tra**: `kube-apiserver --version` hiện v1.33.0.

## Bước 2: Tạo admin kubeconfig

```bash
# Tạo kubeconfig cho admin (dùng ca.crt + admin cert)
# kubeadm tạo admin.conf — nếu đã có, skip
kubectl config set-cluster k8s-lab \
  --server=https://127.0.0.1:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=/tmp/admin.kubeconfig

# Dùng ca.key để tạo admin cert (CN=kubernetes-admin, O=system:masters)
openssl genrsa -out /tmp/admin-key.pem 2048
openssl req -new -key /tmp/admin-key.pem -out /tmp/admin.csr \
  -subj "/CN=kubernetes-admin/O=system:masters"
openssl x509 -req -in /tmp/admin.csr \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca-key.pem \
  -CAcreateserial -out /tmp/admin.pem -days 365

kubectl config set-credentials kubernetes-admin \
  --client-certificate=/tmp/admin.pem \
  --client-key=/tmp/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=/tmp/admin.kubeconfig

kubectl config set-context kubernetes-admin@k8s-lab \
  --cluster=k8s-lab \
  --user=kubernetes-admin \
  --kubeconfig=/tmp/admin.kubeconfig

kubectl config use-context kubernetes-admin@k8s-lab \
  --kubeconfig=/tmp/admin.kubeconfig
```

**Kiểm tra**: `/tmp/admin.kubeconfig` tồn tại, chứa cluster + user + context.

## Bước 3: Chạy kube-apiserver

```bash
sudo kube-apiserver \
  --etcd-servers=https://127.0.0.1:2379 \
  --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt \
  --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt \
  --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key \
  --client-ca-file=/etc/kubernetes/pki/ca.crt \
  --tls-cert-file=/etc/kubernetes/pki/apiserver.crt \
  --tls-private-key-file=/etc/kubernetes/pki/apiserver.key \
  --service-account-key-file=/etc/kubernetes/pki/sa.pub \
  --service-account-signing-key-file=/etc/kubernetes/pki/sa.key \
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \
  --service-cluster-ip-range=10.96.0.0/12 \
  --authorization-mode=Node,RBAC \
  --enable-admission-plugins=NodeRestriction,ServiceAccount \
  --anonymous-auth=false \
  --bind-address=0.0.0.0 \
  --secure-port=6443 \
  --allow-privileged=true \
  --v=2 &
```

> Chạy trong background (`&`) cho lab. Production chạy như systemd service hoặc static pod.

### Giải thích flags

| Flag | Ý nghĩa |
|------|---------|
| `--etcd-servers` | etcd endpoint — API Server connect etcd qua đây |
| `--etcd-cafile/certfile/keyfile` | mTLS cert để connect etcd |
| `--client-ca-file` | CA verify client cert (admin cert) |
| `--tls-cert-file/private-key-file` | Server cert cho HTTPS |
| `--service-account-key-file` | Public key verify JWT |
| `--service-account-signing-key-file` | Private key sign JWT |
| `--authorization-mode=Node,RBAC` | Node cho kubelet, RBAC cho user |
| `--enable-admission-plugins` | Admission plugins tối thiểu |
| `--anonymous-auth=false` | Block anonymous request |

## Bước 4: Verify API Server chạy

```bash
# Health check
curl -k https://127.0.0.1:6443/healthz
# ok

# Version
curl -k https://127.0.0.1:6443/version
# {"major":"1","minor":"33","gitVersion":"v1.33.0",...}

# API discovery
curl -k https://127.0.0.1:6443/apis
# {"kind":"APIGroupList","groups":[...]}
```

**Kiểm tra**: `/healthz` trả về `ok`.

## Bước 5: Dùng kubectl

```bash
export KUBECONFIG=/tmp/admin.kubeconfig

# List namespaces (chưa có namespace nào)
kubectl get namespaces
# No resources found

# Tạo namespace
kubectl create namespace default
kubectl create namespace kube-system

# List namespaces
kubectl get namespaces
# NAME           STATUS   AGE
# default        Active   5s
# kube-system    Active   3s

# Tạo pod
kubectl run nginx --image=nginx -n default
# pod/nginx created

# List pods
kubectl get pods -n default
# NAME    READY   STATUS    RESTARTS   AGE
# nginx   1/1     Running   0          10s
```

> Pod chạy vì container runtime trên node này đã cài (containerd). Nếu không có container runtime, pod sẽ pending.

**Kiểm tra**: `kubectl get pods` hiển thị pod nginx.

## Bước 6: Kiểm tra etcd — API Server ghi gì

```bash
# Mở terminal 2 — kiểm tra etcd
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
export ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt
export ETCDCTL_CERT=/etc/kubernetes/pki/etcd/healthcheck-client.crt
export ETCDCTL_KEY=/etc/kubernetes/pki/etcd/healthcheck-client.key

# Đếm key
etcdctl get --prefix /registry/ --keys-only | grep -c '^/registry/'
# 3  (namespace default, namespace kube-system, pod nginx)

# Xem key
etcdctl get --prefix /registry/ --keys-only
# /registry/namespaces/default
# /registry/namespaces/kube-system
# /registry/pods/default/nginx
```

**Kiểm tra**: etcd có key `/registry/namespaces/default` và `/registry/pods/default/nginx`.

## Bước 7: Kiểm tra API endpoints

```bash
# Core API
curl -k --cert /tmp/admin.pem --key /tmp/admin-key.pem \
  https://127.0.0.1:6443/api/v1
# {"kind":"APIResourceList","resources":[...]}

# Apps API
curl -k --cert /tmp/admin.pem --key /tmp/admin-key.pem \
  https://127.0.0.1:6443/apis/apps/v1
# {"kind":"APIResourceList","resources":[...]}

# RBAC API
curl -k --cert /tmp/admin.pem --key /tmp/admin-key.pem \
  https://127.0.0.1:6443/apis/rbac.authorization.k8s.io/v1
# {"kind":"APIResourceList","resources":[...]}
```

## Bước 8: Stop API Server

```bash
# Tìm PID
sudo pgrep kube-apiserver
# 12345

# Kill
sudo kill 12345

# Verify
curl -k https://127.0.0.1:6443/healthz
# curl: (7) Failed to connect to 127.0.0.1 port 6443
```

> Sau khi stop, etcd vẫn giữ data. Restart API Server → data vẫn còn.

## Cleanup

```bash
# Xóa data etcd (nếu muốn clean start)
etcdctl del --prefix /registry/

# Hoặc giữ lại cho exercise 02+
```

## Câu hỏi tự kiểm tra

1. API Server cần tối thiểu những flag nào để start?
2. Tại sao API Server cần `--service-account-signing-key-file`?
3. Nếu etcd down, điều gì xảy ra khi `kubectl get pods`?
4. Tại sao `--authorization-mode=Node,RBAC` có 2 mode? Bỏ `Node` được không?
5. API Server là stateless — restart có mất data không?

## Đáp án tham khảo

1. `--etcd-servers` + etcd cert + `--client-ca-file` + `--tls-cert-file` + `--tls-private-key-file` + `--authorization-mode` + `--service-cluster-ip-range`. Các flag khác là tùy chọn nhưng recommend cho production.
2. Để sign JWT (Service Account token). Pod dùng JWT gọi API Server, API Server verify signature bằng `--service-account-key-file` (public key tương ứng).
3. API Server trả 500 Internal Server Error hoặc 503 Service Unavailable — không đọc/ghi etcd được. Pod đang chạy không bị ảnh hưởng (kubelet quản lý locally).
4. `Node` authorization cho kubelet request (read pod, update node status). Bỏ `Node` → kubelet không authorize được → không report node status, không manage pod. RBAC không cover đầy đủ kubelet use case.
5. Không mất data — API Server stateless, toàn bộ state trong etcd. Restart → đọc lại etcd, cluster state nguyên vẹn.
