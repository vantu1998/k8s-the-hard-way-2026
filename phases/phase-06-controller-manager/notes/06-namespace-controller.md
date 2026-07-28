# 06 — Namespace Controller

## Namespace Controller là gì

Namespace Controller quản lý **namespace lifecycle** — khi namespace bị delete, controller xóa tất cả resource trong namespace trước, rồi xóa namespace.

```
kubectl delete namespace dev
       │
       ▼
Namespace Controller
  ├── Set finalizer: kubernetes
  ├── List ALL resources in namespace "dev"
  ├── Delete từng resource (Pod, Service, Deployment, ConfigMap...)
  ├── Đợi tất cả resource bị xóa
  └── Remove finalizer → Namespace deleted
```

> Namespace deletion **không tức thời** — controller xóa resource trước, rồi xóa namespace. Có thể mất nhiều phút nếu resource nhiều.

## Finalizer pattern

Finalizer là cơ chế **chặn deletion** cho đến khi cleanup xong:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev
  finalizers:
  - kubernetes    # Namespace controller finalizer
```

### Deletion with finalizer

```
1. kubectl delete namespace dev
2. API Server set deletionTimestamp → object "terminating"
3. API Server KHÔNG xóa object (finalizer còn)
4. Namespace Controller detect "terminating"
5. Controller xóa tất cả resource trong namespace
6. Controller remove finalizer: kubernetes
7. API Server xóa namespace (no finalizer → delete)
```

> Finalizer = "chờ tôi cleanup trước khi xóa". Object có finalizer → không bị xóa khỏi etcd cho đến khi finalizer removed.

### Custom finalizer

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-1
  finalizers:
  - kubernetes.io/pv-protection    # PVC protection
  - external-attacher/example-com  # Custom finalizer
```

```bash
# PV có finalizer → không xóa được
kubectl delete pv pv-1
# persistentvolume "pv-1" deleted (but stuck in Terminating)

# Xóa finalizer manually (dangerous!)
kubectl patch pv pv-1 --type=merge -p '{"metadata":{"finalizers":[]}}'
# → PV deleted
```

> **Không xóa finalizer manually** trừ khi biết chắc resource đã cleanup. Xóa finalizer = bỏ chặn → object bị xóa ngay, có thể orphan external resource.

## Deletion ordering

Namespace controller xóa resource theo **thứ tự** để tránh race condition:

```
1. Discovery: list tất cả API resource types
2. Delete resource theo thứ tự:
   a. Custom Resource Definitions (CRD) — xóa CR trước
   b. Workloads: Deployment, ReplicaSet, StatefulSet, DaemonSet, Job, CronJob
   c. Pod (xóa pod trực tiếp nếu không thuộc controller)
   d. Service, Endpoints, EndpointSlice
   e. ConfigMap, Secret
   f. PersistentVolumeClaim, PersistentVolume
   g. RoleBinding, ClusterRoleBinding (namespace-scoped)
   h. NetworkPolicy, Ingress
   i. ServiceAccount
   j. ResourceQuota, LimitRange
   k. Events
3. Đợi tất cả resource xóa xong
4. Remove finalizer → Namespace deleted
```

> Thứ tự quan trọng: xóa workload trước (Deployment → ReplicaSet → Pod), rồi xóa Service/ConfigMap. Nếu xóa Service trước → pod vẫn chạy nhưng không có Service. Nếu xóa ConfigMap trước → pod restart fail.

## Resource discovery

Namespace controller không hardcode resource types. Thay vào đó, dùng **API discovery** để tìm tất cả resource types:

```bash
# API discovery — list tất cả resource types
kubectl api-resources --verbs=list --namespaced -o name | sort
# configmaps
# endpoints
# events
# persistentvolumeclaims
# pods
# replicasets.apps
# secrets
# services
# ...
```

> Controller gọi `GET /apis` → list tất cả API groups → `GET /apis/<group>/<version>` → list resource types. Tự động discover CRD — xóa custom resource trong namespace.

## Stuck namespace — troubleshooting

Namespace stuck `Terminating` — thường do finalizer không remove được:

```bash
kubectl get namespace dev
# NAME   STATUS        AGE
# dev    Terminating   10m
```

### Nguyên nhân phổ biến

| Nguyên nhân | Cách fix |
|-------------|----------|
| Resource trong namespace không xóa được (finalizer của resource) | Xóa finalizer của resource stuck |
| API server không reach được external webhook (validating/mutating) | Disable webhook hoặc fix webhook |
| CRD đã xóa nhưng CR còn (orphan) | Recreate CRD, xóa CR, xóa CRD lại |
| ResourceQuota block deletion | Xóa ResourceQuota manually |

