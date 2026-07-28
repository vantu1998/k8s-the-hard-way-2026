# Exercise 05 — Job Parallelism

> **Mục tiêu**: Tạo Job với `completions: 5`, `parallelism: 2`, quan sát pod chạy 2 cái lúc. Hiểu Job controller reconcile.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4)

## Bối cảnh

Job tạo pod đến khi đủ `completions` pod thành công. `parallelism` control số pod chạy song song. Bài này tạo Job, quan sát pod chạy 2 cái lúc.

## Bước 1: Tạo Job — completions=5, parallelism=2

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: pi-calc
spec:
  completions: 5
  parallelism: 2
  backoffLimit: 4
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: pi
        image: perl:5.34
        command: ["perl", "-Mbignum=bpi", "-wle", "print bpi(100)"]
EOF
```

### Giải thích

| Field | Value | Ý nghĩa |
|-------|-------|---------|
| `completions` | 5 | Cần 5 pod thành công |
| `parallelism` | 2 | Tối đa 2 pod chạy song song |
| `backoffLimit` | 4 | Tối đa 4 retry khi pod fail |
| `restartPolicy` | OnFailure | Pod fail → restart container (same pod) |

## Bước 2: Quan sát pod chạy 2 cái lúc

```bash
# Watch pod
kubectl get pod -l job-name=pi-calc -w
# NAME              READY   STATUS              RESTARTS   AGE
# pi-calc-xxx-1     0/1     Pending             0          0s
# pi-calc-xxx-1     0/1     ContainerCreating   0          1s
# pi-calc-xxx-2     0/1     Pending             0          0s    ← pod thứ 2 (parallelism=2)
# pi-calc-xxx-2     0/1     ContainerCreating   0          1s
# pi-calc-xxx-1     1/1     Running             0          3s
# pi-calc-xxx-2     1/1     Running             0          3s
# pi-calc-xxx-1     0/1     Completed           0          5s    ← pod 1 complete
# pi-calc-xxx-3     0/1     Pending             0          0s    ← pod 3 tạo (1/5 complete)
# pi-calc-xxx-2     0/1     Completed           0          5s    ← pod 2 complete
# pi-calc-xxx-4     0/1     Pending             0          0s    ← pod 4 tạo (2/5 complete)
# pi-calc-xxx-3     1/1     Running             0          3s
# pi-calc-xxx-4     1/1     Running             0          3s
# pi-calc-xxx-3     0/1     Completed           0          5s    ← pod 3 complete (3/5)
# pi-calc-xxx-5     0/1     Pending             0          0s    ← pod 5 tạo
# pi-calc-xxx-4     0/1     Completed           0          5s    ← pod 4 complete (4/5)
# pi-calc-xxx-5     1/1     Running             0          3s
# pi-calc-xxx-5     0/1     Completed           0          5s    ← pod 5 complete (5/5) → Job Complete
```

> Job controller giữ **2 pod active** (parallelism=2). Pod complete → tạo pod mới. Đến khi đủ 5 pod thành công (completions=5).

**Kiểm tra**: Tối đa 2 pod Running cùng lúc. Pod complete → pod mới tạo. 5 pod thành công → Job Complete.

## Bước 3: Check Job status

```bash
kubectl get job pi-calc
# NAME      COMPLETIONS   DURATION   AGE
# pi-calc   5/5           20s        20s

kubectl get job pi-calc -o yaml | grep -A 10 "status:"
# status:
#   succeeded: 5
#   failed: 0
#   active: 0
#   startTime: "2026-01-01T00:00:00Z"
#   completionTime: "2026-01-01T00:00:20Z"
#   conditions:
#   - type: Complete
#     status: "True"
```

**Kiểm tra**: `COMPLETIONS=5/5`, condition `Complete=True`.

## Bước 4: Test Job fail — backoffLimit

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: fail-job
spec:
  completions: 3
  parallelism: 1
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fail
        image: busybox
        command: ["sh", "-c", "exit 1"]
EOF
```

```bash
# Quan sát — pod fail, retry, fail, retry, fail → Job Failed
kubectl get pod -l job-name=fail-job -w
# fail-job-xxx-1   0/1   Pending          0   0s
# fail-job-xxx-1   0/1   ContainerCreating 0   1s
# fail-job-xxx-1   0/1   Error            0   3s    ← attempt 1 fail
# fail-job-xxx-2   0/1   Pending          0   10s   ← retry (backoff 10s)
# fail-job-xxx-2   0/1   Error            0   3s    ← attempt 2 fail
# fail-job-xxx-3   0/1   Pending          0   20s   ← retry (backoff 20s)
# fail-job-xxx-3   0/1   Error            0   3s    ← attempt 3 fail
# (backoffLimit=2 → 2 retry allowed, 3 attempts total → Job Failed)
```

```bash
kubectl get job fail-job
# NAME       COMPLETIONS   DURATION   AGE
# fail-job   0/3           35s        35s

kubectl get job fail-job -o yaml | grep -A 5 "conditions:"
# conditions:
# - type: Failed
#   status: "True"
#   reason: BackoffLimitExceeded
#   message: Job has reached the specified backoff limit
```

> `backoffLimit=2` → 2 retry. 3 attempts fail → Job `Failed` (reason: `BackoffLimitExceeded`). Exponential backoff: 10s, 20s, 40s...

