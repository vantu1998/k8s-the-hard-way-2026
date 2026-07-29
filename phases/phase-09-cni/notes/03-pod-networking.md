# 03 — Pod Networking

## Pod IP

Mỗi pod có IP riêng, có thể giao tiếp trực tiếp (pod-to-pod) không cần NAT.

```
Cluster network:
  10.244.0.0/16  (cluster CIDR, --cluster-cidr)
    ├── Node 1: 10.244.1.0/24  (pod CIDR for node 1)
    │     ├── Pod A: 10.244.1.5
    │     └── Pod B: 10.244.1.6
    ├── Node 2: 10.244.2.0/24  (pod CIDR for node 2)
    │     └── Pod C: 10.244.2.3
    └── Node 3: 10.244.3.0/24  (pod CIDR for node 3)
          └── Pod D: 10.244.3.7

Service network (separate):
  10.96.0.0/12  (service CIDR, --service-cluster-ip-range)
    ├── Service X: 10.96.0.1
    └── Service Y: 10.96.1.5
```

> Pod CIDR = IP range cho pod. Mỗi node nhận 1 subnet (/24) từ cluster CIDR. Pod IP từ subnet đó. Service network = riêng (virtual IP, không gán cho interface).

## Same-node pod communication

```
Pod A (10.244.1.5) → Pod B (10.244.1.6) — same node (10.244.1.0/24):

1. Pod A: route lookup — 10.244.1.6 in 10.244.1.0/24
   → direct route via eth0
2. Pod A: ARP request "who has 10.244.1.6?"
   → bridge cbr0 broadcast
3. Pod B: ARP reply
4. Pod A → bridge → Pod B (layer 2)

No routing, no NAT, no iptables — pure layer 2 bridge.
```

> Same node: layer 2 bridge. Pod → veth → bridge → veth → pod. < 0.1ms latency. No routing, no NAT.

## Cross-node pod communication

### Routing (flat network — Calico BGP)

```
Pod A (10.244.1.5, Node 1) → Pod C (10.244.2.3, Node 2):

1. Pod A: route lookup — 10.244.2.3 not in 10.244.1.0/24
   → default route via 10.244.1.1 (bridge)
2. Pod A → bridge cbr0 (Node 1)
3. Node 1: route lookup — 10.244.2.0/24 via Node 2 (BGP route)
   → send to Node 2 via eth0
4. Node 2: receive packet, route lookup — 10.244.2.3 in 10.244.2.0/24
   → bridge cbr0 (Node 2)
5. Node 2: bridge → Pod C eth0

No NAT, no overlay — pure routing (BGP advertises pod CIDR).
```

> Flat network (Calico BGP): node route pod CIDR → remote node. No overlay, no NAT. Pod IP visible end-to-end. Yêu cầu: node trong cùng L2 hoặc BGP peering.

### Overlay (VXLAN — Flannel, Calico VXLAN)

```
Pod A (10.244.1.5, Node 1) → Pod C (10.244.2.3, Node 2):

1. Pod A → bridge cbr0 (Node 1)
2. Node 1: route — 10.244.2.0/24 via flannel.1 (VXLAN interface)
3. Node 1: VXLAN encapsulate:
   Inner: src=10.244.1.5 dst=10.244.2.3 (pod IP)
   Outer: src=192.168.1.10 dst=192.168.1.20 (node IP, UDP 4789)
4. Node 1 → Node 2 (physical network, UDP 4789)
5. Node 2: VXLAN decapsulate → inner packet
6. Node 2: route → bridge → Pod C

Overlay: pod IP wrapped in node IP (VXLAN tunnel).
```

> Overlay (VXLAN): pod packet wrapped trong UDP (port 4789). Pod IP invisible (hidden trong tunnel). Work trên any network (không cần BGP). 50 bytes overhead (MTU 1450).

### Flat vs Overlay vs BGP

| Model | Mechanism | MTU | NAT | Requirement | Use case |
|-------|-----------|-----|-----|-------------|----------|
| **Flat (bridge)** | Bridge + routing | 1500 | No | Same L2 | Lab, simple |
| **Overlay (VXLAN)** | UDP tunnel | 1450 | No | Any network | Cloud, multi-network |
| **BGP (Calico)** | BGP route | 1500 | No | BGP peering | Bare metal, datacenter |
| **IPIP (Calico)** | IP-in-IP tunnel | 1480 | No | Any network | Datacenter |
| **eBPF (Cilium)** | eBPF routing | 1500 | No | Kernel 5.4+ | High performance |

