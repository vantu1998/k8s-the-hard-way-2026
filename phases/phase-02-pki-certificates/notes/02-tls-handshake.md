# 02 — TLS Handshake

## TLS là gì

TLS (Transport Layer Security) mã hóa giao tiếp giữa client và server. Trước TLS là SSL (đã deprecated). Kubernetes dùng TLS cho **mọi connection**.

## TLS 1.2 Handshake — step by step

```
Client                                    Server
  │                                         │
  │  1. ClientHello                         │
  │  - TLS version                          │
  │  - Cipher suites (supported)            │
  │  - Client random (32 bytes)             │
  │  - SNI (Server Name Indication)         │
  │────────────────────────────────────────>│
  │                                         │
  │  2. ServerHello                         │
  │  - Chosen TLS version                   │
  │  - Chosen cipher suite                  │
  │  - Server random (32 bytes)             │
  │<────────────────────────────────────────│
  │                                         │
  │  3. Certificate                         │
  │  - Server cert (public key + identity)  │
  │  - Chain: server → intermediate → root  │
  │<────────────────────────────────────────│
  │                                         │
  │  4. ServerKeyExchange (optional)        │
  │  - DH/ECDH params                       │
  │<────────────────────────────────────────│
  │                                         │
  │  5. ServerHelloDone                     │
  │<────────────────────────────────────────│
  │                                         │
  │  === Client verify cert ===             │
  │  - Check CA trust chain                 │
  │  - Check SAN matches                    │
  │  - Check validity date                  │
  │  - Check revocation (CRL/OCSP)          │
  │                                         │
  │  6. ClientKeyExchange                   │
  │  - Pre-master secret (encrypted)        │
  │  - OR DH/ECDH public value              │
  │────────────────────────────────────────>│
  │                                         │
  │  === Cả 2 tính session key ===          │
  │  master_secret = PRF(                   │
  │    pre_master,                          │
  │    client_random,                       │
  │    server_random                        │
  │  )                                      │
  │  → session key (symmetric)              │
  │                                         │
  │  7. ChangeCipherSpec                    │
  │  - "Từ giờ mã hóa"                      │
  │────────────────────────────────────────>│
  │                                         │
  │  8. Finished (encrypted)                │
  │  - Verify data                          │
  │────────────────────────────────────────>│
  │                                         │
  │  9. ChangeCipherSpec                    │
  │<────────────────────────────────────────│
  │                                         │
  │ 10. Finished (encrypted)                │
  │<────────────────────────────────────────│
  │                                         │
  │  === Encrypted data flowing ===         │
  │<──────────────────────────────────────->│
```

### Tóm tắt

1. **Hello** — client + server thỏa thuật toán.
2. **Certificate** — server gửi cert, client verify.
3. **Key exchange** — trao đổi key material, tính session key.
4. **ChangeCipherSpec** — chuyển sang mã hóa.
5. **Finished** — verify handshake thành công.
6. **Data** — giao tiếp mã hóa bằng session key (symmetric).

## TLS 1.3 — đơn giản hơn

TLS 1.3 giảm round trip từ 2 xuống 1 (1-RTT):

```
Client                                    Server
  │                                         │
  │  ClientHello                            │
  │  - TLS 1.3                              │
  │  - Key share (ECDH public value)        │  ← gửi luôn key material
  │  - SNI                                  │
  │────────────────────────────────────────>│
  │                                         │
  │  ServerHello                            │
  │  - Key share (ECDH public value)        │  ← server tính session key ngay
  │  - Encrypted extensions                 │
  │  - Certificate (encrypted)              │
  │  - CertificateVerify                    │
  │  - Finished                             │
  │<────────────────────────────────────────│
  │                                         │
  │  Finished                               │
  │────────────────────────────────────────>│
  │                                         │
  │  === Encrypted data flowing ===         │
  │<──────────────────────────────────────->│
```

### Khác biệt TLS 1.2 vs 1.3

| | TLS 1.2 | TLS 1.3 |
|---|---------|---------|
| Round trips | 2-RTT | 1-RTT (hoặc 0-RTT resume) |
| Key exchange | RSA hoặc DH/ECDH | **Chỉ ECDH** (RSA bị loại — không forward secrecy) |
| Cipher suites | Nhiều, gồm yếu | Ít hơn, mạnh hơn (AEAD only) |
| Certificate | Plaintext | **Encrypted** |
| Session resumption | RTT thêm | 0-RTT possible |
| Compression | Có (BLEACH attack) | **Bỏ** |

## mTLS (Mutual TLS)

Trong TLS thường, chỉ **server** gửi cert. Trong mTLS, **cả client và server** gửi cert:

```
Client                                    Server
  │  ClientHello                           │
  │────────────────────────────────────────>│
  │  ServerHello + Certificate             │
  │<────────────────────────────────────────│
  │  CertificateRequest                    │  ← server yêu cầu client cert
  │<────────────────────────────────────────│
  │  Certificate (client cert)             │  ← client gửi cert
  │────────────────────────────────────────>│
  │  ...                                   │
```

**Kubernetes dùng mTLS ở nhiều nơi**:
- kubelet → apiserver: kubelet gửi client cert.
- apiserver → kubelet: apiserver gửi server cert.
- etcd members ↔ etcd members: mTLS (peer cert).
- apiserver → etcd: apiserver gửi client cert.

## Verify TLS handshake bằng openssl

> cfssl tạo cert nhưng không có tool test TLS handshake. Dùng `openssl s_client` để debug — đây là tool #1 cho TLS issue.

```bash
# Test TLS handshake đến server
openssl s_client -connect 10.0.0.1:6443 -showcerts
# CONNECTED
# ---
# Certificate chain
#  0 s: CN=kube-apiserver
#    i: CN=kubernetes-ca
# ---
# Server certificate
# subject=CN=kube-apiserver
# issuer=CN=kubernetes-ca
# ---
# SSL handshake has read 1234 bytes
# New, TLSv1.3, Cipher is TLS_AES_128_GCM_SHA256

# Test với SNI
openssl s_client -connect 10.0.0.1:6443 -servername kubernetes

# Test mTLS (client cert)
openssl s_client -connect 10.0.0.1:6443 \
  -cert client.pem -key client-key.pem \
  -CAfile ca.pem
```

## Liên hệ với Kubernetes

- **kube-apiserver** listen trên 6443 với TLS — mọi client phải verify server cert.
- **SAN trong apiserver cert** phải chứa: `kubernetes`, `kubernetes.default`, `kubernetes.default.svc`, `kubernetes.default.svc.cluster.local`, `10.96.0.1` (service IP), IP node.
- **kubelet** listen trên 10250 với TLS — apiserver verify kubelet server cert.
- **etcd** listen trên 2379 (client) + 2380 (peer) với mTLS.
- **Cert hết hạn** → component không kết nối được → cluster down.
- `openssl s_client -connect <ip>:<port>` là debug tool #1 cho TLS issue.
