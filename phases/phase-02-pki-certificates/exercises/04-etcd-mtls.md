# Exercise 04 — Tạo etcd peer cert mTLS, test handshake

> **Mục tiêu**: Tạo etcd server + peer cert với mTLS bằng cfssl, test TLS handshake bằng `openssl s_client`.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Đã làm Exercise 01 (có `etcd-ca.pem`, `etcd-ca-key.pem`, `ca-config.json`), `openssl`

## Bối cảnh

etcd dùng mTLS cho cả client connection (2379) và peer connection (2380). Mỗi etcd member cần:
- **Server cert** — client kết nối đến etcd.
- **Peer cert** — etcd member kết nối đến etcd member khác (mTLS cả 2 chiều).

## Bước 1: Tạo etcd server cert

```bash
cd /tmp/k8s-certs

cat > etcd-server-csr.json << 'EOF'
{
  "CN": "etcd-server",
  "hosts": [
    "localhost",
    "etcd-1",
    "10.0.0.1",
    "127.0.0.1"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "CN": "etcd-server"
    }
  ]
}
EOF

# Ký với profile=peer (etcd server cần cả serverAuth + clientAuth)
cfssl gencert \
  -ca=etcd-ca.pem \
  -ca-key=etcd-ca-key.pem \
  -config=ca-config.json \
  -profile=peer \
  etcd-server-csr.json | cfssljson -bare etcd-server

# Verify
openssl verify -CAfile etcd-ca.pem etcd-server.pem
# etcd-server.pem: OK

# Inspect
openssl x509 -in etcd-server.pem -text -noout | grep -E "Subject:|Alternative|Key Usage"
# Subject: CN=etcd-server
# X509v3 Extended Key Usage: TLS Web Server Authentication, TLS Web Client Authentication
# X509v3 Subject Alternative Name: DNS:localhost, DNS:etcd-1, IP Address:10.0.0.1, IP Address:127.0.0.1
```

**Kiểm tra**: etcd-server.pem verify OK, có SAN + EKU cả `serverAuth` + `clientAuth`.

## Bước 2: Tạo etcd peer cert

```bash
cat > etcd-peer-csr.json << 'EOF'
{
  "CN": "etcd-1",
  "hosts": [
    "etcd-1",
    "localhost",
    "10.0.0.1",
    "127.0.0.1"
  ],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "CN": "etcd-1"
    }
  ]
}
EOF

# Peer cert — profile=peer (mTLS: cả serverAuth + clientAuth)
cfssl gencert \
  -ca=etcd-ca.pem \
  -ca-key=etcd-ca-key.pem \
  -config=ca-config.json \
  -profile=peer \
  etcd-peer-csr.json | cfssljson -bare etcd-peer

# Verify
openssl verify -CAfile etcd-ca.pem etcd-peer.pem
# etcd-peer.pem: OK

# Inspect
openssl x509 -in etcd-peer.pem -text -noout | grep -E "Subject:|Alternative|Key Usage"
# Subject: CN=etcd-1
# X509v3 Extended Key Usage: TLS Web Server Authentication, TLS Web Client Authentication
# X509v3 Subject Alternative Name: DNS:etcd-1, DNS:localhost, IP Address:10.0.0.1, IP Address:127.0.0.1
```

**Kiểm tra**: etcd-peer.pem có cả `serverAuth` + `clientAuth` (mTLS).

## Bước 3: Tạo etcd healthcheck client cert

```bash
cat > etcd-healthcheck-client-csr.json << 'EOF'
{
  "CN": "kube-etcd-healthcheck-client",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": []
}
EOF

cfssl gencert \
  -ca=etcd-ca.pem \
  -ca-key=etcd-ca-key.pem \
  -config=ca-config.json \
  -profile=client \
  etcd-healthcheck-client-csr.json | cfssljson -bare etcd-healthcheck-client

openssl verify -CAfile etcd-ca.pem etcd-healthcheck-client.pem
# etcd-healthcheck-client.pem: OK
```

**Kiểm tra**: Healthcheck client cert verify OK.

## Bước 4: Test TLS handshake bằng openssl s_server + s_client

```bash
# Terminal 1: Mở TLS server dùng etcd-server cert
openssl s_server \
  -accept 12379 \
  -cert etcd-server.pem \
  -key etcd-server-key.pem \
  -CAfile etcd-ca.pem \
  -Verify 1 \
  -www

# -Verify 1 = yêu cầu client cert (mTLS)
# Server listen trên port 12379
```

```bash
# Terminal 2: Connect bằng s_client (KHÔNG có client cert)
openssl s_client -connect 127.0.0.1:12379 -CAfile etcd-ca.pem

# Output:
# ---
# Certificate chain
#  0 s: CN=etcd-server
#    i: CN=etcd-ca
# ---
# Verify return code: 0 (ok)    ← server cert verify OK
# ---
# ACCEPT
# (nhưng server yêu cầu client cert — s_client không có → connection fail)
```

