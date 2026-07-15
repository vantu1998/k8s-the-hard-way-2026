# Exercise 02 — Tạo CSR cho kube-apiserver với SAN bằng cfssl

> **Mục tiêu**: Tạo CSR config với SAN chứa tất cả endpoint mà client có thể dùng để truy cập apiserver.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Đã làm Exercise 01 (có `ca.pem`, `ca-key.pem`, `ca-config.json`)

## Bối cảnh

kube-apiserver có thể truy cập qua nhiều tên/IP: `kubernetes`, `10.96.0.1`, IP node, `localhost`. Tất cả phải có trong SAN — nếu thiếu, client kết nối qua endpoint đó sẽ fail. cfssl dùng `hosts` array trong JSON config — dễ hơn openssl nhiều.

## Bước 1: Chuẩn bị

```bash
cd /tmp/k8s-certs
# Đảm bảo có ca.pem, ca-key.pem, ca-config.json từ Exercise 01
ls ca.pem ca-key.pem ca-config.json
```

**Kiểm tra**: CA files + config tồn tại.

## Bước 2: Tạo apiserver CSR config

```bash
# Cluster assumptions:
# - Master node IP: 10.0.0.1
# - Kubernetes service ClusterIP: 10.96.0.1

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

### Giải thích hosts entries

| Host entry | Khi nào dùng |
|------------|-------------|
| `kubernetes` | Pod truy cập `https://kubernetes:6443` (short name) |
| `kubernetes.default` | `https://kubernetes.default:6443` |
| `kubernetes.default.svc` | `https://kubernetes.default.svc:6443` |
| `kubernetes.default.svc.cluster.local` | FQDN — pod truy cập đầy đủ |
| `localhost` | Component trên cùng node: `https://localhost:6443` |
| `10.96.0.1` | Kubernetes service ClusterIP |
| `10.0.0.1` | Master node IP (truy cập trực tiếp) |
| `127.0.0.1` | Localhost IP |

> **Lưu ý**: cfssl `hosts` array chứa cả DNS và IP — cfssl tự nhận biết (IP có dấu chấm số, DNS là string). Không cần prefix `DNS:` hay `IP:` như openssl.

**Kiểm tra**: `apiserver-csr.json` tồn tại, JSON hợp lệ.

## Bước 3: Ký apiserver cert — 1 lệnh duy nhất

```bash
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=server \
  apiserver-csr.json | cfssljson -bare apiserver

# → apiserver.pem (cert), apiserver-key.pem (private key), apiserver.csr (CSR)
```

### Giải thích lệnh

| Flag | Ý nghĩa |
|------|---------|
| `-ca=ca.pem` | CA certificate |
| `-ca-key=ca-key.pem` | CA private key |
| `-config=ca-config.json` | Signing config |
| `-profile=server` | Dùng profile "server" (EKU: serverAuth) |
| `apiserver-csr.json` | CSR config (CN, hosts, key) |
| `cfssljson -bare apiserver` | Tách output thành apiserver.pem, apiserver-key.pem, apiserver.csr |

> **So sánh openssl**: openssl cần 3 lệnh (genrsa → req → x509) + extfile cho SAN. cfssl làm tất cả trong 1 lệnh.

**Kiểm tra**: 3 files: `apiserver.pem`, `apiserver-key.pem`, `apiserver.csr`.

## Bước 4: Inspect cert — verify SAN

```bash
# Cách 1: cfssl certinfo
cfssl certinfo -cert apiserver.pem | jq .certificates[0].subject_alt_name
# {
#   "DNS_names": ["kubernetes", "kubernetes.default", "kubernetes.default.svc",
#                 "kubernetes.default.svc.cluster.local", "localhost"],
#   "IP_addresses": ["10.96.0.1", "10.0.0.1", "127.0.0.1"]
# }

# Cách 2: openssl
openssl x509 -in apiserver.pem -text -noout | grep -A1 "Alternative Name"
# X509v3 Subject Alternative Name:
#   DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc,
#   DNS:kubernetes.default.svc.cluster.local, DNS:localhost,
#   IP Address:10.96.0.1, IP Address:10.0.0.1, IP Address:127.0.0.1
```

**Kiểm tra**: SAN chứa đầy đủ DNS names + IP addresses.

## Bước 5: Verify cert chain

```bash
openssl verify -CAfile ca.pem apiserver.pem
# apiserver.pem: OK
```

**Kiểm tra**: `openssl verify` trả về `OK`.

## Bước 6: Tạo admin client cert

```bash
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

# Ký với profile=client
cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=client \
  admin-csr.json | cfssljson -bare admin

# Verify
openssl verify -CAfile ca.pem admin.pem
# admin.pem: OK

# Inspect — CN + O
openssl x509 -in admin.pem -text -noout | grep -E "Subject:|O="
# Subject: CN=kubernetes-admin, O=system:masters
```

