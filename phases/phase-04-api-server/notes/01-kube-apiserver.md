# 01 — kube-apiserver

## API Server là gì

kube-apiserver là **cửa ngõ duy nhất** (single entry point) vào Kubernetes cluster. Mọi tương tác — `kubectl`, dashboard, controller, kubelet — đều gọi API Server. API Server validate request, authorize, chạy admission controller, rồi ghi vào etcd.

```
kubectl create deployment nginx
       │
       ▼
  API Server
  ├── 1. Authentication: ai gửi request?
  ├── 2. Authorization: có quyền không?
  ├── 3. Mutating Admission: sửa request (thêm default)
  ├── 4. Validation: kiểm tra tính hợp lệ
  ├── 5. etcd: ghi object
  └── 6. Watch event → Controller/Kubelet react
```

**Tại sao API Server là "firewall"?**
- Không ai ghi trực tiếp etcd ngoài API Server (qua cert `apiserver-etcd-client.pem`).
- API Server enforce mọi policy: authentication, authorization, admission, schema validation.
- Nếu bypass API Server (ghi thẳng etcd), không có policy nào được enforce → nguy hiểm.

## Stateless design

API Server là **stateless** — không lưu state trong memory. Toàn bộ state nằm trong etcd. Điều này cho phép:

- Chạy **nhiều instance** song song (horizontal scaling).
- Load balancer phân phối request đến bất kỳ instance nào — kết quả giống nhau.
- Restart instance không mất state (đọc lại từ etcd).

```
         Load Balancer (HAProxy / kube-proxy)
        ┌──────┬──────┬──────┐
        │      │      │      │
   apiserver-1 apiserver-2 apiserver-3
        │      │      │
        └──────┼──────┘
               │
             etcd
```

> Mỗi apiserver instance kết nối đến **tất cả** etcd member. Nếu 1 etcd node down, apiserver vẫn dùng etcd node khác.

## API groups

Kubernetes API được tổ chức theo **API groups** — mỗi group là một tập hợp resource types:

| API Group | Resources | Mục đích |
|-----------|-----------|----------|
| (core) `""` | Pod, Service, Namespace, Node, Secret, ConfigMap, Event, PersistentVolume... | Core resources (legacy API path `/api/v1`) |
| `apps` | Deployment, ReplicaSet, StatefulSet, DaemonSet | Workload resources |
| `batch` | Job, CronJob | Batch workloads |
| `networking.k8s.io` | Ingress, NetworkPolicy, IngressClass | Networking |
| `rbac.authorization.k8s.io` | Role, ClusterRole, RoleBinding, ClusterRoleBinding | RBAC |
| `storage.k8s.io` | StorageClass, VolumeAttachment, CSINode, CSIStorageCapacity | Storage |
| `certificates.k8s.io` | CertificateSigningRequest | TLS cert bootstrap |
| `admissionregistration.k8s.io` | ValidatingWebhookConfiguration, MutatingWebhookConfiguration | Admission webhook |
| `apiextensions.k8s.io` | CustomResourceDefinition | Custom resources (CRD) |
| `authentication.k8s.io` | TokenReview, UserInfo | Authentication |
| `authorization.k8s.io` | SubjectAccessReview, SelfSubjectAccessReview | Authorization |

### API path structure

```
/api/v1/pods                          → list all pods (core group)
/api/v1/namespaces/default/pods       → list pods in namespace default
/apis/apps/v1/deployments             → list all deployments (apps group)
/apis/apps/v1/namespaces/default/deployments/nginx → get specific deployment
/apis/rbac.authorization.k8s.io/v1/clusterroles     → list clusterroles
```

| Path | Ý nghĩa |
|------|---------|
| `/api/v1/...` | Core API group (group name rỗng `""`) |
| `/apis/<group>/<version>/...` | Named API group |
| `/apis/apiextensions.k8s.io/v1/customresourcedefinitions` | CRD definitions |
| `/healthz` | Health check endpoint |
| `/metrics` | Prometheus metrics |
| `/debug/pprof` | Go pprof profiling (if enabled) |

