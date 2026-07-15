# 03 — CSR, SAN, CN

## CSR (Certificate Signing Request)

CSR = **yêu cầu** gửi đến CA để ký thành certificate. CSR chứa:
- Public key của requester.
- Identity (CN, O, OU).
- SAN (DNS, IP).
- Signature bằng private key (chứng minh requester sở hữu key pair).

### Tạo CSR bằng cfssl

cfssl dùng **JSON config** thay vì CLI flags. CSR config chứa CN, key, hosts (SAN), names:

```bash
cat > apiserver-csr.json << 'EOF'
{
  "CN": "kube-apiserver",
  "hosts": [
    "kubernetes",
    "kubernetes.default",
    "kubernetes.default.svc",
    "kubernetes.default.svc.cluster.local",
    "localhost",
    "10.96.0.1",
    "10.0.0.1",
    "127.0.0.1"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "CN": "kube-apiserver"
    }
  ]
}
EOF
```

### Ký CSR — tạo cert + key cùng lúc

```bash
# cfssl gencert tạo key + CSR + ký cert trong 1 lệnh
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=server \
  apiserver-csr.json | cfssljson -bare apiserver

# → apiserver.pem (cert), apiserver-key.pem (private key), apiserver.csr (CSR)
```

### Kiểm tra cert

```bash
# Xem cert detail bằng cfssl
cfssl certinfo -cert apiserver.pem

# Hoặc openssl
openssl x509 -in apiserver.pem -text -noout
# Certificate:
#   Subject: CN=kube-apiserver
#   Issuer: CN=kubernetes-ca
#   X509v3 Subject Alternative Name:
#     DNS:kubernetes, DNS:kubernetes.default, IP:10.96.0.1, IP:10.0.0.1
```

### CSR structure

```
CSR (PKCS#10 format):
├── Version
├── Subject (CN, O, OU, C, ST, L)
├── Public Key (RSA/ECDSA)
├── Attributes
│   └── extensionRequest
│       └── subjectAltName (SAN)
└── Signature (requester's private key)
```

### cfssl CSR config — giải thích

| Field | Ý nghĩa | Tương đương openssl |
|-------|---------|---------------------|
| `CN` | Common Name | `-subj "/CN=..."` |
| `hosts` | SAN entries (DNS + IP混在一起) | `-addext "subjectAltName=..."` |
| `key.algo` | Thuật toán key | `genrsa` (rsa) |
| `key.size` | Key size | `2048` |
| `names[].CN` | Thêm CN vào subject | `-subj "/CN=..."` |
| `names[].O` | Organization | `-subj "/CN=.../O=..."` |

> **Lưu ý**: cfssl `hosts` array chứa cả DNS và IP — cfssl tự nhận biết DNS vs IP (nếu là IP thì thêm `IP:`, nếu là DNS thì thêm `DNS:`).

## SAN (Subject Alternative Name)

SAN = danh sách **tên/IP** mà certificate hợp lệ. Khi client kết nối, client kiểm tra: "server IP/DNS có trong SAN không?"

### Tại sao cần SAN (không chỉ CN)

Trước đây, client match **CN (Common Name)** với hostname. Nhưng:
- CN chỉ chứa 1 giá trị.
- Server có thể truy cập qua nhiều tên: `kubernetes`, `10.96.0.1`, `10.0.0.1`, `kubernetes.default.svc`.
- RFC 2818: **nên dùng SAN**, CN chỉ là fallback.

**Kubernetes yêu cầu SAN** — nếu cert không có SAN đúng → connection fail.

### Loại SAN

| Loại | Ví dụ | Khi nào dùng |
|------|-------|-------------|
| DNS | `kubernetes.default.svc.cluster.local` | Truy cập qua DNS name |
| IP | `10.96.0.1`, `10.0.0.1` | Truy cập qua IP |
| URI | `spiffe://cluster.local/ns/default/sa/myapp` | SPIFFE identity (service mesh) |
| Email | `admin@example.com` | S/MIME (không liên quan K8s) |

### SAN cho kube-apiserver

kube-apiserver cần SAN cho **mọi endpoint** client có thể dùng:

