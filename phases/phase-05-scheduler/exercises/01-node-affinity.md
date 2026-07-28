# Exercise 01 — Node Affinity

> **Mục tiêu**: Tạo 3 node với label khác nhau (`zone=a`, `zone=b`, `zone=c`), deploy pod với `nodeAffinity` preferred, quan sát distribution.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), ít nhất 3 worker node

## Bối cảnh

Node affinity cho phép control pod chạy trên node nào dựa trên node label. Bài này lab với 3 node khác zone, deploy pod preferred zone=a, quan sát scheduler decision.

## Prerequisites

### Cluster có ít nhất 3 worker node

```bash
kubectl get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# master    Ready     control-plane   10d   v1.33.0
# worker-1  Ready     <none>          10d   v1.33.0
# worker-2  Ready     <none>          10d   v1.33.0
# worker-3  Ready     <none>          10d   v1.33.0
```

> Nếu chỉ có 1 node (minikube), dùng `kubectl scale` hoặc tạo thêm node. Bài này cần 3 node để thấy distribution.

## Bước 1: Label node theo zone

```bash
# Label 3 worker node với zone khác nhau
kubectl label nodes worker-1 zone=a
kubectl label nodes worker-2 zone=b
kubectl label nodes worker-3 zone=c

# Verify
kubectl get nodes --show-labels | grep zone
# worker-1   Ready   <none>   10d   v1.33.0   ...,zone=a
# worker-2   Ready   <none>   10d   v1.33.0   ...,zone=b
# worker-3   Ready   <none>   10d   v1.33.0   ...,zone=c
```

**Kiểm tra**: 3 node đều có label `zone` với giá trị khác nhau.

## Bước 2: Deploy pod với nodeSelector (hard constraint)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-selector
  labels:
    app: nginx-selector
spec:
  nodeSelector:
    zone: a
  containers:
  - name: nginx
    image: nginx
EOF
```

```bash
# Verify pod chạy trên worker-1 (zone=a)
kubectl get pod nginx-selector -o wide
# NAME              READY   STATUS    RESTARTS   AGE   IP          NODE       ZONE
# nginx-selector    1/1     Running   0          10s   10.244.1.5  worker-1
```

**Kiểm tra**: Pod chạy trên `worker-1` (zone=a).

## Bước 3: Test nodeSelector fail — zone không tồn tại

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-fail
spec:
  nodeSelector:
    zone: x
  containers:
  - name: nginx
    image: nginx
EOF

# Pod Pending — không node nào có zone=x
kubectl get pod nginx-fail
# NAME         READY   STATUS    RESTARTS   AGE
# nginx-fail   0/1     Pending   0          5s

# Xem reason
kubectl describe pod nginx-fail | tail -5
# Events:
#   Warning  FailedScheduling  ...  0/4 nodes are available: 4 node(s) didn't match node selector.
```

```bash
# Cleanup
kubectl delete pod nginx-fail
```

**Kiểm tra**: Pod `Pending` với reason `didn't match node selector`.

## Bước 4: Deploy với nodeAffinity required — multiple values

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-required
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: zone
            operator: In
            values:
            - a
            - b
  containers:
  - name: nginx
    image: nginx
EOF
```

```bash
# Pod schedule lên worker-1 (zone=a) hoặc worker-2 (zone=b)
kubectl get pod nginx-required -o wide
# NAME             READY   STATUS    RESTARTS   AGE   IP          NODE
# nginx-required   1/1     Running   0          5s    10.244.1.6  worker-1
```

**Kiểm tra**: Pod chạy trên `worker-1` hoặc `worker-2` (zone=a hoặc zone=b), không trên `worker-3` (zone=c).

## Bước 5: Deploy với nodeAffinity preferred

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-preferred
spec:
  replicas: 6
  selector:
    matchLabels:
      app: nginx-preferred
  template:
    metadata:
      labels:
        app: nginx-preferred
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: zone
                operator: In
                values:
                - a
          - weight: 50
            preference:
              matchExpressions:
              - key: zone
                operator: In
                values:
                - b
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
# Đợi pod chạy
kubectl wait --for=condition=Ready pod -l app=nginx-preferred --timeout=60s

# Quan sát distribution
kubectl get pod -l app=nginx-preferred -o wide
# NAME                                 READY   STATUS    NODE
# nginx-preferred-xxx-aaa              1/1     Running   worker-1   ← zone=a (weight 100)
# nginx-preferred-xxx-bbb              1/1     Running   worker-1   ← zone=a
# nginx-preferred-xxx-ccc              1/1     Running   worker-1   ← zone=a
# nginx-preferred-xxx-ddd              1/1     Running   worker-2   ← zone=b (weight 50)
# nginx-preferred-xxx-eee              1/1     Running   worker-2   ← zone=b
# nginx-preferred-xxx-fff              1/1     Running   worker-3   ← zone=c (weight 0, fallback)
```