**Lưu ý**: Admin cert có `O=system:masters` — group có full cluster admin quyền. `hosts: []` vì client cert không cần SAN.

**Kiểm tra**: Admin cert có CN=`kubernetes-admin`, O=`system:masters`, verify OK.

## Bước 7: Tạo scheduler + controller-manager cert

```bash
# Scheduler
cat > scheduler-csr.json << 'EOF'
{
  "CN": "system:kube-scheduler",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": []
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem \
  -config=ca-config.json -profile=client \
  scheduler-csr.json | cfssljson -bare scheduler

# Controller-manager
cat > controller-manager-csr.json << 'EOF'
{
  "CN": "system:kube-controller-manager",
  "hosts": [],
  "key": {"algo": "rsa", "size": 2048},
  "names": []
}
EOF

cfssl gencert -ca=ca.pem -ca-key=ca-key.pem \
  -config=ca-config.json -profile=client \
  controller-manager-csr.json | cfssljson -bare controller-manager

# Verify cả 2
openssl verify -CAfile ca.pem scheduler.pem controller-manager.pem
# scheduler.pem: OK
# controller-manager.pem: OK
```

**Kiểm tra**: 2 cert verify OK, CN đúng.

## Bước 8: Tạo kubelet cert (per node)

```bash
cat > kubelet-node-1-csr.json << 'EOF'
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
EOF

# Ký với profile=peer (kubelet cần cả serverAuth + clientAuth)
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem \
  -config=ca-config.json -profile=peer \
  kubelet-node-1-csr.json | cfssljson -bare kubelet-node-1

# Verify
openssl verify -CAfile ca.pem kubelet-node-1.pem
# kubelet-node-1.pem: OK

# Inspect
openssl x509 -in kubelet-node-1.pem -text -noout | grep -E "Subject:|Alternative|Key Usage"
# Subject: CN=system:node:node-1, O=system:nodes
# X509v3 Extended Key Usage: TLS Web Server Authentication, TLS Web Client Authentication
# X509v3 Subject Alternative Name: DNS:node-1, IP Address:10.0.0.1
```

**Kiểm tra**: Kubelet cert có CN=`system:node:node-1`, O=`system:nodes`, SAN có node DNS + IP, EKU cả serverAuth + clientAuth.

## Tổng kết CSR config + cert đã tạo

```
/tmp/k8s-certs/
├── apiserver-csr.json         # CN=kube-apiserver, hosts: nhiều DNS + IP
├── apiserver.pem              # server cert (profile=server)
├── admin-csr.json             # CN=kubernetes-admin, O=system:masters
├── admin.pem                  # client cert (profile=client)
├── scheduler-csr.json         # CN=system:kube-scheduler
├── scheduler.pem              # client cert
├── controller-manager-csr.json # CN=system:kube-controller-manager
├── controller-manager.pem     # client cert
├── kubelet-node-1-csr.json    # CN=system:node:node-1, O=system:nodes, hosts: node-1
└── kubelet-node-1.pem         # peer cert (profile=peer — serverAuth + clientAuth)
```

## Câu hỏi tự kiểm tra

1. Nếu apiserver cert thiếu `10.96.0.1` trong `hosts` → điều gì xảy ra khi pod truy cập `https://10.96.0.1:6443`?
2. Tại sao cfssl `hosts` array không cần prefix `DNS:` hay `IP:` như openssl?
3. Admin cert có `O=system:masters` — nếu bỏ O thì sao?
4. Kubelet cert dùng `profile=peer` thay vì `profile=server` — tại sao?
5. So sánh số lệnh: tạo apiserver cert bằng cfssl vs openssl?

## Đáp án tham khảo

1. TLS handshake fail: "x509: certificate is valid for X, not 10.96.0.1". Client kiểm tra IP trong SAN, không thấy → reject.
2. cfssl tự nhận biết: nếu entry là IP hợp lệ (vd `10.96.0.1`) → thêm `IP:`, nếu là DNS name (vd `kubernetes`) → thêm `DNS:`. openssl yêu cầu prefix rõ ràng.
3. Admin không có group `system:masters` → RBAC không cấp admin quyền → `kubectl` trả về "forbidden".
4. Kubelet vừa là server (apiserver → kubelet) vừa là client (kubelet → apiserver). Profile `peer` có cả `serverAuth` + `clientAuth`. Profile `server` chỉ có `serverAuth`.
5. cfssl: 1 lệnh (`gencert` — tạo key + CSR + ký cert). openssl: 3 lệnh (`genrsa` + `req` + `x509`) + extfile cho SAN.
