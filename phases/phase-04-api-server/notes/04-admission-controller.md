# 04 — Admission Controller

## Admission Controller là gì

Admission Controller chạy **sau** Authorization, **trước** khi ghi vào etcd. Có 2 loại:

- **Mutating**: Sửa request trước khi lưu — thêm default, inject sidecar, modify spec.
- **Validating**: Kiểm tra request — reject nếu không hợp lệ, không sửa gì.

```
Authentication → Authorization → Mutating Admission → Validation → etcd
                                      │                   │
                                      ▼                   ▼
                                 Sửa request         Kiểm tra request
                                 (add defaults)      (reject if invalid)
```

> **Tại sao Mutating trước Validating?** Mutating có thể sửa request (add default, inject sidecar). Validating kiểm tra **final result** — sau khi tất cả mutation đã apply. Nếu Validating trước, mutation sau có thể vi phạm rule mà Validating đã pass.

## Admission flow chi tiết

```
Request (create pod)
       │
       ▼
  Authentication (who?)
       │
       ▼
  Authorization (allowed?)
       │
       ▼
  ┌─── Mutating Admission (phase 1) ───┐
  │  Plugin 1: ServiceAccount          → add default SA, mount token
  │  Plugin 2: DefaultStorageClass     → add default StorageClass
  │  Plugin 3: DefaultTolerationSeconds → add default toleration
  │  Plugin 4: MutatingAdmissionWebhook → call external webhook (inject sidecar)
  │  Plugin 5: ... (thứ tự trong flag)  → mutate
  └────────────────────────────────────┘
       │ (request đã được mutate)
       ▼
  ┌─── Validating Admission (phase 2) ─┐
  │  Plugin 1: NamespaceLifecycle       → reject if namespace deleting
  │  Plugin 2: ResourceQuota            → reject if over quota
  │  Plugin 3: ValidatingAdmissionWebhook → call external webhook (check policy)
  │  Plugin 4: ... (thứ tự trong flag)  → validate
  └────────────────────────────────────┘
       │
       ▼
  etcd (ghi object)
       │
       ▼
  Watch event → Controller/Kubelet react
```

## Built-in admission plugins

### Mutating plugins

| Plugin | Ý nghĩa |
|--------|---------|
| `ServiceAccount` | Add default ServiceAccount nếu không chỉ định. Mount SA token volume tự động. |
| `DefaultStorageClass` | Add `storageClassName: <default>` vào PVC nếu không chỉ định. |
| `DefaultTolerationSeconds` | Add default toleration cho `not-ready` và `unreachable` taint. |
| `DefaultIngressClass` | Add default IngressClass nếu không chỉ định. |
| `MutatingAdmissionWebhook` | Gọi external mutating webhook (sidecar injection, OPA, Kyverno). |
| `NamespaceLifecycle` | Block tạo resource trong namespace không tồn tại hoặc đang xóa. |
| `TaintNodesByCondition` | Auto-taint node theo condition (NotReady, DiskPressure...). |
| `PodSecurity` | Replace PodSecurityPolicy — enforce Pod Security Standards. |

### Validating plugins

| Plugin | Ý nghĩa |
|--------|---------|
| `NamespaceLifecycle` | Block tạo resource trong namespace đang xóa. Block xóa namespace còn resource. |
| `ResourceQuota` | Enforce quota — reject create nếu vượt limit (CPU, memory, pod count, PVC...). |
| `LimitRanger` | Enforce resource limit per container/pod — reject nếu vượt LimitRange. |
| `NodeRestriction` | Kubelet chỉ modify node/pod của chính nó. |
| `ValidatingAdmissionWebhook` | Gọi external validating webhook (policy enforcement, OPA Gatekeeper). |
| `PodSecurity` | Enforce Pod Security Standards (privileged, baseline, restricted). |
| `CertificateApproval` | Validate CSR approval request. |
| `CertificateSigning` | Validate CSR signing request. |

### Cấu hình

```bash
--enable-admission-plugins=NodeRestriction,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota,NamespaceLifecycle \
--disable-admission-plugins=PodSecurity \
```

