# 05 — Kubernetes Certificates

## Tổng quan tất cả cert Kubernetes cần

Kubernetes cluster cần **nhiều certificate** — mỗi component cần cert riêng cho mục đích riêng.

```
                    ┌─────────────────────────────────────┐
                    │          kube-apiserver               │
                    │  server cert: apiserver.pem          │
                    │  client cert (→ etcd): etcd-client   │
                    │  client cert (→ kubelet): kubelet    │
                    │  SA key: sa.key (sign JWT)           │
                    └──────────┬──────────────┬────────────┘
                               │ mTLS         │ mTLS
                    ┌──────────▼──────┐  ┌───▼──────────────┐
                    │      etcd       │  │     kubelet       │
                    │  server cert    │  │  server cert      │
                    │  peer cert      │  │  client cert      │
                    │  (mTLS giữa     │  │  (→ apiserver)    │
                    │   etcd members) │  │                   │
                    └─────────────────┘  └───────────────────┘

  ┌──────────────────────┐    ┌──────────────────────────────┐
  │  kube-scheduler      │    │  kube-controller-manager      │
  │  client cert         │    │  client cert                  │
  │  (→ apiserver)       │    │  (→ apiserver)                │
  │  CN=system:kube-     │    │  CN=system:kube-              │
  │    scheduler         │    │    controller-manager         │
  └──────────────────────┘    └──────────────────────────────┘
```

## Danh sách đầy đủ

### 1. CA certificates

| File | CN | Mục đích |
|------|-----|---------|
| `ca.pem` / `ca-key.pem` | `kubernetes-ca` | CA chính — ký cert cho apiserver, kubelet, scheduler, controller-manager |
| `etcd/ca.pem` / `etcd/ca-key.pem` | `etcd-ca` | CA riêng cho etcd |
| `front-proxy-ca.pem` / `front-proxy-ca-key.pem` | `kubernetes-front-proxy-ca` | CA cho API aggregation proxy |

### 2. kube-apiserver

| File | CN | SAN (hosts) | Mục đích |
|------|-----|-------------|---------|
| `apiserver.pem` / `apiserver-key.pem` | `kube-apiserver` | `kubernetes`, `kubernetes.default`, `kubernetes.default.svc`, `kubernetes.default.svc.cluster.local`, `localhost`, `10.96.0.1`, `<master-IP>`, `127.0.0.1` | Server cert — client verify apiserver |
| `apiserver-etcd-client.pem` / `apiserver-etcd-client-key.pem` | `kube-apiserver-etcd-client` | — | Client cert — apiserver → etcd (mTLS) |
| `apiserver-kubelet-client.pem` / `apiserver-kubelet-client-key.pem` | `kube-apiserver-kubelet-client` | — | Client cert — apiserver → kubelet (mTLS) |
| `sa.pub` / `sa.key` | — | — | Service account key pair — sa.key sign JWT, sa.pub verify |

### 3. etcd

| File | CN | SAN (hosts) | Mục đích |
|------|-----|-------------|---------|
| `etcd/server.pem` / `etcd/server-key.pem` | `<node-name>` | `<node-name>`, `localhost`, `<node-IP>`, `127.0.0.1` | Server cert — client → etcd |
| `etcd/peer.pem` / `etcd/peer-key.pem` | `<node-name>` | `<node-name>`, `localhost`, `<node-IP>`, `127.0.0.1` | Peer cert — etcd ↔ etcd (mTLS) |
| `etcd/healthcheck-client.pem` / `etcd/healthcheck-client-key.pem` | `kube-etcd-healthcheck-client` | — | Client cert — liveness probe → etcd |

### 4. kubelet (per node)

| File | CN | SAN (hosts) | Mục đích |
|------|-----|-------------|---------|
| `kubelet.pem` / `kubelet-key.pem` | `system:node:<node-name>` | `<node-name>`, `<node-IP>` | Server cert — apiserver → kubelet |
| `kubelet-client.pem` / `kubelet-client-key.pem` | `system:node:<node-name>` | — | Client cert — kubelet → apiserver |

**Lưu ý**: kubelet client cert thường được tạo qua **TLS bootstrap** (kubelet gửi CSR, controller approve), không tạo trước.

### 5. scheduler & controller-manager

| File | CN | Mục đích |
|------|-----|---------|
| `scheduler.pem` / `scheduler-key.pem` | `system:kube-scheduler` | Client cert — scheduler → apiserver |
| `controller-manager.pem` / `controller-manager-key.pem` | `system:kube-controller-manager` | Client cert — controller-manager → apiserver |

### 6. Front proxy (API aggregation)

| File | CN | Mục đích |
|------|-----|---------|
| `front-proxy-client.pem` / `front-proxy-client-key.pem` | `front-proxy-client` | Client cert — apiserver → aggregation API |

### 7. Admin / kubectl

| File | CN | O | Mục đích |
|------|-----|---|---------|
| `admin.pem` / `admin-key.pem` | `kubernetes-admin` | `system:masters` | Client cert — kubectl → apiserver |

## File layout (kubeadm style)

> kubeadm dùng extension `.crt` / `.key` cho file trên disk, nhưng cfssl output `.pem` / `-key.pem`. Khi copy vào `/etc/kubernetes/pki/`, rename cho đồng nhất.