### API versioning

Mỗi API group có thể có nhiều version: `v1alpha1`, `v1beta1`, `v1`.

```
/apis/apps/v1beta1/deployments    → deprecated, sẽ bị xóa
/apis/apps/v1/deployments         → stable, production-ready
```

| Version | Ý nghĩa |
|---------|---------|
| `v1alpha1` | Alpha — có thể break, không enable mặc định |
| `v1beta1` | Beta — enable mặc định, có thể break trong version sau |
| `v1` | Stable — backward compatible, production-ready |

> `kubectl api-versions` liệt kê tất cả API version mà API Server hỗ trợ.

## Cấu hình chính — flags quan trọng

### etcd connection

```bash
--etcd-servers=https://127.0.0.1:2379 \
--etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt \
--etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt \
--etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key \
```

| Flag | Ý nghĩa |
|------|---------|
| `--etcd-servers` | Danh sách etcd endpoint (comma-separated) |
| `--etcd-cafile` | CA cert để verify etcd server cert |
| `--etcd-certfile` | Client cert trình cho etcd (mTLS) |
| `--etcd-keyfile` | Private key cho client cert |

> API Server là **client** của etcd. Cert `apiserver-etcd-client.crt` được ký bởi **etcd CA** (không phải Kubernetes CA).

### TLS server

```bash
--tls-cert-file=/etc/kubernetes/pki/apiserver.crt \
--tls-private-key-file=/etc/kubernetes/pki/apiserver.key \
--client-ca-file=/etc/kubernetes/pki/ca.crt \
```

| Flag | Ý nghĩa |
|------|---------|
| `--tls-cert-file` | Server cert trình cho client (kubectl, kubelet...) |
| `--tls-private-key-file` | Private key cho server cert |
| `--client-ca-file` | CA cert để verify client cert (client mTLS) |

> `--client-ca-file` chỉ định CA dùng để verify client cert. Nếu client trình cert không ký bởi CA này → request bị reject ở Authentication phase.

### Service account

```bash
--service-account-key-file=/etc/kubernetes/pki/sa.pub \
--service-account-signing-key-file=/etc/kubernetes/pki/sa.key \
--service-account-issuer=https://kubernetes.default.svc.cluster.local \
```

| Flag | Ý nghĩa |
|------|---------|
| `--service-account-key-file` | Public key để verify JWT signature |
| `--service-account-signing-key-file` | Private key để sign JWT (Service Account token) |
| `--service-account-issuer` | Issuer claim trong JWT — dùng cho OIDC validation |

### Authorization

```bash
--authorization-mode=Node,RBAC \
```

| Mode | Ý nghĩa |
|------|---------|
| `Node` | Authorize kubelet request (kubelet đọc node/pod info) |
| `RBAC` | Role-Based Access Control — Role/ClusterRole + Binding |
| `ABAC` | Attribute-Based Access Control — policy file (legacy) |
| `AlwaysAllow` | Cho phép tất cả (chỉ cho lab/testing) |
| `AlwaysDeny` | Từ chối tất cả (chỉ cho testing) |
| `Webhook` | Gọi external service để authorize |

> Production dùng `Node,RBAC` — Node authorization cho kubelet, RBAC cho user/service. Nhiều mode được eval theo thứ tự — mode đầu tiên allow thì request được accept.

### Admission controller

```bash
--enable-admission-plugins=NodeRestriction,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota,NamespaceLifecycle \
```

| Plugin | Phase | Ý nghĩa |
|--------|-------|---------|
| `NodeRestriction` | Validating | Kubelet chỉ modify node/pod của chính nó |
| `ServiceAccount` | Mutating | Auto-mount ServiceAccount token + default SA |
| `DefaultStorageClass` | Mutating | Add default StorageClass nếu PVC không chỉ định |
| `DefaultTolerationSeconds` | Mutating | Add default toleration cho pod |
| `MutatingAdmissionWebhook` | Mutating | Gọi external webhook để sửa request |
| `ValidatingAdmissionWebhook` | Validating | Gọi external webhook để validate request |
| `ResourceQuota` | Validating | Enforce namespace quota limit |
| `NamespaceLifecycle` | Validating | Block tạo resource trong namespace đang xóa |