> Flat = no overhead, but need same L2. Overlay = works anywhere, but 50 bytes overhead. BGP = no overhead, but need BGP peering. eBPF = fastest, but need modern kernel.

## Pod-to-Service communication

```
Pod A (10.244.1.5) → Service X (10.96.0.1):

1. Pod A: route — 10.96.0.1 not in 10.244.1.0/24
   → default route via 10.244.1.1 (bridge)
2. Pod A → bridge → Node 1
3. Node 1: iptables KUBE-SERVICES chain
   → DNAT: 10.96.0.1 → 10.244.2.3 (pod IP behind Service)
4. Node 1: route — 10.244.2.0/24 via Node 2
5. Node 1 → Node 2 → Pod C

Service IP = virtual (iptables DNAT). Actual traffic to pod IP.
```

> Pod → Service: iptables DNAT (Service IP → pod IP). Then pod-to-pod (routing/overlay). Service IP không tồn tại trong network — chỉ là iptables rule. Xem Phase 10 cho kube-proxy chi tiết.

## Pod-to-external communication

```
Pod A (10.244.1.5) → external (8.8.8.8):

1. Pod A → bridge → Node 1
2. Node 1: iptables POSTROUTING chain
   → MASQUERADE (SNAT): 10.244.1.5 → 192.168.1.10 (node IP)
3. Node 1 → external (8.8.8.8, source = node IP)
4. Response: 8.8.8.8 → Node 1 (192.168.1.10)
5. Node 1: conntrack — reverse NAT: 192.168.1.10 → 10.244.1.5
6. Node 1 → bridge → Pod A

Pod IP → SNAT → node IP → external. Response → reverse NAT → pod IP.
```

> Pod → external: SNAT (masquerade) pod IP → node IP. External thấy node IP, không thấy pod IP. Response: conntrack reverse NAT. `ipMasq: true` trong CNI config hoặc iptables MASQUERADE rule.

## DNS resolution

```
Pod A → my-service.default.svc.cluster.local:

1. Pod A: DNS query to /etc/resolv.conf
   nameserver 10.96.0.10  (CoreDNS Service IP)
   search default.svc.cluster.local svc.cluster.local cluster.local
2. Pod A → 10.96.0.10:53 (CoreDNS)
   → iptables DNAT → CoreDNS pod IP
3. CoreDNS: resolve my-service.default.svc.cluster.local
   → Service ClusterIP: 10.96.0.1
4. CoreDNS → Pod A: answer 10.96.0.1
5. Pod A → 10.96.0.1 (Service IP)
   → iptables DNAT → pod IP
```

> DNS: pod query CoreDNS (via Service IP → DNAT → CoreDNS pod). CoreDNS resolve Service name → ClusterIP. Pod connect ClusterIP → DNAT → pod IP. DNS là Service, dùng kube-proxy iptables.

## Network model — Kubernetes requirements

K8s network model (CNI must satisfy):

1. **Pod-to-pod without NAT** — pod giao tiếp trực tiếp, không NAT
2. **Node-to-pod without NAT** — node giao tiếp pod trực tiếp
3. **Pod-to-external with NAT** — pod ra external qua SNAT (node IP)
4. **Unique pod IP** — mỗi pod 1 IP, unique trong cluster
5. **Pod IP routable** — pod IP reachable từ mọi node

> K8s yêu cầu: pod-to-pod no NAT (flat/overlay/BGP). Pod → external: SNAT. Mỗi pod 1 IP unique. CNI phải satisfy các requirement này.

## Liên hệ với Kubernetes

- Mỗi pod có **IP riêng**, pod-to-pod no NAT (K8s requirement).
- Pod CIDR: cluster CIDR chia cho mỗi node 1 subnet (/24). Node nhận từ controller-manager `--cluster-cidr`.
- Same-node: layer 2 bridge (pod → veth → bridge → veth → pod, no routing).
- Cross-node: routing (BGP/flat), overlay (VXLAN/IPIP), hoặc eBPF (Cilium).
- VXLAN: pod packet wrapped trong UDP 4789, 50 bytes overhead, MTU 1450. Works anywhere.
- BGP (Calico): no overhead, pod IP routable, but need BGP peering.
- Pod → Service: iptables DNAT (Service IP → pod IP). Xem Phase 10.
- Pod → external: SNAT (masquerade pod IP → node IP). Response: conntrack reverse NAT.
- DNS: pod → CoreDNS (Service IP → DNAT → CoreDNS pod) → resolve → Service ClusterIP.
- K8s network model: pod-to-pod no NAT, node-to-pod no NAT, pod-to-external SNAT, unique pod IP.
