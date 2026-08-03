# Phase 11 — CoreDNS

> Hiểu DNS resolution trong Kubernetes — pod tìm Service bằng tên (`my-svc.my-namespace.svc.cluster.local`) hoạt động thế nào.
>
> **Mục tiêu**: Giải thích được flow: pod curl `my-svc` → resolv.conf → CoreDNS → kubernetes plugin → API Server → Service ClusterIP. Phân biệt Service vs Headless Service DNS response. Sửa được CoreDNS ConfigMap thêm plugin.

## Cấu trúc thư mục

```
phase-11-coredns/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-dns-resolution.md
│   ├── 02-service-discovery.md
│   ├── 03-dns-records.md
│   ├── 04-coredns-plugins.md
│   └── 05-dns-policy.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-basic-dns-resolution.md
│   ├── 02-headless-service-dns.md
│   ├── 03-coredns-configmap.md
│   ├── 04-dns-policy.md
│   └── 05-coredns-troubleshooting.md
└── scripts/                   # Helper scripts
    ├── coredns-ops.sh
    ├── dns-debug.sh
    └── coredns-examples.yaml
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — DNS Resolution: Pod inherit `/etc/resolv.conf` từ kubelet (`--cluster-dns`), nameserver = CoreDNS ClusterIP, search domain chain, ndots:5, resolv.conf anatomy
- [ ] 02 — Service Discovery: A/AAAA record (ClusterIP), Headless Service (pod IP directly), StatefulSet pod DNS, SRV record cho named port
- [ ] 03 — DNS Records: A record (Service → ClusterIP), AAAA record (IPv6), SRV record (port discovery), PTR record (reverse lookup), pod DNS format
- [ ] 04 — CoreDNS Plugins: `kubernetes` plugin (watch API → serve DNS), `forward` (upstream), `cache`, `rewrite`, `hosts`, `health`, `ready`, `log`, `errors` — plugin chain flow
- [ ] 05 — DNS Policy: `ClusterFirst` (default), `ClusterFirstWithHostNet`, `Default` (node DNS), `None` (custom dnsConfig) — khi nào dùng cái nào

### Thực hành (exercises/)

- [ ] 01 — Deploy pod, `nslookup kubernetes.default.svc.cluster.local` thấy API Server ClusterIP, đọc `/etc/resolv.conf`, trace query đến CoreDNS
- [ ] 02 — Tạo Headless Service (`clusterIP: None`), `nslookup` thấy pod IP thay vì ClusterIP, so sánh response với normal Service
- [ ] 03 — Sửa CoreDNS ConfigMap thêm `rewrite` rule + `hosts` entry, restart CoreDNS pod, test custom DNS resolution
- [ ] 04 — Deploy pod với `dnsPolicy: ClusterFirst` vs `Default` vs `None` (custom dnsConfig), so sánh `/etc/resolv.conf` từng loại
- [ ] 05 — Debug DNS: pod không resolve được Service, dùng `dig` + `tcpdump` + CoreDNS log trace root cause

### Checkpoint hoàn thành phase

- [ ] Giải thích được flow: pod curl `my-svc` → resolv.conf → CoreDNS → kubernetes plugin → API Server → Service ClusterIP
- [ ] Phân biệt được Service vs Headless Service DNS response
- [ ] Sửa được CoreDNS ConfigMap thêm plugin

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên VM
- Packages: `dnsutils` (`dig`, `nslookup`), `tcpdump`, `jq`, `kubectl`
- Đã hoàn thành Phase 10 (kube-proxy — Service ClusterIP hoạt động)
- CoreDNS running trong `kube-system` namespace
