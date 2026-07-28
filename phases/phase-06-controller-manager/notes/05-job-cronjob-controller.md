# 05 — Job/CronJob Controller

## Job là gì

Job tạo pod chạy đến **completion** — đảm bảo `completions` số pod thành công. Khác với Deployment (chạy mãi), Job dừng khi đủ completion.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pi
spec:
  completions: 5        # Tổng số pod thành công cần đạt
  parallelism: 2        # Số pod chạy song song cùng lúc
  backoffLimit: 6       # Số lần retry khi pod fail
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: pi
        image: perl:5.34
        command: ["perl", "-Mbignum=bpi", "-wle", "print bpi(2000)"]
```

| Field | Ý nghĩa |
|-------|---------|
| `completions` | Số pod thành công cần đạt (default=1) |
| `parallelism` | Số pod chạy song song (default=1) |
| `backoffLimit` | Số retry khi pod fail (default=6) |
| `activeDeadlineSeconds` | Timeout — Job fail nếu chạy quá lâu |
| `ttlSecondsAfterFinished` | Auto-delete Job sau N giây khi complete |
| `suspend` | Tạm dừng Job (pod không tạo mới) |
| `restartPolicy` | `OnFailure` hoặc `Never` (không `Always`) |

## Job types

### 1. Fixed completion count

```yaml
spec:
  completions: 5
  parallelism: 2
```

```
Pod-1 ✓, Pod-2 ✓ → 2/5 complete
Pod-3 ✓, Pod-4 ✓ → 4/5 complete
Pod-5 ✓ → 5/5 complete → Job Complete
```

> Controller tạo pod đến khi đủ `completions` pod thành công. Pod fail → retry (tối đa `backoffLimit`).

### 2. Work queue (parallelism only)

```yaml
spec:
  completions: null    # Không set
  parallelism: 3
```

```
Pod-1 ✓, Pod-2 ✓, Pod-3 ✓ → 1 pod thành công → Job Complete (completions=1 default)
```

> Không set `completions` → chỉ cần 1 pod thành công. `parallelism: 3` → 3 pod chạy song song, pod nào xong trước → Job Complete. Dùng cho work queue (pod tự lấy task từ queue).

### 3. Single pod

```yaml
spec:
  completions: 1
  parallelism: 1
```

> Đơn giản nhất — 1 pod, chạy 1 lần. Fail → retry đến `backoffLimit`.

## Parallelism & completions interaction

```
completions=5, parallelism=2

Time →
t=0:  Pod-1 (running), Pod-2 (running)         → 2 pod active
t=10: Pod-1 ✓ complete                          → 1/5, create Pod-3
t=10: Pod-1 ✓, Pod-2 (running), Pod-3 (running) → 2 pod active
t=15: Pod-2 ✓ complete                          → 2/5, create Pod-4
t=15: Pod-3 (running), Pod-4 (running)           → 2 pod active
t=20: Pod-3 ✓, Pod-4 ✓                          → 4/5, create Pod-5
t=20: Pod-5 (running)                            → 1 pod active
t=25: Pod-5 ✓                                    → 5/5 → Job Complete
```

> Controller giữ `parallelism` pod active. Pod complete → tạo pod mới. Pod fail → tạo retry (nếu chưa quá `backoffLimit`).

## backoffLimit — retry khi fail

```yaml
spec:
  backoffLimit: 4
```

```
Pod-1 fail (attempt 1) → retry
Pod-2 fail (attempt 2) → retry
Pod-3 fail (attempt 3) → retry
Pod-4 fail (attempt 4) → retry
Pod-5 fail (attempt 5) → backoffLimit exceeded → Job Failed
```

> `backoffLimit` = số lần **retry** (không phải số pod fail). Pod fail + retry = 1 attempt. Vượt `backoffLimit` → Job `Failed`.

### Backoff delay

```
Attempt 1 fail → wait 10s
Attempt 2 fail → wait 20s (exponential)
Attempt 3 fail → wait 40s
Attempt 4 fail → wait 80s
... (cap at 6 min)
```

> Exponential backoff — retry chậm dần. Tránh spam pod fail liên tục.

## restartPolicy

| Policy | Behavior | Use case |
|--------|----------|----------|
| `OnFailure` | Pod fail → restart container (same pod) | Task có thể retry trong cùng pod |
| `Never` | Pod fail → tạo pod mới | Task cần clean environment mỗi retry |

> Job **không** hỗ trợ `restartPolicy: Always` (chạy mãi). Chỉ `OnFailure` hoặc `Never`.

## Pod failure policy (v1.31+)

```yaml
spec:
  podFailurePolicy:
    rules:
    - action: FailJob    # Fail toàn Job
      onExitCodes:
        values: [42]     # Exit code 42 → fail Job ngay (không retry)
    - action: Ignore     # Ignore (count as success)
      onExitCodes:
        values: [0]
    - action: Count    # Count toward backoffLimit
      onExitCodes:
        operator: In
        values: [1, 2, 3]
