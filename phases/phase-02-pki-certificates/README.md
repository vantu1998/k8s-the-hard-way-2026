# Phase 2 — PKI & Certificates

> Hiểu đủ PKI/TLS để tự sinh toàn bộ certificate cho Kubernetes cluster: CA, server cert, client cert, etcd peer cert.
>
> **Mục tiêu**: Tạo được CA + sign cert với đúng SAN. Liệt kê được tất cả cert K8s cần. Script sinh cert chạy thành công, verify bằng `openssl verify`.

## Cấu trúc thư mục

```
phase-02-pki-certificates/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-pki-ca.md
│   ├── 02-tls-handshake.md
│   ├── 03-csr-san-cn.md
│   ├── 04-cert-signing.md
│   └── 05-k8s-certificates.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-create-ca.md
│   ├── 02-apiserver-cert-san.md
│   ├── 03-sign-verify.md
│   ├── 04-etcd-mtls.md
│   └── 05-gen-all-certs.md
└── scripts/                   # Helper scripts
    ├── gen-ca.sh
    ├── gen-apiserver-cert.sh
    ├── gen-etcd-cert.sh
    └── gen-all-certs.sh
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — PKI & CA: Public Key Infrastructure, root CA, intermediate CA, self-signed cert
- [ ] 02 — TLS Handshake: ClientHello, ServerHello, cert exchange, key exchange, TLS 1.2 vs 1.3
- [ ] 03 — CSR, SAN, CN: Certificate Signing Request, Subject Alternative Name, Common Name = RBAC
- [ ] 04 — Certificate Signing: CA ký CSR, hash, signature, serial, validity, verify chain
- [ ] 05 — Kubernetes Certificates: Mỗi component cần cert nào (apiserver, kubelet, etcd, scheduler, controller-manager, service-account)

### Thực hành (exercises/)

- [ ] 01 — Tạo root CA bằng openssl (private key + self-signed cert)
- [ ] 02 — Tạo CSR cho kube-apiserver với SAN (IP node + DNS names)
- [ ] 03 — Ký CSR bằng CA, verify bằng `openssl verify`
- [ ] 04 — Tạo etcd peer cert mTLS, test handshake bằng `openssl s_client`
- [ ] 05 — Viết script sinh toàn bộ cert cho cluster 3 master + 2 worker

### Checkpoint hoàn thành phase

- [ ] Giải thích được TLS handshake từng bước
- [ ] Tạo được CA + sign cert với đúng SAN
- [ ] Liệt kê được tất cả cert Kubernetes cần và mỗi cert phục vụ ai
- [ ] Script sinh cert chạy thành công, verify bằng `cfssl certinfo` + `openssl verify`

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+)
- Root access (sudo)
- Packages: `cfssl`, `cfssljson` (primary), `openssl` (verify/debug), `jq`
- Đã hoàn thành Phase 0 + Phase 1 (hiểu systemd, container runtime)
