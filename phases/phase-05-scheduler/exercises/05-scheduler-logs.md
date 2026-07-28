# Exercise 05 — Scheduler Logs

> **Mục tiêu**: Xem scheduler log, tìm decision log biết pod bị schedule lên node nào, tại sao. Bật `--v=5` để thấy chi tiết Filter/Score.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), ít nhất 2 worker node

## Bối cảnh

Scheduler log chứa chi tiết scheduling decision — node nào pass Filter, node nào có score cao nhất. Bài này deploy pod, đọc scheduler log để hiểu scheduler "nghĩ gì" khi chọn node.

## Prerequisites

```bash
kubectl get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# master    Ready     control-plane   10d   v1.33.0
# worker-1  Ready     <none>          10d   v1.33.0
# worker-2  Ready     <none>          10d   v1.33.0

# Label zone
kubectl label nodes worker-1 zone=a
kubectl label nodes worker-2 zone=b
```

## Bước 1: Xem scheduler log mặc định (v=2)

```bash
# Xem scheduler pod
kubectl get pod -n kube-system -l component=kube-scheduler
# NAME                READY   STATUS    NODE
# kube-scheduler-master   1/1     Running   master

# Xem log mặc định (v=2 — ít chi tiết)
kubectl logs -n kube-system kube-scheduler-master --tail=20
# I0101 00:00:00.000000 1 scheduler.go:XXX] "Scheduled pod" pod="default/nginx" node="worker-1"
```

> v=2 chỉ log "Scheduled pod" — không thấy Filter/Score detail. Cần tăng verbosity.

## Bước 2: Bật scheduler v=5 (temporary)

```bash
# Edit scheduler static pod manifest (kubeadm)
sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml.bak

# Thay --v=2 thành --v=5
sudo sed -i 's/--v=2/--v=5/' /etc/kubernetes/manifests/kube-scheduler.yaml

# Kubelet tự restart scheduler pod (watch manifests dir)
# Đợi pod restart
kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-scheduler --timeout=60s

# Verify v=5
kubectl logs -n kube-system kube-scheduler-master --tail=5 | head -1
# ... --v=5 ...
```

> Static pod manifest thay đổi → kubelet tự restart pod. Không cần restart kubelet.

**Kiểm tra**: Scheduler log hiện chi tiết hơn (nhiều dòng hơn).

## Bước 3: Deploy pod và xem scheduling decision

```bash
# Xóa log cũ (ghi lại từ đây)
kubectl logs -n kube-system kube-scheduler-master --tail=0 -f > /tmp/scheduler.log 2>&1 &

# Deploy pod
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: log-test
  labels:
    app: log-test
spec:
  nodeSelector:
    zone: a
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
EOF

# Đợi pod schedule
sleep 5

# Stop log capture
kill %1 2>/dev/null
```

## Bước 4: Phân tích scheduler log

```bash
# Tìm scheduling decision cho pod log-test
grep "log-test" /tmp/scheduler.log | head -30
```

### Filter phase log

```bash
# Tìm Filter result
grep -E "(Filter|log-test|feasible)" /tmp/scheduler.log | head -20
```

Log mẫu (v=5):
```
I0101 00:00:01.123456 1 default_binder.go:XXX] "Attempting to bind pod" pod="default/log-test" node="worker-1"
I0101 00:00:01.123789 1 schedule_one.go:XXX] "Filtering nodes for pod" pod="default/log-test"
I0101 00:00:01.124000 1 default_binder.go:XXX] "NodeFilter" node="worker-1" pass=true
I0101 00:00:01.124100 1 default_binder.go:XXX] "NodeFilter" node="worker-2" pass=false reason="node(s) didn't match node selector"
I0101 00:00:01.124200 1 schedule_one.go:XXX] "Feasible nodes" pod="default/log-test" nodes=["worker-1"]
```

> Filter log: `worker-1` pass (zone=a match), `worker-2` fail (zone=b không match nodeSelector zone=a).

### Score phase log

```bash
# Tìm Score result
grep -E "(Score|scoring|log-test)" /tmp/scheduler.log | head -20
```