> `--enable-admission-plugins` chỉ định plugin **thêm vào** default set. `--disable-admission-plugins` chỉ định plugin **loại bỏ** khỏi default set.

### Default admission plugins (v1.33)

kubeadm enable các plugin sau mặc định:

```
NodeRestriction,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,
MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota,NamespaceLifecycle
```

> Kiểm tra plugin đang enable: `kubectl get pod -n kube-system kube-apiserver-<node> -o yaml | grep enable-admission-plugins`

## Pod Security Standards (PSS)

Pod Security Standards thay thế PodSecurityPolicy (PSP — deprecated v1.21, removed v1.25):

| Level | Ý nghĩa |
|-------|---------|
| `privileged` | Không restrict — privileged container, hostPath, hostNetwork... |
| `baseline` | Prevent escalation — không privileged, không hostPath, không hostNetwork |
| `restricted` | Strict hardening — require runAsNonRoot, drop ALL capabilities, readOnlyRootFilesystem |

### Cấu hình PSS qua namespace label

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
```

| Label | Ý nghĩa |
|-------|---------|
| `enforce` | Reject pod không tuân thủ |
| `audit` | Log audit event nếu pod không tuân thủ (không reject) |
| `warn` | Show warning cho user nếu pod không tuân thủ (không reject) |

> PSS enforce qua namespace label — không cần Admission webhook. Built-in `PodSecurity` admission plugin đọc label và enforce.

## Admission Webhook

Admission webhook cho phép **external service** tham gia admission pipeline. Có 2 loại:

- **MutatingWebhookConfiguration**: Webhook sửa request (inject sidecar, add label).
- **ValidatingWebhookConfiguration**: Webhook validate request (enforce policy, check compliance).

### Cách hoạt động

```
API Server nhận request (create pod)
       │
       ▼
  MutatingAdmissionWebhook plugin
       │
       ├── POST AdmissionReview → Webhook service (sidecar injector)
       │                          ├── Parse request
       │                          ├── Modify pod spec (add sidecar container)
       │                          └── Return AdmissionResponse {allowed: true, patch: <json-patch>}
       │
       ▼
  API Server apply patch → request đã mutate
       │
       ▼
  ValidatingAdmissionWebhook plugin
       │
       ├── POST AdmissionReview → Webhook service (policy checker)
       │                          ├── Parse request
       │                          ├── Check policy (e.g. must have label)
       │                          └── Return AdmissionResponse {allowed: false, message: "missing label"}
       │
       ▼
  If allowed → etcd
  If denied → 403 Forbidden to client
```

### AdmissionReview request

API Server gửi `AdmissionReview` đến webhook:

```json
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "request": {
    "uid": "abc-123",
    "kind": {"group": "", "version": "v1", "kind": "Pod"},
    "resource": {"group": "", "version": "v1", "resource": "pods"},
    "name": "nginx",
    "namespace": "default",
    "operation": "CREATE",
    "userInfo": {"username": "alice", "groups": ["dev"]},
    "object": { /* full Pod object */ },
    "oldObject": null,
    "dryRun": false,
    "options": { /* CreateOptions, UpdateOptions... */ }
  }
}
```

### AdmissionReview response

Webhook trả về `AdmissionReview` response:

```json
// Validating — allow
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "abc-123",
    "allowed": true
  }
}

// Validating — deny
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "abc-123",
    "allowed": false,
    "status": {
      "message": "Pod must have label 'app'"
    }
  }
}

// Mutating — allow + patch
{
  "apiVersion": "admission.k8s.io/v1",
  "kind": "AdmissionReview",
  "response": {
    "uid": "abc-123",
    "allowed": true,
    "patchType": "JSONPatch",
    "patch": "W3sib3AiOiJhZGQiLCJwYXRoIjoiL3NwZWMvY29udGFpbmVycy8tIiwidmFsdWUiOnsibmFtZSI6InNpZGVjYXIiLCJpbWFnZSI6InByb3h5In19XQ=="
  }
}
```

> `patch` là base64-encoded JSON Patch (RFC 6902). API Server apply patch vào object trước khi lưu.

### MutatingWebhookConfiguration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: sidecar-injector
webhooks:
- name: sidecar.injector.example.com
  clientConfig:
    service:
      name: sidecar-injector
      namespace: kube-system
      path: /mutate
    caBundle: <base64-ca-cert>
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["pods"]
  failurePolicy: Fail
  sideEffects: None
  admissionReviewVersions: ["v1"]
```

