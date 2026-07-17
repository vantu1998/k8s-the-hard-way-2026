# Phase 4 — Kubernetes API Server

> Hiểu API Server là "cửa ngõ duy nhất" — mọi tương tác đều qua nó. Nắm được flow request từ client đến etcd.
>
> **Mục tiêu**: Chạy được kube-apiserver standalone. Tạo user bằng cert + RBAC, test permission. Giải thích được Mutating vs Validating Admission Controller. Bật encryption at rest, verify Secret mã hóa trong etcd.

## Cấu trúc thư mục

```
phase-04-api-server/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-kube-apiserver.md
│   ├── 02-authentication.md
│   ├── 03-authorization-rbac.md
│   ├── 04-admission-controller.md
│   ├── 05-api-flow.md
│   └── 06-encryption-at-rest.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-run-apiserver-standalone.md
│   ├── 02-rbac-with-cert.md
│   ├── 03-admission-webhook.md
│   ├── 04-encryption-at-rest.md
│   └── 05-debug-api-verbose.md
└── scripts/                   # Helper scripts
    ├── run-apiserver.sh
    ├── gen-user-cert.sh
    └── encryption-provider.yaml
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — kube-apiserver: Cấu hình chính, stateless design, API groups, static pod manifest
- [ ] 02 — Authentication: Client cert (CN=username, O=group), Bearer token, OIDC, Service Account token
- [ ] 03 — Authorization (RBAC): Role/ClusterRole + RoleBinding/ClusterRoleBinding, ABAC, Node authorization
- [ ] 04 — Admission Controller: Mutating vs Validating, built-in plugins, webhook admission (OPA Gatekeeper, Kyverno)
- [ ] 05 — API Flow: Client → Authn → Authz → Mutating Admission → Validation → etcd → Watch → Controller/Kubelet
- [ ] 06 — Encryption at Rest: EncryptionConfiguration, AES-CBC, AES-GCM, secretbox, key rotation

### Thực hành (exercises/)

- [ ] 01 — Chạy `kube-apiserver` standalone (không kubelet/controller), dùng `kubectl` gọi API
- [ ] 02 — Tạo user cert với CN=`alice`, O=`dev`, tạo RoleBinding, test RBAC — alice có quyền gì, không có quyền gì
- [ ] 03 — Enable admission webhook, viết một ValidatingAdmissionWebhook từ chối pod không có label
- [ ] 04 — Enable encryption at rest, tạo Secret, đọc raw trong etcd — thấy đã mã hóa
- [ ] 05 — Dùng `kubectl --v=8` xem HTTP request/response đầy đủ đến API Server

### Checkpoint hoàn thành phase

- [ ] Vẽ được flow: Client → Authn → Authz → Admission → etcd → Watch → Controller/Kubelet
- [ ] Tạo được user bằng cert + RBAC, test permission thành công
- [ ] Giải thích được Mutating vs Validating Admission Controller
- [ ] Bật encryption at rest, verify Secret mã hóa trong etcd

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên VM
- Packages: `cfssl`, `jq`, `curl`, `openssl`
- Đã hoàn thành Phase 2 (có Kubernetes CA + apiserver cert sẵn)
- Đã hoàn thành Phase 3 (etcd cluster đang chạy)
