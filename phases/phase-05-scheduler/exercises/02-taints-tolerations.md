# Exercise 02 — Taints & Tolerations

> **Mục tiêu**: Taint 1 node `NoSchedule`, deploy pod không có toleration, quan sát pod không schedule lên node đó. Thêm toleration, quan sát pod schedule được.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), ít nhất 2 worker node

## Bối cảnh

Taints đuổi pod ra khỏi node. Bài này taint 1 node, deploy pod, quan sát scheduler tránh node đó. Sau đó thêm toleration, quan sát pod schedule được.

## Prerequisites

```bash
kubectl get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# master    Ready     control-plane   10d   v1.33.0
# worker-1  Ready     <none>          10d   v1.33.0
# worker-2  Ready     <none>          10d   v1.33.0
```

## Bước 1: Taint worker-1 với NoSchedule

```bash
kubectl taint nodes worker-1 dedicated=gpu:NoSchedule
# node/worker-1 tainted

# Verify
kubectl describe node worker-1 | grep -i taint
# Taints:  dedicated=gpu:NoSchedule
```

**Kiểm tra**: Node `worker-1` có taint `dedicated=gpu:NoSchedule`.

## Bước 2: Deploy pod KHÔNG có toleration

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: no-toleration
spec:
  containers:
  - name: nginx
    image: nginx
EOF
```

```bash
# Pod schedule lên worker-2 (tránh worker-1 có taint)
kubectl get pod no-toleration -o wide
# NAME            READY   STATUS    RESTARTS   AGE   IP          NODE
# no-toleration   1/1     Running   0          5s    10.244.2.3  worker-2
```

> Scheduler tránh worker-1 vì pod không có toleration cho taint `dedicated=gpu:NoSchedule`.

**Kiểm tra**: Pod chạy trên `worker-2`, không trên `worker-1`.

## Bước 3: Deploy pod CÓ toleration

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: with-toleration
spec:
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "gpu"
    effect: "NoSchedule"
  containers:
  - name: nginx
    image: nginx
EOF
```

```bash
# Pod có thể schedule trên worker-1 (có toleration)
kubectl get pod with-toleration -o wide
# NAME             READY   STATUS    RESTARTS   AGE   IP          NODE
# with-toleration  1/1     Running   0          5s    10.244.1.3  worker-1
```

> Pod có toleration cho `dedicated=gpu:NoSchedule` → scheduler không tránh worker-1. Pod schedule lên worker-1 (hoặc worker-2, tùy score).

**Kiểm tra**: Pod chạy được trên `worker-1` (node có taint).

## Bước 4: Deploy 5 pod không toleration — quan sát tất cả lên worker-2

```bash
for i in $(seq 1 5); do
  kubectl run test-$i --image=nginx
done

# Đợi
kubectl wait --for=condition=Ready pod -l run=test --timeout=60s 2>/dev/null || sleep 10

# Quan sát — tất cả lên worker-2
kubectl get pod -l run=test -o wide
# NAME     READY   STATUS    NODE
# test-1   1/1     Running   worker-2
# test-2   1/1     Running   worker-2
# test-3   1/1     Running   worker-2
# test-4   1/1     Running   worker-2
# test-5   1/1     Running   worker-2
```

> Worker-1 bị taint → tất cả pod không toleration schedule lên worker-2. Nếu worker-2 đầy → pod Pending.

```bash
# Cleanup
kubectl delete pod -l run=test
```

## Bước 5: Test NoExecute — evict pod đang chạy

```bash
# Xóa taint NoSchedule, add taint NoExecute
kubectl taint nodes worker-1 dedicated=gpu:NoSchedule-
kubectl taint nodes worker-1 dedicated=gpu:NoExecute

# Deploy pod lên worker-2 (không có taint)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: noexec-test
spec:
  nodeSelector:
    kubernetes.io/hostname: worker-2
  containers:
  - name: nginx
    image: nginx
EOF

kubectl get pod noexec-test -o wide
# NAME           READY   STATUS    NODE
# noexec-test    1/1     Running   worker-2
```

```bash
# Bây giờ xóa nodeSelector, deploy pod mới KHÔNG có toleration trên worker-1
# Trước tiên deploy pod CÓ toleration lên worker-1
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: noexec-tolerated
spec:
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "gpu"
    effect: "NoExecute"
  nodeSelector:
    kubernetes.io/hostname: worker-1
  containers:
  - name: nginx
    image: nginx
EOF

kubectl get pod noexec-tolerated -o wide
# NAME               READY   STATUS    NODE
# noexec-tolerated   1/1     Running   worker-1
```

```bash
# Giờ add toleration cho noexec-test và xem nó vẫn chạy
# Thay vì add toleration, hãy REMOVE taint NoExecute và add lại
# để thấy evict happening

# Xóa taint, deploy pod lên worker-1
kubectl taint nodes worker-1 dedicated=gpu:NoExecute-
kubectl run evict-test --image=nginx
# Pod schedule lên worker-1 hoặc worker-2

kubectl get pod evict-test -o wide
# NAME         READY   STATUS    NODE
# evict-test   1/1     Running   worker-1   ← giả sử lên worker-1

# Add taint NoExecute → pod không có toleration bị evict
kubectl taint nodes worker-1 dedicated=gpu:NoExecute

# Quan sát pod bị evict
kubectl get pod evict-test -o wide
# NAME         READY   STATUS        RESTARTS   AGE
# evict-test   1/1     Terminating   0          30s   ← bị evict

# Sau vài giây, pod reschedule lên worker-2
kubectl get pod evict-test -o wide
# NAME         READY   STATUS    RESTARTS   AGE   NODE
# evict-test   1/1     Running   0          35s   worker-2
```

