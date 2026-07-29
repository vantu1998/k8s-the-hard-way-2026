# Exercise 04 — Calico vs Cilium

> **Mục tiêu**: Cài Calico hoặc Cilium, so sánh IPAM và policy enforcement. Hiểu khác biệt giữa iptables (Calico) và eBPF (Cilium).
>
> **Thời gian dự kiến**: 40 phút
>
> **Yêu cầu**: Cluster K8s (Phase 8), `sudo` privilege, internet access

## Bối cảnh

Calico = iptables-based, Cilium = eBPF-based. Bài này cài 1 trong 2 (hoặc cả 2 nếu có cluster test), so sánh IPAM, policy enforcement, performance.

## Prerequisites

```bash
# Check current CNI
kubectl get pods -n kube-system | grep -E "(calico|cilium|flannel|weave)"
# If bridge CNI only → install Calico or Cilium

# Check kernel version (Cilium needs 5.4+)
uname -r
# 5.15.0-xxx   ← OK for Cilium

# Check eBPF support
ls /sys/fs/bpf/ 2>/dev/null && echo "eBPF supported" || echo "eBPF not mounted"
```

## Bước 1: Install Calico (option A)

```bash
# Download Calico manifest
curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml -o calico.yaml

# Edit pod CIDR if not 192.168.0.0/16
# Default Calico uses 192.168.0.0/16 — change to match cluster
CLUSTER_CIDR=$(kubectl get node worker-1 -o jsonpath='{.spec.podCIDR}' | cut -d'.' -f1-2)
echo "Cluster CIDR prefix: ${CLUSTER_CIDR}"
# If 10.244 → edit calico.yaml: 192.168.0.0/16 → 10.244.0.0/16

# Install Calico
kubectl apply -f calico.yaml

# Wait for Calico pods
kubectl wait --for=condition=Ready pod -l k8s-app=calico-node -n kube-system --timeout=120s

# Verify
kubectl get pods -n kube-system | grep calico
# calico-node-xxx       1/1   Running
# calico-kube-controllers-xxx  1/1   Running
```

### Calico architecture

```
Calico components:
  ├── calico-node (DaemonSet)
  │     ├── Felix — iptables rules, routing
  │     ├── BIRD — BGP routing (if BGP mode)
  │     └── confd — config management
  ├── calico-kube-controllers (Deployment)
  │     └── IPAM controller, policy controller
  └── typha (optional) — scale Felix for large cluster
```

> Calico = Felix (daemon, iptables) + BIRD (BGP) + kube-controllers (IPAM/policy). iptables enforce NetworkPolicy.

## Bước 1: Install Cilium (option B)

```bash
# Install Cilium CLI
curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable/install.sh | bash

# Install Cilium
cilium install --version 1.16.0

# Wait for Cilium pods
kubectl wait --for=condition=Ready pod -l k8s-app=cilium -n kube-system --timeout=120s

# Verify
kubectl get pods -n kube-system | grep cilium
# cilium-xxx       1/1   Running
# cilium-operator-xxx  1/1   Running

# Check Cilium status
cilium status
#     /¯¯\
#  /¯¯\__/¯¯\    Cilium:             1.16.0
#  \__/¯¯\__/    Operator:           1.16.0
#  /¯¯\__/¯¯\    Kernel:             5.15.0
#  \__/¯¯\__/    Kubernetes:         v1.33.0
```

### Cilium architecture

```
Cilium components:
  ├── cilium-agent (DaemonSet)
  │     ├── eBPF programs (kernel) — socket, TC, XDP
  │     ├── cilium-health — health check
  │     └── hubble — flow visibility (optional)
  ├── cilium-operator (Deployment)
  │     └── IPAM, CRD controller
  └── hubble-relay (optional) — flow viewer
```

> Cilium = eBPF programs in kernel (socket, TC, XDP). No iptables for pod traffic. Hubble = flow visibility.

## Bước 2: Compare IPAM

### Calico IPAM

