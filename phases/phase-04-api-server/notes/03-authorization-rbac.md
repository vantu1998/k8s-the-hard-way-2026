# 03 — Authorization (RBAC)

## Authorization là gì

Authorization (Authz) trả lời câu hỏi: **"User này có quyền làm action này trên resource này không?"** — chạy sau Authentication, trước Admission.

```
Authentication: "Alice gửi request"        → User{alice, [dev]}
       │
       ▼
Authorization: "Alice có quyền list pods?"  → Allow / Deny
       │
       ▼
Admission: "Request hợp lệ về policy?"     → Allow / Mutate / Deny
```

> Authorization **chỉ kiểm tra quyền** — không sửa request. Admission có thể sửa (Mutating) hoặc reject (Validating).

## Authorization modes

API Server cấu hình qua `--authorization-mode`:

| Mode | Ý nghĩa | Use case |
|------|---------|----------|
| `RBAC` | Role-Based Access Control — Role + Binding | Production (default) |
| `Node` | Authorize kubelet request | Production (luôn dùng cùng RBAC) |
| `ABAC` | Attribute-Based Access Control — policy file | Legacy, deprecated |
| `Webhook` | External service decide | Custom authorization logic |
| `AlwaysAllow` | Cho phép tất cả | Lab/testing only |
| `AlwaysDeny` | Từ chối tất cả | Testing only |

```bash
# Production
--authorization-mode=Node,RBAC
```

> Nhiều mode eval theo **thứ tự** — mode đầu tiên allow → request accept. Nếu tất cả deny → 403 Forbidden. `Node` trước `RBAC` vì kubelet request cần Node authorization (RBAC không cover đầy đủ kubelet use case).

## RBAC — Role-Based Access Control

RBAC là mode phổ biến nhất. Quyền được gán qua **Role** + **Binding**:

```
Role: "Cho phép list/get pod trong namespace default"
       │
       ▼
RoleBinding: "Gán Role này cho user alice"
       │
       ▼
Result: alice có thể list/get pod trong namespace default
```

### 4 RBAC objects

| Object | Scope | Ý nghĩa |
|--------|-------|---------|
| **Role** | Namespace | Quyền trên resource trong 1 namespace |
| **RoleBinding** | Namespace | Gán Role cho user/group/SA trong 1 namespace |
| **ClusterRole** | Cluster | Quyền trên resource cluster-wide (hoặc tất cả namespace) |
| **ClusterRoleBinding** | Cluster | Gán ClusterRole cho user/group/SA cluster-wide |

### Role vs ClusterRole

```yaml
# Role — namespace-scoped
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: default          ← chỉ áp dụng trong namespace default
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

```yaml
# ClusterRole — cluster-scoped
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-reader            ← không có namespace field
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

> ClusterRole có thể áp dụng cho **tất cả namespace** (qua ClusterRoleBinding) hoặc **1 namespace** (qua RoleBinding). Role chỉ áp dụng trong 1 namespace.

### RoleBinding vs ClusterRoleBinding

```yaml
# RoleBinding — bind Role hoặc ClusterRole vào 1 namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader
  namespace: default
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role                   ← có thể là Role hoặc ClusterRole
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

```yaml
# ClusterRoleBinding — bind ClusterRole cluster-wide
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: alice-pod-reader-global
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### subjects — ai nhận quyền

| `kind` | `name` | Ý nghĩa |
|--------|--------|---------|
| `User` | `alice` | Human user (từ cert CN hoặc OIDC) |
| `Group` | `dev` | Group (từ cert O hoặc OIDC groups) |
| `ServiceAccount` | `my-sa` | ServiceAccount (phải chỉ định `namespace`) |

```yaml
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
- kind: Group
  name: dev
  apiGroup: rbac.authorization.k8s.io
- kind: ServiceAccount
  name: my-sa
  namespace: default
```

### rules — quyền gì trên resource nào

```yaml
rules:
- apiGroups: [""]                    # core API group (Pod, Service, ConfigMap...)
  resources: ["pods", "pods/log"]    # resource types
  verbs: ["get", "list", "watch"]    # allowed actions
  resourceNames: ["nginx", "redis"]  # optional: chỉ specific resources
```

