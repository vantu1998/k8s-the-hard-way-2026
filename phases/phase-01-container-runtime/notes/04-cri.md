# 04 — CRI (Container Runtime Interface)

## CRI là gì

CRI là **gRPC interface** giữa kubelet và container runtime. Kubelet không biết runtime là containerd hay CRI-O hay Docker — nó chỉ biết CRI interface.

```
kubelet
  │
  ├── gRPC (CRI proto)
  │
  ▼
containerd (CRI plugin)  /  CRI-O  /  Docker (via cri-dockerd)
```

## Tại sao cần CRI

Trước CRI, kubelet code trực tiếp với Docker API. Nếu thêm runtime mới (rkt, containerd, CRI-O) → phải sửa kubelet code. CRI tách interface:

- Kubelet → CRI gRPC → bất kỳ runtime nào implement CRI.
- Runtime implement CRI plugin → plug-and-play.

## CRI Proto — 2 service

### RuntimeService

Quản lý pod sandbox + container lifecycle:

```protobuf
service RuntimeService {
  // Pod sandbox
  rpc RunPodSandbox(RunPodSandboxRequest) returns (RunPodSandboxResponse);
  rpc StopPodSandbox(StopPodSandboxRequest) returns (StopPodSandboxResponse);
  rpc RemovePodSandbox(RemovePodSandboxRequest) returns (RemovePodSandboxResponse);
  rpc ListPodSandbox(ListPodSandboxRequest) returns (ListPodSandboxResponse);
  rpc PodSandboxStatus(PodSandboxStatusRequest) returns (PodSandboxStatusResponse);

  // Container
  rpc CreateContainer(CreateContainerRequest) returns (CreateContainerResponse);
  rpc StartContainer(StartContainerRequest) returns (StartContainerResponse);
  rpc StopContainer(StopContainerRequest) returns (StopContainerResponse);
  rpc RemoveContainer(RemoveContainerRequest) returns (RemoveContainerResponse);
  rpc ListContainers(ListContainersRequest) returns (ListContainersResponse);
  rpc ContainerStatus(ContainerStatusRequest) returns (ContainerStatusResponse);

  // Exec / attach
  rpc Exec(ExecRequest) returns (ExecResponse);
  rpc Attach(AttachRequest) returns (AttachResponse);

  // Logs
  rpc ContainerStats(ContainerStatsRequest) returns (ContainerStatsResponse);
  rpc ListContainerStats(ListContainerStatsRequest) returns (ListContainerStatsResponse);
}
```

### ImageService

Quản lý image:

```protobuf
service ImageService {
  rpc ListImages(ListImagesRequest) returns (ListImagesResponse);
  rpc ImageStatus(ImageStatusRequest) returns (ImageStatusResponse);
  rpc PullImage(PullImageRequest) returns (PullImageResponse);
  rpc RemoveImage(RemoveImageRequest) returns (RemoveImageResponse);
  rpc ImageFsInfo(ImageFsInfoRequest) returns (ImageFsInfoResponse);
}
```

## Pod Sandbox — khái niệm quan trọng

Pod sandbox = **network namespace + infrastructure container** cho pod. Tất cả container trong pod chia sẻ sandbox này.

```
Pod (sandbox = netns + pause container)
├── Container A (app)     ← dùng netns của sandbox
├── Container B (sidecar) ← dùng netns của sandbox
└── Container C (init)    ← dùng netns của sandbox
```

### Pause container

Sandbox được đại diện bởi **pause container** — image `registry.k8s.io/pause:3.9`. Pause container chỉ `pause()` syscall — không làm gì, chỉ giữ netns sống.

```
Tại sao cần pause container?
- Nếu container A chết → netns vẫn sống (pause giữ)
- Container B vẫn giao tiếp được
- Kubelet restart container A → rejoin netns cũ
```

## Flow: kubelet tạo pod qua CRI

```
1. kubelet nhận Pod object từ API Server

2. RunPodSandbox(podSandboxConfig)
   → containerd tạo network namespace
   → containerd gọi CNI plugin gán IP, veth, route
   → containerd tạo pause container (runc)
   → trả về sandboxID

3. For each container in pod:
   a. PullImage(image)
      → containerd pull image từ registry
      → unpack layers → rootfs

   b. CreateContainer(sandboxID, containerConfig)
      → containerd tạo OCI bundle (config.json + rootfs)
      → runc create (created state)
      → trả về containerID

   c. StartContainer(containerID)
      → runc start
      → container chạy

4. ContainerStatus(containerID)
   → kubelet poll status
   → report lên API Server
```

## CRI socket

```bash
# containerd CRI socket
ls -la /run/containerd/containerd.sock

# CRI-O socket
ls -la /var/run/crio/crio.sock

# Docker (via cri-dockerd)
ls -la /var/run/cri-dockerd.sock

# Kubelet config
cat /etc/kubernetes/kubelet.yaml | grep runtimeEndpoint
# runtimeEndpoint: unix:///run/containerd/containerd.sock
```

## CRI version

```bash
# Kiểm tra CRI version
crictl info | jq .config
# {
#   "containerd": {
#     "snapshotter": "overlayfs",
#     "defaultRuntime": "runc",
#     "runtimes": {
#       "runc": {
#         "runtimeType": "io.containerd.runc.v2"
#       }
#     }
#   }
# }
```

## Liên hệ với Kubernetes

### Debug CRI

```bash
# Xem runtime info
crictl info

# Xem CRI version
crictl version

# Test CRI connection
crictl --runtime-endpoint unix:///run/containerd/containerd.sock pods
```

### Khi kubelet không kết nối được CRI

```bash
# Lỗi phổ biến:
# "Failed to connect to CRI" → socket sai hoặc containerd chưa chạy

# Debug:
sudo systemctl status containerd
ls -la /run/containerd/containerd.sock
journalctl -u kubelet | grep -i cri
```

### CRI và container runtime thay thế

| Runtime | CRI Implementation | Đặc điểm |
|---------|-------------------|----------|
| containerd | Built-in CRI plugin | Mặc định K8s |
| CRI-O | Built-in | Red Hat, tối ưu cho K8s |
| Docker | cri-dockerd (shim) | Deprecated từ K8s 1.24 |
| gVisor (runsc) | Qua containerd | Security — sandbox VM |
| Kata Containers | Qua containerd | VM-per-container |