Log mẫu:
```
I0101 00:00:01.125000 1 schedule_one.go:XXX] "Scoring nodes for pod" pod="default/log-test"
I0101 00:00:01.125100 1 node_resources_fit.go:XXX] "NodeResourcesFit score" pod="default/log-test" node="worker-1" score=80
I0101 00:00:01.125200 1 schedule_one.go:XXX] "Final score" pod="default/log-test" node="worker-1" score=80
I0101 00:00:01.125300 1 default_binder.go:XXX] "Binding pod" pod="default/log-test" node="worker-1"
```

> Chỉ 1 feasible node (worker-1) → Score trivial. Nếu nhiều node feasible, log hiển thị score cho từng node.

### Bind log

```bash
# Tìm Bind result
grep -E "(Bind|Scheduled)" /tmp/scheduler.log | grep log-test
```

Log mẫu:
```
I0101 00:00:01.130000 1 scheduler.go:XXX] "Scheduled pod" pod="default/log-test" node="worker-1"
```

## Bước 5: Deploy pod không có constraint — xem full Filter/Score

```bash
# Capture log
kubectl logs -n kube-system kube-scheduler-master --tail=0 -f > /tmp/scheduler2.log 2>&1 &

# Deploy pod không có nodeSelector
kubectl run log-test-2 --image=nginx --requests=cpu=100m,memory=128Mi

sleep 5
kill %1 2>/dev/null
```

```bash
# Phân tích — thấy Filter + Score cho tất cả node
grep "log-test-2" /tmp/scheduler2.log | head -40

# Filter — tất cả node pass (không có constraint)
# Score — node ít utilized có score cao hơn
```

Log mẫu:
```
"Filtering nodes for pod" pod="default/log-test-2"
"NodeFilter" node="worker-1" pass=true
"NodeFilter" node="worker-2" pass=true
"Feasible nodes" pod="default/log-test-2" nodes=["worker-1","worker-2"]
"Scoring nodes for pod" pod="default/log-test-2"
"NodeResourcesFit score" node="worker-1" score=75
"NodeResourcesFit score" node="worker-2" score=85
"Final score" node="worker-1" score=75
"Final score" node="worker-2" score=85
"Binding pod" pod="default/log-test-2" node="worker-2"  ← score cao hơn
"Scheduled pod" pod="default/log-test-2" node="worker-2"
```

> `worker-2` score=85 > `worker-1` score=75 → scheduler chọn `worker-2` (ít utilized hơn).

## Bước 6: Deploy pod Unschedulable — xem log fail

```bash
kubectl logs -n kube-system kube-scheduler-master --tail=0 -f > /tmp/scheduler3.log 2>&1 &

# Pod yêu cầu node không tồn tại
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: unschedulable-test
spec:
  nodeSelector:
    zone: x
  containers:
  - name: nginx
    image: nginx
EOF

sleep 5
kill %1 2>/dev/null
```

```bash
# Phân tích — tất cả node fail Filter
grep "unschedulable-test" /tmp/scheduler3.log | head -20
```

Log mẫu:
```
"Filtering nodes for pod" pod="default/unschedulable-test"
"NodeFilter" node="worker-1" pass=false reason="node(s) didn't match node selector"
"NodeFilter" node="worker-2" pass=false reason="node(s) didn't match node selector"
"Feasible nodes" pod="default/unschedulable-test" nodes=[]
"Failed to schedule pod" pod="default/unschedulable-test" reason="0/3 nodes are available: 2 node(s) didn't match node selector."
```

> 0 feasible node → pod Unschedulable. Scheduler log hiển thị lý do mỗi node fail.

```bash
# Verify pod Pending
kubectl get pod unschedulable-test
# NAME                READY   STATUS    RESTARTS   AGE
# unschedulable-test  0/1     Pending   0          10s

kubectl describe pod unschedulable-test | tail -5
# Events:
#   Warning  FailedScheduling  ...  0/3 nodes are available: 2 node(s) didn't match node selector.
```

## Bước 7: Dùng kubectl events để xem scheduling decision

