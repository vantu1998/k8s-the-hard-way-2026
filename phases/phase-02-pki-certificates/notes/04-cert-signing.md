# 04 — Certificate Signing

## Quá trình CA ký CSR

CA nhận CSR → verify CSR signature → tạo certificate → ký → trả về.

```
CSR (requester)                     CA
  │                                   │
  │  1. Gửi CSR                        │
  │──────────────────────────────────>│
  │                                   │
  │  2. CA verify CSR signature       │
  │     (dùng public key trong CSR)   │
  │                                   │
  │  3. CA tạo certificate:           │
  │     - Copy public key từ CSR      │
  │     - Copy subject (CN, O)        │
  │     - Copy SAN từ CSR             │
  │     - Thêm issuer (CN của CA)     │
  │     - Thêm serial number          │
  │     - Thêm validity (notBefore,   │
  │       notAfter)                   │
  │     - Thêm key usage              │
  │     - Thêm extended key usage     │
  │                                   │
  │  4. CA ký certificate:            │
  │     - Hash cert content (SHA256)  │
  │     - Encrypt hash bằng CA        │
  │       private key → signature     │
  │                                   │
  │  5. Trả về certificate             │
  │<──────────────────────────────────│
```

## Ký cert bằng cfssl

cfssl gộp **tạo key + CSR + ký cert** trong 1 lệnh `gencert`:

```bash
# CA đã có: ca.pem, ca-key.pem (từ -initca)
# ca-config.json đã có (định nghĩa profiles)

# CSR config cho apiserver
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

# Ký cert — 1 lệnh duy nhất
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=server \
  apiserver-csr.json | cfssljson -bare apiserver

# → apiserver.pem (cert), apiserver-key.pem (private key), apiserver.csr (CSR)
```

### Giải thích lệnh gencert

| Flag | Ý nghĩa |
|------|---------|
| `-ca=ca.pem` | CA certificate |
| `-ca-key=ca-key.pem` | CA private key |
| `-config=ca-config.json` | Signing config (profiles, expiry, usages) |
| `-profile=server` | Dùng profile "server" từ ca-config.json |
| `apiserver-csr.json` | CSR config (CN, hosts, key) |
| `cfssljson -bare apiserver` | Tách JSON output thành apiserver.pem, apiserver-key.pem, apiserver.csr |

### cfssl gencert vs openssl

| | cfssl gencert | openssl |
|---|---------------|---------|
| Tạo key | ✅ Tự động (từ CSR config) | `openssl genrsa` riêng |
| Tạo CSR | ✅ Tự động | `openssl req -new` riêng |
| Ký cert | ✅ Tự động | `openssl x509 -req` riêng |
| SAN | ✅ Tự copy từ `hosts` | ❌ Phải chỉ định lại qua `-extfile` |
| Key usage | ✅ Từ profile trong config | ❌ Phải chỉ định qua `-extfile` |
| Số lệnh | 1 lệnh | 3 lệnh + extfile |

> **Lợi thế lớn nhất của cfssl**: SAN tự động copy từ `hosts` array. Với openssl, phải khai báo SAN 2 lần (trong CSR và trong extfile khi ký) — dễ quên → cert không có SAN → TLS fail.

## Key Usage & Extended Key Usage

Key Usage (KU) — cert dùng cho mục đích gì:

| KU | cfssl usage | Ý nghĩa |
|----|-------------|---------|
| `digitalSignature` | `signing` | Ký digital (TLS handshake) |
| `keyEncipherment` | `key encipherment` | Mã hóa key (RSA key exchange) |
| `keyCertSign` | `cert sign` | Ký cert khác (chỉ CA) |

Extended Key Usage (EKU) — mục đích cụ thể hơn:

| EKU | cfssl usage | Ý nghĩa |
|-----|-------------|---------|
| `serverAuth` | `server auth` | Server cert (TLS server) |
| `clientAuth` | `client auth` | Client cert (TLS client) |

### K8s cert key usage — cfssl profiles

| Cert | Profile | cfssl usages |
|------|---------|-------------|
| CA | (initca) | `cert sign` (tự động) |
| apiserver (server) | `server` | `signing`, `key encipherment`, `server auth` |
| kubelet (client) | `client` | `signing`, `key encipherment`, `client auth` |
| kubelet (server) | `server` | `signing`, `key encipherment`, `server auth` |
| etcd (server) | `peer` | `signing`, `key encipherment`, `server auth`, `client auth` |
| etcd (peer) | `peer` | `signing`, `key encipherment`, `server auth`, `client auth` |
| scheduler (client) | `client` | `signing`, `key encipherment`, `client auth` |
| controller-manager (client) | `client` | `signing`, `key encipherment`, `client auth` |

