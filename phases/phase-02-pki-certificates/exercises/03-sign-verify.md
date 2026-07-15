# Exercise 03 — Ký cert, verify chain, inspect detail

> **Mục tiêu**: Ký cert bằng cfssl với đúng profile, verify chain of trust, inspect cert detail.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Đã làm Exercise 01 + 02 (có CA + apiserver cert)

## Bước 1: Ký apiserver → etcd client cert

```bash
cd /tmp/k8s-certs

# Apiserver kết nối etcd — cần client cert ký bởi ETCD CA
cat > apiserver-etcd-client-csr.json << 'EOF'
{
  "CN": "kube-apiserver-etcd-client",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": []
}
EOF

# Ký bằng ETCD CA (không phải kubernetes CA)
cfssl gencert \
  -ca=etcd-ca.pem \
  -ca-key=etcd-ca-key.pem \
  -config=ca-config.json \
  -profile=client \
  apiserver-etcd-client-csr.json | cfssljson -bare apiserver-etcd-client

# Verify — dùng etcd CA
openssl verify -CAfile etcd-ca.pem apiserver-etcd-client.pem
# apiserver-etcd-client.pem: OK
```

**Kiểm tra**: Etcd client cert được ký bởi **etcd CA**, verify OK.

## Bước 2: Ký apiserver → kubelet client cert

```bash
cat > apiserver-kubelet-client-csr.json << 'EOF'
{
  "CN": "kube-apiserver-kubelet-client",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": []
}
EOF

# Ký bằng kubernetes CA
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=client \
  apiserver-kubelet-client-csr.json | cfssljson -bare apiserver-kubelet-client

openssl verify -CAfile ca.pem apiserver-kubelet-client.pem
# apiserver-kubelet-client.pem: OK
```

**Kiểm tra**: Kubelet client cert verify OK.

## Bước 3: Ký front-proxy client cert

```bash
cat > front-proxy-client-csr.json << 'EOF'
{
  "CN": "front-proxy-client",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": []
}
EOF

# Ký bằng front-proxy CA
cfssl gencert \
  -ca=front-proxy-ca.pem \
  -ca-key=front-proxy-ca-key.pem \
  -config=ca-config.json \
  -profile=client \
  front-proxy-client-csr.json | cfssljson -bare front-proxy-client

openssl verify -CAfile front-proxy-ca.pem front-proxy-client.pem
# front-proxy-client.pem: OK
```

**Kiểm tra**: Front-proxy client cert verify OK.

## Bước 4: Verify tất cả cert

```bash
# Cert ký bởi kubernetes CA
for cert in apiserver admin scheduler controller-manager \
            apiserver-kubelet-client kubelet-node-1; do
    echo -n "$cert: "
    openssl verify -CAfile ca.pem ${cert}.pem
done
# apiserver: OK
# admin: OK
# scheduler: OK
# controller-manager: OK
# apiserver-kubelet-client: OK
# kubelet-node-1: OK

# Cert ký bởi etcd CA
for cert in apiserver-etcd-client; do
    echo -n "$cert: "
    openssl verify -CAfile etcd-ca.pem ${cert}.pem
done
# apiserver-etcd-client: OK

# Cert ký bởi front-proxy CA
openssl verify -CAfile front-proxy-ca.pem front-proxy-client.pem
# front-proxy-client: OK
```

**Kiểm tra**: Tất cả cert verify OK.

## Bước 5: Inspect cert — cfssl certinfo

```bash
# Apiserver cert
cfssl certinfo -cert apiserver.pem | jq .
# {
#   "subject": {"CN": "kube-apiserver"},
#   "issuer": {"CN": "kubernetes-ca"},
#   "serial_number": "...",
#   "not_before": "2026-01-15T...",
#   "not_after": "2027-01-15T...",
#   "subject_alt_name": {
#     "DNS_names": ["kubernetes", "kubernetes.default", ...],
#     "IP_addresses": ["10.96.0.1", "10.0.0.1", "127.0.0.1"]
#   },
#   "usages": ["Digital Signature", "Key Encipherment", "Server Auth"]
# }

# Admin cert
cfssl certinfo -cert admin.pem | jq '{subject, issuer, usages}
# {
#   "subject": {"CN": "kubernetes-admin", "O": "system:masters"},
#   "issuer": {"CN": "kubernetes-ca"},
#   "usages": ["Digital Signature", "Key Encipherment", "Client Auth"]
# }
```

**Kiểm tra**: `cfssl certinfo` hiện subject, issuer, SAN, usages.

## Bước 6: Inspect cert — openssl (chi tiết hơn)