```json
// Trong cfssl CSR config:
"hosts": [
  "kubernetes",                              // short name
  "kubernetes.default",                      // namespace
  "kubernetes.default.svc",                  // svc suffix
  "kubernetes.default.svc.cluster.local",    // FQDN
  "localhost",                               // localhost
  "10.96.0.1",                               // ClusterIP của kubernetes service
  "10.0.0.1",                                // IP node master 1
  "10.0.0.2",                                // IP node master 2 (HA)
  "10.0.0.3",                                // IP node master 3 (HA)
  "127.0.0.1"                                // localhost IP
]
```

### Debug SAN mismatch

```bash
# Lỗi phổ biến: "certificate signed by unknown authority" hoặc "x509: certificate is valid for X, not Y"

# Kiểm tra SAN trong cert bằng cfssl
cfssl certinfo -cert apiserver.pem | jq .certificates[0].subject_alt_name
# hoặc
openssl x509 -in apiserver.pem -text -noout | grep -A1 "Alternative Name"
# X509v3 Subject Alternative Name:
#   DNS:kubernetes, DNS:kubernetes.default, IP:10.96.0.1, IP:10.0.0.1

# Test connection với tên không có trong SAN
openssl s_client -connect 10.0.0.1:6443 -servername wrong.name
# → error: certificate verify failed
```

## CN (Common Name) — RBAC trong Kubernetes

Trong Kubernetes, **CN = username**, **O = group** cho RBAC:

```bash
# cfssl CSR config với CN=admin, O=system:masters
cat > admin-csr.json << 'EOF'
{
  "CN": "kubernetes-admin",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "system:masters"
    }
  ]
}
EOF

# Ký cert
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem \
  -config=ca-config.json -profile=client \
  admin-csr.json | cfssljson -bare admin

# Khi client dùng cert này → Kubernetes thấy:
# User: kubernetes-admin (từ CN)
# Groups: system:masters (từ names[].O)
# → RBAC check: kubernetes-admin có quyền gì? system:masters có quyền gì?
```

### Kubernetes RBAC mapping

| Cert CN | Cert O | K8s Identity | Quyền |
|---------|--------|-------------|-------|
| `kube-apiserver` | — | Server identity | — (server cert, không RBAC) |
| `kubernetes-admin` | `system:masters` | User: kubernetes-admin, Group: system:masters | Cluster admin (full access) |
| `system:kube-scheduler` | — | User: system:kube-scheduler | Built-in Role: system:kube-scheduler |
| `system:kube-controller-manager` | — | User: system:kube-controller-manager | Built-in Role: system:kube-controller-manager |
| `system:node:node-1` | `system:nodes` | User: system:node:node-1, Group: system:nodes | Node authorizer (chỉ quản lý pod trên node mình) |
| `system:serviceaccount:default:myapp` | `system:serviceaccounts` | SA: default/myapp | Tùy RoleBinding |

### Format đặc biệt

- **Kubelet**: `CN=system:node:<node-name>` — Node authorizer check node name.
- **Service Account**: `CN=system:serviceaccount:<namespace>:<name>` — SA identity.
- **Scheduler/Controller**: `CN=system:kube-scheduler` / `CN=system:kube-controller-manager` — built-in user.

### cfssl CSR cho kubelet (CN + O + SAN)

```json
{
  "CN": "system:node:node-1",
  "hosts": [
    "node-1",
    "10.0.0.1"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "O": "system:nodes"
    }
  ]
}
```

## Liên hệ với Kubernetes

- **CSR object trong K8s**: Kubernetes có CSR resource (`kubectl get csr`) — kubelet TLS bootstrap gửi CSR qua API server.
- **CSR approval**: CA controller (hoặc admin) approve CSR → controller ký CSR bằng CA → cert trả về.
- **TLS bootstrap**: kubelet start không có cert → gửi CSR → approved → nhận cert → dùng cert gọi API server.
- **Cert với CN sai** → RBAC deny → "forbidden" error.
- **Cert với SAN sai** → TLS handshake fail → "certificate signed by unknown authority".
- **cfssl `hosts` array** = cách dễ nhất để khai báo SAN — không cần phân biệt DNS vs IP, cfssl tự nhận.