```

> Dùng `podFailurePolicy` để control retry behavior dựa trên exit code. Exit code 42 = fail Job ngay, không retry.

## Job status

```yaml
status:
  succeeded: 5           # Số pod thành công
  failed: 2              # Số pod fail (trước khi success)
  active: 0              # Số pod đang chạy
  startTime: ...
  completionTime: ...
  conditions:
  - type: Complete
    status: "True"
  - type: Failed
    status: "False"
```

| Condition | Ý nghĩa |
|-----------|---------|
| `Complete` | Job thành công — đủ `completions` |
| `Failed` | Job fail — vượt `backoffLimit` hoặc `activeDeadlineSeconds` |
| `Suspended` | Job tạm dừng (`suspend: true`) |

## TTL after finished

```yaml
spec:
  ttlSecondsAfterFinished: 300
```

> Job complete/fail → sau 300s, TTL controller auto-delete Job + pod. Giảm clutter trong cluster. Không set → Job tồn tại mãi (manual cleanup).

## CronJob — scheduled Job

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
spec:
  schedule: "0 2 * * *"          # 2AM daily (cron format)
  timeZone: "Asia/Ho_Chi_Minh"   # Timezone (v1.25+)
  startingDeadlineSeconds: 200   # Grace period nếu miss schedule
  concurrencyPolicy: Forbid      # Allow, Forbid, Replace
  successfulJobsHistoryLimit: 3  # Giữ 3 Job thành công gần nhất
  failedJobsHistoryLimit: 1      # Giữ 1 Job fail gần nhất
  jobTemplate:
    spec:
      completions: 1
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: backup
            image: backup-tool:latest
            command: ["./backup.sh"]
```

### Schedule format (cron)

```
┌───────────── minute (0 - 59)
│ ┌───────────── hour (0 - 23)
│ │ ┌───────────── day of month (1 - 31)
│ │ │ ┌───────────── month (1 - 12)
│ │ │ │ ┌───────────── day of week (0 - 6) (Sun=0)
│ │ │ │ │
0 2 * * *      → 2:00 AM daily
*/15 * * * *   → Every 15 minutes
0 0 * * 0      → Every Sunday midnight
0 0 1 * *      → 1st of every month midnight
```

### Concurrency policy

| Policy | Behavior |
|--------|----------|
| `Allow` (default) | Cho phép nhiều Job chạy cùng lúc |
| `Forbid` | Skip new Job nếu Job trước đang chạy |
| `Replace` | Delete Job đang chạy, tạo Job mới |

```
schedule: "*/1 * * * *" (every minute)
concurrencyPolicy: Forbid

t=0:00: Job-1 created, running
t=0:01: Job-2 scheduled → SKIP (Job-1 still running)
t=0:02: Job-3 scheduled → SKIP (Job-1 still running)
t=0:03: Job-1 done → Job-4 created
```

> `Forbid` = skip nếu đang chạy. Dùng cho backup — không chạy 2 backup cùng lúc. `Replace` = kill cũ, chạy mới.

### Job history limits

```yaml
successfulJobsHistoryLimit: 3   # default 3
failedJobsHistoryLimit: 1       # default 1
```

> CronJob controller tự xóa Job cũ vượt limit. Giảm etcd storage. Set `0` → không giữ history.

### startingDeadlineSeconds

```yaml
startingDeadlineSeconds: 200
```

> Nếu CronJob controller miss schedule (controller down) → tạo Job muộn nhưng trong 200s. Vượt 200s → skip schedule. Default: no deadline (tạo khi nào cũng được).

## CronJob status

```yaml
status:
  lastScheduleTime: "2026-01-01T02:00:00Z"
  lastSuccessfulTime: "2026-01-01T02:05:00Z"
```

> CronJob không track chi tiết — chỉ ghi last schedule + last success. Xem Job con để biết detail.

## Liên hệ với Kubernetes

- Job đảm bảo `completions` pod thành công — dừng khi đủ (khác Deployment chạy mãi).
- `parallelism` = số pod chạy song song. `completions` = tổng pod thành công cần đạt.
- `backoffLimit` = số retry. Vượt → Job `Failed`. Exponential backoff giữa retry.
- `restartPolicy: OnFailure` (restart container) hoặc `Never` (tạo pod mới).
- `podFailurePolicy` control retry dựa trên exit code (v1.31+).
- `ttlSecondsAfterFinished` auto-delete Job sau khi complete — giảm clutter.
- CronJob tạo Job theo cron schedule. `concurrencyPolicy` control overlap.
- `Forbid` = skip nếu đang chạy (backup use case). `Replace` = kill cũ chạy mới.
- Job history limits giảm etcd storage — `successfulJobsHistoryLimit` + `failedJobsHistoryLimit`.
- CronJob controller **chỉ tạo Job** — Job controller tạo Pod. Controller chain: CronJob → Job → Pod.