| Field | Ý nghĩa |
|-------|---------|
| `clientConfig.service` | Webhook service — API Server gọi qua Service ClusterIP |
| `clientConfig.caBundle` | CA cert để verify webhook server cert |
| `rules` | Khi nào gọi webhook — apiGroup, operation, resource |
| `failurePolicy` | `Fail` (reject request nếu webhook down) hoặc `Ignore` (skip webhook nếu down) |
| `sideEffects` | `None` (webhook không side effect) hoặc `NoneOnDryRun` |
| `admissionReviewVersions` | API version webhook support (`v1`) |

### ValidatingWebhookConfiguration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: label-policy
webhooks:
- name: label.policy.example.com
  clientConfig:
    service:
      name: admission-webhook
      namespace: kube-system
      path: /validate
    caBundle: <base64-ca-cert>
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
  failurePolicy: Fail
  sideEffects: None
  admissionReviewVersions: ["v1"]
```

## Popular admission webhook tools

| Tool | Type | Ý nghĩa |
|------|------|---------|
| **OPA Gatekeeper** | Validating | Policy engine — enforce policy viết bằng Rego |
| **Kyverno** | Mutating + Validating | Policy engine — policy viết bằng YAML (K8s native) |
| **cert-manager** | Mutating | Inject CA cert vào pod (trust-manager) |
| **Istio** | Mutating | Inject Envoy sidecar vào pod |
| **Linkerd** | Mutating | Inject Linkerd proxy sidecar |
| **Vault Agent** | Mutating | Inject Vault secret vào pod |
| **Cloud Provider** | Mutating + Validating | Cloud-specific admission (GKE, EKS, AKS) |

## failurePolicy — quan trọng

| `failurePolicy` | Webhook down | Ý nghĩa |
|-----------------|-------------|---------|
| `Fail` | Request bị reject | Strict — webhook phải available. Good cho security policy. |
| `Ignore` | Request tiếp tục | Relaxed — webhook down không block. Good cho non-critical mutation. |

> **Production**: Security policy webhook → `Fail` (block if webhook down). Sidecar injection → `Ignore` (don't block if injector down). Nếu sidecar injector `Fail` và service down → không tạo pod được → cluster down.

## Timeout

```yaml
webhooks:
- name: ...
  timeoutSeconds: 10    # default 10s, max 30s
```

> Nếu webhook không trả lời trong `timeoutSeconds` → apply `failurePolicy`. Default 10s — đủ cho hầu hết webhook.

## Namespace selector

```yaml
webhooks:
- name: ...
  namespaceSelector:
    matchLabels:
      sidecar-injection: enabled
```

> Webhook chỉ gọi cho namespace có label `sidecar-injection=enabled`. Pod trong namespace không có label → webhook bị skip.

## Object selector

```yaml
webhooks:
- name: ...
  objectSelector:
    matchLabels:
      inject-sidecar: "true"
```

> Webhook chỉ gọi cho object có label `inject-sidecar=true`. Hữu ích khi chỉ inject sidecar cho pod cụ thể.

## Liên hệ với Kubernetes

- Admission chạy **sau** Authorization, **trước** etcd — last gate trước khi lưu.
- **Mutating trước Validating** — mutating sửa request, validating kiểm tra final result.
- Built-in plugin cover common case (ServiceAccount, default StorageClass, quota, namespace lifecycle).
- Webhook admission cho phép **external policy** — OPA Gatekeeper, Kyverno, sidecar injector.
- `failurePolicy: Fail` cho security policy, `Ignore` cho non-critical mutation.
- PSS (Pod Security Standards) thay thế PSP — enforce qua namespace label, không cần webhook.
- Admission webhook tăng request latency — mỗi webhook call thêm network round-trip.
- `MutatingAdmissionWebhook` và `ValidatingAdmissionWebhook` phải trong `--enable-admission-plugins` để webhook config có hiệu lực.
