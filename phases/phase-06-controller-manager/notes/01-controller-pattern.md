# 01 — Controller Pattern

## Controller là gì

Controller là component **watch** API resource và **reconcile** (đưa actual state về desired state). Đây là nguyên lý cốt lõi của Kubernetes — mọi thứ trong K8s đều là controller.

```
    Desired State (spec)          Actual State (status)
         │                              │
         └──────────┬───────────────────┘
                    │
              ┌─────▼─────┐
              │  Compare   │
              └─────┬──────┘
                    │
           Match?   │
           ├── YES → done (wait for next event)
           └── NO  → Act (create/delete/update resource)
                    │
              ┌─────▼─────┐
              │  Reconcile │ ← chạy lại từ đầu
              └────────────┘
```

> Controller **không event-driven** (edge-triggered) mà **level-triggered** — reconcile loop chạy liên tục, kiểm tra state hiện tại, không phụ thuộc event.

## Reconcile loop

```
reconcile():
    1. Read desired state (spec) from API Server
    2. Read actual state (status) from API Server
    3. Compare desired vs actual
    4. If match → return (nothing to do)
    5. If not match → act:
       - Create missing resource
       - Delete extra resource
       - Update existing resource
    6. Update status
    7. Go back to step 1 (or wait for next event)
```

### Ví dụ: ReplicaSet controller

```
ReplicaSet spec: replicas=3, selector=app=web

reconcile():
    1. Read RS: desired = 3 replicas
    2. List pods matching selector: found 2 pods
    3. Compare: 3 ≠ 2 → need 1 more pod
    4. Create 1 pod
    5. Update RS status: readyReplicas=2 (pod chưa ready)
    6. Wait → reconcile again → pod ready → readyReplicas=3
```

> Controller **không tạo 3 pod cùng lúc** — tạo từng cái, reconcile, tạo cái tiếp. Mỗi reconcile cycle chỉ tạo 1 pod (rate limited).

## Idempotent

Reconcile loop phải **idempotent** — chạy nhiều lần cho cùng state → kết quả giống nhau:

```
reconcile() lần 1: desired=3, actual=2 → create 1 pod → actual=3
reconcile() lần 2: desired=3, actual=3 → nothing to do
reconcile() lần 3: desired=3, actual=3 → nothing to do
```

> Nếu reconcile không idempotent (ví dụ: tạo pod mỗi lần chạy) → controller tạo pod liên tục → cluster overflow. Idempotent = an toàn khi retry.

## Level-triggered vs Edge-triggered

| | Level-triggered | Edge-triggered |
|---|---|---|
| **Logic** | Kiểm tra state hiện tại | React khi event xảy ra |
| **Missed event** | OK — state vẫn đúng | Bug — event mất = action mất |
| **Example** | "Có 3 pod không?" → tạo nếu thiếu | "Pod bị xóa" → tạo pod mới |
| **K8s** | ✅ Controller dùng level-triggered | ❌ Không dùng |

> Kubernetes **cố tình** chọn level-triggered. Nếu controller miss event (network glitch, restart), reconcile loop vẫn correct — kiểm tra state hiện tại, không phụ thuộc event đã nhận.

## Informer pattern

Controller không poll API Server liên tục. Thay vào đó dùng **Informer** — watch API resource và cache local:

```
API Server
    │
    ▼ Watch (long-poll HTTP)
Informer
    ├── List: fetch all resources once (cache init)
    ├── Watch: receive add/update/delete events
    ├── Local cache: in-memory store
    └── WorkQueue: enqueue resource key khi event arrive
         │
         ▼
    Reconcile loop: dequeue key → read from cache → reconcile
```

### Informer components

| Component | Chức năng |
|-----------|-----------|
| `Lister` | Đọc resource từ cache (không gọi API Server) |
| `Watcher` | Watch API Server, nhận event add/update/delete |
| `Store` | In-memory cache của resource |
| `WorkQueue` | Queue chứa resource key cần reconcile |
| `Handler` | Callback khi event arrive → enqueue key |

```go
// Pseudo-code (Go client-go)
informer := factory.Core().V1().Pods().Informer()
informer.AddEventHandler(
    cache.ResourceEventHandlerFuncs{
        AddFunc:    func(obj) { queue.Add(key(obj)) },
        UpdateFunc: func(old, new) { queue.Add(key(new)) },
        DeleteFunc: func(obj) { queue.Add(key(obj)) },
    },
)
informer.Run(stopCh)
```

> Informer giảm load API Server — controller đọc từ cache, chỉ gọi API Server khi cần. Watch là long-poll — API Server giữ connection, push event khi có thay đổi.

### SharedInformer

Nhiều controller có thể **share** cùng informer — giảm API Server load:

```
SharedInformerFactory
├── Pod Informer (shared by ReplicaSet, Deployment, Node controller...)
├── Node Informer (shared by Node, DaemonSet controller...)
└── Service Informer (shared by Endpoint, kube-proxy...)
```

> 1 Informer cho Pod → tất cả controller share. Thay vì 10 controller × 1 watch = 10 watch, chỉ cần 1 watch.

## Controller Manager

kube-controller-manager là process chạy **tất cả built-in controller**:

```
kube-controller-manager
├── Deployment controller
├── ReplicaSet controller
├── Node controller
├── Job controller
├── CronJob controller
├── Namespace controller
├── Service Account controller
├── Endpoint controller
├── DaemonSet controller
├── StatefulSet controller
├── Garbage Collector
├── Resource Quota controller
└── ... (20+ controllers)
```

