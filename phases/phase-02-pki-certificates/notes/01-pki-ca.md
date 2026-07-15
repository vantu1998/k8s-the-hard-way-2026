# 01 — PKI & Certificate Authority

## PKI là gì

PKI (Public Key Infrastructure) là hệ thống quản lý **public key cryptography** — gồm CA, certificate, key pair, CRL, OCSP. PKI đảm bảo **identity** (ai là ai) và **encryption** (giao tiếp an toàn).

## Public Key Cryptography — cơ sở

Mỗi entity có **key pair**:
- **Private key** — giữ bí mật, ký/giải mã.
- **Public key** — công khai, verify/mã hóa.

```
Alice                              Bob
  │                                  │
  │  "Tôi là Alice, đây public key"  │
  │─────────────────────────────────>│
  │                                  │
  │  Làm sao Bob biết đây thật là    │
  │  Alice chứ không phải Mallory?   │
  │                                  │
  │  → Cần CA chứng nhận!            │
```

## Certificate — gì và tại sao

Certificate = **public key + identity + chữ ký CA**.

```
Certificate:
  Subject: CN=alice (ai)
  Public Key: RSA 2048 (khóa công khai)
  Issuer: CN=my-ca (ai ký)
  Signature: <CA private key ký hash của cert> (chứng nhận)
  Validity: 2026-01-01 to 2027-01-01 (thời hạn)
  SAN: alice.example.com, 10.0.0.1 (các tên/IP khác)
```

**Tại sao cần certificate thay vì chỉ gửi public key?**
- Bob verify cert bằng CA public key (CA đáng tin cậy).
- Nếu Mallory gửi key giả → cert không có chữ ký CA → Bob reject.

## CA (Certificate Authority)

CA là **entity đáng tin cậy** — ký certificate cho người khác.

### Root CA

Root CA = **self-signed** cert (tự ký chính mình). Đây là **trust anchor** — mọi chain of trust bắt đầu từ đây.

```
Root CA (self-signed)
  ├── ký → Server cert (kube-apiserver)
  ├── ký → Client cert (kubelet)
  └── ký → Intermediate CA (optional)
              └── ký → Server cert
```

### Intermediate CA

Intermediate CA = CA do Root CA ký. Dùng khi không muốn Root CA trực tiếp ký cert (bảo mật — Root CA offline).

```
Root CA (offline, trong vault)
  └── ký → Intermediate CA (online)
              ├── ký → Server cert A
              ├── ký → Server cert B
              └── ký → Server cert C
```

**Kubernetes thường dùng 1 Root CA cho tất cả** — không cần intermediate (cluster nội bộ, không public).

### Trust chain

```bash
# Verify chain bằng openssl (cfssl không có lệnh verify trực tiếp):
openssl verify -CAfile ca.pem server.pem
# server.pem: OK

# Với intermediate:
openssl verify -CAfile root-ca.pem -untrusted intermediate.pem server.pem
# server.pem: OK
```

## cfssl — công cụ tạo CA

cfssl (CloudFlare SSL) là tool phổ biến nhất trong Kubernetes ecosystem. kubeadm dùng cfssl internal để tạo cert. cfssl dùng **JSON config** thay vì CLI flags dài dòng.

### Cài đặt cfssl

```bash
# Download binary
curl -fsSL https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssl_1.6.5_linux_amd64 -o /usr/local/bin/cfssl
curl -fsSL https://github.com/cloudflare/cfssl/releases/download/v1.6.5/cfssljson_1.6.5_linux_amd64 -o /usr/local/bin/cfssljson
chmod +x /usr/local/bin/cfssl /usr/local/bin/cfssljson

# Kiểm tra
cfssl version
# Version: 1.6.5
# Runtime: go1.21.0
```

### cfssl vs openssl

| | cfssl | openssl |
|---|-------|---------|
| Config | JSON file | CLI flags |
| SAN | `hosts` array trong JSON | `-addext` hoặc `-extfile` |
| Key usage | `usages` array trong config | `-extfile` thủ công |
| Output | JSON → `cfssljson` tách file | File trực tiếp |
| Phổ biến trong | K8s ecosystem (kubeadm, kubespray) | General purpose |
| Verify | Không có `verify` — dùng `openssl verify` | `openssl verify` |

## Tạo Root CA bằng cfssl

### Bước 1: Tạo CA CSR config

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

### Bước 2: Tạo CA

