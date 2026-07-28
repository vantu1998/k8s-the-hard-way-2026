# 04 — Static Pods

## Static Pod là gì

Static Pod là pod do **kubelet quản lý trực tiếp** — đọc manifest YAML từ thư mục trên disk, chạy pod mà không qua API Server. API Server thấy static pod (read-only mirror) nhưng không quản lý.

```
/etc/kubernetes/manifests/
├── kube-apiserver.yaml      ← static pod manifest
├── kube-controller-manager.yaml
├── kube-scheduler.yaml
└── etcd.yaml

Kubelet watch /etc/kubernetes/manifests/ (inotify)
  ├── Detect new manifest → syncPod → create container
  ├── Detect manifest change → recreate container
  └── Detect manifest deleted → delete pod
```

> Static pod **không thể quản lý qua kubectl** — không delete, scale, update qua API Server. Chỉ sửa/xóa file manifest trên disk.

## Cách hoạt động

```
1. Kubelet start → watch --static-pod-path (/etc/kubernetes/manifests/)
2. Detect YAML manifest in directory
3. Parse manifest → Pod object
4. syncPod → CRI create sandbox + container
5. Kubelet create **mirror pod** in API Server (read-only)
6. API Server see pod (but can't manage)
7. If manifest deleted → kubelet delete container + mirror pod
```

### Mirror pod

```bash
# Static pod trên node
kubectl get pod -n kube-system -o wide | grep master
# kube-apiserver-master      1/1   Running   master
# kube-controller-manager-master   1/1   Running   master
# kube-scheduler-master      1/1   Running   master
# etcd-master                1/1   Running   master

# Mirror pod — annotation chỉ ra node
kubectl get pod -n kube-system kube-apiserver-master -o yaml | grep -A 2 "mirror"
# annotations:
#   kubernetes.io/config.mirror: "master"
#   kubernetes.io/config.source: "file"
```

> Mirror pod = read-only copy trong API Server. `config.source: file` = static pod. `config.mirror: <node>` = node chạy static pod. **Không thể delete mirror pod** qua kubectl — kubelet tạo lại ngay.

### Static pod vs Regular pod

| | Static Pod | Regular Pod |
|---|---|---|
| **Managed by** | Kubelet (file on disk) | API Server + Controller |
| **Create** | Put YAML in manifest dir | kubectl apply |
| **Delete** | Remove YAML from dir | kubectl delete |
| **Update** | Edit YAML file | kubectl apply (rolling update) |
| **API Server** | Read-only mirror | Full management |
| **Scheduling** | Always on local node | Scheduler decides |
| **Use case** | Control plane components | User workload |

## Static pod manifest

```yaml
# /etc/kubernetes/manifests/my-static-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-static-pod
spec:
  containers:
  - name: nginx
    image: nginx
    ports:
    - containerPort: 80
```

> Static pod manifest **không có** `metadata.namespace` (mặc định = `kube-system` hoặc `default` tùy config). Không có `nodeName` (luôn chạy trên node local). Không có controller owner (không ReplicaSet/Deployment).

## Static pod naming

```
Pod name = <manifest-name>-<node-name>

Manifest: my-static-pod.yaml on node "worker-1"
→ Pod name: my-static-pod-worker-1
```

> Kubelet append node name vào pod name — đảm bảo unique nếu nhiều node chạy cùng static pod manifest.

## --static-pod-path

```bash
# Kubelet flag
--static-pod-path=/etc/kubernetes/manifests

# Hoặc trong config file
# /var/lib/kubelet/config.yaml
staticPodPath: /etc/kubernetes/manifests
```

```bash
# Verify path
ls /etc/kubernetes/manifests/
# kube-apiserver.yaml
# kube-controller-manager.yaml
# kube-scheduler.yaml
# etcd.yaml
```

> Kubelet watch thư mục bằng `inotify` — detect file create/modify/delete ngay (milliseconds). Không cần restart kubelet khi thêm/sửa manifest.

## Control plane as static pod

kubeadm chạy control plane component (apiserver, controller-manager, scheduler, etcd) as static pod:

```
/etc/kubernetes/manifests/
├── kube-apiserver.yaml          ← API Server
├── kube-controller-manager.yaml ← Controller Manager
├── kube-scheduler.yaml          ← Scheduler
└── etcd.yaml                    ← etcd
```

### Tại sao static pod cho control plane?

```
Chicken-and-egg problem:
  - API Server cần etcd để chạy
  - etcd cần API Server để được manage
  - Controller Manager cần API Server

Solution:
  - Kubelet chạy TRƯỚC, không cần API Server
  - Kubelet đọc manifest dir → chạy control plane as static pod
  - Control plane start → API Server available
  - Kubelet register node → cluster ready
```

