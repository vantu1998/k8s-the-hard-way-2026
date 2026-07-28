# Phase 5 — Scheduler

> Hiểu scheduler quyết định pod chạy trên node nào, và biết can thiệp scheduling bằng affinity/taint/toleration/priority.
>
> **Mục tiêu**: Giải thích được 2 phase Filter + Score. Dùng được nodeAffinity, podAntiAffinity, taint/toleration, priority/preemption. Đọc được scheduler log biết pod bị schedule lên node nào, tại sao.

## Cấu trúc thư mục

```
phase-05-scheduler/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-scheduling-process.md
│   ├── 02-scheduling-algorithms.md
│   ├── 03-node-selection.md
│   ├── 04-affinity-anti-affinity.md
│   ├── 05-taints-tolerations.md
│   └── 06-priority-preemption.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-node-affinity.md
│   ├── 02-taints-tolerations.md
│   ├── 03-priority-preemption.md
│   ├── 04-pod-anti-affinity.md
│   └── 05-scheduler-logs.md
└── scripts/                   # Helper scripts
    ├── run-scheduler.sh
    ├── setup-lab-nodes.sh
    └── scheduling-examples.yaml
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — Scheduling Process: Scheduler architecture, watch pending pod, 2 phase Filter + Score, bind pod → node
- [ ] 02 — Scheduling Algorithms: Filter plugins (PodFitsResources, PodFitsHostPorts, MatchNodeSelector...), Score plugins (LeastRequestedPriority, BalancedResourceAllocation...), Scheduling Framework
- [ ] 03 — Node Selection: `nodeSelector` (label đơn giản), `nodeAffinity` (required/preferred, operator In/NotIn/Exists)
- [ ] 04 — Pod Affinity/Anti-Affinity: Co-locate pod (affinity) hoặc tách node (anti-affinity), topology spread, use case replica spread
- [ ] 05 — Taints & Tolerations: `NoSchedule`, `NoExecute`, `PreferNoSchedule`, taint node đuổi pod, toleration chịu taint, dedicated node
- [ ] 06 — Priority & Preemption: PriorityClass, high priority pod evict low priority pod, preemption chọn victim, graceful termination

### Thực hành (exercises/)

- [ ] 01 — Tạo 3 node với label khác nhau (`zone=a`, `zone=b`, `zone=c`), deploy pod với `nodeAffinity` preferred, quan sát distribution
- [ ] 02 — Taint 1 node `NoSchedule`, deploy pod không có toleration, quan sát pod không schedule lên node đó
- [ ] 03 — Tạo PriorityClass high/low, deploy high priority pod khi node full, quan sát preemption
- [ ] 04 — Deploy pod với podAntiAffinity, quan sát replica spread đều ra các node
- [ ] 05 — Xem scheduler log: `kubectl logs -n kube-system kube-scheduler-<node>`, tìm decision log

### Checkpoint hoàn thành phase

- [ ] Giải thích được 2 phase Filter + Score
- [ ] Dùng được nodeAffinity, podAntiAffinity, taint/toleration, priority/preemption
- [ ] Đọc được scheduler log biết pod bị schedule lên node nào, tại sao

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên VM
- Packages: `jq`, `curl`, `kubectl`
- Đã hoàn thành Phase 4 (API Server đang chạy, cluster hoạt động)
- Cluster có ít nhất 2 worker node (hoặc dùng minikube/multipass multi-node)
