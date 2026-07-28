# Exercise 05 — Kubelet Logs

> **Mục tiêu**: Xem kubelet log qua `journalctl -u kubelet`, tìm syncPod event, hiểu kubelet reconcile decision.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), SSH access vào worker node, `sudo` privilege

## Bối cảnh

Kubelet log chứa chi tiết pod lifecycle — syncPod, container create/start/stop, probe result. Bài này deploy pod, xem kubelet log, tìm syncPod event.

## Prerequisites

```bash
# SSH vào worker node
ssh worker-1

# Check kubelet running
sudo systemctl status kubelet
# Active: active (running)

# Check kubelet log (recent)
sudo journalctl -u kubelet --no-pager -n 10
# ... kubelet[1234]: I0101 00:00:00.000000 ... "SyncPod" pod="default/web"
```

## Bước 1: Deploy pod (trên master)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: log-test
  labels:
    app: log-test
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
# Verify pod scheduled on worker-1
kubectl get pod log-test -o wide
# NAME       READY   STATUS    NODE
# log-test   1/1     Running   worker-1
```

## Bước 2: Xem kubelet log — syncPod event (trên worker-1)

```bash
# SSH vào worker-1
ssh worker-1

# Find syncPod event for log-test pod
sudo journalctl -u kubelet --no-pager | grep "log-test" | head -30
```

Log mẫu:
```
I0101 00:00:01.123456 1234 kubelet.go:XXX] "SyncPod" pod="default/log-test"
I0101 00:00:01.123567 1234 kuberuntime_container.go:XXX] "createNewContainer" container="nginx"
I0101 00:00:01.123678 1234 kuberuntime_container.go:XXX] "PullImage" image="nginx:1.25"
I0101 00:00:03.456789 1234 kuberuntime_container.go:XXX] "CreateContainer" containerID="abc123"
I0101 00:00:03.456890 1234 kuberuntime_container.go:XXX] "StartContainer" containerID="abc123"
I0101 00:00:03.567890 1234 kubelet.go:XXX] "PodSyncResult" pod="default/log-test" result="success"
```

> Kubelet log hiển thị: SyncPod → PullImage → CreateContainer → StartContainer → PodSyncResult. Mỗi step có timestamp + containerID.

**Kiểm tra**: Log hiển thị `SyncPod` cho `log-test` pod, PullImage, CreateContainer, StartContainer.

## Bước 3: Xem chi tiết syncPod — increase verbosity

```bash
# Check current verbosity
cat /var/lib/kubelet/config.yaml | grep -i verbose
# (not set — default v=2)

# Temporarily increase to v=4
# Edit kubelet config or add --v=4 flag
sudo sed -i 's/^$/v: 4/' /var/lib/kubelet/config.yaml 2>/dev/null || \
  echo 'v: 4' | sudo tee -a /var/lib/kubelet/config.yaml

# Restart kubelet
sudo systemctl restart kubelet

# Wait for kubelet to be ready
sleep 5
sudo systemctl is-active kubelet
# active
```

```bash
# Deploy another pod
# (trên master)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: log-test-v4
spec:
  containers:
  - name: nginx
    image: nginx:1.26
EOF

# (trên worker-1) — check log with v=4
sudo journalctl -u kubelet --no-pager -n 50 | grep "log-test-v4"
```

Log mẫu (v=4):
```
I0101 00:00:10.111111 1234 kubelet.go:XXX] "SyncPod" pod="default/log-test-v4" syncType="sync"
I0101 00:00:10.111222 1234 kuberuntime_manager.go:XXX] "InspectPod" pod="default/log-test-v4"
I0101 00:00:10.111333 1234 kuberuntime_container.go:XXX] "computePodActions" pod="default/log-test-v4" actions=["CreateContainer"]
I0101 00:00:10.111444 1234 kuberuntime_container.go:XXX] "createNewContainer" container="nginx" image="nginx:1.26"
I0101 00:00:10.111555 1234 kuberuntime_container.go:XXX] "generateContainerConfig" container="nginx"
I0101 00:00:10.111666 1234 remote_image.go:XXX] "PullImage" image="nginx:1.26" provider="containerd"
I0101 00:00:12.333444 1234 remote_image.go:XXX] "PullImage success" image="nginx:1.26" imageID="sha256:xxx"
I0101 00:00:12.333555 1234 kuberuntime_container.go:XXX] "CreateContainer" container="nginx" containerID="abc456"
I0101 00:00:12.333666 1234 kuberuntime_container.go:XXX] "StartContainer" containerID="abc456"
I0101 00:00:12.444555 1234 kubelet.go:XXX] "PodSyncResult" pod="default/log-test-v4" result="success"
```

> v=4 hiển thị chi tiết hơn: `computePodActions` (decide what to do), `generateContainerConfig` (spec from pod), `PullImage success` (imageID). v=2 chỉ log SyncPod + result.

**Kiểm tra**: v=4 log chi tiết hơn — `computePodActions`, `generateContainerConfig`, `PullImage success`.

## Bước 4: Xem PLEG event

```bash
# PLEG = Pod Lifecycle Event Generator — check container status every 1s
sudo journalctl -u kubelet --no-pager | grep -i "pleg" | tail -10
```

Log mẫu:
```
I0101 00:00:00.000000 1234 pleq.go:XXX] "pleg" event={"ID":"abc123","Type":"ContainerStarted","Data":"abc456"}
I0101 00:00:01.000000 1234 pleq.go:XXX] "pleg" event={"ID":"abc123","Type":"ContainerRunning","Data":"abc456"}
```

> PLEG poll container status mỗi 1s. Container start → PLEG generate event → SyncLoop process → update pod status.

## Bước 5: Xem probe result log

```bash
# (trên master) — deploy pod with probe
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: probe-log
spec:
  containers:
  - name: nginx
    image: nginx
    livenessProbe:
      httpGet:
        path: /
        port: 80
      periodSeconds: 5
