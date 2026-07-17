# 02 — Authentication

## Authentication là gì

Authentication (Authn) trả lời câu hỏi: **"Ai gửi request?"** — xác định danh tính của client. API Server hỗ trợ nhiều phương thức authentication, có thể bật đồng thời.

```
Client request (cert / token / basic auth)
       │
       ▼
  API Server
  ├── 1. Client cert authn → CN=alice, O=dev
  ├── 2. Bearer token authn → system:serviceaccount:default:my-sa
  ├── 3. OIDC authn → alice@example.com
  ├── 4. Anonymous → system:anonymous
  └── Result: User{username, groups, uid, extra}
```

> Authentication **chỉ xác định ai** — không quyết định có quyền gì. Đó là Authorization (Authz).

## Authentication methods

| Method | Flag | User type | Use case |
|--------|------|-----------|----------|
| **Client cert (X.509)** | `--client-ca-file` | Human + component | kubectl, kubelet, controller-manager |
| **Bearer token (static)** | `--token-auth-file` | Human + service | Legacy, deprecated |
| **Service Account token (JWT)** | `--service-account-key-file` | Service (pod) | Pod gọi API Server |
| **OIDC (OpenID Connect)** | `--oidc-issuer-url`, `--oidc-client-id` | Human | Enterprise SSO (Google, Keycloak, Dex) |
| **Bootstrap token** | `--enable-bootstrap-token-auth` | Kubelet bootstrap | Node join cluster (kubeadm) |
| **Anonymous** | `--anonymous-auth=true` | Unknown | Public resource access |
| **Webhook** | `--authentication-token-webhook-config-file` | External | External token verification |

> Production thường dùng **client cert** cho component + admin, **OIDC** cho human user, **Service Account JWT** cho pod.

## 1. Client cert (X.509) authentication

Client trình TLS cert khi kết nối API Server. API Server dùng `--client-ca-file` để verify cert. **CN** (Common Name) = username, **O** (Organization) = group.

```
Client cert:
  CN=alice        → username: alice
  O=dev           → group: dev
  O=admins        → group: admins
```

### Cấu hình API Server

```bash
--client-ca-file=/etc/kubernetes/pki/ca.crt
```

> Mọi client cert ký bởi CA này được accept. CN → username, O → groups.

### Tạo user cert

```bash
# Tạo private key
openssl genrsa -out alice-key.pem 2048

# Tạo CSR — CN=alice, O=dev
openssl req -new -key alice-key.pem -out alice.csr -subj "/CN=alice/O=dev"

# Ký CSR bằng Kubernetes CA
openssl x509 -req -in alice.csr \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca-key.pem \
  -CAcreateserial -out alice.pem -days 365

# Verify
openssl verify -CAfile /etc/kubernetes/pki/ca.crt alice.pem
# alice.pem: OK
```

### Tạo kubeconfig cho user

```bash
# Set cluster
kubectl config set-cluster k8s-lab \
  --server=https://192.168.56.11:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=alice.kubeconfig

# Set credentials
kubectl config set-credentials alice \
  --client-certificate=alice.pem \
  --client-key=alice-key.pem \
  --embed-certs=true \
  --kubeconfig=alice.kubeconfig

# Set context
kubectl config set-context alice@k8s-lab \
  --cluster=k8s-lab \
  --user=alice \
  --kubeconfig=alice.kubeconfig

# Use context
kubectl config use-context alice@k8s-lab --kubeconfig=alice.kubeconfig

# Test
kubectl get pods --kubeconfig=alice.kubeconfig
# Error from server (Forbidden): pods is forbidden: User "alice" cannot list resource "pods"...
```

> Authentication thành công (API Server biết là `alice`), nhưng Authorization fail (alice chưa có quyền). Xem `03-authorization-rbac.md` để cấp quyền.

### Component cert — ai dùng cert nào

| Component | CN | O | Mục đích |
|-----------|-----|------|----------|
| `kube-controller-manager` | `system:kube-controller-manager` | `system:authenticated` | Gọi API Server |
| `kube-scheduler` | `system:kube-scheduler` | `system:authenticated` | Gọi API Server |
| `kubelet` | `system:node:<node-name>` | `system:nodes` | Gọi API Server (node API) |
| `kube-proxy` | `system:kube-proxy` | `system:authenticated` | Gọi API Server |
| `admin` | `kubernetes-admin` | `system:masters` | Admin access (kubeadm) |

> `system:masters` group có **superuser** — bypass RBAC. Chỉ dùng cho admin, không cấp cho user thường.

## 2. Bearer token (static file)

Token file chứa `token,user,uid,group1,group2,...`:

```bash
# /etc/kubernetes/tokens.csv
abcdef.0123456789abcdef,alice,1000,dev,admins
xyz123.4567890123456789,bob,1001,dev
```

```bash
# API Server flag
--token-auth-file=/etc/kubernetes/tokens.csv
```

```bash
# Sử dụng
curl -k -H "Authorization: Bearer abcdef.0123456789abcdef" \
  https://192.168.56.11:6443/api/v1/namespaces/default/pods
```

> **Deprecated** — không recommend cho production. Token tĩnh, không expire, không rotate. Dùng OIDC hoặc Service Account JWT thay thế.

## 3. Service Account token (JWT)

Pod chạy trong cluster dùng Service Account token (JWT) để gọi API Server. Token được mount tự động vào pod.

```
Pod
├── /var/run/secrets/kubernetes.io/serviceaccount/token    → JWT token
├── /var/run/secrets/kubernetes.io/serviceaccount/ca.crt   → CA cert
└── /var/run/secrets/kubernetes.io/serviceaccount/namespace → namespace name
```

### JWT structure

```
eyJhbGciOiJSUzI1NiIsImtpZCI6...  ← JWT token
```

Decode JWT (3 phần ngăn cách bởi `.`):

```bash
# Decode header
echo "eyJhbGciOiJSUzI1NiIsImtpZCI6..." | cut -d. -f1 | base64 -d 2>/dev/null | jq .
# {"alg":"RS256","kid":"..."}

# Decode payload
echo "eyJhbGciOiJSUzI1NiIsImtpZCI6..." | cut -d. -f2 | base64 -d 2>/dev/null | jq .
# {
#   "iss": "https://kubernetes.default.svc.cluster.local",
#   "sub": "system:serviceaccount:default:my-sa",
#   "aud": ["https://kubernetes.default.svc.cluster.local"],
#   "exp": 1735689600,
#   "iat": 1704067200,
#   "nbf": 1704067200,
#   "kubernetes.io": {
#     "namespace": "default",
#     "serviceaccount": {"name": "my-sa", "uid": "..."},
#     "warnafter": 1704153600
#   }
# }
```

| JWT claim | Ý nghĩa |
|-----------|---------|
| `iss` | Issuer — API Server URL (set bởi `--service-account-issuer`) |
| `sub` | Subject — `system:serviceaccount:<namespace>:<sa-name>` |
| `aud` | Audience — API Server URL |
| `exp` | Expiration time |
| `iat` | Issued at time |
| `nbf` | Not before time |
| `kubernetes.io.namespace` | Namespace của ServiceAccount |

> API Server verify JWT signature bằng `--service-account-key-file` (public key). Token sign bằng `--service-account-signing-key-file` (private key).

### Token projection (v1.21+)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-sa
  namespace: default
---
apiVersion: v1
kind: Pod
metadata:
  name: api-client
spec:
  serviceAccountName: my-sa
  containers:
  - name: app
    image: curlimages/curl
    volumeMounts:
    - name: token
      mountPath: /var/run/secrets/tokens
  volumes:
  - name: token
    projected:
      sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3600
          audience: vault
```

| Field | Ý nghĩa |
|-------|---------|
| `expirationSeconds` | Token TTL — tự động rotate |
| `audience` | Audience claim — giới hạn token dùng cho service nào |

> Token projected tự động rotate khi đến 80% TTL. Pod không cần restart để lấy token mới.

## 4. OIDC (OpenID Connect)

OIDC cho phép tích hợp external identity provider (Google, Keycloak, Dex, Okta) để authenticate human user.

```bash
# API Server flags
--oidc-issuer-url=https://dex.example.com \
--oidc-client-id=kubernetes \
--oidc-username-claim=email \
--oidc-username-prefix=oidc: \
--oidc-groups-claim=groups \
--oidc-groups-prefix=oidc: \
--oidc-ca-file=/etc/kubernetes/pki/oidc-ca.crt
```

| Flag | Ý nghĩa |
|------|---------|
| `--oidc-issuer-url` | OIDC provider URL (phải serve `.well-known/openid-configuration`) |
| `--oidc-client-id` | Client ID — token phải có aud claim khớp |
| `--oidc-username-claim` | JWT claim dùng làm username (thường `email` hoặc `sub`) |
| `--oidc-username-prefix` | Prefix cho username (tránh collision với K8s user) |
| `--oidc-groups-claim` | JWT claim chứa groups |
| `--oidc-groups-prefix` | Prefix cho groups |

```
OIDC token payload:
  email: alice@example.com  → username: oidc:alice@example.com
  groups: ["dev", "admins"] → groups: oidc:dev, oidc:admins