**Kiểm tra**: Job `Failed`, reason `BackoffLimitExceeded`, 0/3 completions.

## Bước 5: Test podFailurePolicy — fail Job ngay khi exit code cụ thể

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: policy-job
spec:
  completions: 3
  parallelism: 1
  backoffLimit: 10
  podFailurePolicy:
    rules:
    - action: FailJob
      onExitCodes:
        values: [42]
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: app
        image: busybox
        command: ["sh", "-c", "exit 42"]
EOF
```

```bash
# Pod fail với exit code 42 → Job Failed ngay (không retry dù backoffLimit=10)
kubectl get job policy-job
# NAME         COMPLETIONS   DURATION   AGE
# policy-job   0/3           5s         5s

kubectl get job policy-job -o yaml | grep -A 5 "conditions:"
# conditions:
# - type: Failed
#   status: "True"
#   reason: PodFailurePolicy
#   message: Pod failure policy was applied
```

> `podFailurePolicy` với `action: FailJob` + `onExitCodes: [42]` → exit code 42 = fail Job ngay, không retry. Dùng cho task có exit code đặc biệt (ví dụ: 42 = fatal error, không retry).

**Kiểm tra**: Job `Failed` ngay sau 1 pod fail (exit 42), reason `PodFailurePolicy`.

## Bước 6: Test activeDeadlineSeconds — timeout

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: timeout-job
spec:
  completions: 1
  parallelism: 1
  activeDeadlineSeconds: 10
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: sleep
        image: busybox
        command: ["sleep", "300"]
EOF
```

```bash
# Pod chạy 10s → Job timeout → terminate pod
kubectl get job timeout-job
# NAME           COMPLETIONS   DURATION   AGE
# timeout-job    0/1           10s        10s

kubectl get job timeout-job -o yaml | grep -A 5 "conditions:"
# conditions:
# - type: Failed
#   status: "True"
#   reason: DeadlineExceeded
#   message: Job was active longer than specified deadline
```

> `activeDeadlineSeconds: 10` → Job chạy quá 10s → `Failed` (reason: `DeadlineExceeded`). Pod bị terminate.

**Kiểm tra**: Job `Failed` sau 10s, reason `DeadlineExceeded`.

## Bước 7: Test TTL after finished

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ttl-job
spec:
  completions: 1
  parallelism: 1
  ttlSecondsAfterFinished: 30
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: pi
        image: perl:5.34
        command: ["perl", "-Mbignum=bpi", "-wle", "print bpi(50)"]
EOF
```

```bash
# Job complete
kubectl get job ttl-job
# NAME      COMPLETIONS   DURATION   AGE
# ttl-job   1/1           3s         5s

# Đợi 30s — Job auto-delete
sleep 35
kubectl get job ttl-job
# Error from server (NotFound): jobs.batch "ttl-job" not found

# Pod cũng bị delete (cascade)
kubectl get pod -l job-name=ttl-job
# No resources found in default namespace.
```

> `ttlSecondsAfterFinished: 30` → Job + pod auto-delete 30s sau khi complete. Giảm clutter. TTL controller quản lý cleanup.

**Kiểm tra**: Job + pod auto-delete sau 30s.

## Cleanup

```bash
kubectl delete job pi-calc fail-job policy-job timeout-job 2>/dev/null
```

## Câu hỏi tự kiểm tra

1. `completions=5, parallelism=2` — tối đa bao nhiêu pod chạy cùng lúc? Tổng bao nhiêu pod thành công?
2. Pod fail với `restartPolicy: OnFailure` — điều gì xảy ra? Khác gì `restartPolicy: Never`?
3. `backoffLimit=2` — bao nhiêu lần retry? Exponential backoff hoạt động thế nào?
4. `podFailurePolicy` với `action: FailJob, onExitCodes: [42]` — exit code 42 gây gì?
5. `ttlSecondsAfterFinished: 30` — auto-delete gì? Khi nào?

## Đáp án tham khảo

1. Tối đa **2 pod** chạy cùng lúc (parallelism=2). Tổng **5 pod thành công** (completions=5). Controller tạo pod mới khi pod complete, giữ 2 active cho đến khi đủ 5 success.
2. `OnFailure`: pod fail → restart container trong **cùng pod** (RESTARTS++). `Never`: pod fail → tạo **pod mới** (pod cũ stays in Failed status). `OnFailure` cho task retry được trong cùng environment. `Never` cho task cần clean environment mỗi retry.
3. `backoffLimit=2` = **2 retry** (3 attempts total: 1 initial + 2 retry). Exponential backoff: attempt 1 fail → wait 10s, attempt 2 fail → wait 20s, attempt 3 fail → wait 40s. Vượt backoffLimit → Job `Failed` (BackoffLimitExceeded).
4. Exit code 42 → `action: FailJob` → Job **Failed ngay**, không retry (dù `backoffLimit=10`). Reason: `PodFailurePolicy`. Dùng cho fatal error — không retry vô ích.
5. `ttlSecondsAfterFinished: 30` → TTL controller auto-delete **Job + pod** 30s sau khi Job complete hoặc fail. Giảm clutter trong cluster. Không set → Job tồn tại mãi (manual cleanup).