| Field | Ý nghĩa | Ví dụ |
|-------|---------|-------|
| `apiGroups` | API group name | `""` (core), `apps`, `batch`, `rbac.authorization.k8s.io` |
| `resources` | Resource types | `pods`, `services`, `deployments`, `pods/log`, `secrets` |
| `verbs` | Allowed actions | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection` |
| `resourceNames` | Restrict to specific resources | `["nginx"]` — chỉ pod tên `nginx` |

### Verbs

| Verb | HTTP method | Ý nghĩa |
|------|-------------|---------|
| `get` | GET | Đọc 1 resource |
| `list` | GET | Liệt kê tất cả resource |
| `watch` | GET (stream) | Watch thay đổi |
| `create` | POST | Tạo resource mới |
| `update` | PUT | Update toàn bộ resource |
| `patch` | PATCH | Patch resource (sửa 1 phần) |
| `delete` | DELETE | Xóa 1 resource |
| `deletecollection` | DELETE | Xóa nhiều resource (kubectl delete pods --all) |

> `get` vs `list`: `get` đọc 1 resource cụ thể (`pods/nginx`), `list` liệt kê tất cả (`pods`). `watch` = `list` + stream event.

### Subresources

Resource có **subresource** — ví dụ `pods/log`, `pods/exec`, `pods/portforward`:

```yaml
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]            # exec = create subresource
```

| Subresource | Verb | Ý nghĩa |
|-------------|------|---------|
| `pods/log` | `get` | Xem log pod |
| `pods/exec` | `create` | Exec vào container |
| `pods/portforward` | `create` | Port-forward vào pod |
| `pods/attach` | `create` | Attach vào container |
| `deployments/scale` | `update`, `patch` | Scale deployment |
| `secrets` | `get`, `list`, `watch`, `create`, `update`, `patch`, `delete` | Quản lý Secret |

## Node authorization

Node authorization chuyên cho kubelet request. Kubelet dùng cert với CN=`system:node:<node-name>`, O=`system:nodes`.

```
Kubelet (CN=system:node:worker-1, O=system:nodes)
       │
       ▼
  Node Authorizer
  ├── Allow: read pod scheduled on worker-1
  ├── Allow: update node status for worker-1
  ├── Allow: update pod status for pod on worker-1
  ├── Deny: read pod on other node
  └── Deny: modify other node
```

> Node authorizer restrict kubelet chỉ modify **node của chính nó** + **pod scheduled trên node đó**. Nếu không có Node authorizer, kubelet có thể modify bất kỳ node/pod (nếu RBAC cho phép).

### NodeRestriction admission plugin

`NodeRestriction` (validating admission) enforce thêm:
- Kubelet chỉ update **node của chính nó** (không update node khác).
- Kubelet chỉ update **pod status** của pod scheduled trên node đó.
- Kubelet không thể modify **label/annotation** mà nó không sở hữu.

> Node authorizer + NodeRestriction admission = kubelet chỉ quản lý node + pod của chính nó.

## Default ClusterRole / ClusterRoleBinding

kubeadm tạo sẵn nhiều ClusterRole + ClusterRoleBinding:

```bash
kubectl get clusterroles | head -20
# cluster-admin                          → superuser, bypass RBAC
# system:basic-user                      → basic read access
# system:discovery                       → API discovery
# system:node                            → kubelet permissions
# system:node-proxier                    → kube-proxy permissions
# admin                                  → namespace admin (all resources except RBAC)
# edit                                   → edit resources (no RBAC, no secret)
# view                                   → view resources (no secret)
```

### Built-in roles

| Role | Ý nghĩa |
|------|---------|
| `cluster-admin` | Superuser — `*` trên tất cả resource. Bind cho `system:masters` group. |
| `admin` | Namespace admin — tất cả resource trong namespace, trừ RBAC + authorization |
| `edit` | Edit resource trong namespace — không sửa RBAC, không đọc Secret |
| `view` | Read-only — không đọc Secret |
| `system:node` | Kubelet permission — chỉ dùng cho `system:nodes` group |
| `system:node-proxier` | kube-proxy permission — chỉ dùng cho `system:kube-proxy` user |

```yaml
# cluster-admin — superuser
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-admin
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
- nonResourceURLs: ["*"]
  verbs: ["*"]
