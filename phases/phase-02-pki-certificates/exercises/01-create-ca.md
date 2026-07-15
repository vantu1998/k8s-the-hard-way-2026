# Exercise 01 — Tạo Root CA bằng cfssl

> **Mục tiêu**: Tạo CA key pair + self-signed CA cert — trust anchor cho toàn bộ cluster.
>
> **Thời gian dự kiến**: 15 phút
>
> **Yêu cầu**: Linux VM, `cfssl`, `cfssljson`, `openssl` (verify), `jq`

## Bối cảnh

Mọi cert trong Kubernetes đều được ký bởi CA. Bài này tạo Root CA — bước đầu tiên trước khi tạo bất kỳ cert nào khác.

## Bước 1: Cài cfssl

```bash
# Download cfssl + cfssljson
curl -fsSL https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssl_1.6.5_linux_amd64 -o /usr/local/bin/cfssl
curl -fsSL https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssljson_1.6.5_linux_amd64 -o /usr/local/bin/cfssljson
chmod +x /usr/local/bin/cfssl /usr/local/bin/cfssljson

# Kiểm tra
cfssl version
# Version: 1.6.5
# Runtime: go1.21.0
```

**Kiểm tra**: `cfssl version` hiện version 1.6.5.

## Bước 2: Tạo thư mục làm việc

```bash
mkdir -p /tmp/k8s-certs
cd /tmp/k8s-certs
```

## Bước 3: Tạo CA CSR config

```bash
cat > ca-csr.json << 'EOF'
{
  "CN": "kubernetes-ca",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "CN": "kubernetes-ca"
    }
  ],
  "ca": {
    "expiry": "87600h"
  }
}
EOF
```

### Giải thích config

| Field | Ý nghĩa |
|-------|---------|
| `CN` | Common Name = `kubernetes-ca` |
| `key.algo` | RSA |
| `key.size` | 2048 bit |
| `ca.expiry` | CA cert valid 10 năm (`87600h`) |

**Kiểm tra**: `ca-csr.json` tồn tại, JSON hợp lệ (`jq . ca-csr.json`).

## Bước 4: Tạo CA

```bash
cfssl gencert -initca ca-csr.json | cfssljson -bare ca

# Output:
# ca.pem (certificate)
# ca-key.pem (private key)
# ca.csr (CSR)
```

**Kiểm tra**: 3 files: `ca.pem`, `ca-key.pem`, `ca.csr`.

## Bước 5: Inspect CA cert

```bash
# Cách 1: cfssl certinfo
cfssl certinfo -cert ca.pem | jq .
# {
#   "subject": {"CN": "kubernetes-ca"},
#   "issuer": {"CN": "kubernetes-ca"},    ← self-signed (subject = issuer)
#   "serial_number": "...",
#   "not_before": "2026-01-15T...",
#   "not_after": "2036-01-15T...",        ← 10 năm
#   "is_ca": true,                        ← đây là CA
#   ...
# }

# Cách 2: openssl (chi tiết hơn)
openssl x509 -in ca.pem -text -noout
# Certificate:
#   Version: 3
#   Subject: CN=kubernetes-ca
#   Issuer: CN=kubernetes-ca          ← self-signed
#   Validity: Not Before: ... Not After: ... (10 năm)
#   X509v3 Basic Constraints: critical, CA:TRUE
#   X509v3 Key Usage: Certificate Sign, CRL Sign
```

**Kiểm tra**: `Issuer = Subject`, `is_ca: true`, validity 10 năm.

## Bước 6: Verify self-signed cert

```bash
# cfssl không có verify — dùng openssl
openssl verify -CAfile ca.pem ca.pem
# ca.pem: OK
```

**Kiểm tra**: `openssl verify` trả về `OK`.

## Bước 7: Tạo signing config (ca-config.json)

```bash
cat > ca-config.json << 'EOF'
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
EOF
```

### Giải thích profiles

| Profile | EKU | Dùng cho |
|---------|-----|----------|
| `server` | `serverAuth` | Server cert (apiserver, kubelet server, etcd server) |
| `client` | `clientAuth` | Client cert (admin, scheduler, controller-manager) |
| `peer` | `serverAuth` + `clientAuth` | mTLS cert (etcd peer) |