```

> **Prefix** tránh collision: `oidc:alice@example.com` khác `alice` (local user). Nếu không set prefix, OIDC user có thể collision với K8s system user.

### kubectl với OIDC

```bash
# Cài kubelogin plugin
brew install int128/kubelogin/kubelogin  # macOS
# hoặc
go install github.com/int128/kubelogin@latest  # Go

# kubeconfig
apiVersion: v1
kind: Config
users:
- name: oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: kubelogin
      args:
      - get-token
      - --oidc-issuer-url=https://dex.example.com
      - --oidc-client-id=kubernetes
```

> `kubelogin` mở browser → user login → nhận OIDC token → pass token cho kubectl → kubectl gửi đến API Server.

## 5. Bootstrap token

Bootstrap token dùng cho `kubeadm join` — kubelet join cluster không cần cert sẵn.

```bash
# API Server flag
--enable-bootstrap-token-auth=true
```

```bash
# Tạo bootstrap token (kubeadm)
kubeadm token create
# abcdef.0123456789abcdef

# Kubelet join
kubeadm join 192.168.56.11:6443 --token abcdef.0123456789abcdef
```

> Bootstrap token có format `<6-char>.<16-char>`. Token map đến user `system:bootstrap:<token-id>`, group `system:bootstrappers`. Sau khi kubelet join, CSR được approve, kubelet nhận cert riêng — bootstrap token không cần nữa.

## 6. Anonymous auth

Khi `--anonymous-auth=true` (mặc định), request không có credential được accept với user `system:anonymous`, group `system:unauthenticated`.

```bash
# Anonymous request
curl -k https://192.168.56.11:6443/api/v1/namespaces/default/pods
# {
#   "kind": "Status",
#   "message": "pods is forbidden: User \"system:anonymous\" cannot list resource \"pods\"...",
#   "code": 403
# }
```

> Authentication thành công (user = `system:anonymous`), nhưng Authorization fail (anonymous không có quyền). Production nên set `--anonymous-auth=false`.

## Authentication flow — nhiều method cùng lúc

API Server thử **từng method** theo thứ tự. Method đầu tiên match → user được xác định. Nếu không method nào match → anonymous (nếu enabled) hoặc reject.

```
Request arrives
       │
       ▼
  ┌─ Client cert? ──→ verify cert → extract CN/O → User
  │
  ┌─ Bearer token? ──→ check token file / JWT / webhook → User
  │
  ┌─ Bootstrap token? ──→ check bootstrap token → User
  │
  ┌─ OIDC token? ──→ verify JWT with OIDC provider → User
  │
  └─ No credential ──→ anonymous (if enabled) → User{system:anonymous}
```

> API Server **không dừng** ở method đầu tiên fail — thử method tiếp theo. Chỉ method đầu tiên **success** mới xác định user.

## User vs ServiceAccount

| | User | ServiceAccount |
|---|------|----------------|
| **Dành cho** | Human (admin, dev) | Pod / workload |
| **Tạo bằng** | Cert (openssl/cfssl) | `kubectl create serviceaccount` |
| **Identity** | CN trong cert | `system:serviceaccount:<ns>:<name>` |
| **Token** | Cert (không expire) hoặc OIDC | JWT (auto-rotate) |
| **RBAC** | Bind Role/ClusterRole đến user | Bind Role/ClusterRole đến SA |
| **Namespace** | Cluster-scoped | Namespace-scoped |

> Kubernetes **không có User resource** — user chỉ tồn tại trong cert/OIDC token. Không `kubectl get users`. ServiceAccount là K8s resource — `kubectl get serviceaccounts`.

## Impersonation

User có quyền `impersonate` có thể gửi request thay mặt user khác:

```bash
# Admin impersonate alice để test RBAC
kubectl get pods --as=alice
kubectl get pods --as=alice --as-group=dev
```

```yaml
# RBAC cho impersonation
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: impersonator
rules:
- apiGroups: [""]
  resources: ["users", "groups", "serviceaccounts"]
  verbs: ["impersonate"]
```

> Impersonation hữu ích cho debugging RBAC — admin test quyền của user khác mà không cần cert của user đó.

## Liên hệ với Kubernetes

- Authentication là **bước đầu tiên** trong request flow — fail → 401 Unauthorized.
- Client cert là **phổ biến nhất** cho component — kubelet, controller-manager, scheduler đều dùng cert.
- OIDC là **best practice** cho human user — SSO, token expire, rotate.
- Service Account JWT cho pod — auto-rotate, audience-scoped.
- `system:masters` group **bypass RBAC** — chỉ cho admin, không cấp cho user thường.
- `--anonymous-auth=false` trong production — block anonymous request.
- Impersonation cho phép admin test RBAC của user khác.
