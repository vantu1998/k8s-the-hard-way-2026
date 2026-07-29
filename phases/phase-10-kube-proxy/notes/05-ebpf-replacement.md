# 05 — eBPF Proxy Replacement

## eBPF Proxy Replacement là gì

Cilium thay kube-proxy bằng **eBPF program** at socket layer. Bypass iptables entirely — no KUBE-SVC chains, no conntrack. Faster, less overhead.

```
Traditional (kube-proxy):
  Client → socket → iptables (KUBE-SERVICES → KUBE-SVC → KUBE-SEP → DNAT)
  → conntrack → pod IP → pod

eBPF (Cilium):
  Client → socket → eBPF program (at socket layer, intercept connect())
  → rewrite dst (Service IP → pod IP) → pod IP → pod
  → no iptables, no conntrack
```

> eBPF = program in kernel, intercept `connect()` syscall. Rewrite destination (Service IP → pod IP) before packet created. No iptables traversal, no conntrack. Faster.

## Cilium kube-proxy replacement

```
Cilium eBPF programs:
  ├── Socket layer (cgroup/connect4): intercept connect() — rewrite dst
  ├── TC (traffic control): ingress/egress — DNAT, SNAT
  ├── XDP: packet processing (early drop, routing)
  └── cgroup/sock_ops: socket operations

Service load balancing:
  1. Pod calls connect(10.96.0.1:80)
  2. eBPF program (cgroup/connect4) intercept
  3. Lookup Service → select endpoint (pod IP)
  4. Rewrite: dst 10.96.0.1:80 → 10.244.2.3:8080
  5. Socket connects directly to pod IP
  6. No iptables, no conntrack
```

> Cilium eBPF at socket layer — intercept before packet created. Rewrite dst (Service IP → pod IP). Socket connects directly to pod. No iptables chain traversal, no conntrack entry.

## Enable kube-proxy replacement

```bash
# Install Cilium with kube-proxy replacement
cilium install --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.1.10 \
  --set k8sServicePort=6443

# Or via Helm
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.1.10 \
  --set k8sServicePort=6443

# Verify
cilium status | grep "kube-proxy"
# Kube Proxy Replacement:   True

# Check eBPF programs
kubectl -n kube-system exec ds/cilium -- cilium bpf lb list
# Service IP     Port   Backends
# 10.96.0.1      80     10.244.1.5:8080, 10.244.2.3:8080
# 10.96.0.10    53     10.244.1.3:53
```

### Remove kube-proxy

```bash
# After Cilium kube-proxy replacement enabled
# Remove kube-proxy DaemonSet
kubectl -n kube-system delete ds kube-proxy

# Verify Service still works (Cilium handles)
kubectl exec client -- curl http://web-service.default.svc.cluster.local
# <!DOCTYPE html>   ← WORKS! Cilium eBPF handles Service

# Verify no kube-proxy
kubectl -n kube-system get ds | grep kube-proxy
# (empty — kube-proxy deleted)
```

> After Cilium replacement: delete kube-proxy. Service still works — Cilium eBPF handles. No kube-proxy = fewer components, less CPU, less iptables.

## eBPF vs iptables vs IPVS

| Feature | iptables | IPVS | eBPF (Cilium) |
|---------|----------|------|---------------|
| **Data plane** | iptables chain | IPVS hash | eBPF program |
| **Lookup** | O(n) | O(1) | O(1) |
| **Layer** | Netfilter (packet) | Netfilter (packet) | Socket (syscall) |
| **conntrack** | Yes (netfilter) | Yes (IPVS) | No (socket-level) |
| **SNAT** | iptables | iptables | eBPF (TC) |
| **Load balancing** | Random probability | Algorithm (rr/lc/sh) | Algorithm (rr/lc/maglev) |
| **Scalability** | ~5000 Services | 100000+ | 100000+ |
| **Latency** | Higher (iptables) | Lower (IPVS) | Lowest (socket) |
| **kube-proxy** | Required | Required | Not required |
| **Visibility** | iptables logs | ipvsadm | Hubble |

> eBPF = fastest (socket-level, no iptables, no conntrack). IPVS = fast (O(1) hash). iptables = slow (O(n) chain). eBPF also replaces kube-proxy entirely.

## eBPF socket-level — how it works

```
Traditional (iptables/IPVS):
  1. Pod: connect(10.96.0.1:80)
  2. Kernel: create packet (src=pod, dst=10.96.0.1:80)
  3. Netfilter: PREROUTING → KUBE-SERVICES → DNAT → 10.244.2.3:8080
  4. conntrack: record connection
  5. Kernel: route packet to pod
  → 3-4 steps, iptables traversal, conntrack

eBPF (Cilium):
  1. Pod: connect(10.96.0.1:80)
  2. eBPF (cgroup/connect4): intercept connect()
  3. eBPF: lookup Service → select endpoint → rewrite dst
  4. Kernel: connect directly to 10.244.2.3:8080
  → 2 steps, no iptables, no conntrack, no packet created yet
```

