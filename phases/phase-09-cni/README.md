# Phase 9 — CNI (Container Network Interface)

> Hiểu cách pod nhận IP, giao tiếp network, và network policy kiểm soát traffic. Nắm được CNI plugin chạy gì khi pod start.
>
> **Mục tiêu**: Giải thích flow pod start → CNI ADD → veth + IP + route, tạo NetworkPolicy default deny + allow, trace packet path giữa 2 pod khác node.

## Cấu trúc thư mục

```
phase-09-cni/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-cni-specification.md
│   ├── 02-bridge-network.md
│   ├── 03-pod-networking.md
│   ├── 04-ipam.md
│   └── 05-network-policies.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-bridge-cni.md
│   ├── 02-trace-packet.md
│   ├── 03-network-policy.md
│   ├── 04-calico-cilium.md
│   └── 05-tcpdump-pod.md
└── scripts/                   # Helper scripts
    ├── cni-ops.sh
    ├── bridge-cni-config.json
    └── cni-examples.yaml
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — CNI Specification: CNI plugin binary, env var (CNI_COMMAND, CNI_CONTAINERID, CNI_NETNS), JSON config input, JSON result output, plugin chain (multus), CNI version
- [ ] 02 — Bridge Network: bridge cbr0, veth pair (pod netns ↔ bridge), IPAM assign IP, route setup, ARP, bridge CNI plugin flow
- [ ] 03 — Pod Networking: pod IP, same-node (bridge), cross-node (routing/overlay), flat vs overlay (VXLAN) vs BGP, MTU, pod-to-pod vs pod-to-Service
- [ ] 04 — IPAM: host-local (CIDR range per node), DHCP, Calico IPAM (block-based), node CIDR allocation from controller-manager --cluster-cidr
- [ ] 05 — Network Policies: Layer 3/4 firewall, ingress/egress rule, default deny + allow pattern, selector (podSelector, namespaceSelector), CNI plugin enforce (iptables/eBPF)

### Thực hành (exercises/)

- [ ] 01 — Cài bridge CNI thủ công: viết CNI config JSON, deploy pod, `crictl inspect` xem IP gán
- [ ] 02 — Tạo 2 pod khác node, trace packet path: pod → veth → bridge → route → node interface → remote node
- [ ] 03 — Tạo NetworkPolicy default deny ingress, test pod không nhận traffic, add allow rule, test lại
- [ ] 04 — Cài Calico hoặc Cilium, so sánh IPAM và policy enforcement
- [ ] 05 — `tcpdump` trên veth interface của pod, capture traffic giữa 2 pod

### Checkpoint hoàn thành phase

- [ ] Giải thích được flow: pod start → CNI plugin ADD → veth + IP + route
- [ ] Tạo được NetworkPolicy default deny + allow
- [ ] Trace được packet path giữa 2 pod khác node

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — có thể dùng multipass/Vagrant
- Root access (sudo) trên VM
- Packages: `containerd`, `crictl`, `tcpdump`, `iproute2`, `iptables`, `jq`, `kubectl`
- Đã hoàn thành Phase 8 (CRI — containerd running, kubelet connected)
- CNI plugins binary: `/opt/cni/bin/` (bridge, host-local, loopback, portmap)
