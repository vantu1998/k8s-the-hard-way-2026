# Exercise 04 — Cordon & Drain

> **Mục tiêu**: Cordon + drain node, quan sát Node controller + DaemonSet controller behavior. Pod evict, reschedule, DaemonSet stay.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), ít nhất 2 worker node

## Bối cảnh

Cordon mark node unschedulable, drain evict pod. Bài này cordon + drain 1 node, quan sát pod reschedule, DaemonSet pod không bị evict.

## Prerequisites

```bash
kubectl get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# master    Ready     control-plane   10d   v1.33.0
# worker-1  Ready     <none>          10d   v1.33.0
# worker-2  Ready     <none>          10d   v1.33.0
```

## Bước 1: Deploy Deployment + DaemonSet

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 4
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
        image: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
spec:
  selector:
    matchLabels:
      app: log-agent
  template:
    metadata:
      labels:
        app: log-agent
    spec:
      containers:
      - name: fluentd
        image: fluent/fluentd:v1.16
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Verify — Deployment pod spread, DaemonSet pod trên mỗi node
kubectl get pod -o wide | grep -E "(web|log-agent)"
# web-xxx-aaa      1/1   Running   worker-1
# web-xxx-bbb      1/1   Running   worker-1
# web-xxx-ccc      1/1   Running   worker-2
# web-xxx-ddd      1/1   Running   worker-2
# log-agent-yyy    1/1   Running   worker-1   ← DaemonSet
# log-agent-zzz    1/1   Running   worker-2   ← DaemonSet
```

**Kiểm tra**: 4 Deployment pod + 2 DaemonSet pod (1 per node).

## Bước 2: Cordon worker-1

```bash
kubectl cordon worker-1
# node/worker-1 cordoned

# Verify — node SchedulingDisabled
kubectl get node worker-1
# NAME       STATUS                     ROLES    AGE
# worker-1   Ready,SchedulingDisabled   <none>   10d
```

```bash
# Check taint
kubectl describe node worker-1 | grep -i taint
# Taints:  node.kubernetes.io/unschedulable:NoSchedule
```

> Cordon = add taint `unschedulable:NoSchedule`. Pod mới không schedule lên node. Pod đang chạy **không bị evict**.

**Kiểm tra**: Node `worker-1` có status `SchedulingDisabled`, taint `unschedulable:NoSchedule`.

## Bước 3: Verify pod đang chạy không bị ảnh hưởng

```bash
# Pod vẫn chạy trên worker-1
kubectl get pod -o wide | grep worker-1
# web-xxx-aaa      1/1   Running   worker-1   ← vẫn chạy
# web-xxx-bbb      1/1   Running   worker-1
# log-agent-yyy    1/1   Running   worker-1
```

> Cordon chỉ chặn pod **mới**. Pod đang chạy không bị evict.

## Bước 4: Drain worker-1 — evict pod

```bash
# Drain — evict pod (ignore daemonset, delete emptydir)
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data --force
# node/worker-1 cordoned
# evicting pod default/web-xxx-aaa
# evicting pod default/web-xxx-bbb
# evicting pod kube-system/kube-proxy-xxx
# evicting pod default/log-agent-yyy    ← DaemonSet, ignored
# node/worker-1 drained
```

| Flag | Ý nghĩa |
|------|---------|
| `--ignore-daemonsets` | Không evict DaemonSet pod (chạy trên mọi node) |
| `--delete-emptydir-data` | Evict pod dùng emptyDir (data sẽ mất) |
| `--force` | Evict standalone pod (không thuộc controller) |
| `--grace-period=30` | Grace period cho pod shutdown |
| `--timeout=120s` | Timeout đợi evict |

```bash
# Verify — Deployment pod evicted, reschedule lên worker-2
kubectl get pod -o wide | grep -E "(web|log-agent)"
# web-xxx-aaa      1/1   Running   worker-2   ← reschedule
# web-xxx-bbb      1/1   Running   worker-2
# web-xxx-ccc      1/1   Running   worker-2
# web-xxx-ddd      1/1   Running   worker-2
# web-xxx-eee      1/1   Running   worker-2   ← pod mới (reschedule)
# web-xxx-fff      1/1   Running   worker-2   ← pod mới
# log-agent-yyy    1/1   Running   worker-1   ← DaemonSet, KHÔNG evict
# log-agent-zzz    1/1   Running   worker-2
```

> Deployment pod bị evict → ReplicaSet controller tạo pod mới trên worker-2 (worker-1 cordoned). DaemonSet pod **không bị evict** (`--ignore-daemonsets`).

**Kiểm tra**: Deployment pod reschedule lên `worker-2`. DaemonSet pod vẫn chạy trên `worker-1`.

## Bước 5: Quan sát event log

```bash
kubectl get events --sort-by='.lastTimestamp' | grep -E "(worker-1|evict|Eviction|Marking)"
# NORMAL  NodeNotReady          node/worker-1    Node worker-1 status is now: NotReady
# NORMAL  NodeSchedulable       node/worker-1    Node worker-1 status is now: SchedulingDisabled
# NORMAL  Evictioner            pod/web-xxx-aaa  This pod is evicted from node worker-1
# NORMAL  Killing               pod/web-xxx-aaa  Stopping container nginx
# NORMAL  SuccessfulCreate      replicaset/web   Created pod: web-xxx-eee
# NORMAL  Scheduled             pod/web-xxx-eee  Successfully assigned to worker-2
```

> Drain = evict pod → ReplicaSet controller detect pod delete → create new pod → scheduler schedule lên worker-2 (worker-1 unschedulable).

## Bước 6: Simulate node NotReady — stop kubelet

```bash
# SSH vào worker-1, stop kubelet
ssh worker-1 'sudo systemctl stop kubelet'

