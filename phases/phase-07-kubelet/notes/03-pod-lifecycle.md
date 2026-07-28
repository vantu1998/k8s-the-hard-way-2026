# 03 — Pod Lifecycle

## SyncLoop — kubelet reconcile loop

Kubelet chạy **SyncLoop** (PLEG — Pod Lifecycle Event Generator) liên tục — watch pod assigned cho node, reconcile pod state:

```
SyncLoop:
    ┌─────────────────────────────────────────────┐
    │  1. Watch API Server (pod assigned to node)  │
    │  2. PLEG: check container status (running?)  │
    │  3. Compare desired (spec) vs actual (status)│
    │  4. If mismatch → syncPod                    │
    │  5. Update pod status                        │
    │  6. Repeat                                   │
    └─────────────────────────────────────────────┘
```

### PLEG — Pod Lifecycle Event Generator

```
PLEG running every 1s:
  1. List all container (CRI: ListContainers)
  2. Compare with cached status
  3. If container status changed → generate event
  4. SyncLoop process event → syncPod
```

> PLEG poll container status mỗi 1s. Nếu container crash → PLEG detect → syncPod → restart container (if restartPolicy allows).

## syncPod — reconcile một pod

```
syncPod(pod):
    1. Check if pod can run (node condition, resource)
    2. If pod sandbox not exist → create sandbox (CRI: RunPodSandbox)
       ├── Create network namespace
       ├── CNI setup (assign IP, route)
       └── Create IPC namespace (if share)
    3. For each container in pod:
       a. If container not exist → create (CRI: CreateContainer)
          ├── Pull image (if not cached)
          ├── Create container spec (image, command, env, mounts)
          └── CreateContainer → return containerID
       b. If container exist but stopped → start (CRI: StartContainer)
       c. If container exist but spec changed → kill + recreate
    4. Start container (CRI: StartContainer)
    5. Run probes (liveness, readiness, startup)
    6. Update pod status (Running, Waiting, Terminated)
```

### CRI call chain

```
Kubelet
  │
  ├── RunPodSandbox (CRI: RuntimeService)
  │     ├── Create network namespace
  │     ├── CNI: setup pod network (IP, route, iptables)
  │     └── Return sandboxID
  │
  ├── PullImage (CRI: ImageService) — if image not cached
  │     └── containerd pull → runc
  │
  ├── CreateContainer (CRI: RuntimeService)
  │     ├── Create container spec from pod spec
  │     ├── Mount volumes (configmap, secret, emptyDir)
  │     ├── Set env vars, command, args
  │     └── Return containerID
  │
  ├── StartContainer (CRI: RuntimeService)
  │     └── runc start container
  │
  └── Update pod status → API Server
```

> Kubelet không tạo container trực tiếp — gọi CRI (Container Runtime Interface). CRI = gRPC API đến containerd/CRI-O. Xem Phase 8 cho CRI chi tiết.

## Pod status — kubelet report

```yaml
status:
  phase: Running
  conditions:
  - type: Ready
    status: "True"
  - type: ContainersReady
    status: "True"
  containerStatuses:
  - name: nginx
    containerID: containerd://abc123
    image: nginx:1.25
    imageID: sha256:xxx
    ready: true
    restartCount: 0
    started: true
    state:
      running:
        startedAt: "2026-01-01T00:00:00Z"
```

### Container states

| State | Ý nghĩa |
|-------|---------|
| `waiting` | Container chưa chạy (pulling image, creating) |
| `running` | Container đang chạy |
| `terminated` | Container đã dừng (exit code, reason) |

```yaml
# Waiting
state:
  waiting:
    reason: ImagePullBackOff
    message: "Back-off pulling image nginx:99.99"

# Running
state:
  running:
    startedAt: "2026-01-01T00:00:00Z"

# Terminated
state:
  terminated:
    exitCode: 0
    reason: Completed
    startedAt: "2026-01-01T00:00:00Z"
    finishedAt: "2026-01-01T00:05:00Z"
```

## Pod start flow

```
1. Scheduler bind pod to node (pod.spec.nodeName = worker-1)
2. Kubelet watch detect pod assigned
3. syncPod:
   a. Create pod sandbox (network namespace + CNI)
   b. Pull image (if not cached, depends on imagePullPolicy)
   c. Create container (spec from pod template)
   d. Start container
   e. Run startup probe (if configured)
   f. Run readiness probe (if configured)
   g. Update pod status: Running, Ready=True
4. Kubelet report status to API Server
```

### Image pull policy

| Policy | Behavior |
|--------|----------|
| `Always` | Always pull image (even if cached) |
| `IfNotPresent` (default) | Pull only if not in local cache |
| `Never` | Never pull — use local cache only (fail if not cached) |

```yaml
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    imagePullPolicy: IfNotPresent   # default
```

> `Always` cho `:latest` tag (default nếu tag=rỗng). `IfNotPresent` cho versioned tag. `Never` cho air-gapped cluster.

## Pod stop flow — graceful shutdown