EOF
```

```bash
# (trên worker-1) — check probe log
sudo journalctl -u kubelet --no-pager | grep "probe-log" | grep -i probe | tail -10
```

Log mẫu:
```
I0101 00:00:05.000000 1234 prober.go:XXX] "Probe" pod="default/probe-log" container="nginx" probe="liveness" result="success"
I0101 00:00:10.000000 1234 prober.go:XXX] "Probe" pod="default/probe-log" container="nginx" probe="liveness" result="success"
I0101 00:00:15.000000 1234 prober.go:XXX] "Probe" pod="default/probe-log" container="nginx" probe="liveness" result="success"
```

> Kubelet log probe result mỗi `periodSeconds`. `result="success"` = probe pass. `result="failure"` = probe fail → restart.

## Bước 6: Xem container kill log

```bash
# (trên master) — delete pod
kubectl delete pod log-test

# (trên worker-1) — check kill log
sudo journalctl -u kubelet --no-pager | grep "log-test" | grep -iE "(kill|stop|remove)" | tail -10
```

Log mẫu:
```
I0101 00:00:20.000000 1234 kuberuntime_container.go:XXX] "KillContainer" pod="default/log-test" container="nginx"
I0101 00:00:20.111111 1234 kuberuntime_container.go:XXX] "StopContainer" containerID="abc123" timeout=30
I0101 00:00:25.222222 1234 kuberuntime_sandbox.go:XXX] "StopPodSandbox" pod="default/log-test" sandboxID="xyz789"
I0101 00:00:25.333333 1234 kuberuntime_sandbox.go:XXX] "RemovePodSandbox" sandboxID="xyz789"
```

> Kill log: KillContainer → StopContainer (grace period) → StopPodSandbox → RemovePodSandbox. Container kill trước, sandbox destroy sau.

## Bước 7: Restore verbosity to v=2

```bash
# (trên worker-1)
sudo sed -i '/^v: 4$/d' /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
sleep 5
sudo systemctl is-active kubelet
# active
```

## Bước 8: Kubelet metrics

```bash
# Kubelet expose metrics on port 10250 (HTTPS, auth)
# hoặc 10255 (read-only, if enabled)

# Port-forward (trên master)
kubectl port-forward -n kube-system pod/kube-proxy-xxx 10250:10250 &

# Get metrics
curl -sk https://localhost:10250/metrics | grep -E "(kubelet_|container_" | head -20

# Kill port-forward
kill %1 2>/dev/null
```

Metrics mẫu:
```
# PLEG duration
kubelet_pleg_relist_duration_seconds_bucket{le="0.01"} 60
# Container start time
kubelet_container_start_time_seconds{container="nginx"} 1735689600
# Running pods
kubelet_running_pods 15
```

## Cleanup

```bash
# (trên master)
kubectl delete pod log-test log-test-v4 probe-log 2>/dev/null
```

## Câu hỏi tự kiểm tra

1. `journalctl -u kubelet` hiển thị gì? Làm sao tìm event cho pod cụ thể?
2. SyncPod log hiển thị những step nào? Thứ tự?
3. PLEG là gì? Nó chạy bao lâu một lần?
4. v=2 vs v=4 — khác nhau thế nào? Khi nào cần v=4?
5. Container kill log hiển thị những step nào? StopContainer vs StopPodSandbox khác nhau?

## Đáp án tham khảo

1. `journalctl -u kubelet` hiển thị kubelet log — SyncPod, container create/start/stop, probe result, PLEG event. Tìm pod cụ thể: `journalctl -u kubelet | grep "<pod-name>"`. Tìm event type: `journalctl -u kubelet | grep -i "syncPod"`.
2. SyncPod → computePodActions (decide what to do) → PullImage (if not cached) → CreateContainer (spec from pod) → StartContainer → PodSyncResult. Thứ tự: decide → pull → create → start → result.
3. PLEG = Pod Lifecycle Event Generator. Poll container status (CRI: ListContainers) mỗi **1s**. Compare with cached status → generate event if changed. SyncLoop process event → syncPod. PLEG detect container crash → trigger restart.
4. v=2 = default, log SyncPod + result (minimal). v=4 = log chi tiết: computePodActions, generateContainerConfig, PullImage success, probe result. Cần v=4 khi debug: pod stuck, container not creating, probe fail without restart.
5. KillContainer (decision) → StopContainer (send SIGTERM, wait grace period) → StopPodSandbox (stop network namespace) → RemovePodSandbox (cleanup). StopContainer = stop container process. StopPodSandbox = stop network namespace + CNI cleanup. Container stop trước, sandbox stop sau.