> Thứ tự: **Mutating** chạy trước (sửa request), **Validating** chạy sau (kiểm tra final result). Xem chi tiết trong `04-admission-controller.md`.

### Encryption at rest

```bash
--encryption-provider-config=/etc/kubernetes/encryption-provider.yaml \
```

> Khi enabled, Secret (và resource khác nếu cấu hình) được mã hóa trước khi ghi vào etcd. Xem chi tiết trong `06-encryption-at-rest.md`.

### Other important flags

```bash
--allow-privileged=true \
--kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt \
--kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key \
--kubelet-https=true \
--bind-address=0.0.0.0 \
--secure-port=6443 \
--anonymous-auth=false \
```

| Flag | Mặc định | Ý nghĩa |
|------|----------|---------|
| `--bind-address` | `0.0.0.0` | Bind API Server listener |
| `--secure-port` | `6443` | HTTPS port — tất cả API request đi qua đây |
| `--anonymous-auth` | `true` | Cho phép anonymous request (chỉ read public resource) |
| `--allow-privileged` | `true` | Cho phép privileged container |
| `--kubelet-client-certificate` | — | Client cert khi API Server gọi kubelet |
| `--kubelet-https` | `true` | Dùng HTTPS khi gọi kubelet |

> **Production**: Set `--anonymous-auth=false` để block anonymous request. Mặc định `true` cho phép anonymous read public resource (healthz, api discovery).

## API Server chạy như thế nào

### Static Pod (kubeadm)

kubeadm chạy kube-apiserver như **static pod** — manifest trong `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml (kubeadm generated)
apiVersion: v1
kind: Pod
metadata:
  labels:
    component: kube-apiserver
    tier: control-plane
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-apiserver
    - --advertise-address=192.168.56.11
    - --allow-privileged=true
    - --authorization-mode=Node,RBAC
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --enable-admission-plugins=NodeRestriction,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota,NamespaceLifecycle
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
    - --kubelet-client-certificate=/etc/kubernetes/pki/apiserver-kubelet-client.crt
    - --kubelet-client-key=/etc/kubernetes/pki/apiserver-kubelet-client.key
    - --kubelet-https=true
    - --bind-address=0.0.0.0
    - --secure-port=6443
    - --service-account-key-file=/etc/kubernetes/pki/sa.pub
    - --service-account-signing-key-file=/etc/kubernetes/pki/sa.key
    - --service-account-issuer=https://kubernetes.default.svc.cluster.local
    - --service-cluster-ip-range=10.96.0.0/12
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    - --anonymous-auth=false
    image: registry.k8s.io/kube-apiserver:v1.33.0
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 8
      httpGet:
        host: 192.168.56.11
        path: /livez
        port: 6443
        scheme: HTTPS
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 15
    name: kube-apiserver
    resources:
      requests:
        cpu: 250m
        memory: 1Gi
    volumeMounts:
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /etc/kubernetes/pki/etcd
      name: etcd-certs
      readOnly: true
  hostNetwork: true
  priority: 2000001000
  priorityClassName: system-node-critical
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  volumes:
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
  - hostPath:
      path: /etc/kubernetes/pki/etcd
      type: DirectoryOrCreate
    name: etcd-certs
```

### Giải thích các thành phần trong manifest