**Kiểm tra**: Server cert verify OK, nhưng mTLS yêu cầu client cert.

## Bước 5: Test mTLS handshake (với client cert)

```bash
# Terminal 2: Connect với client cert
openssl s_client -connect 127.0.0.1:12379 \
  -CAfile etcd-ca.pem \
  -cert etcd-healthcheck-client.pem \
  -key etcd-healthcheck-client-key.pem

# Output:
# ---
# Certificate chain
#  0 s: CN=etcd-server
#    i: CN=etcd-ca
# ---
# Server certificate
# subject=CN=etcd-server
# issuer=CN=etcd-ca
# ---
# Client certificate chain   ← mTLS: client cũng gửi cert
#  0 s: CN=kube-etcd-healthcheck-client
#    i: CN=etcd-ca
# ---
# Verify return code: 0 (ok)    ← cả 2 verify OK
# ---
# ACCEPT
# (connection thành công — mTLS handshake complete)
```

**Kiểm tra**: Cả server + client cert verify OK, mTLS handshake thành công.

## Bước 6: Test SAN mismatch

```bash
# Terminal 2: Connect với SNI sai
openssl s_client -connect 127.0.0.1:12379 \
  -CAfile etcd-ca.pem \
  -cert etcd-healthcheck-client.pem \
  -key etcd-healthcheck-client-key.pem \
  -servername wrong.name

# Cert có SAN: localhost, etcd-1, 127.0.0.1
# "wrong.name" không trong SAN → verify fail (nếu client check SAN)
```

**Kiểm tra**: SAN mismatch → verify fail.

## Bước 7: Test với cert sai CA

```bash
# Terminal 2: Connect nhưng dùng kubernetes CA (sai CA)
openssl s_client -connect 127.0.0.1:12379 \
  -CAfile ca.pem \
  -cert admin.pem \
  -key admin-key.pem

# Output:
# Verify return code: 21 (unable to verify the first certificate)
# → etcd-server cert được ký bởi etcd-ca, không phải kubernetes-ca
```

**Kiểm tra**: Sai CA → verify fail.

## Bước 8: Inspect etcd cert bằng cfssl

```bash
# Etcd server cert
cfssl certinfo -cert etcd-server.pem | jq '{subject, issuer, subject_alt_name, usages}
# {
#   "subject": {"CN": "etcd-server"},
#   "issuer": {"CN": "etcd-ca"},
#   "subject_alt_name": {
#     "DNS_names": ["localhost", "etcd-1"],
#     "IP_addresses": ["10.0.0.1", "127.0.0.1"]
#   },
#   "usages": ["Digital Signature", "Key Encipherment", "Server Auth", "Client Auth"]
# }

# Etcd peer cert
cfssl certinfo -cert etcd-peer.pem | jq '{subject, issuer, subject_alt_name, usages}
# {
#   "subject": {"CN": "etcd-1"},
#   "issuer": {"CN": "etcd-ca"},
#   "subject_alt_name": {
#     "DNS_names": ["etcd-1", "localhost"],
#     "IP_addresses": ["10.0.0.1", "127.0.0.1"]
#   },
#   "usages": ["Digital Signature", "Key Encipherment", "Server Auth", "Client Auth"]
# }
```

**Kiểm tra**: Cả 2 cert có EKU `Server Auth` + `Client Auth` (mTLS).

## Cleanup

```bash
# Kill openssl s_server (Ctrl+C trong terminal 1)
# Giữ lại cert files cho Exercise 05
```

## Câu hỏi tự kiểm tra

1. Tại sao etcd peer cert cần cả `serverAuth` + `clientAuth`? Profile nào trong ca-config.json cung cấp cả 2?
2. Tại sao etcd dùng CA riêng thay vì kubernetes CA?
3. `openssl s_server -Verify 1` làm gì? Nếu bỏ `-Verify 1` thì sao?
4. Nếu etcd server cert thiếu `127.0.0.1` trong `hosts` → điều gì xảy ra?
5. Apiserver kết nối etcd — apiserver cần cert ký bởi CA nào?

## Đáp án tham khảo

1. Vì etcd peer connection là mTLS — mỗi member vừa là server (chấp nhận connection) vừa là client (kết nối đến member khác). Profile `peer` trong ca-config.json cung cấp cả `serverAuth` + `clientAuth`.
2. Cách ly bảo mật. Nếu kubernetes CA bị compromise, etcd không bị ảnh hưởng. Etcd chứa toàn bộ cluster state — dữ liệu nhạy cảm nhất.
3. `-Verify 1` = yêu cầu client phải gửi cert (mTLS). Nếu bỏ → server không yêu cầu client cert → chỉ 1-way TLS, không mTLS.
4. Apiserver/kubelet trên cùng node kết nối `https://127.0.0.1:2379` → SAN không có 127.0.0.1 → TLS fail.
5. Etcd CA. Apiserver cần `apiserver-etcd-client.pem` được ký bởi `etcd-ca`, không phải `kubernetes-ca`.
