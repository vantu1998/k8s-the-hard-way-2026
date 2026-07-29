# Phase 10 — kube-proxy

> Hiểu Service abstraction — cách Kubernetes load balance traffic đến pod, và kube-proxy implement bằng iptables/IPVS/eBPF.
>
> **Mục tiêu**: Đọc được iptables rule cho một Service, hiểu flow DNAT. Giải thích khác biệt iptables vs IPVS vs eBPF mode. Trace được packet: curl ClusterIP → iptables DNAT → pod IP.

## Cấu trúc thư mục

```
phase-10-kube-proxy/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-service-abstraction.md
│   ├── 02-clusterip-nodeport.md
│   ├── 03-iptables-mode.md
│   ├── 04-ipvs-mode.md
│   └── 05-ebpf-replacement.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-iptables-rules.md
│   ├── 02-load-balance.md
│   ├── 03-nodeport.md
│   ├── 04-ipvs-mode.md
│   └── 05-ebpf-replacement.md
└── scripts/                   # Helper scripts
    ├── kube-proxy-ops.sh
    ├── ipvs-inspect.sh
    └── kube-proxy-examples.yaml
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — Service Abstraction: Service = stable IP + DNS, không tồn tại trong network (iptables rule), EndpointSlice track pod IP, Service type (ClusterIP, NodePort, LoadBalancer, ExternalName), selector + label
- [ ] 02 — ClusterIP & NodePort: ClusterIP = virtual IP DNAT → pod IP, NodePort = port trên mọi node (30000-32767), LoadBalancer = cloud external IP → NodePort, MetalLB bare metal, hairpin
- [ ] 03 — iptables Mode: KUBE-SERVICES chain, KUBE-SVC-<hash> per Service, KUBE-SEP-<hash> per endpoint, DNAT, random probability load balance, O(n) rule, conntrack
- [ ] 04 — IPVS Mode: IPVS kernel module, load balancing algorithm (rr/wrr/lc/sh), virtual server + real server, ipvsadm, faster than iptables for many Services
- [ ] 05 — eBPF Proxy Replacement: Cilium thay kube-proxy bằng eBPF at socket layer, bypass iptables, no conntrack, faster, `kubeProxyReplacement=true`

### Thực hành (exercises/)

- [ ] 01 — Tạo Service ClusterIP + 3 pod, `iptables-save | grep KUBE-SVC` xem rule DNAT, đọc iptables chain
- [ ] 02 — Curl ClusterIP nhiều lần, quan sát traffic chia đều ra 3 pod (xem access log), verify random probability
- [ ] 03 — Tạo NodePort, curl từ ngoài node, trace iptables rule DNAT (KUBE-NODEPORTS → KUBE-SVC → KUBE-SEP)
- [ ] 04 — Chuyển kube-proxy sang IPVS mode, `ipvsadm -L -n` xem virtual server + real server, compare with iptables
- [ ] 05 — Cài Cilium với kube-proxy replacement, `kubectl -n kube-system delete ds kube-proxy`, test Service vẫn hoạt động

### Checkpoint hoàn thành phase

- [ ] Đọc được iptables rule cho một Service, hiểu flow DNAT
- [ ] Giải thích được khác biệt iptables vs IPVS vs eBPF mode
- [ ] Trace được packet: curl ClusterIP → iptables DNAT → pod IP

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên VM
- Packages: `iptables`, `ipvsadm`, `tcpdump`, `jq`, `kubectl`
- Đã hoàn thành Phase 9 (CNI — pod network running, pod-to-pod connectivity)
- kube-proxy running (iptables or IPVS mode)