### Định nghĩa profiles trong ca-config.json

```json
{
  "signing": {
    "default": {
      "expiry": "8760h",
      "usages": ["signing", "key encipherment", "server auth"]
    },
    "profiles": {
      "server": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "server auth"]
      },
      "client": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "client auth"]
      },
      "peer": {
        "expiry": "8760h",
        "usages": ["signing", "key encipherment", "server auth", "client auth"]
      }
    }
  }
}
```

## Verify certificate

cfssl không có lệnh `verify` — dùng `openssl verify`:

```bash
# Verify cert được ký bởi CA
openssl verify -CAfile ca.pem apiserver.pem
# apiserver.pem: OK

# Verify với intermediate CA
openssl verify -CAfile root-ca.pem -untrusted intermediate.pem server.pem
# server.pem: OK
```

### Inspect cert bằng cfssl

```bash
# Xem cert detail bằng cfssl
cfssl certinfo -cert apiserver.pem

# Output JSON:
# {
#   "subject": {"CN": "kube-apiserver"},
#   "issuer": {"CN": "kubernetes-ca"},
#   "serial_number": "1234...",
#   "not_before": "2026-01-15T10:00:00Z",
#   "not_after": "2027-01-15T10:00:00Z",
#   "subject_alt_name": {
#     "DNS_names": ["kubernetes", "kubernetes.default", ...],
#     "IP_addresses": ["10.96.0.1", "10.0.0.1", ...]
#   },
#   "usages": ["Digital Signature", "Key Encipherment", "Server Auth"]
# }
```

### Inspect cert bằng openssl

```bash
# Chi tiết hơn
openssl x509 -in apiserver.pem -text -noout
# Certificate:
#   Version: 3
#   Serial Number: 1234...
#   Signature Algorithm: sha256WithRSAEncryption
#   Issuer: CN=kubernetes-ca
#   Validity: Not Before: Jan 15 10:00:00 2026 GMT
#             Not After:  Jan 15 10:00:00 2027 GMT
#   Subject: CN=kube-apiserver
#   Subject Public Key Info: RSA (2048 bit)
#   X509v3 extensions:
#     X509v3 Key Usage: digitalSignature, keyEncipherment
#     X509v3 Extended Key Usage: TLS Web Server Authentication
#     X509v3 Subject Alternative Name:
#       DNS:kubernetes, DNS:kubernetes.default, IP:10.96.0.1
```

## Serial number

cfssl tự generate serial number ngẫu nhiên cho mỗi cert:

```bash
# Xem serial
cfssl certinfo -cert apiserver.pem | jq .serial_number
# "1234567890abcdef..."

# openssl
openssl x509 -in apiserver.pem -noout -serial
# serial=1234...
```

> Khác openssl (`-CAcreateserial` tăng serial tuần tự), cfssl dùng **random serial** — an toàn hơn, khó đoán.

## Validity period

```bash
# Kiểm tra validity bằng cfssl
cfssl certinfo -cert apiserver.pem | jq '{not_before, not_after}'

# Hoặc openssl
openssl x509 -in apiserver.pem -noout -dates
# notBefore=Jan 15 10:00:00 2026 GMT
# notAfter=Jan 15 10:00:00 2027 GMT

# Kiểm tra cert còn hạn không
openssl x509 -in apiserver.pem -checkend 86400
# Certificate will not expire (still good for 86400 seconds)
```

### K8s cert validity

| Cert | Validity (kubeadm default) | cfssl expiry |
|------|---------------------------|-------------|
| CA | 10 năm | `87600h` |
| apiserver | 1 năm | `8760h` |
| kubelet | 1 năm | `8760h` |
| etcd | 1 năm | `8760h` |
| scheduler/controller-manager | 1 năm | `8760h` |
| front-proxy | 1 năm | `8760h` |

**kubeadm cert hết hạn sau 1 năm** → cần `kubeadm certs renew` trước khi hết.

## Liên hệ với Kubernetes

- **Cert rotation**: `kubeadm certs renew` — renew tất cả cert, giữ CA (dùng cfssl internal).
- **Cert expiry check**: `kubeadm certs check-expiration` — xem khi nào hết hạn.
- **Auto rotation**: kubelet tự rotate client cert qua CSR (nếu bật `rotateCertificates: true`).
- **Cert expired → cluster down**: component không kết nối được → lỗi "x509: certificate has expired".
- **Debug**: `cfssl certinfo -cert <cert>` hoặc `openssl x509 -in <cert> -checkend 0` — check hết hạn.