**Kiểm tra**: `ca-config.json` tồn tại, JSON hợp lệ.

## Bước 8: Tạo etcd CA (separate CA)

```bash
cat > etcd-ca-csr.json << 'EOF'
{
  "CN": "etcd-ca",
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "etcd-ca"}],
  "ca": {"expiry": "87600h"}
}
EOF

cfssl gencert -initca etcd-ca-csr.json | cfssljson -bare etcd-ca

# Verify
openssl verify -CAfile etcd-ca.pem etcd-ca.pem
# etcd-ca.pem: OK
```

**Kiểm tra**: `etcd-ca.pem` tồn tại, verify OK.

## Bước 9: Tạo front-proxy CA

```bash
cat > front-proxy-ca-csr.json << 'EOF'
{
  "CN": "kubernetes-front-proxy-ca",
  "key": {"algo": "rsa", "size": 2048},
  "names": [{"CN": "kubernetes-front-proxy-ca"}],
  "ca": {"expiry": "87600h"}
}
EOF

cfssl gencert -initca front-proxy-ca-csr.json | cfssljson -bare front-proxy-ca

openssl verify -CAfile front-proxy-ca.pem front-proxy-ca.pem
# front-proxy-ca.pem: OK
```

**Kiểm tra**: `front-proxy-ca.pem` tồn tại, verify OK.

## Bước 10: Tạo service account key pair

```bash
# SA key — KHÔNG phải cert, chỉ key pair
# Dùng openssl cho đơn giản (cfssl genkey tạo CSR, không cần cho SA)
openssl genrsa -out sa.key 2048
openssl rsa -in sa.key -pubout -out sa.pub

# Verify
openssl rsa -in sa.key -pubout 2>/dev/null | diff - sa.pub
# (no output = identical)
```

**Kiểm tra**: `sa.key` + `sa.pub` tồn tại.

## Tổng kết files đã tạo

```
/tmp/k8s-certs/
├── ca-csr.json                # CA CSR config
├── ca-config.json             # Signing config (profiles)
├── ca.pem                     # CA cert (public)
├── ca-key.pem                 # CA private key (BÍ MẬT)
├── ca.csr                     # CA CSR (intermediate)
├── etcd-ca-csr.json
├── etcd-ca.pem                # etcd CA cert
├── etcd-ca-key.pem            # etcd CA private key (BÍ MẬT)
├── front-proxy-ca-csr.json
├── front-proxy-ca.pem         # front-proxy CA cert
├── front-proxy-ca-key.pem     # front-proxy CA private key (BÍ MẬT)
├── sa.key                     # SA signing key (BÍ MẬT)
└── sa.pub                     # SA verifying key
```

## Cleanup (sau khi hoàn thành tất cả exercises)

```bash
# Giữ lại cho exercise 02+
# rm -rf /tmp/k8s-certs
```

## Câu hỏi tự kiểm tra

1. Tại sao CA cert self-signed (Issuer = Subject)?
2. `ca.expiry: "87600h"` nghĩa là bao lâu? Tại sao CA valid lâu hơn component cert?
3. `ca-config.json` có 3 profiles: `server`, `client`, `peer` — khác nhau thế nào?
4. Tại sao Kubernetes dùng CA riêng cho etcd thay vì dùng CA chung?
5. SA key pair khác gì so với CA? Tại sao không cần cert?

## Đáp án tham khảo

1. Vì Root CA không có CA nào ở trên để ký cho nó. Self-signed = trust anchor — mọi người tin CA này vì họ chọn tin nó.
2. 87600 giờ = 10 năm. CA valid lâu vì rotation CA rất khó (phải rollout tất cả component). Component cert valid 1 năm — dễ rotate.
3. `server` = `serverAuth` (server cert). `client` = `clientAuth` (client cert). `peer` = cả 2 (mTLS — etcd peer vừa là server vừa là client).
4. Cách ly — nếu etcd CA bị compromise, K8s CA không bị ảnh hưởng. Etcd là dữ liệu nhạy cảm nhất cluster.
5. SA key chỉ sign/verify JWT, không cần identity (CN, SAN). Cert cần cho TLS (identity + encryption), SA key chỉ cho JWT signing.