> eBPF intercept at **socket layer** — before packet created. Rewrite dst in connect() syscall. Kernel connects directly to pod. No packet → no iptables → no conntrack. Fastest possible.

## Maglev consistent hashing

```
Cilium eBPF supports Maglev consistent hashing:
  - Consistent hash: same client → same pod (stable)
  - When pod added/removed: minimal rebalancing (only ~1/n changes)
  - vs round-robin: all connections rebalanced when pod added

Use case:
  - Large Service (100+ endpoints)
  - Need sticky session (same client → same pod)
  - Pod scale up/down: minimal disruption
```

> Maglev = Google's consistent hashing algorithm. Same client → same pod. Pod added → only 1/n connections rebalanced (vs rr: all rebalanced). Better for large Service + sticky session.

## eBPF service map

```bash
# View Cilium service map (eBPF)
kubectl -n kube-system exec ds/cilium -- cilium bpf lb list
# Service ID   Service IP:Port   Slots (weight)
# 1            10.96.0.1:80      3
#   Backend 1: 10.244.1.5:8080 (weight 1)
#   Backend 2: 10.244.2.3:8080 (weight 1)
#   Backend 3: 10.244.3.7:8080 (weight 1)

# View backend details
kubectl -n kube-system exec ds/cilium -- cilium bpf lb get 10.96.0.1
# Service ID: 1
# Frontend: 10.96.0.1:80
# Backend: 10.244.1.5:8080 (1/3), 10.244.2.3:8080 (1/3), 10.244.3.7:8080 (1/3)

# View socket-level eBPF programs
kubectl -n kube-system exec ds/cilium -- cilium bpf prog list
# ID   Type   Load   Name
# 1    cgroup/connect4  2026-01-01  cilium_connect4
# 2    cgroup/sendmsg4  2026-01-01  cilium_sendmsg4
# 3    tc/ingress       2026-01-01  cilium_tc_ingress
```

> Cilium eBPF: service map (Service → backends), socket-level programs (cgroup/connect4, sendmsg4), TC programs (ingress/egress). `cilium bpf lb list` = Service → pod mapping.

## Hubble — flow visibility

```bash
# Enable Hubble
cilium hubble enable

# View Service flows
hubble observe --type flow --verdict forwarded | grep "10.96.0.1"
# TIMESTAMP            SRC              DST              POLICY   VERDICT
# 2026-01-01T00:00:00  10.244.1.5:80   10.96.0.1:80     allow    FORWARDED
#   → DNAT to 10.244.2.3:8080

# Hubble UI
cilium hubble ui
# Open browser: http://localhost:12000
# Visualize Service → pod traffic, policy verdict, dropped packets
```

> Hubble = Cilium flow visibility. See every packet: src, dst, Service DNAT, policy verdict. UI for visualization. iptables/IPVS = no equivalent (logs only).

## Advantages of eBPF replacement

```
1. Performance: no iptables traversal, no conntrack → faster
2. Less CPU: no kube-proxy, no iptables rule sync → less CPU
3. Scalability: O(1) hash + socket-level → 100K+ Services
4. Visibility: Hubble — real-time flow, policy verdict
5. Consistent hashing: Maglev — sticky session, minimal rebalancing
6. Fewer components: no kube-proxy → simpler
```

> eBPF = faster, less CPU, more scalable, better visibility, fewer components. Trade-off: requires modern kernel (5.4+), Cilium (not built-in).

## Requirements

```
Kernel: 5.4+ (eBPF features)
  - BTF (BPF Type Format) — 5.4+
  - bpf_sk_lookup_tcp — 4.6+
  - cgroup/connect4 — 4.18+
  - bpf_skb_adjust_room — 5.2+

Cilium: 1.9+ (kube-proxy replacement)
  - Full replacement: 1.16+ (stable)

Check:
  uname -r   # 5.15.0+ OK
  ls /sys/kernel/btf/vmlinux   # BTF support
```

> eBPF needs kernel 5.4+ (cgroup/connect4, BTF). Cilium 1.16+ for stable kube-proxy replacement. Check kernel + BTF before install.

## Liên hệ với Kubernetes

- eBPF replacement = Cilium thay kube-proxy bằng eBPF at socket layer. No iptables, no conntrack.
- eBPF intercept `connect()` — rewrite dst (Service IP → pod IP) before packet created. Fastest.
- Enable: `kubeProxyReplacement=true` in Cilium. Delete kube-proxy after.
- eBPF vs IPVS vs iptables: eBPF (socket, O(1), no conntrack) > IPVS (packet, O(1), conntrack) > iptables (packet, O(n), conntrack).
- Maglev = consistent hashing. Same client → same pod. Pod added → minimal rebalancing (1/n).
- Hubble = flow visibility (real-time, UI). iptables/IPVS = no equivalent.
- Advantages: faster, less CPU, scalable (100K+), fewer components (no kube-proxy).
- Requirements: kernel 5.4+, BTF, Cilium 1.16+.
- `cilium bpf lb list` — Service → backend mapping. `hubble observe` — flow visibility.