```bash
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
# → ca.pem (cert), ca-key.pem (private key), ca.csr (CSR)
```

### Bước 3: Kiểm tra

```bash
# Xem cert detail bằng cfssl
cfssl certinfo -cert ca.pem

# Hoặc dùng openssl (chi tiết hơn)
openssl x509 -in ca.pem -text -noout
# Certificate:
#   Version: 3
#   Subject: CN=kubernetes-ca
#   Issuer: CN=kubernetes-ca    ← self-signed (Subject = Issuer)
#   Validity: Not Before: ... Not After: ... (10 năm — 87600h)
#   Public Key: RSA (2048 bit)
#   X509v3 Basic Constraints: critical, CA:TRUE    ← đây là CA
#   X509v3 Key Usage: Certificate Sign, CRL Sign   ← có quyền ký cert
```

### Giải thích config

| Field | Ý nghĩa |
|-------|---------|
| `CN` | Common Name — identity của CA |
| `key.algo` | Thuật toán (rsa, ecdsa) |
| `key.size` | Key size (2048, 4096 cho RSA) |
| `names[].CN` | Thêm CN vào subject |
| `ca.expiry` | CA cert validity — `87600h` = 10 năm |

### cfssljson — tách JSON output

`cfssl gencert` xuất JSON ra stdout. `cfssljson -bare <prefix>` tách thành:
- `<prefix>.pem` — certificate
- `<prefix>-key.pem` — private key
- `<prefix>.csr` — CSR

```bash
# Không có cfssljson:
cfssl gencert -initca ca-csr.json > ca-response.json
# ca-response.json chứa cả cert + key + CSR trong 1 JSON

# Có cfssljson:
cfssl gencert -initca ca-csr.json | cfssljson -bare ca
# → ca.pem, ca-key.pem, ca.csr (3 file riêng)
```

## Signing config — ca-config.json

cfssl dùng **ca-config.json** để định nghĩa cách ký cert:

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

### Giải thích

| Field | Ý nghĩa |
|-------|---------|
| `signing.default` | Profile mặc định khi ký không chỉ định profile |
| `signing.profiles.server` | Profile cho server cert — EKU: `serverAuth` |
| `signing.profiles.client` | Profile cho client cert — EKU: `clientAuth` |
| `signing.profiles.peer` | Profile cho mTLS cert — EKU: cả `serverAuth` + `clientAuth` |
| `expiry` | Validity period — `8760h` = 1 năm |
| `usages` | Key usage + EKU — `signing` = digitalSignature, `key encipherment` = keyEncipherment |

### Usages trong cfssl

| cfssl usage | X509 KU/EKU |
|-------------|-------------|
| `signing` | digitalSignature |
| `key encipherment` | keyEncipherment |
| `server auth` | extendedKeyUsage: serverAuth |
| `client auth` | extendedKeyUsage: clientAuth |
| `cert sign` | keyCertSign (chỉ CA) |

## Kubernetes CA hierarchy

Kubernetes dùng **nhiều CA** cho mục đích khác nhau:

| CA | Dùng cho | File |
|----|---------|------|
| `kubernetes-ca` | apiserver, kubelet, scheduler, controller-manager | `ca.pem` / `ca-key.pem` |
| `etcd-ca` | etcd server + peer cert | `etcd/ca.pem` / `etcd/ca-key.pem` |
| `front-proxy-ca` | aggregation layer (API proxy) | `front-proxy-ca.pem` |
| `service-account-key` | Sign JWT token (không phải CA, chỉ key pair) | `sa.pub` / `sa.key` |

**kubeadm** tự tạo tất cả CA này khi `kubeadm init` (dùng cfssl internal). Khi làm bằng tay, tự tạo bằng cfssl CLI.

## Liên hệ với Kubernetes

- Mọi giao tiếp trong Kubernetes **mã hóa bằng TLS** — apiserver↔kubelet, kubelet↔etcd, client↔apiserver.
- Mỗi component cần **certificate** để chứng minh identity.
- CA là **trust root** — tất cả component trust cùng 1 CA.
- Nếu CA key bị lộ → toàn bộ cluster compromised (attacker có thể tạo cert giả cho bất kỳ component nào).
- Cert rotation: `kubeadm certs renew` — renew cert nhưng giữ CA (dùng cfssl internal).
- CA rotation: phức tạp hơn — cần rollout CA mới cho tất cả component.
