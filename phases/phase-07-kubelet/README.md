# Phase 7 — Kubelet

> Hiểu kubelet — agent trên mỗi node quản lý pod lifecycle từ API Server đến container runtime.
>
> **Mục tiêu**: Chạy được static pod, join node bằng TLS bootstrap, giải thích được SyncLoop và graceful shutdown, cấu hình được liveness/readiness/startup probe.

## Cấu trúc thư mục

```
phase-07-kubelet/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-node-registration.md
│   ├── 02-tls-bootstrap.md
│   ├── 03-pod-lifecycle.md
│   ├── 04-static-pods.md
│   └── 05-health-checking.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-static-pod.md
│   ├── 02-tls-bootstrap.md
│   ├── 03-liveness-probe.md
│   ├── 04-graceful-shutdown.md
│   └── 05-kubelet-logs.md
└── scripts/                   # Helper scripts
    ├── run-kubelet.sh
    ├── bootstrap-token.sh
    └── kubelet-examples.yaml
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — Node Registration: Kubelet register node, heartbeat (Lease + status), capacity/allocatable, conditions, node status update
- [ ] 02 — TLS Bootstrap: Bootstrap token, CSR, API Server ký cert, kubelet nhận cert, cert rotation, kubelet.conf bootstrap
- [ ] 03 — Pod Lifecycle: SyncLoop, syncPod, CRI call chain, pod update, container start/stop, graceful shutdown, preStop hook, terminationGracePeriodSeconds
- [ ] 04 — Static Pods: Manifest trong /etc/kubernetes/manifests/, kubelet watch dir, chạy pod không qua API Server, mirror pod, control plane as static pod
- [ ] 05 — Health Checking: Liveness probe (restart), Readiness probe (remove from Service), Startup probe (initial only), probe type (HTTP/TCP/exec), probe timing

### Thực hành (exercises/)

- [ ] 01 — Chạy kubelet standalone, tạo pod manifest YAML, đặt vào /etc/kubernetes/manifests/, quan sát kubelet chạy pod
- [ ] 02 — Join worker node vào cluster bằng TLS bootstrap token, xem CSR trong kubectl get csr
- [ ] 03 — Deploy pod với liveness probe HTTP, kill endpoint, quan sát container restart
- [ ] 04 — Deploy pod với preStop hook + terminationGracePeriodSeconds: 60, delete pod, quan sát graceful shutdown
- [ ] 05 — Xem kubelet log: journalctl -u kubelet, tìm syncPod event

### Checkpoint hoàn thành phase

- [ ] Chạy được static pod bằng manifest trong /etc/kubernetes/manifests/
- [ ] Join node bằng TLS bootstrap, CSR được approve
- [ ] Giải thích được SyncLoop và graceful shutdown flow
- [ ] Cấu hình được liveness/readiness/startup probe

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên VM
- Packages: `jq`, `curl`, `kubectl`, `containerd` (hoặc `cri-o`)
- Đã hoàn thành Phase 4 (API Server đang chạy, cluster hoạt động)
- Đã hoàn thành Phase 6 (Controller Manager đang chạy, node controller active)
