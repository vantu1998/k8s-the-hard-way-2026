# 02 — TLS Bootstrap

## TLS Bootstrap là gì

TLS Bootstrap cho phép kubelet **join cluster không cần cert sẵn** — dùng bootstrap token, request CSR (Certificate Signing Request), API Server ký cert, kubelet nhận cert và bắt đầu chạy.

```
Worker Node (chưa có cert)
    │
    │ 1. Kubelet start với bootstrap-kubeconfig (token auth)
    │
    ▼
API Server (verify token)
    │
    │ 2. Kubelet submit CSR (Certificate Signing Request)
    │
    ▼
Controller Manager (CSR signer)
    │
    │ 3. Auto-approve CSR → sign cert with CA
    │
    ▼
Kubelet nhận cert → kubelet.conf (cert auth)
    │
    │ 4. Kubelet register node, start heartbeat
    │
    ▼
Node joined cluster ✓
```

> Không cần copy cert manually cho mỗi worker node. Bootstrap token + CSR = secure auto-join.

## Bootstrap token

### Tạo bootstrap token

```bash
# Tạo token (kubeadm)
kubeadm token create --print-join-command
# kubeadm join 192.168.1.10:6443 --token abcdef.0123456789abcdef \
#   --discovery-token-ca-cert-hash sha256:xxx

# Hoặc tạo manually
TOKEN_ID="abcdef"
TOKEN_SECRET="0123456789abcdef"
TOKEN="${TOKEN_ID}.${TOKEN_SECRET}"

# Tạo bootstrap token object
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: bootstrap-token-${TOKEN_ID}
  namespace: kube-system
type: bootstrap.kubernetes.io/token
stringData:
  token-id: "${TOKEN_ID}"
  token-secret: "${TOKEN_SECRET}"
  usage-bootstrap-authentication: "true"
  usage-bootstrap-signing: "true"
  auth-extra-groups: "system:bootstrappers"
EOF
```

### Token format

```
abcdef.0123456789abcdef
│      │
│      └── Token Secret (16 char random)
└── Token ID (6 char random)
```

> Token = `ID.Secret`. ID dùng để identify token. Secret dùng để authenticate. Token có TTL (default 24h nếu tạo bằng kubeadm).

### Discovery token CA cert hash

```bash
# Hash của CA cert — kubelet verify API Server cert
openssl x509 -in /etc/kubernetes/pki/ca.crt -pubkey -noout | \
  openssl rsa -pubin -outform DER 2>/dev/null | \
  sha256sum
# sha256:xxx...
```

> Kubelet dùng CA cert hash để verify API Server — tránh MITM attack. Nếu API Server cert không match CA → kubelet refuse connect.

## Bootstrap kubeconfig

```bash
# /etc/kubernetes/bootstrap-kubelet.conf
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://192.168.1.10:6443
  name: k8s-lab
contexts:
- context:
    cluster: k8s-lab
    user: kubelet-bootstrap
  name: kubelet-bootstrap
current-context: kubelet-bootstrap
users:
- name: kubelet-bootstrap
  user:
    token: abcdef.0123456789abcdef
```

> Bootstrap kubeconfig dùng **token auth** (không cert). Kubelet dùng config này để submit CSR. Sau khi nhận cert → kubelet tạo `kubelet.conf` (cert auth) và dùng cert thay vì token.

## CSR process

### Step 1: Kubelet submit CSR

```bash
# Kubelet tạo key pair
# /var/lib/kubelet/pki/kubelet-client-current.pem (client cert)
# /var/lib/kubelet/pki/kubelet.crt (serving cert)

# Submit CSR to API Server
kubectl get csr
# NAME        AGE   SIGNOR   REQUESTOR          REQUESTEDDURATION
# csr-abc123  10s   <none>   kubelet-bootstrap  365d
```

### Step 2: Auto-approve CSR

Controller Manager có **CSR signer** + **CSR approver**:

```yaml
# RBAC — cho phép auto-approve bootstrap CSR
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeadm:node-autoapprove-bootstrap
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:certificates.k8s.io:certificatesigningrequests:nodecluster
subjects:
- kind: Group
  name: system:bootstrappers
  apiGroup: rbac.authorization.k8s.io
```

> CSR từ group `system:bootstrappers` → auto-approve. Controller Manager sign CSR với CA key → kubelet nhận cert.

### Step 3: Kubelet nhận cert

```bash
# Sau khi CSR approved + signed
kubectl get csr csr-abc123 -o yaml | grep certificate
# certificate: LS0tLS1CRUdJTi... (base64 encoded cert)

# Kubelet download cert, tạo kubelet.conf
cat /etc/kubernetes/kubelet.conf
# apiVersion: v1
# kind: Config
# users:
# - name: default-auth
#   user:
#     client-certificate: /var/lib/kubelet/pki/kubelet-client-current.pem
#     client-key: /var/lib/kubelet/pki/kubelet-client-current.pem
```

> Kubelet tự động download cert từ CSR, tạo `kubelet.conf` với cert auth. Từ đây kubelet dùng cert (không cần token nữa).

## CSR types

| CSR Type | Purpose | Auto-approve |
|----------|---------|--------------|
| **Bootstrap CSR** | Kubelet client cert (lần đầu join) | Yes (system:bootstrappers group) |
| **Client CSR** | Kubelet client cert rotation | Yes (system:nodes group) |
| **Serving CSR** | Kubelet serving cert (API 10250) | Manual (hoặc `serverTLSBootstrap: true`) |

