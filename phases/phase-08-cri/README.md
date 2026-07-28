# Phase 8 — Container Runtime Interface (CRI)

> Hiểu chi tiết giao tiếp giữa kubelet và container runtime qua CRI gRPC — từ Pod sandbox đến container start.
>
> **Mục tiêu**: Giải thích được Pod Sandbox và tại sao container trong pod share network, dùng `crictl` inspect sandbox + container, mô tả flow kubelet → CRI gRPC → containerd → runc.

## Cấu trúc thư mục

```
phase-08-cri/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-cri-architecture.md
│   ├── 02-kubelet-containerd.md
│   ├── 03-image-management.md
│   └── 04-pod-sandbox.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-configure-containerd.md
│   ├── 02-crictl-inspect.md
│   ├── 03-pull-image.md
│   ├── 04-multi-container.md
│   └── 05-strace-cri.md
└── scripts/                   # Helper scripts
    ├── crictl-ops.sh
    ├── containerd-config.toml
    └── cri-examples.yaml
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — CRI Architecture: CRI gRPC interface, RuntimeService + ImageService, Unix socket, kubelet không biết runtime là gì, containerd vs CRI-O vs docker-shim
- [ ] 02 — kubelet ↔ containerd: RunPodSandbox → CNI setup, CreateContainer → spec from pod, StartContainer → runc, containerd architecture (containerd-shim, runc, OCI runtime)
- [ ] 03 — Image Management: PullImage, ListImages, ImageStatus, image pull policy (Always/IfNotPresent/Never), image GC, image store layout
- [ ] 04 — Pod Sandbox: sandbox = network namespace + IPC namespace, container share sandbox, sandbox lifecycle, sandbox ID vs container ID, crictl inspect sandbox

### Thực hành (exercises/)

- [ ] 01 — Cấu hình kubelet dùng containerd (`--container-runtime-endpoint`), verify CRI connection
- [ ] 02 — Deploy pod 2 container share volume, quan sát sandbox + 2 container trong `crictl ps`, `crictl inspect` sandbox
- [ ] 03 — Pull image thủ công bằng `crictl pull`, deploy pod với `imagePullPolicy: Never`, quan sát dùng image local
- [ ] 04 — `crictl inspect <sandbox-id>` — xem network namespace, cgroup path, veth interface
- [ ] 05 — Strace kubelet khi tạo pod, tìm gRPC call đến containerd socket

### Checkpoint hoàn thành phase

- [ ] Giải thích được Pod Sandbox là gì và tại sao container trong pod share network
- [ ] Dùng `crictl` inspect được sandbox + container
- [ ] Mô tả được flow: kubelet → CRI gRPC → containerd → runc

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên VM
- Packages: `containerd`, `crictl`, `strace`, `jq`, `kubectl`
- Đã hoàn thành Phase 7 (Kubelet đang chạy, node Ready)