```bash
# Calico IPAM — block-based
calicoctl ipam show
# +----------+----------------+-----------+------------+
# | Grouping |     CIDR       | IPS IN USE | IPS FREE  |
# +----------+----------------+-----------+------------+
# | IP Pool  | 10.244.0.0/16  | 15        | 65521     |
# | Block    | 10.244.1.0/26  | 5         | 59        |  ← Node 1
# | Block    | 10.244.2.0/26  | 3         | 61        |  ← Node 2
# +----------+----------------+-----------+------------+

# Block detail
calicoctl ipam show --ip=10.244.1.5
# IP 10.244.1.5 is in block 10.244.1.0/26 (affinity: worker-1)

# Check pod IP assignment
calicoctl get wep -A  # workload endpoint
# NAMESPACE   WORKLOAD   NODE       INTERFACE   IP
# default     web        worker-1   eth0        10.244.1.5
```

### Cilium IPAM

```bash
# Cilium IPAM
kubectl -n kube-system exec ds/cilium -- cilium ipam list
# IP            NODE        STATUS      HANDLE
# 10.244.1.5    worker-1    allocated   k8s:default:web
# 10.244.2.3    worker-2    allocated   k8s:default:frontend

# IPAM mode
kubectl -n kube-system exec ds/cilium -- cilium ipam info
# IPAM Mode: cluster-pool
# Pool: 10.244.0.0/16
# Per-node: 10.244.1.0/24 (worker-1)
```

| Feature | Calico | Cilium |
|---------|--------|--------|
| **Allocation** | Block-based (/26) | Cluster-pool (/24 per node) or ENI |
| **State** | etcd/CRD | etcd/k8s |
| **Persistence** | Yes (etcd) | Yes (etcd) |
| **Borrow** | Yes (block borrowing) | No (per-node /24) |
| **ENI** | No | Yes (AWS) |

> Calico = block-based (/26), borrow when full. Cilium = cluster-pool (/24 per node, like host-local) or ENI (AWS). Calico flexible hơn, Cilium simpler.

## Bước 3: Compare policy enforcement

### Calico — iptables

```bash
# Check Calico iptables rules
sudo iptables -S | grep cali | head -10
# -A cali-INPUT -m comment --comment "cali:..." -j cali-from-host-endpoint
# -A cali-OUTPUT -m comment --comment "cali:..." -j cali-to-host-endpoint
# -A cali-fw-cali-xxx -m comment --comment "cali:policy" -j MARK

# Count Calico iptables rules
sudo iptables -S | grep -c cali
# 500   ← hundreds of rules

# Check policy
calicoctl get networkpolicy -A
# NAMESPACE   NAME                  SELECTOR
# default     web-deny-all          app=web
```

> Calico = iptables rules (`cali-` prefix). Hundreds of rules. O(n) lookup — slow with many policies. Mature, well-tested.

### Cilium — eBPF

```bash
# Check Cilium eBPF programs
kubectl -n kube-system exec ds/cilium -- cilium bpf endpoint list
# IP            IDENTITY   POLICY   STATUS
# 10.244.1.5    12345      egress   ready
# 10.244.2.3    67890      ingress   ready

# Check policy
kubectl -n kube-system exec ds/cilium -- cilium policy get
# Default: allow all
# Policy: deny ingress for app=web

# Check eBPF maps
kubectl -n kube-system exec ds/cilium -- cilium bpf policy get
# Policy: default-deny-ingress
#   Ingress: deny all
#   Egress: allow all
```

| Feature | Calico (iptables) | Cilium (eBPF) |
|---------|-------------------|---------------|
| **Mechanism** | iptables rules | eBPF programs |
| **Lookup** | O(n) sequential | O(1) hash map |
| **Latency** | Higher (many rules) | Lower (kernel eBPF) |
| **Visibility** | iptables logs | Hubble flows |
| **kube-proxy** | Required | Replaced (eBPF) |

> Calico = iptables (O(n) rules, mature). Cilium = eBPF (O(1) lookup, faster). Cilium can replace kube-proxy (eBPF at socket layer).

## Bước 4: Compare visibility

### Calico — logs

```bash
# Calico denied traffic — check logs
sudo journalctl -u calico-node -f | grep -i "deny"
# ... "Denied" src=10.244.2.3 dst=10.244.1.5 port=80

# Or check iptables counters
sudo iptables -L cali-INPUT -v -n | grep -i drop
#   0   0 DROP     all  --  *      *       0.0.0.0/0    0.0.0.0/0    /* cali:deny */
```

### Cilium — Hubble