> Kubelet là **first component** — chạy mà không cần API Server. Kubelet đọc manifest dir, chạy control plane as static pod. Control plane start → API Server available → kubelet register node.

### kube-apiserver static pod manifest

```yaml
# /etc/kubernetes/manifests/kube-apiserver.yaml
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
    - --advertise-address=192.168.1.10
    - --etcd-servers=https://127.0.0.1:2379
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    # ... (many flags)
    image: registry.k8s.io/kube-apiserver:v1.33.0
    name: kube-apiserver
    volumeMounts:
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /etc/kubernetes
      name: k8s-conf
      readOnly: true
  hostNetwork: true
  priorityClassName: system-node-critical
  volumes:
  - hostPath:
      path: /etc/kubernetes/pki
      type: DirectoryOrCreate
    name: k8s-certs
  - hostPath:
      path: /etc/kubernetes
      type: DirectoryOrCreate
    name: k8s-conf
```

> Static pod dùng `hostNetwork: true` — dùng network của node (không qua pod network). `hostPath` volume — mount cert/config từ node filesystem. `priorityClassName: system-node-critical` — priority cao nhất, không bị preempt.

## Static pod use cases

### 1. Control plane (kubeadm)

```
/etc/kubernetes/manifests/kube-apiserver.yaml
/etc/kubernetes/manifests/kube-controller-manager.yaml
/etc/kubernetes/manifests/kube-scheduler.yaml
/etc/kubernetes/manifests/etcd.yaml
```

> Default cho kubeadm cluster. Control plane chạy as static pod — kubelet quản lý.

### 2. Bootstrap component

```
/etc/kubernetes/manifests/nginx-ingress.yaml   ← Ingress controller before CNI ready
/etc/kubernetes/manifests/kube-proxy.yaml       ← kube-proxy (if not DaemonSet)
```

> Component cần chạy trước CNI/network ready — static pod không cần pod network (hostNetwork).

### 3. Monitoring agent

```
/etc/kubernetes/manifests/node-exporter.yaml    ← Prometheus node exporter
```

> Agent chạy trên mỗi node, không cần API Server. Đặt manifest trong manifest dir → kubelet chạy.

## Static pod limitations

- **Không scale** — 1 manifest = 1 pod. Không thể replicas=3 (cần đặt manifest trên 3 node).
- **Không rolling update** — sửa manifest → kubelet recreate container ngay (downtime ngắn).
- **Không health check qua API** — mirror pod read-only, không update status qua API.
- **Không manage qua kubectl** — không delete/scale/update qua API Server.
- **Node-specific** — manifest trên node A không affect node B.

> Static pod phù hợp cho control plane + bootstrap. **Không dùng cho user workload** — dùng Deployment/DaemonSet thay thế.

## Debugging static pod

```bash
# List static pod
kubectl get pod -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.kubernetes\.io/config\.source}{"\n"}{end}' | grep file
# kube-apiserver-master       file
# kube-controller-manager-master   file
# kube-scheduler-master       file
# etcd-master                 file

# Check manifest on disk
ls /etc/kubernetes/manifests/

# Kubelet log
journalctl -u kubelet | grep "static pod"
# "Sync static pod" pod="kube-apiserver-master"

# Delete static pod (must remove manifest)
sudo rm /etc/kubernetes/manifests/my-static-pod.yaml
# Kubelet detect file deleted → delete container + mirror pod
```

> **Không `kubectl delete pod`** — mirror pod sẽ tạo lại ngay. Phải xóa file manifest trên disk.

## Liên hệ với Kubernetes

- Static pod = kubelet quản lý trực tiếp từ file manifest trên disk, không qua API Server.
- Mirror pod = read-only copy trong API Server — `config.source: file`.
- **Không thể delete/scale/update** qua kubectl — chỉ sửa/xóa file manifest.
- Control plane (kubeadm) chạy as static pod — kubelet là first component, chạy mà không cần API Server.
- `--static-pod-path=/etc/kubernetes/manifests` — kubelet watch dir bằng inotify.
- Static pod dùng `hostNetwork: true` + `hostPath` volume — chạy trước pod network ready.
- Pod name = `<manifest-name>-<node-name>` — unique across nodes.
- **Không dùng cho user workload** — dùng Deployment/DaemonSet. Static pod cho control plane + bootstrap only.
- `kubectl delete pod` mirror → kubelet tạo lại ngay. Phải xóa file manifest.