| Thành phần | Ý nghĩa |
|-----------|---------|
| `--advertise-address` | IP mà client dùng để kết nối API Server |
| `--service-cluster-ip-range` | CIDR range cho Service ClusterIP (phải khớp kube-controller-manager) |
| `--etcd-servers=https://127.0.0.1:2379` | etcd trên cùng node (localhost) — nhanh nhất |
| `hostNetwork: true` | Dùng host network — API Server cần reach được từ outside |
| `priorityClassName: system-node-critical` | Priority cao nhất — không bị evict |
| `livenessProbe: /livez` | Health check — kill pod nếu fail 8 lần |
| `resources: requests` | CPU 250m, memory 1Gi — minimum guarantee |
| `volumeMounts: /etc/kubernetes/pki` | Mount cert directory — API Server đọc cert từ đây |

### Standalone (không kubeadm)

Khi chạy API Server standalone (lab, learning), chạy binary trực tiếp:

```bash
kube-apiserver \
  --etcd-servers=https://127.0.0.1:2379 \
  --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt \
  --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt \
  --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key \
  --client-ca-file=/etc/kubernetes/pki/ca.crt \
  --tls-cert-file=/etc/kubernetes/pki/apiserver.crt \
  --tls-private-key-file=/etc/kubernetes/pki/apiserver.key \
  --service-account-key-file=/etc/kubernetes/pki/sa.pub \
  --service-account-signing-key-file=/etc/kubernetes/pki/sa.key \
  --service-account-issuer=https://kubernetes.default.svc.cluster.local \
  --service-cluster-ip-range=10.96.0.0/12 \
  --authorization-mode=Node,RBAC \
  --enable-admission-plugins=NodeRestriction,ServiceAccount \
  --anonymous-auth=false \
  --bind-address=0.0.0.0 \
  --secure-port=6443 \
  --v=2
```

> Xem exercise 01 để chạy API Server standalone từng bước.

## API Server endpoints

| Endpoint | Method | Ý nghĩa |
|----------|--------|---------|
| `/api/v1/...` | GET, POST, PUT, PATCH, DELETE | Core API resources |
| `/apis/<group>/<version>/...` | GET, POST, PUT, PATCH, DELETE | Named API group resources |
| `/healthz` | GET | Health check (HTTP 200 = healthy) |
| `/livez` | GET | Liveness check (HTTP 200 = alive) |
| `/readyz` | GET | Readiness check (HTTP 200 = ready) |
| `/metrics` | GET | Prometheus metrics |
| `/version` | GET | Kubernetes version info |
| `/openapi/v2` | GET | OpenAPI spec (Swagger) |
| `/apis` | GET | List all API groups |
| `/api` | GET | List core API versions |

```bash
# Health check
curl -k https://localhost:6443/healthz
# ok

# Version
curl -k https://localhost:6443/version
# {"major":"1","minor":"33","gitVersion":"v1.33.0",...}

# API discovery
curl -k https://localhost:6443/apis
# {"kind":"APIGroupList","groups":[...]}
```

## Cài đặt kube-apiserver binary

```bash
K8S_VERSION="v1.33.0"
curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kube-apiserver" \
  -o /usr/local/bin/kube-apiserver
sudo chmod +x /usr/local/bin/kube-apiserver

# Kiểm tra
kube-apiserver --version
# Kubernetes v1.33.0
```

## Cài kubectl

```bash
K8S_VERSION="v1.33.0"
curl -fsSL "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl
sudo chmod +x /usr/local/bin/kubectl

# Kiểm tra
kubectl version --client
# Client Version: v1.33.0
```

## Liên hệ với Kubernetes

- API Server là **stateless** — có thể chạy nhiều instance song song, load balancer phân phối.
- API Server là **firewall** — enforce authentication, authorization, admission, schema validation.
- API Server là **client duy nhất** ghi etcd — không ai bypass được.
- API Server **proxy watch** — controller/kubelet watch qua API Server, API Server forward đến etcd.
- Mất tất cả API Server → cluster "freeze" (pod vẫn chạy, nhưng không tạo/sửa/xóa được).
- API Server **latency** phụ thuộc etcd — etcd chậm → API Server chậm → kubectl chậm.
- `--authorization-mode` quyết định policy model — production dùng `Node,RBAC`.
- `--enable-admission-plugins` quyết định admission pipeline — thêm webhook cho policy enforcement.