> Scheduler prefer zone=a (weight 100) → đa số pod lên worker-1. Zone=b (weight 50) → một số pod. Zone=c (weight 0) → fallback khi worker-1 và worker-2 đầy.

**Kiểm tra**: Đa số pod chạy trên `worker-1` (zone=a, weight cao nhất), một số trên `worker-2` (zone=b), ít/nếu cần trên `worker-3` (zone=c).

## Bước 6: Test operator Exists và DoesNotExist

```bash
# Thêm label disktype=ssd cho worker-1
kubectl label nodes worker-1 disktype=ssd

# Pod yêu cầu node có label disktype (Exists)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-exists
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: Exists
  containers:
  - name: nginx
    image: nginx
EOF

kubectl get pod nginx-exists -o wide
# NAME           READY   STATUS    NODE
# nginx-exists   1/1     Running   worker-1   ← chỉ worker-1 có label disktype
```

```bash
# Pod yêu cầu node KHÔNG có label disktype (DoesNotExist)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-not-exists
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: DoesNotExist
  containers:
  - name: nginx
    image: nginx
EOF

kubectl get pod nginx-not-exists -o wide
# NAME               READY   STATUS    NODE
# nginx-not-exists   1/1     Running   worker-2   ← worker-2 không có label disktype
```

**Kiểm tra**: `Exists` schedule lên node có label, `DoesNotExist` schedule lên node không có label.

## Bước 7: Quan sát scheduler decision

```bash
# Xem scheduler log (v=4 để thấy decision)
kubectl logs -n kube-system kube-scheduler-master --tail=50 | grep nginx-preferred

# Hoặc xem event
kubectl get events --sort-by='.lastTimestamp' | grep nginx-preferred
# ... Scheduled: Successfully assigned default/nginx-preferred-xxx to worker-1
# ... Scheduled: Successfully assigned default/nginx-preferred-yyy to worker-2
```

> Scheduler log hiển thị node nào được chọn cho pod nào. Xem exercise 05 để đọc log chi tiết hơn.

## Cleanup

```bash
kubectl delete deployment nginx-preferred
kubectl delete pod nginx-selector nginx-required nginx-exists nginx-not-exists
kubectl label nodes worker-1 zone- disktype-
kubectl label nodes worker-2 zone-
kubectl label nodes worker-3 zone-
```

## Câu hỏi tự kiểm tra

1. `nodeSelector` và `nodeAffinity required` khác nhau thế nào?
2. `preferredDuringScheduling` với weight=100 có đảm bảo pod luôn schedule lên node match không?
3. Nếu 3 node đều zone=a, pod có `nodeAffinity required zone In [a,b,c]`, pod schedule lên node nào?
4. `Exists` vs `DoesNotExist` — cho ví dụ use case?
5. Tại sao pod thứ 6 trong deployment preferred vẫn lên worker-3 (zone=c) dù weight=0?

## Đáp án tham khảo

1. `nodeSelector` chỉ hỗ trợ `=` (equal), AND logic. `nodeAffinity required` hỗ trợ operator `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`, AND trong term + OR giữa terms. `nodeAffinity` mạnh hơn nhưng phức tạp hơn.
2. Không — `preferred` là soft constraint. Scheduler ưu tiên node match (score cao hơn), nhưng nếu node đó đầy hoặc không feasible, pod vẫn schedule lên node khác.
3. Bất kỳ node nào — tất cả đều match `zone In [a,b,c]`. Scheduler chọn node có score cao nhất (thường là node ít utilized nhất).
4. `Exists`: pod cần node có GPU label (`accelerator Exists` → node có label accelerator). `DoesNotExist`: pod không chạy trên node có maintenance label (`maintenance DoesNotExist` → node không đang maintenance).
5. Weight=0 nghĩa là không có preference cho zone=c, nhưng zone=c vẫn pass Filter (preferred không cấm). Khi worker-1 (zone=a) và worker-2 (zone=b) đủ resource cho 5 pod, pod thứ 6 phải lên worker-3 vì 2 node kia đã đầy.
