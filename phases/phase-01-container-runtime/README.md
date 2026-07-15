# Phase 1 — Container Runtime

> Hiểu container runtime stack từ dưới lên: OCI runtime (runc) → high-level runtime (containerd) → CRI interface.
>
> **Mục tiêu**: Biết `docker run` thực sự gọi gì bên dưới. Tạo được container bằng `runc` từ OCI bundle thủ công. Giải thích được khác biệt `ctr` vs `crictl` vs `docker`.

## Cấu trúc thư mục

```
phase-01-container-runtime/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-oci-spec.md
│   ├── 02-runc.md
│   ├── 03-containerd.md
│   ├── 04-cri.md
│   ├── 05-crictl.md
│   └── 06-ctr.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-oci-bundle-runc.md
│   ├── 02-containerd-ctr.md
│   ├── 03-crictl-debug.md
│   ├── 04-ctr-vs-crictl.md
│   └── 05-kill-shim.md
└── scripts/                   # Helper scripts
    ├── create-oci-bundle.sh
    └── minimal-config.json
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — OCI Spec: Runtime Spec (config.json, rootfs, namespaces) + Image Spec (manifest, layer, config)
- [ ] 02 — runc: CLI trực tiếp tạo container từ OCI bundle, create/start/exec
- [ ] 03 — containerd: daemon, image pull/push, snapshot, containerd-shim
- [ ] 04 — CRI: gRPC interface giữa kubelet và runtime, RuntimeService + ImageService
- [ ] 05 — crictl: CLI giao tiếp CRI runtime, xem pod/container/image/log
- [ ] 06 — ctr: CLI trực tiếp containerd, debug không qua CRI

### Thực hành (exercises/)

- [ ] 01 — Tạo OCI bundle bằng tay, chạy `runc run`
- [ ] 02 — Cài containerd, dùng `ctr` pull nginx, run, exec
- [ ] 03 — Dùng `crictl` kết nối CRI socket, list pod/container/image
- [ ] 04 — So sánh `ctr run` vs `crictl runp` — hiểu khác biệt layer
- [ ] 05 — Kill `containerd-shim`, quan sát container bị ảnh hưởng

### Checkpoint hoàn thành phase

- [ ] Vẽ được stack: kubelet → CRI gRPC → containerd → containerd-shim → runc → kernel
- [ ] Tạo được container bằng `runc` từ OCI bundle thủ công
- [ ] Giải thích được khác biệt `ctr` vs `crictl` vs `docker`
- [ ] Pull image bằng `ctr`, xem image layer unpack vào snapshotter

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+)
- Root access (sudo)
- Packages: `containerd`, `runc`, `cri-tools` (crictl), `jq` (đọc JSON)
- Đã hoàn thành Phase 0 (hiểu namespaces, cgroups, overlayfs)
