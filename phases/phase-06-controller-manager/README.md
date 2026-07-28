# Phase 6 — Controller Manager

> Hiểu controller pattern (watch + reconcile loop) — nguyên lý cốt lõi của Kubernetes. Nắm được từng controller chính làm gì.
>
> **Mục tiêu**: Giải thích được reconcile loop bằng ví dụ Deployment → ReplicaSet → Pod. Quan sát được rolling update tạo 2 ReplicaSet. Viết được simple controller watch + react.

## Cấu trúc thư mục

```
phase-06-controller-manager/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-controller-pattern.md
│   ├── 02-replicaset-controller.md
│   ├── 03-deployment-controller.md
│   ├── 04-node-controller.md
│   ├── 05-job-cronjob-controller.md
│   └── 06-namespace-controller.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-scale-replicaset.md
│   ├── 02-rolling-update.md
│   ├── 03-rollback.md
│   ├── 04-cordon-drain.md
│   ├── 05-job-parallelism.md
│   └── 06-simple-controller.md
└── scripts/                   # Helper scripts
    ├── run-controller-manager.sh
    ├── watch-reconcile.py
    └── controller-examples.yaml
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — Controller Pattern: Watch + reconcile loop, desired vs actual state, idempotent, level-triggered vs edge-triggered, informer pattern
- [ ] 02 — ReplicaSet Controller: Đảm bảo số replica, scale up/down, selector matching, pod adoption, deletion policy
- [ ] 03 — Deployment Controller: Rolling update strategy, ReplicaSet management, maxSurge/maxUnavailable, rollback
- [ ] 04 — Node Controller: Watch node status, heartbeat timeout, mark NotReady, evict pod sau pod-eviction-timeout, podCIDR allocation
- [ ] 05 — Job/CronJob Controller: Job completions/parallelism/backoffLimit, CronJob schedule, Job history, suspended job
- [ ] 06 — Namespace Controller: Finalizer pattern, delete resource trong namespace, deletion ordering, resource quota

### Thực hành (exercises/)

- [ ] 01 — Scale Deployment từ 1 → 5, xem ReplicaSet controller tạo pod từng cái trong event log
- [ ] 02 — Rolling update image, quan sát 2 ReplicaSet (cũ + mới) cùng tồn tại, pod thay đổi dần
- [ ] 03 — Rollback rollout, quan sát ReplicaSet cũ scale lên lại
- [ ] 04 — Cordon + drain node, quan sát Node controller + DaemonSet controller behavior
- [ ] 05 — Tạo Job với `completions: 5`, `parallelism: 2`, quan sát pod chạy 2 cái lúc
- [ ] 06 — Viết một simple controller bằng Python (watch ConfigMap, tạo file) — hiểu reconcile loop bằng tay

### Checkpoint hoàn thành phase

- [ ] Giải thích được reconcile loop bằng ví dụ Deployment → ReplicaSet → Pod
- [ ] Quan sát được rolling update tạo 2 ReplicaSet
- [ ] Viết được simple controller watch + react

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên VM
- Packages: `jq`, `curl`, `kubectl`, `python3`
- Đã hoàn thành Phase 4 (API Server đang chạy, cluster hoạt động)
- Cluster có ít nhất 2 worker node (cho cordon/drain exercise)