```
/etc/kubernetes/pki/
├── ca.crt                              # CA chính (= ca.pem)
├── ca.key                              # (= ca-key.pem)
├── apiserver.crt                       # apiserver server cert
├── apiserver.key
├── apiserver-etcd-client.crt           # apiserver → etcd
├── apiserver-etcd-client.key
├── apiserver-kubelet-client.crt        # apiserver → kubelet
├── apiserver-kubelet-client.key
├── front-proxy-ca.crt                  # front proxy CA
├── front-proxy-ca.key
├── front-proxy-client.crt
├── front-proxy-client.key
├── sa.key                              # service account signing key
├── sa.pub                              # service account verifying key
├── etcd/
│   ├── ca.crt                          # etcd CA
│   ├── ca.key
│   ├── server.crt                      # etcd server cert
│   ├── server.key
│   ├── peer.crt                        # etcd peer cert
│   ├── peer.key
│   ├── healthcheck-client.crt
│   └── healthcheck-client.key
├── scheduler.crt                       # scheduler client cert
├── scheduler.key
├── controller-manager.crt              # controller-manager client cert
└── controller-manager.key
```

### Rename cfssl output cho kubeadm style

```bash
# cfssl output: apiserver.pem, apiserver-key.pem
# kubeadm style: apiserver.crt, apiserver.key

cp ca.pem ca.crt
cp ca-key.pem ca.key
cp apiserver.pem apiserver.crt
cp apiserver-key.pem apiserver.key
# ... cho tất cả cert
```

## cfssl CSR config cho tất cả cert

### apiserver

```json
{
  "CN": "kube-apiserver",
  "hosts": [
    "kubernetes", "kubernetes.default", "kubernetes.default.svc",
    "kubernetes.default.svc.cluster.local", "localhost",
    "10.96.0.1", "10.0.0.1", "127.0.0.1",
    "192.168.56.100", "k8s-api.example.com"
  ],
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "kube-apiserver"}]
}
```

### admin

```json
{
  "CN": "kubernetes-admin",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"O": "system:masters"}]
}
```

### kubelet (per node)

```json
{
  "CN": "system:node:node-1",
  "hosts": ["node-1", "10.0.0.1"],
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"O": "system:nodes"}]
}
```

### etcd peer

```json
{
  "CN": "etcd-1",
  "hosts": ["etcd-1", "localhost", "10.0.0.1", "127.0.0.1"],
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "etcd-1"}]
}
```

### scheduler / controller-manager

```json
// scheduler-csr.json
{"CN": "system:kube-scheduler", "hosts": [], "key": {"algo": "rsa", "size": 2048}, "names": []}

// controller-manager-csr.json
{"CN": "system:kube-controller-manager", "hosts": [], "key": {"algo": "rsa", "size": 2048}, "names": []}
```

## Kubeconfig — cert nhúng trong kubeconfig

Cert thường nhúng trong kubeconfig file thay vì file riêng:

```yaml
# /etc/kubernetes/admin.conf
apiVersion: v1
kind: Config
clusters:
- name: kubernetes
  cluster:
    certificate-authority-data: <base64 ca.pem>      # CA
    server: https://10.0.0.1:6443                     # API server
users:
- name: kubernetes-admin
  user:
    client-certificate-data: <base64 admin.pem>       # client cert
    client-key-data: <base64 admin-key.pem>           # client key
contexts:
- name: kubernetes-admin@kubernetes
  context:
    cluster: kubernetes
    user: kubernetes-admin
current-context: kubernetes-admin@kubernetes
```

### Tạo kubeconfig bằng tay

```bash
# Set cluster
kubectl config set-cluster kubernetes \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://10.0.0.1:6443 \
  --kubeconfig=admin.kubeconfig

# Set credentials
kubectl config set-credentials kubernetes-admin \
  --client-certificate=admin.pem \
  --client-key=admin-key.pem \
  --embed-certs=true \
  --kubeconfig=admin.kubeconfig

# Set context
kubectl config set-context kubernetes-admin@kubernetes \
  --cluster=kubernetes \
  --user=kubernetes-admin \
  --kubeconfig=admin.kubeconfig

# Use context
kubectl config use-context kubernetes-admin@kubernetes \
  --kubeconfig=admin.kubeconfig
```

## Service Account key — khác biệt

SA key (`sa.key` / `sa.pub`) **không phải certificate** — chỉ là key pair:
- `sa.key` (private) — controller-manager dùng để **sign JWT** token cho ServiceAccount.
- `sa.pub` (public) — apiserver dùng để **verify JWT** token.

```bash
# Tạo SA key pair bằng cfssl
cfssl genkey sa-key.json | cfssljson -bare sa

# Hoặc đơn giản hơn bằng openssl (cfssl genkey tạo CSR, không cần cho SA)
openssl genrsa -out sa.key 2048
openssl rsa -in sa.key -pubout -out sa.pub

# JWT token được sign bằng sa.key
# apiserver verify bằng sa.pub
# Không cần CA, không cần cert, không cần SAN
```

## Liên hệ với Kubernetes

- **kubeadm** tự tạo tất cả cert này khi `kubeadm init` → nằm trong `/etc/kubernetes/pki/` (dùng cfssl internal).
- **Làm bằng tay** → tự tạo tất cả bằng cfssl CLI, copy đến đúng vị trí trên mỗi node.
- **Cert hết hạn** → `kubeadm certs check-expiration` để xem, `kubeadm certs renew` để renew.
- **Cert sai SAN** → lỗi phổ biến nhất khi setup K8s bằng tay. cfssl `hosts` array giúp tránh lỗi này.
- **Cert sai CN/O** → RBAC deny, component không có quyền.
- **CA key bị lộ** → toàn bộ cluster compromised — phải rotate CA (rất khó).