> `NoExecute` evict pod đang chạy nếu không có toleration. Pod reschedule lên node khác.

**Kiểm tra**: Pod `evict-test` bị `Terminating` trên `worker-1`, reschedule lên `worker-2`.

## Bước 6: Test tolerationSeconds

```bash
# Xóa taint cũ
kubectl taint nodes worker-1 dedicated=gpu:NoExecute-

# Deploy pod với tolerationSeconds=30
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: toleration-seconds
spec:
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "gpu"
    effect: "NoExecute"
    tolerationSeconds: 30
  nodeSelector:
    kubernetes.io/hostname: worker-1
  containers:
  - name: nginx
    image: nginx
EOF

kubectl get pod toleration-seconds -o wide
# NAME                 READY   STATUS    NODE
# toleration-seconds   1/1     Running   worker-1

# Add taint NoExecute
kubectl taint nodes worker-1 dedicated=gpu:NoExecute

# Pod vẫn chạy (trong 30 giây)
kubectl get pod toleration-seconds
# NAME                 READY   STATUS    AGE
# toleration-seconds   1/1     Running   10s   ← vẫn chạy

# Sau 30 giây
kubectl get pod toleration-seconds
# NAME                 READY   STATUS        AGE
# toleration-seconds   1/1     Terminating   35s   ← bị evict sau 30s
```

> `tolerationSeconds: 30` = pod chịu taint trong 30 giây, sau đó bị evict. Dùng cho graceful degradation.

**Kiểm tra**: Pod chạy bình thường trong 30s sau khi taint add, sau đó bị `Terminating`.

## Bước 7: Test PreferNoSchedule (soft taint)

```bash
# Xóa taint NoExecute
kubectl taint nodes worker-1 dedicated=gpu:NoExecute-

# Add PreferNoSchedule
kubectl taint nodes worker-1 dedicated=gpu:PreferNoSchedule

# Deploy pod không toleration
kubectl run prefer-test --image=nginx

kubectl get pod prefer-test -o wide
# NAME         READY   STATUS    NODE
# prefer-test  1/1     Running   worker-2   ← prefer worker-2, tránh worker-1
```

> `PreferNoSchedule` = soft — scheduler ưu tiên tránh worker-1, nhưng nếu worker-2 đầy → vẫn schedule lên worker-1.

```bash
# Deploy nhiều pod đến khi worker-2 đầy
for i in $(seq 1 10); do
  kubectl run fill-$i --image=nginx --requests=cpu=500m,memory=512Mi
done

# Một số pod sẽ lên worker-1 (PreferNoSchedule không cấm)
kubectl get pod -l run=fill -o wide | grep worker-1
# fill-7   1/1   Running   worker-1   ← worker-2 đầy, scheduler fallback worker-1
```

**Kiểm tra**: `PreferNoSchedule` ưu tiên tránh node, nhưng khi node khác đầy, pod vẫn schedule lên.

## Cleanup

```bash
kubectl delete pod --all
kubectl taint nodes worker-1 dedicated=gpu:PreferNoSchedule-
kubectl label nodes worker-1 disktype- 2>/dev/null
```

## Câu hỏi tự kiểm tra

1. `NoSchedule` vs `NoExecute` khác nhau thế nào?
2. Pod đang chạy trên node, node add taint `NoSchedule` — điều gì xảy ra với pod?
3. `tolerationSeconds: 60` có ý nghĩa gì? Dùng khi nào?
4. `PreferNoSchedule` khác gì `NoSchedule`?
5. Tại sao nên dùng taint + nodeAffinity cùng nhau cho dedicated node?

## Đáp án tham khảo

1. `NoSchedule` chặn pod mới schedule lên node, không evict pod đang chạy. `NoExecute` chặn pod mới + evict pod đang chạy nếu không có toleration.
2. Pod vẫn chạy — `NoSchedule` chỉ ảnh hưởng scheduling mới, không evict pod đang chạy. Pod bị evict chỉ khi `NoExecute`.
3. Pod chịu taint `NoExecute` trong 60 giây, sau đó bị evict. Dùng cho graceful degradation — đợi node recover (ví dụ `node.kubernetes.io/not-ready` với 300s default).
4. `NoSchedule` = hard, cấm hoàn toàn. `PreferNoSchedule` = soft, scheduler ưu tiên tránh nhưng vẫn schedule nếu không có lựa chọn tốt hơn.
5. Taint đẩy pod không mong muốn ra khỏi node. nodeAffinity kéo pod mong muốn vào node. Chỉ taint: pod có toleration nhưng không cần node → vẫn schedule lên node khác. Chỉ nodeAffinity: pod không match → vẫn schedule lên node. Cả hai: chỉ pod mong muốn + có toleration → schedule đúng dedicated node.
