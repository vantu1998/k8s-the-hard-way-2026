# Exercise 01 — Static Pod

> **Mục tiêu**: Tạo pod manifest YAML, đặt vào `/etc/kubernetes/manifests/`, quan sát kubelet chạy static pod. Xóa manifest, quan sát pod bị xóa.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), SSH access vào worker node, `sudo` privilege

## Bối cảnh

Static pod do kubelet quản lý trực tiếp từ file manifest trên disk. Bài này tạo manifest, đặt vào manifest dir, quan sát kubelet chạy pod. Xóa manifest, quan sát pod bị xóa.

## Prerequisites

```bash
# SSH vào worker node
ssh worker-1

# Check kubelet running
sudo systemctl status kubelet
# Active: active (running)

# Check static pod path
cat /var/lib/kubelet/config.yaml | grep staticPodPath
# staticPodPath: /etc/kubernetes/manifests

# Check manifest dir
ls /etc/kubernetes/manifests/
# (kubeadm cluster: kube-apiserver.yaml, kube-controller-manager.yaml, ...)
```

**Kiểm tra**: Kubelet running, `staticPodPath: /etc/kubernetes/manifests`.

## Bước 1: Tạo static pod manifest

```bash
# SSH vào worker-1
ssh worker-1

# Tạo static pod manifest
sudo cat <<'EOF' > /etc/kubernetes/manifests/my-static-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-static-pod
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    ports:
    - containerPort: 80
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
EOF
```

## Bước 2: Quan sát kubelet chạy static pod

```bash
# Trên worker-1 — check kubelet log
sudo journalctl -u kubelet -f --no-pager | grep "static pod"
# ... "Sync static pod" pod="my-static-pod"
# ... "Creating pod" pod="my-static-pod"

# Kubelet detect file trong manifest dir (inotify) → syncPod → create container
```

```bash
# Trên master — verify mirror pod created
kubectl get pod -A | grep my-static-pod
# NAMESPACE     NAME                    READY   STATUS    NODE
# default       my-static-pod-worker-1  1/1     Running   worker-1

# Check annotation — config.source: file = static pod
kubectl get pod my-static-pod-worker-1 -o yaml | grep -A 3 annotations
# annotations:
#   kubernetes.io/config.mirror: "worker-1"
#   kubernetes.io/config.source: "file"
#   kubernetes.io/config.hash: "abc123"
```

> Kubelet tạo **mirror pod** trong API Server. `config.source: file` = static pod. Pod name = `my-static-pod-worker-1` (manifest name + node name).

**Kiểm tra**: Static pod `my-static-pod-worker-1` Running, annotation `config.source: file`.

## Bước 3: Verify không thể delete qua kubectl

```bash
# Trên master — try delete mirror pod
kubectl delete pod my-static-pod-worker-1
# pod "my-static-pod-worker-1" deleted

# Check again — kubelet tạo lại ngay
kubectl get pod | grep my-static-pod
# my-static-pod-worker-1   1/1   Running   10s   ← tạo lại!
```

> Mirror pod deleted → kubelet detect mirror missing → tạo lại ngay. **Không thể delete static pod qua kubectl** — phải xóa file manifest.

**Kiểm tra**: Pod bị xóa nhưng kubelet tạo lại ngay.

## Bước 4: Update static pod manifest

```bash
# Trên worker-1 — update manifest (change image)
sudo sed -i 's/nginx:1.25/nginx:1.26/' /etc/kubernetes/manifests/my-static-pod.yaml

# Kubelet detect file change → recreate container
sudo journalctl -u kubelet --no-pager | tail -5
# ... "Sync static pod" pod="my-static-pod"
# ... "Killing container" container="nginx"
# ... "Creating container" container="nginx"
```

```bash
# Trên master — verify new image
kubectl get pod my-static-pod-worker-1 -o jsonpath='{.spec.containers[0].image}'
# nginx:1.26
```

> Kubelet watch manifest dir (inotify) → detect file change → recreate container. **No rolling update** — kill old + create new (downtime ngắn).

**Kiểm tra**: Pod chạy `nginx:1.26` sau khi update manifest.

## Bước 5: Xóa static pod — remove manifest

```bash
# Trên worker-1 — remove manifest file
sudo rm /etc/kubernetes/manifests/my-static-pod.yaml

# Kubelet detect file deleted → delete container + mirror pod
sudo journalctl -u kubelet --no-pager | tail -5
# ... "Killing container" pod="my-static-pod"
# ... "StopPodSandbox" pod="my-static-pod"
```

```bash
# Trên master — verify pod deleted
kubectl get pod | grep my-static-pod
# (empty — pod gone, no recreate)
```

> Xóa file manifest → kubelet delete container + mirror pod. **Không tạo lại** vì manifest không còn.

**Kiểm tra**: Pod bị xóa hoàn toàn, không tạo lại.

## Bước 6: Quan sát control plane static pod

```bash
# Trên master — list control plane static pod
kubectl get pod -n kube-system -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.kubernetes\.io/config\.source}{"\n"}{end}' | grep file
# etcd-master                      file
# kube-apiserver-master            file
# kube-controller-manager-master   file
# kube-scheduler-master            file

# Check manifest on disk
ls /etc/kubernetes/manifests/
# etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml
```

> Control plane (kubeadm) chạy as static pod. Kubelet quản lý — nếu API Server crash, kubelet restart nó từ manifest.

**Kiểm tra**: 4 control plane component là static pod (`config.source: file`).

## Cleanup

```bash
# Đảm bảo manifest đã xóa
ssh worker-1 'sudo rm -f /etc/kubernetes/manifests/my-static-pod.yaml'
```

## Câu hỏi tự kiểm tra

1. Static pod khác regular pod thế nào? Ai quản lý?
2. Tại sao `kubectl delete pod` không xóa được static pod?
3. Control plane chạy as static pod — tại sao không chạy as Deployment?
4. Update static pod manifest — có rolling update không? Downtime?
5. `config.source: file` annotation có ý nghĩa gì?

## Đáp án tham khảo

1. Static pod do **kubelet quản lý** từ file manifest trên disk (`/etc/kubernetes/manifests/`). Regular pod do API Server + Controller quản lý. Static pod không thể scale/update/delete qua kubectl — chỉ sửa/xóa file manifest.
2. `kubectl delete pod` xóa **mirror pod** trong API Server. Kubelet detect mirror missing → tạo lại ngay từ file manifest. Phải **xóa file manifest** trên disk → kubelet mới delete container + mirror pod.
3. **Chicken-and-egg**: API Server cần etcd, etcd cần API Server. Kubelet chạy first (không cần API Server) → đọc manifest dir → chạy control plane. Nếu control plane crash → kubelet restart từ manifest. Deployment cần API Server — nếu API Server down, không thể restart Deployment.
4. **Không rolling update** — kubelet kill old container + create new container ngay. Downtime ngắn (vài giây). Không có maxSurge/maxUnavailable. Static pod phù hợp cho control plane (HA qua multiple master), không phù hợp cho user workload.
5. `config.source: file` = static pod (manifest từ file). `config.source: api` = regular pod (từ API Server). Kubelet dùng annotation này để distinguish. Mirror pod có `config.mirror: <node>` = node chạy static pod.