# Quan sát — node controller mark NotReady sau ~40s
kubectl get node worker-1 -w
# worker-1   Ready                     <none>   10d
# worker-1   NotReady                  <none>   10d   ← mark NotReady

# Check conditions
kubectl describe node worker-1 | grep -A 2 "Ready:"
#   Ready     Unknown   ...   NodeStatusUnknown   Kubelet stopped posting node status
```

```bash
# Taint added
kubectl describe node worker-1 | grep -i taint
# Taints:  node.kubernetes.io/unreachable:NoExecute
#          node.kubernetes.io/not-ready:NoExecute
```

> Node controller detect no heartbeat (40s) → mark `Ready=Unknown` → add taint `unreachable:NoExecute`.

```bash
# Pod trên worker-1 — DaemonSet pod có toleration, vẫn chạy
# (kubelet stopped but container still running via containerd)
kubectl get pod -o wide | grep worker-1
# log-agent-yyy   1/1   Running   worker-1   ← DaemonSet tolerates not-ready

# Đợi 5 phút (pod-eviction-timeout) — pod không có toleration bị evict
# (nhưng worker-1 đã drained, không còn Deployment pod)
```

```bash
# Restart kubelet
ssh worker-1 'sudo systemctl start kubelet'

# Node Ready again
kubectl get node worker-1 -w
# worker-1   NotReady   <none>   10d
# worker-1   Ready      <none>   10d   ← recover
```

> Node recover → taint removed → node schedulable again (nếu chưa cordoned).

## Bước 7: Uncordon worker-1

```bash
# Uncordon
kubectl uncordon worker-1
# node/worker-1 uncordoned

# Verify
kubectl get node worker-1
# NAME       STATUS   ROLES    AGE
# worker-1   Ready    <none>   10d   ← schedulable again
```

```bash
# Pod không tự migrate về worker-1
kubectl get pod -o wide | grep web
# web-xxx-ccc   1/1   Running   worker-2   ← vẫn worker-2
# web-xxx-ddd   1/1   Running   worker-2
# web-xxx-eee   1/1   Running   worker-2
# web-xxx-fff   1/1   Running   worker-2

# Pod mới sẽ schedule trên cả 2 node
kubectl scale deployment web --replicas=6
kubectl get pod -o wide | grep web | sort -k 7
# web-xxx-ccc   1/1   Running   worker-1   ← pod mới lên worker-1
# web-xxx-ddd   1/1   Running   worker-1
# web-xxx-eee   1/1   Running   worker-2
# web-xxx-fff   1/1   Running   worker-2
# web-xxx-ggg   1/1   Running   worker-1
# web-xxx-hhh   1/1   Running   worker-2
```

> Uncordon = node nhận pod mới. Pod đã reschedule lên worker-2 **không tự migrate** về worker-1. Chỉ pod mới (scale up) mới schedule đều ra.

**Kiểm tra**: Node `worker-1` Ready + schedulable. Pod mới spread ra cả 2 node.

## Cleanup

```bash
kubectl delete deployment web
kubectl delete daemonset log-agent
```

## Câu hỏi tự kiểm tra

1. Cordon vs Drain khác nhau thế nào? Pod đang chạy có bị evict khi cordon?
2. Tại sao DaemonSet pod không bị drain evict? Làm sao drain evict được?
3. Node NotReady (kubelet stop) — sau bao lâu node controller mark Unknown? Pod bị evict khi nào?
4. Uncordon — pod có tự migrate về node không? Tại sao?
5. `--ignore-daemonsets` trong drain có ý nghĩa gì? Bỏ flag này thì sao?

## Đáp án tham khảo

1. Cordon = mark node unschedulable (add taint `unschedulable:NoSchedule`). Pod mới không schedule lên, pod đang chạy **không bị evict**. Drain = cordon + evict pod đang chạy → pod reschedule lên node khác.
2. DaemonSet pod có toleration cho `unschedulable`, `not-ready`, `unreachable` taint → không bị evict. `--ignore-daemonsets` skip DaemonSet pod. Bỏ flag → drain fail (DaemonSet pod không evict được, drain stuck).
3. Node controller mark `Ready=Unknown` sau `--node-monitor-grace-period` (default 40s) không heartbeat. Pod bị evict sau `--pod-eviction-timeout` (default 5m) hoặc `tolerationSeconds` (default 300s cho unreachable taint).
4. **Không tự migrate** — pod đã reschedule lên node khác, không có mechanism migrate về. Uncordon chỉ cho phép pod **mới** schedule lên node. Pod cũ vẫn chạy trên node khác đến khi bị delete/scale down.
5. `--ignore-daemonsets` = skip DaemonSet pod khi drain. DaemonSet pod chạy trên mọi node — evict không có ý nghĩa (sẽ tạo lại ngay). Bỏ flag → drain cố evict DaemonSet pod → fail (DaemonSet có toleration) → drain stuck. Luôn dùng `--ignore-daemonsets` khi drain.