### Debug stuck namespace

```bash
# 1. Check namespace status
kubectl get namespace dev -o yaml
# status: { phase: Terminating }
# metadata: { finalizers: [kubernetes] }

# 2. List resource còn trong namespace
kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get -n dev --ignore-not-found

# 3. Tìm resource có finalizer
kubectl get all -n dev -o jsonpath='{range .items[*]}{.kind}{"/"}{.metadata.name}{"\t"}{.metadata.finalizers}{"\n"}{end}'

# 4. Xóa finalizer của resource stuck (last resort)
kubectl patch <resource-type> <name> -n dev --type=merge -p '{"metadata":{"finalizers":[]}}'

# 5. Nếu namespace vẫn stuck — force delete finalizer (DANGEROUS)
kubectl patch namespace dev --type=merge -p '{"metadata":{"finalizers":[]}}'
```

> **Force delete namespace finalizer** = xóa namespace ngay, resource bên trong có thể orphan (pod vẫn chạy nhưng không có namespace). Last resort only.

## Resource Quota controller

ResourceQuota controller (cũng trong Controller Manager) enforce **resource limit** per namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-dev
  namespace: dev
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    persistentvolumeclaims: "10"
    requests.storage: 100Gi
    pods: "50"
    services: "20"
    configmaps: "100"
    secrets: "50"
```

### How quota works

```
1. Pod create request → API Server → Admission (ResourceQuota admission plugin)
2. Quota controller check: tổng request trong namespace + pod mới ≤ hard limit?
3. If OK → admit, update quota status (used)
4. If exceed → reject: "pods is forbidden: exceeded quota"
```

```bash
kubectl get resourcequota -n dev
# NAME        CREATED   REQUESTS                                    LIMITS
# quota-dev   5m        cpu: 5000m/10000m, memory: 10Gi/20Gi        cpu: 8000m/20000m, memory: 15Gi/40Gi
```

> ResourceQuota admission plugin chạy trong **API Server** (not controller), nhưng quota status update bởi **ResourceQuota controller**. Controller đếm resource used định kỳ.

### LimitRange — per-resource limit

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: limits-dev
  namespace: dev
spec:
  limits:
  - type: Container
    default:           # Default limit (if not specified)
      cpu: 500m
      memory: 512Mi
    defaultRequest:    # Default request (if not specified)
      cpu: 100m
      memory: 128Mi
    max:               # Max limit
      cpu: 2000m
      memory: 2Gi
    min:               # Min request
      cpu: 50m
      memory: 64Mi
```

> LimitRange set **default** request/limit cho container không chỉ định. Cũng enforce min/max — container không được set limit vượt max hoặc request dưới min.

## Default namespace

```bash
kubectl get namespace
# NAME              STATUS   AGE
# default           Active   10d
# kube-system       Active   10d
# kube-public       Active   10d
# kube-node-lease   Active   10d
```

| Namespace | Mục đích |
|-----------|----------|
| `default` | Namespace mặc định cho user resource (nếu không chỉ định) |
| `kube-system` | System component (apiserver, controller-manager, scheduler, CNI, DNS...) |
| `kube-public` | Public resource — configmap `cluster-info` (kubeadm bootstrap info) |
| `kube-node-lease` | Node lease object (heartbeat) — tách riêng để giảm etcd load |

> `kube-node-lease` tách khỏi `kube-system` vì lease update rất thường xuyên (10s) — tách ra để không ảnh hưởng etcd compaction của namespace khác.

## Liên hệ với Kubernetes

- Namespace Controller xóa **tất cả resource** trong namespace trước, rồi xóa namespace.
- **Finalizer** chặn deletion cho đến khi cleanup xong — object có finalizer không bị xóa khỏi etcd.
- Deletion theo **thứ tự** — workload trước, Service/ConfigMap sau. Tránh race condition.
- Resource discovery qua API — controller tự discover CRD, xóa custom resource.
- Namespace stuck `Terminating` = finalizer không remove được — debug resource stuck.
- **Không xóa finalizer manually** trừ khi biết chắc đã cleanup — có thể orphan external resource.
- ResourceQuota controller enforce per-namespace limit — admission plugin reject nếu exceed.
- LimitRange set default request/limit + enforce min/max per container.
- `kube-node-lease` tách riêng — lease update thường xuyên, giảm etcd load cho namespace khác.
