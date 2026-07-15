# Kubernetes The Hard Way 2026

Hành trình học Kubernetes từ bên trong — từ Linux kernel đến cluster production.

## Cấu trúc repo

```
k8s-the-hard-way-2026/
├── README.md                              # File này
├── kubernetes-the-hard-way-2026-learning-plan.md  # Lộ trình tổng quan
├── phases/                                # Mỗi phase một thư mục
│   ├── phase-00-linux-foundation/
│   ├── phase-01-container-runtime/
│   ├── phase-02-pki-certificates/
│   ├── phase-03-etcd/
│   ├── phase-04-api-server/
│   ├── phase-05-scheduler/
│   ├── phase-06-controller-manager/
│   ├── phase-07-kubelet/
│   ├── phase-08-cri/
│   ├── phase-09-cni/
│   ├── phase-10-kube-proxy/
│   ├── phase-11-coredns/
│   ├── phase-12-ingress/
│   ├── phase-13-storage/
│   ├── phase-14-observability/
│   ├── phase-15-ebpf/
│   └── phase-16-kubernetes-distributions/
├── capstone/                              # Dự án tổng hợp
└── resources/                             # Cheatsheets, tài liệu tham khảo
```

## Cách sử dụng

1. Đọc `kubernetes-the-hard-way-2026-learning-plan.md` để xem lộ trình tổng quan.
2. Mỗi phase có file `README.md` liệt kê chủ đề cần học.
3. Ghi chú, bài tập, scripts đặt trong thư mục con của phase tương ứng.
4. Capstone là dự án tổng hợp áp dụng tất cả kiến thức.

## Tiến độ

Đánh dấu phase đã hoàn thành bằng cách cập nhật checkbox trong file plan hoặc README của từng phase.