### Client cert vs serving cert

```
Client cert:  kubelet → API Server (kubelet authenticate với API Server)
Serving cert: API Server/kubectl → kubelet (client authenticate với kubelet API 10250)
```

> Client cert = kubelet là client (connect API Server). Serving cert = kubelet là server (kubectl exec/logs connect kubelet). Cả 2 cần cert riêng.

## Cert rotation

```yaml
# KubeletConfiguration
rotateCertificates: true        # Auto-rotate client cert
serverTLSBootstrap: true        # Auto-rotate serving cert via CSR
```

```
Client cert lifecycle:
  1. Kubelet nhận cert (bootstrap hoặc rotation)
  2. Cert valid 1 year (default)
  3. Khi cert còn 30% lifetime → kubelet submit CSR mới
  4. Controller Manager auto-approve + sign
  5. Kubelet download new cert → reload (no restart)
  6. Old cert expire → kubelet dùng new cert
```

> `rotateCertificates: true` = kubelet tự rotate client cert trước khi expire. Không cần restart kubelet. Default rotation: khi cert còn 30% lifetime (~109 ngày trước expire cho cert 1 năm).

### Serving cert rotation

```bash
# Serving cert cần serverTLSBootstrap: true
# Kubelet submit serving CSR → cần approve manually (hoặc auto-approve RBAC)

kubectl get csr | grep serving
# csr-serving-xxx   10s   <none>   worker-1   365d

# Approve manually
kubectl certificate approve csr-serving-xxx
```

> Serving CSR **không auto-approve** mặc định — cần approve manually hoặc tạo RBAC cho auto-approve. Dùng `serverTLSBootstrap: true` để enable serving CSR.

## kubeadm join — full flow

```bash
# Trên worker node
kubeadm join 192.168.1.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:xxx

# What happens:
# 1. Download CA cert from API Server (verify with hash)
# 2. Create bootstrap-kubelet.conf (token auth)
# 3. Kubelet start with bootstrap-kubelet.conf
# 4. Kubelet submit CSR (client cert)
# 5. Controller Manager auto-approve + sign
# 6. Kubelet download cert → create kubelet.conf (cert auth)
# 7. Kubelet register node
# 8. Kubelet start heartbeat
# 9. Node Ready ✓
```

### Verify node joined

```bash
# Trên master
kubectl get nodes
# NAME       STATUS   ROLES    AGE   VERSION
# master     Ready    control-plane   10d  v1.33.0
# worker-1   Ready    <none>   30s   v1.33.0   ← just joined

# Check CSR
kubectl get csr
# NAME        AGE   SIGNOR               REQUESTOR   REQUESTEDDURATION
# csr-abc123  30s   kubernetes-ca        kubelet-bootstrap  365d   ← approved + signed
```

## Manual CSR approve

```bash
# List CSR
kubectl get csr
# NAME        AGE   SIGNOR   REQUESTOR          CONDITION
# csr-abc123  10s   <none>   kubelet-bootstrap  Pending

# Approve
kubectl certificate approve csr-abc123
# certificatesigningrequest.certificates.k8s.io/csr-abc123 approved

# Deny
kubectl certificate deny csr-abc123
```

> Auto-approve chỉ cho `system:bootstrappers` và `system:nodes` group. CSR từ user khác → approve manually.

## Troubleshooting

### CSR stuck Pending

```bash
# Check CSR
kubectl get csr csr-abc123 -o yaml
# status: {} (empty = Pending)

# Check Controller Manager CSR signer
kubectl logs -n kube-system kube-controller-manager-master | grep -i csr
# "Signing certificate" csr=csr-abc123

# Nếu CSR Pending → check RBAC
kubectl get clusterrolebinding | grep autoapprove
# kubeadm:node-autoapprove-bootstrap   ClusterRole/system:certificates.k8s.io:certificatesigningrequests:nodecluster
# kubeadm:node-autoapprove-certificate-rotation   ...
```

### Kubelet can't connect API Server

```bash
# Check bootstrap kubeconfig
cat /etc/kubernetes/bootstrap-kubelet.conf | grep token
# token: abcdef.0123456789abcdef

# Verify token valid
kubectl get secret -n kube-system bootstrap-token-abcdef
# (if NotFound → token expired or deleted)

# Check CA cert hash
openssl x509 -in /etc/kubernetes/pki/ca.crt -pubkey -noout | \
  openssl rsa -pubin -outform DER 2>/dev/null | sha256sum
# Compare with --discovery-token-ca-cert-hash
```

## Liên hệ với Kubernetes

- TLS Bootstrap = kubelet join cluster **không cần cert sẵn** — token + CSR.
- Bootstrap token format: `ID.Secret` (6.16 char). Token trong Secret `kube-system/bootstrap-token-<ID>`.
- CA cert hash = verify API Server (tránh MITM). Kubelet refuse connect nếu hash không match.
- CSR flow: kubelet submit CSR → Controller Manager auto-approve (system:bootstrappers) → sign with CA → kubelet download cert.
- Client cert (kubelet → API Server) auto-rotate khi còn 30% lifetime. Serving cert (kubectl → kubelet) cần approve manually.
- `rotateCertificates: true` = auto-rotate client cert, no restart. `serverTLSBootstrap: true` = enable serving CSR.
- `kubeadm join` = full bootstrap flow (download CA, bootstrap kubeconfig, CSR, cert, register node).
- CSR từ `system:bootstrappers` / `system:nodes` auto-approve. CSR từ user khác → approve manually.