```
1. API Server receive delete pod request
2. Kubelet watch detect pod delete (deletionTimestamp set)
3. Kubelet graceful shutdown:
   a. Run preStop hook (if configured) — exec or HTTP
   b. Wait for preStop to complete (or timeout)
   c. Send SIGTERM to container
   d. Wait for terminationGracePeriodSeconds (default 30s)
   e. If container still running → SIGKILL
   f. Stop container (CRI: StopContainer)
   g. Destroy sandbox (CRI: StopPodSandbox + RemovePodSandbox)
4. Kubelet update pod status: Terminated
5. API Server delete pod object
```

### terminationGracePeriodSeconds

```yaml
spec:
  terminationGracePeriodSeconds: 60   # default 30
  containers:
  - name: nginx
    image: nginx
    lifecycle:
      preStop:
        exec:
          command: ["sh", "-c", "nginx -s quit; sleep 10"]
```

```
Timeline (terminationGracePeriodSeconds=60):
  t=0s:   Delete pod → preStop hook start
  t=10s:  preStop complete (nginx -s quit + sleep 10)
  t=10s:  SIGTERM sent to container
  t=10s:  Container graceful shutdown (save state, close connection)
  t=60s:  If still running → SIGKILL
  t=60s:  Container stopped → sandbox destroyed
```

> preStop + SIGTERM **cùng countdown** `terminationGracePeriodSeconds`. Nếu preStop chạy 20s → SIGTERM có 40s còn lại. Tổng không vượt grace period.

### preStop hook

```yaml
lifecycle:
  preStop:
    exec:                    # Execute command in container
      command: ["sh", "-c", "nginx -s quit"]
  # OR
    httpGet:                 # HTTP GET to container
      path: /shutdown
      port: 8080
```

> preStop chạy **trước** SIGTERM. Dùng cho: graceful shutdown (nginx -s quit), deregister from load balancer, save state. preStop fail → vẫn send SIGTERM (preStop error không block shutdown).

### SIGTERM vs SIGKILL

| Signal | Behavior |
|--------|----------|
| `SIGTERM` | Graceful — container có thể catch signal, cleanup, exit |
| `SIGKILL` | Force — kernel kill process ngay, không catch được |

> Container **phải catch SIGTERM** để graceful shutdown. Nếu container ignore SIGTERM → đợi grace period → SIGKILL. App nên implement signal handler.

## Pod update — container recreate

```
Pod spec change (image, env, command):
  1. Kubelet detect spec change (watch event)
  2. syncPod: compare desired vs actual
  3. Container spec changed → kill old container (SIGTERM → grace period → SIGKILL)
  4. Create new container with new spec
  5. Start new container
```

> Kubelet **recreate** container khi spec change — không update in-place. Container là immutable. Pod spec change → kill + create container mới.

### What triggers container recreate

| Change | Recreate container? |
|--------|---------------------|
| Image | Yes |
| Command/Args | Yes |
| Env | Yes |
| Resources (CPU/memory) | Yes |
| Volume mount | Yes |
| Probe config | Yes |
| Labels/Annotations | No (metadata only) |
| Node selector | No (pod reschedule) |

## restartPolicy

| Policy | Behavior |
|--------|----------|
| `Always` (default) | Container exit (any code) → restart |
| `OnFailure` | Container exit non-zero → restart |
| `Never` | Container exit → no restart (pod stays in Failed/Completed) |

```
Container exit code 0:
  Always → restart
  OnFailure → no restart (success)
  Never → no restart

Container exit code 1 (fail):
  Always → restart
  OnFailure → restart
  Never → no restart
```

> restartPolicy là **pod-level** — áp dụng cho tất cả container trong pod. Job dùng `OnFailure` hoặc `Never`. Deployment/ReplicaSet dùng `Always` (default).

### Restart backoff

```
Container fail → restart after 10s
Container fail again → restart after 20s
Container fail again → restart after 40s
... (exponential, max 5 min)
Container fail again → restart after 5 min (cap)
```

> Kubelet exponential backoff — restart chậm dần. Tránh crash loop. `CrashLoopBackOff` status = container fail + đang chờ restart.

## Liên hệ với Kubernetes

- SyncLoop (PLEG) = kubelet reconcile loop — watch pod, check container status, syncPod.
- PLEG poll container status mỗi 1s — detect container crash → syncPod → restart.
- syncPod: create sandbox → pull image → create container → start container → run probes → update status.
- Kubelet gọi **CRI** (gRPC) — không tạo container trực tiếp. CRI = containerd/CRI-O.
- Container states: `waiting` (creating), `running`, `terminated` (exited).
- Graceful shutdown: preStop hook → SIGTERM → wait grace period → SIGKILL.
- `terminationGracePeriodSeconds` (default 30s) — preStop + SIGTERM cùng countdown.
- preStop chạy **trước** SIGTERM — graceful shutdown, deregister.
- restartPolicy: `Always` (Deployment), `OnFailure`/`Never` (Job).
- Container **immutable** — spec change → kill + recreate (không update in-place).
- `CrashLoopBackOff` = container fail + exponential backoff restart (10s, 20s, 40s... max 5 min).