```bash
# Enable Hubble (if not enabled)
cilium hubble enable

# Hubble flows — real-time traffic
cilium hubble port-forward &
sleep 3
hubble observe --follow | head -20
# TIMESTAMP            SRC              DST              POLICY   VERDICT
# 2026-01-01T00:00:00   10.244.1.5:80   10.244.2.3:80   allow    FORWARDED
# 2026-01-01T00:00:01   10.244.3.7:80   10.244.1.5:80   deny     DROPPED

# Hubble UI
cilium hubble ui
# Open browser: http://localhost:12000
```

> Calico = logs (text, manual). Cilium = Hubble (real-time flow, UI, filter). Cilium visibility tốt hơn nhiều — see every packet, policy verdict, dropped traffic.

## Bước 5: Compare performance

```bash
# Deploy test pods
kubectl run perf-server --image=nginx:1.25
kubectl run perf-client --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod/perf-server pod/perf-client --timeout=60s

SERVER_IP=$(kubectl get pod perf-server -o jsonpath='{.status.podIP}')

# Test latency (ping)
kubectl exec perf-client -- ping -c 10 "${SERVER_IP}" | tail -1
# rtt min/avg/max/mdev = 0.1/0.1/0.2/0.1 ms   ← Calico: ~0.1ms
# rtt min/avg/max/mdev = 0.05/0.05/0.1/0.02 ms ← Cilium: ~0.05ms (eBPF faster)

# Test throughput (wget large file)
kubectl exec perf-client -- wget -qO- "http://${SERVER_IP}/large-file" | wc -c
# 104857600   ← 100MB file
```

> Cilium (eBPF) faster: no iptables traversal, eBPF at socket layer. Calico (iptables) = every packet traverse iptables chain. Difference small for few policies, large for many policies (1000+ Services).

## Bước 6: Feature comparison summary

| Feature | Calico | Cilium |
|---------|--------|--------|
| **Data plane** | iptables | eBPF |
| **NetworkPolicy** | ✅ Full | ✅ Full |
| **IPAM** | Block-based (/26) | Cluster-pool / ENI |
| **Overlay** | IPIP / VXLAN | VXLAN / Geneve |
| **BGP** | ✅ Native | ❌ (via BGP control plane) |
| **kube-proxy** | Required | Replaced (eBPF) |
| **Visibility** | Logs | Hubble (flow UI) |
| **Performance** | Good | Better (eBPF) |
| **Maturity** | Very mature | Newer, growing |
| **Use case** | Bare metal, BGP | Cloud, high perf |

## Cleanup

```bash
kubectl delete pod perf-server perf-client

# If uninstalling CNI (be careful — will break pod network)
# Calico: kubectl delete -f calico.yaml
# Cilium: cilium uninstall
```

## Câu hỏi tự kiểm tra

1. Calico dùng gì để enforce NetworkPolicy? Cilium dùng gì?
2. Calico IPAM block-based (/26) khác Cilium cluster-pool (/24) thế nào? Ưu/nhược?
3. Cilium thay thế kube-proxy bằng gì? Lợi ích?
4. Hubble (Cilium) cho thấy gì? Calico có tương đương không?
5. Khi nào chọn Calico? Khi nào chọn Cilium?

## Đáp án tham khảo

1. **Calico** = iptables (Felix daemon → iptables rules, `cali-` prefix). O(n) rule lookup. **Cilium** = eBPF programs (kernel, socket/TC/XDP layer). O(1) hash map lookup. eBPF faster, no iptables traversal.
2. Calico /26 block: linh hoạt (borrow block khi full, block affinity per node). Cilium /24 per node: đơn giản (like host-local), no borrow. Calico tốt cho large cluster (efficient IP usage). Cilium đơn giản hơn, đủ cho most cases.
3. Cilium thay kube-proxy bằng **eBPF program at socket layer** — intercept `connect()`, `bind()`, do Service load balancing in kernel. Lợi ích: no iptables (faster), no conntrack (less memory), no kube-proxy (fewer components). `kubectl -n kube-system delete ds kube-proxy` → Service vẫn work.
4. **Hubble** = real-time flow visibility — every packet, policy verdict (allow/deny), source/dest, dropped traffic. UI (hubble-ui). Calico = logs (text, manual grep). No real-time flow viewer. Hubble = big advantage for debugging.
5. **Calico**: bare metal, datacenter, BGP routing, mature, simple (iptables). **Cilium**: cloud, high performance, need visibility (Hubble), want kube-proxy replacement, modern kernel (5.4+). Calico = conservative. Cilium = cutting-edge.