```bash
# Full detail
openssl x509 -in apiserver.pem -text -noout
# Certificate:
#   Version: 3
#   Serial Number: ...
#   Signature Algorithm: sha256WithRSAEncryption
#   Issuer: CN=kubernetes-ca
#   Validity
#     Not Before: Jan 15 10:00:00 2026 GMT
#     Not After:  Jan 15 10:00:00 2027 GMT
#   Subject: CN=kube-apiserver
#   Subject Public Key Info: RSA (2048 bit)
#   X509v3 extensions:
#     X509v3 Key Usage: digitalSignature, keyEncipherment
#     X509v3 Extended Key Usage: TLS Web Server Authentication
#     X509v3 Subject Alternative Name:
#       DNS:kubernetes, DNS:kubernetes.default, ...
#       IP Address:10.96.0.1, IP Address:10.0.0.1

# Chỉ xem SAN
openssl x509 -in apiserver.pem -text -noout | grep -A1 "Alternative Name"

# Chỉ xem validity
openssl x509 -in apiserver.pem -noout -dates
# notBefore=Jan 15 10:00:00 2026 GMT
# notAfter=Jan 15 10:00:00 2027 GMT

# Chỉ xem subject + issuer
openssl x509 -in apiserver.pem -noout -subject -issuer
# subject=CN=kube-apiserver
# issuer=CN=kubernetes-ca
```

**Kiểm tra**: openssl hiện đầy đủ: subject, issuer, SAN, KU, EKU, validity.

## Bước 7: Kiểm tra expiry

```bash
# Tất cả cert valid 365 ngày (8760h)
for cert in apiserver admin scheduler controller-manager \
            apiserver-etcd-client apiserver-kubelet-client \
            kubelet-node-1 front-proxy-client; do
    echo -n "$cert: "
    openssl x509 -in ${cert}.pem -noout -enddate
done
# apiserver: notAfter=Jan 15 10:00:00 2027 GMT
# admin: notAfter=Jan 15 10:00:00 2027 GMT
# ...

# Check còn hạn 30 ngày không
openssl x509 -in apiserver.pem -checkend 2592000
# Certificate will not expire (still good for 2592000 seconds = 30 days)
```

**Kiểm tra**: Tất cả cert (trừ CA) hết hạn sau 365 ngày.

## Bước 8: So sánh cfssl vs openssl workflow

```bash
# === cfssl workflow (1 lệnh per cert) ===
# 1. Viết CSR JSON config
# 2. cfssl gencert (tạo key + CSR + ký cert)
# 3. cfssljson -bare (tách file)
# → 3 files: .pem, -key.pem, .csr

# === openssl workflow (3+ lệnh per cert) ===
# 1. openssl genrsa (tạo key)
# 2. openssl req -new (tạo CSR + SAN)
# 3. Viết extfile (SAN + KU + EKU — khai báo lại SAN!)
# 4. openssl x509 -req (ký cert)
# → 4 files: .key, .csr, .ext, .crt

# cfssl lợi thế:
# - SAN tự copy từ hosts array (openssl phải khai báo 2 lần)
# - Key usage từ profile (openssl phải viết extfile)
# - 1 lệnh thay vì 3+
# - JSON config dễ version control
```

## Tổng kết files

```
/tmp/k8s-certs/
├── ca.pem, ca-key.pem                         # CA
├── etcd-ca.pem, etcd-ca-key.pem               # etcd CA
├── front-proxy-ca.pem, front-proxy-ca-key.pem # front-proxy CA
├── sa.key, sa.pub                             # SA key pair
├── apiserver.pem, apiserver-key.pem           # apiserver server cert
├── apiserver-etcd-client.pem, -key.pem        # apiserver → etcd
├── apiserver-kubelet-client.pem, -key.pem     # apiserver → kubelet
├── admin.pem, admin-key.pem                   # admin kubectl
├── scheduler.pem, scheduler-key.pem           # scheduler
├── controller-manager.pem, -key.pem           # controller-manager
├── kubelet-node-1.pem, -key.pem               # kubelet node-1
├── front-proxy-client.pem, -key.pem           # front-proxy client
├── ca-config.json                             # signing config
└── *-csr.json                                 # CSR configs
```

## Câu hỏi tự kiểm tra

1. Apiserver → etcd cert ký bởi CA nào? Tại sao?
2. `cfssl certinfo` vs `openssl x509 -text` — khác gì? Khi nào dùng cái nào?
3. cfssl dùng `profile=server` cho apiserver, `profile=client` cho admin — nếu đảo ngược thì sao?
4. Tại sao cfssl không có lệnh `verify`? Dùng gì thay thế?
5. So sánh lợi thế cfssl vs openssl khi tạo cert cho Kubernetes?

## Đáp án tham khảo

1. Etcd CA. Vì etcd dùng CA riêng — cách ly bảo mật. Apiserver cần etcd CA ký client cert để etcd trust.
2. `cfssl certinfo` xuất JSON, dễ parse bằng `jq`. `openssl x509 -text` xuất text, chi tiết hơn nhưng khó parse. Dùng cfssl cho scripting, openssl cho debug thủ công.
3. Apiserver với `profile=client` → EKU chỉ có `clientAuth`, không có `serverAuth` → TLS handshake fail khi client kết nối đến apiserver (server cần `serverAuth`).
4. cfssl tập trung vào tạo cert, không phải verify. Dùng `openssl verify` — tool chuẩn cho verify chain of trust.
5. cfssl: (1) SAN tự copy từ hosts, (2) key usage từ profile, (3) 1 lệnh thay vì 3+, (4) JSON config dễ version control, (5) phổ biến trong K8s ecosystem.