### Static pod manifest (kubeadm)

```yaml
# /etc/kubernetes/manifests/kube-controller-manager.yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    component: kube-controller-manager
    tier: control-plane
  name: kube-controller-manager
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-controller-manager
    - --allocate-node-cidrs=true
    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
    - --bind-address=127.0.0.1
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --cluster-cidr=10.244.0.0/16
    - --cluster-name=k8s-lab
    - --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
    - --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
    - --kubeconfig=/etc/kubernetes/controller-manager.conf
    - --leader-elect=true
    - --node-cidr-mask-size=24
    - --root-ca-file=/etc/kubernetes/pki/ca.crt
    - --service-account-private-key-file=/etc/kubernetes/pki/sa.key
    - --service-cluster-ip-range=10.96.0.0/12
    - --use-service-account-credentials=true
    - --v=2
    image: registry.k8s.io/kube-controller-manager:v1.33.0
    name: kube-controller-manager
    livenessProbe:
      httpGet:
        path: /healthz
        port: 10257
        scheme: HTTPS
    volumeMounts:
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /etc/kubernetes/controller-manager.conf
      name: kubeconfig
      readOnly: true
  hostNetwork: true
  priorityClassName: system-node-critical
```

### Flags quan trọng

| Flag | Ý nghĩa |
|------|---------|
| `--kubeconfig` | Kubeconfig connect API Server |
| `--leader-elect` | Leader election (HA) |
| `--allocate-node-cidrs` | Controller Manager cấp podCIDR cho node |
| `--cluster-cidr` | CIDR range cho pod IP |
| `--node-cidr-mask-size` | Subnet mask cho mỗi node (default 24) |
| `--cluster-signing-cert-file` | CA cert để ký CSR (kubelet bootstrap) |
| `--cluster-signing-key-file` | CA key để ký CSR |
| `--service-account-private-key-file` | SA key để sign token |
| `--root-ca-file` | CA cert injected vào ServiceAccount |
| `--use-service-account-credentials` | Mỗi controller dùng SA riêng (RBAC isolation) |
| `--node-monitor-period` | Khoảng thời gian check node status (default 5s) |
| `--node-monitor-grace-period` | Timeout trước khi mark node NotReady (default 40s) |
| `--pod-eviction-timeout` | Timeout trước khi evict pod trên NotReady node (default 5m) |

### Leader election

Controller Manager chạy **1 instance active** (leader election qua lease):

```bash
kubectl get lease -n kube-system kube-controller-manager
# NAME                      HOLDER                              AGE
# kube-controller-manager   master_abc123def456                 10m
```

> Standby instance không reconcile — chỉ leader active. Nếu leader crash → standby trở thành leader (seconds).

## Controller chain — Deployment → ReplicaSet → Pod

```
User: kubectl apply deployment (replicas=3)
       │
       ▼
Deployment Controller (watch Deployment)
  ├── Create ReplicaSet (replicas=3)
  └── Update Deployment status
       │
       ▼
ReplicaSet Controller (watch ReplicaSet)
  ├── Create Pod-1
  ├── Create Pod-2
  └── Create Pod-3
       │
       ▼
Scheduler (watch Pending Pod)
  ├── Bind Pod-1 → node-1
  ├── Bind Pod-2 → node-2
  └── Bind Pod-3 → node-3
       │
       ▼
Kubelet (watch Pod assigned to node)
  ├── Create container for Pod-1
  ├── Create container for Pod-2
  └── Create container for Pod-3
```

> Mỗi controller **chỉ quan tâm resource của nó**. Deployment controller không tạo Pod — tạo ReplicaSet. ReplicaSet controller tạo Pod. **Separation of concerns**.

## Custom Controller (CRD + Operator)

Custom Resource Definition (CRD) + custom controller = **Operator pattern**:

```yaml
# CRD: định nghĩa resource mới
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.example.com
spec:
  group: example.com
  names:
    kind: Database
    plural: databases
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              image:
                type: string
              replicas:
                type: integer
```

```yaml
# Custom resource
apiVersion: example.com/v1
kind: Database
metadata:
  name: my-db
spec:
  image: postgres:16
  replicas: 3
```

> Custom controller watch `Database` resource, reconcile → tạo StatefulSet, Service, ConfigMap. Operator = controller quản lý ứng dụng cụ thể (PostgreSQL, Redis, Elasticsearch...).

## Liên hệ với Kubernetes

- Controller pattern = **watch + reconcile loop** — nguyên lý cốt lõi của Kubernetes.
- **Level-triggered** — kiểm tra state hiện tại, không phụ thuộc event. Miss event vẫn correct.
- **Idempotent** — chạy nhiều lần cho cùng state → kết quả giống nhau.
- **Informer** — cache + watch, giảm API Server load. SharedInformer cho nhiều controller.
- Controller Manager chạy **tất cả built-in controller** — 1 process, leader election.
- Controller chain: Deployment → ReplicaSet → Pod. Mỗi controller tạo resource cấp dưới.
- Operator pattern = CRD + custom controller — mở rộng Kubernetes cho ứng dụng cụ thể.
- Controller **không chạy pod** — chỉ tạo resource. Kubelet tạo container.
- `--pod-eviction-timeout` quyết định khi nào evict pod trên NotReady node.