```

> `system:masters` group **bypass RBAC entirely** — không cần RoleBinding. Đây là lý do kubeadm admin cert có O=`system:masters`.

## RBAC examples

### Example 1: User chỉ đọc pod trong namespace default

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader
  namespace: default
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

### Example 2: ServiceAccount deploy app trong namespace

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-cd
  namespace: production
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: production
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods", "services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-cd-deployer
  namespace: production
subjects:
- kind: ServiceAccount
  name: ci-cd
  namespace: production
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
```

### Example 3: Group đọc tất cả namespace

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-reader-global
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dev-pod-reader
subjects:
- kind: Group
  name: dev
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: pod-reader-global
  apiGroup: rbac.authorization.k8s.io
```

## Kiểm tra quyền

### kubectl auth can-i

```bash
# Kiểm tra quyền của current user
kubectl auth can-i list pods
# yes

kubectl auth can-i create deployments
# yes

kubectl auth can-i delete nodes
# no

# Kiểm tra quyền của user khác (cần impersonate permission)
kubectl auth can-i list pods --as=alice
# no

kubectl auth can-i list pods --as=alice -n default
# yes  (nếu đã bind Role)

# Kiểm tra quyền của ServiceAccount
kubectl auth can-i list pods --as=system:serviceaccount:default:my-sa
# no

# Kiểm tra tất cả quyền
kubectl auth can-i --list
# Resources   Non-Resource URLs   Resource Names   Verbs
# pods.*      []                  []               [get list watch create update patch delete]
# services.*  []                  []               [get list watch create update patch delete]
```

### kubectl auth whoami

```bash
# Xem current user (v1.25+)
kubectl auth whoami
# ATTRIBUTE   VALUE
# Username    kubernetes-admin
# Groups      [system:masters system:authenticated]
```

## Aggregated ClusterRole

ClusterRole có thể aggregate quyền từ ClusterRole khác qua label selector:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.example.com/aggregate-to-monitoring: "true"
rules: []  # rules được aggregate từ ClusterRole match label
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: monitoring-pods
  labels:
    rbac.example.com/aggregate-to-monitoring: "true"
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
```

> Aggregation tự động gom quyền từ tất cả ClusterRole có label match. Thêm ClusterRole mới với label → quyền tự động thêm vào aggregated role.

## ABAC (Attribute-Based Access Control)

ABAC dùng policy file JSON — mỗi line 1 policy:

```json
{"user":"alice","namespace":"default","resource":"pods","readonly":true}
{"user":"kubelet","namespace":"*","resource":"pods","readonly":true}
```

```bash
--authorization-mode=ABAC
--authorization-policy-file=/etc/kubernetes/abac-policy.json
```

> **Deprecated** — không recommend. Khó quản lý, không dynamic (cần restart API Server để update policy), không namespace-scoped. Dùng RBAC thay thế.

## Webhook authorization

API Server gọi external service để authorize:

```bash
--authorization-mode=Webhook
--authorization-webhook-config-file=/etc/kubernetes/authz-webhook.yaml
```

```yaml
# /etc/kubernetes/authz-webhook.yaml
apiVersion: v1
kind: Config
clusters:
- name: authz-webhook
  cluster:
    server: https://authz-service.example.com/authorize
    certificate-authority: /etc/kubernetes/pki/authz-ca.crt
users:
- name: apiserver
  user:
    client-certificate: /etc/kubernetes/pki/apiserver-authz-client.crt
    client-key: /etc/kubernetes/pki/apiserver-authz-client.key
```

> API Server gửi `SubjectAccessReview` đến webhook. Webhook trả về allow/deny. Dùng cho custom authorization logic (OPA, custom service).

## Liên hệ với Kubernetes

- RBAC là **production standard** — `--authorization-mode=Node,RBAC`.
- `system:masters` group **bypass RBAC** — chỉ cho admin cert, không cấp cho user thường.
- Role = namespace-scoped, ClusterRole = cluster-scoped. ClusterRole có thể bind vào namespace qua RoleBinding.
- `kubectl auth can-i` là tool debug RBAC nhanh nhất.
- Node authorizer + NodeRestriction admission restrict kubelet chỉ quản lý node/pod của chính nó.
- Aggregated ClusterRole cho phép dynamic permission aggregation qua label.
- ABAC deprecated — dùng RBAC.
- Webhook authorization cho custom logic — nhưng tăng latency (external call).
