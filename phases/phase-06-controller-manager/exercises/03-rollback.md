# Exercise 03 — Rollback

> **Mục tiêu**: Rollback rollout, quan sát ReplicaSet cũ scale lên lại. Hiểu rollback mechanism.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4)

## Bối cảnh

Rolling update fail (image lỗi, config sai) → rollback về version cũ. Bài này deploy v1, update v2 (bad image), rollback v1, quan sát RS cũ scale lên lại.

## Bước 1: Deploy v1

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  annotations:
    kubernetes.io/change-cause: "v1 — initial deploy"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Verify
kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    3         3         3       10s

# Check rollout history
kubectl rollout history deployment/web
# REVISION  CHANGE-CAUSE
# 1         v1 — initial deploy
```

**Kiểm tra**: 3 pod running nginx:1.25, revision 1.

## Bước 2: Update v2 — bad image

```bash
# Update image (intentionally bad)
kubectl set image deployment/web nginx=nginx:99.99.99 \
  --record=false

kubectl annotate deployment/web kubernetes.io/change-cause="v2 — bad image"

# Pod mới fail — ImagePullError
kubectl get pod -l app=web -w
# web-def456-aaa   0/1   ImagePullBackOff   0   10s
# web-def456-bbb   0/1   ImagePullBackOff   0   10s
```

```bash
# Deployment status — rollout stuck
kubectl get deploy web
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    3/3     1            3           2m     ← UP-TO-DATE=1 (1 pod mới fail)

kubectl rollout status deployment/web
# Waiting for deployment "web" rollout to finish: 1 out of 3 new replicas have been updated...
# (stuck — pod mới không ready)
```

```bash
# 2 RS — RS-mới có pod fail
kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    2         2         2       2m     ← RS-cũ scale xuống 2
# web-def456    1         1         0       30s    ← RS-mới: 1 pod, 0 ready (ImagePullBackOff)
```

> Rolling update stuck: RS-mới có 1 pod fail (ImagePullBackOff) → Deployment controller không scale RS-mới lên tiếp. RS-cũ vẫn giữ 2 pod (available).

**Kiểm tra**: Pod mới `ImagePullBackOff`, rollout stuck, RS-cũ vẫn giữ 2 pod.

## Bước 3: Rollback về v1

```bash
# Rollback
kubectl rollout undo deployment/web
# deployment.apps/web rolled back

# Quan sát — RS-cũ scale lên, RS-mới scale xuống
kubectl get rs -l app=web -w
# web-abc123    2         2         2       3m
# web-def456    1         1         0       1m
# web-abc123    3         2         2       3m     ← RS-cũ scale lên 3
# web-def456    0         1         0       1m     ← RS-mới scale xuống 0
```

```bash
# Verify — all pod running v1
kubectl get pod -l app=web -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
# web-abc123-aaa   nginx:1.25
# web-abc123-bbb   nginx:1.25
# web-abc123-ccc   nginx:1.25

kubectl get deploy web
# NAME   READY   UP-TO-DATE   AVAILABLE   AGE
# web    3/3     3            3           5m     ← all 3 up-to-date
```

> Rollback = rolling update ngược. Deployment controller scale RS-cũ lên, RS-mới xuống. **Reuse RS-cũ** — không tạo RS mới.

**Kiểm tra**: 3 pod running `nginx:1.25` (v1), RS-cũ `DESIRED=3`, RS-mới `DESIRED=0`.

## Bước 4: Rollback history

```bash
# Check history — 3 revisions
kubectl rollout history deployment/web
# REVISION  CHANGE-CAUSE
# 1         v1 — initial deploy
# 2         v2 — bad image
# 3         v3 — rollback to revision 1   ← rollback tạo revision mới

# Detail revision 2
kubectl rollout history deployment/web --revision=2
# Pod Template:
#   Labels: app=web
#   Containers:
#     nginx: nginx:99.99.99 (bad image)
#   Events: <none>