```bash
# Event hiển thị scheduling decision (không cần v=5)
kubectl get events --sort-by='.lastTimestamp' | grep -E "(Scheduled|FailedScheduling)"

# LAST SEEN   TYPE      REASON              OBJECT                       MESSAGE
# 30s         Normal    Scheduled           pod/log-test                 Successfully assigned default/log-test to worker-1
# 20s         Normal    Scheduled           pod/log-test-2               Successfully assigned default/log-test-2 to worker-2
# 10s         Warning   FailedScheduling    pod/unschedulable-test       0/3 nodes are available: 2 node(s) didn't match node selector.
```

> `kubectl get events` hiển thị scheduling result — không cần scheduler log. Nhưng không thấy Filter/Score detail.

## Bước 8: Dùng scheduler metrics

```bash
# Scheduler expose metrics trên port 10259
kubectl get pod -n kube-system -l component=kube-scheduler -o wide
# NAME                    NODE
# kube-scheduler-master   master

# Port-forward
kubectl port-forward -n kube-system kube-scheduler-master 10259:10259 &
sleep 2

# Get metrics
curl -sk https://localhost:10259/metrics | grep -E "(scheduler_(queue|schedule|filter|score)|e2e_scheduling)" | head -20

# Kill port-forward
kill %1 2>/dev/null
```

Metrics mẫu:
```
# Scheduling latency
scheduler_e2e_scheduling_duration_seconds_bucket{le="1"} 42
# Queue latency
scheduler_queue_incoming_pods_total{queue="active"} 42
# Scheduling attempts
scheduler_schedule_attempts_total{result="scheduled"} 40
scheduler_schedule_attempts_total{result="unschedulable"} 2
```

> Metrics cho thấy scheduling latency, queue size, success/fail rate. Dùng Prometheus để monitor scheduler performance.

## Bước 9: Restore scheduler v=2

```bash
# Restore
sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml.bak /etc/kubernetes/manifests/kube-scheduler.yaml

# Đợi scheduler restart
kubectl wait --for=condition=Ready pod -n kube-system -l component=kube-scheduler --timeout=60s

# Verify
kubectl logs -n kube-system kube-scheduler-master --tail=3
# (ít log hơn — v=2 restored)
```

## Cleanup

```bash
kubectl delete pod log-test log-test-2 unschedulable-test
kubectl label nodes worker-1 zone- worker-2 zone-
rm -f /tmp/scheduler*.log
```

## Câu hỏi tự kiểm tra

1. Scheduler log v=2 vs v=5 khác nhau thế nào? Cần v nào để thấy Filter/Score?
2. Làm sao biết pod fail Filter vì lý do gì?
3. Scheduler log hiển thị score cho từng node như thế nào?
4. `kubectl get events` hiển thị gì về scheduling? Khác gì scheduler log?
5. Scheduler metrics cho biết gì? Làm sao truy cập?

## Đáp án tham khảo

1. v=2 chỉ log "Scheduled pod" (result). v=5 log chi tiết: Filter (pass/fail per node + reason), Score (score per node), Bind. Cần v=5+ để thấy Filter/Score decision.
2. Log v=5 hiển thị `NodeFilter node=worker-1 pass=false reason="..."`. Reason ví dụ: `didn't match node selector`, `insufficient CPU`, `had untolerated taint`. Hoặc `kubectl describe pod` → Events → `FailedScheduling` message.
3. Log v=5 hiển thị score cho từng plugin: `NodeResourcesFit score node=worker-1 score=75`. Final score = Σ(plugin_score × weight). Node có final score cao nhất được chọn.
4. `kubectl get events` hiển thị `Scheduled` (success) hoặc `FailedScheduling` (fail) với message ngắn. Scheduler log v=5 chi tiết hơn: Filter/Score per node, plugin name, score value. Events = summary, scheduler log = detail.
5. Scheduler metrics: scheduling latency, queue size, schedule attempts (scheduled/unschedulable/error), filter/score duration. Truy cập qua `https://<scheduler-ip>:10259/metrics` (port-forward hoặc direct). Dùng Prometheus + Grafana để monitor.