# Detail revision 1
kubectl rollout history deployment/web --revision=1
# Pod Template:
#   Containers:
#     nginx: nginx:1.25
```

> Rollback tạo **revision mới** (revision 3 = rollback to 1). Không quay lại revision 1 — tạo revision 3 với cùng template revision 1.

## Bước 5: Rollback to specific revision

```bash
# Deploy v3 (good image)
kubectl set image deployment/web nginx=nginx:1.26
kubectl annotate deployment/web kubernetes.io/change-cause="v3 — nginx 1.26"

kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# History
kubectl rollout history deployment/web
# REVISION  CHANGE-CAUSE
# 1         v1 — initial deploy
# 2         v2 — bad image
# 3         v3 — rollback to revision 1
# 4         v3 — nginx 1.26

# Rollback to revision 1 (nginx:1.25)
kubectl rollout undo deployment/web --to-revision=1
# deployment.apps/web rolled back

# Verify
kubectl get pod -l app=web -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u
# nginx:1.25
```

**Kiểm tra**: Rollback to revision 1 → pod chạy `nginx:1.25`.

## Bước 6: Pause & Resume

```bash
# Pause rollout
kubectl rollout pause deployment/web

# Thay đổi nhiều field — không trigger rollout
kubectl set image deployment/web nginx=nginx:1.27
kubectl set resources deployment/web -c=nginx --limits=cpu=200m,memory=256Mi
kubectl set env deployment/web DEBUG=false

# Verify — chưa rollout (paused)
kubectl get rs -l app=web
# NAME          DESIRED   CURRENT   READY   AGE
# web-abc123    3         3         3       10m   ← vẫn RS cũ

# Resume — trigger 1 rollout cho tất cả thay đổi
kubectl rollout resume deployment/web

# Quan sát — 1 rolling update cho tất cả thay đổi
kubectl rollout status deployment/web --watch
# deployment "web" successfully rolled out
```

> Pause cho phép thay đổi nhiều field, resume trigger **1 rollout** thay vì nhiều. Tiết kiệm resource + thời gian.

**Kiểm tra**: Paused → thay đổi không trigger rollout. Resume → 1 rollout cho tất cả.

## Cleanup

```bash
kubectl delete deployment web
```

## Câu hỏi tự kiểm tra

1. Rollback có tạo ReplicaSet mới không? Cơ chế rollback là gì?
2. Rollback tạo revision mới hay quay lại revision cũ? Tại sao?
3. Rollout stuck (pod mới ImagePullBackOff) — RS-cũ có bị xóa không? Pod cũ có chạy không?
4. `kubectl rollout undo --to-revision=2` rollback về revision 2 — điều gì xảy ra với RS?
5. Pause/resume lợi ích gì so với thay đổi từng field?

## Đáp án tham khảo

1. **Không tạo RS mới** — reuse RS-cũ (replicas=0). Rollback = scale RS-cũ lên, RS-mới xuống (rolling update ngược). RS-cũ đã tồn tại, chỉ cần scale lên.
2. Tạo **revision mới** — revision 3 = rollback to revision 1. Không quay lại revision 1 vì history là append-only. Revision 3 có cùng template revision 1 nhưng là revision mới.
3. RS-cũ **không bị xóa** — vẫn giữ pod (available). Pod mới fail → Deployment controller không scale RS-mới lên tiếp. Pod cũ vẫn chạy → service available. Rollback → scale RS-cũ lên lại.
4. Scale RS của revision 2 lên, RS hiện tại xuống. Nếu revision 2 = bad image → rollout lại stuck. `--to-revision` cho phép rollback đến bất kỳ revision nào trong history (giới hạn bởi `revisionHistoryLimit`).
5. Pause/resume cho phép thay đổi nhiều field (image, resources, env) mà chỉ trigger **1 rollout**. Không pause → mỗi thay đổi trigger 1 rollout → nhiều rolling update liên tiếp → tốn resource + thời gian. Pause = batch changes, resume = 1 rollout.
