# 04 — IPVS Mode

## IPVS là gì

IPVS (IP Virtual Server) = kernel module cho load balancing. kube-proxy IPVS mode dùng IPVS thay iptables. O(1) lookup — nhanh hơn iptables với nhiều Service.

```
iptables mode:
  KUBE-SERVICES (N rules) → linear scan → O(n)
  10000 Services = 10000 rules per packet

IPVS mode:
  IPVS hash table → O(1) lookup
  10000 Services = 10000 entries, but O(1) per lookup
```

> IPVS = L4 load balancer trong kernel. Hash table lookup O(1). iptables = linear chain O(n). IPVS faster cho nhiều Service.

## IPVS architecture

```
IPVS (kernel module: ip_vs)
  ├── Virtual server (Service IP:port)
  │     ├── Real server 1 (pod IP:targetPort) — weight 1
  │     ├── Real server 2 (pod IP:targetPort) — weight 1
  │     └── Real server 3 (pod IP:targetPort) — weight 1
  │
  └── Scheduling algorithm:
        ├── rr (round-robin)
        ├── wrr (weighted round-robin)
        ├── lc (least-connection)
        ├── wlc (weighted least-connection)
        ├── sh (source hashing)
        └── dh (destination hashing)
```

> IPVS = virtual server + real servers. Virtual server = Service IP. Real server = pod IP. Scheduling algorithm = load balancing strategy. Kernel module `ip_vs`.

## IPVS vs iptables

| Feature | iptables | IPVS |
|---------|----------|------|
| **Data structure** | Linear chain | Hash table |
| **Lookup** | O(n) | O(1) |
| **Load balancing** | Random probability | Algorithm (rr, wrr, lc, sh) |
| **Connection** | Per-packet (conntrack sticky) | Per-connection (IPVS conn) |
| **Scalability** | ~5000 Services | 100000+ Services |
| **Rules** | N×M iptables rules | N IPVS entries |
| **Maturity** | Very mature | Mature |

> iptables = O(n), random probability. IPVS = O(1), scheduling algorithm. IPVS scales better (100K+ Services). iptables simpler, more mature.

## ipvsadm — IPVS CLI

```bash
# Install ipvsadm
sudo apt install -y ipvsadm

# List virtual servers (Services)
sudo ipvsadm -L -n
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port  Scheduler Flags
#   -> RemoteAddress:Port  Forward  Weight  ActiveConn  InActConn
# TCP  10.96.0.1:80        rr
#   -> 10.244.1.5:8080     Masq     1       0           0
#   -> 10.244.2.3:8080     Masq     1       0           0
#   -> 10.244.3.7:8080     Masq     1       0           0
# TCP  10.96.0.10:53       rr
#   -> 10.244.1.3:53       Masq     1       0           0

# Detailed output
sudo ipvsadm -L -n --stats
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port  Conns  InPkts  OutPkts  InBytes  OutBytes
# TCP  10.96.0.1:80        150    1200    1200     120000   120000
#   -> 10.244.1.5:8080     50     400     400      40000    40000
#   -> 10.244.2.3:8080     50     400     400      40000    40000
#   -> 10.244.3.7:8080     50     400     400      40000    40000

# Rate (per second)
sudo ipvsadm -L -n --rate
# Prot LocalAddress:Port  CPS    InPPS  OutPPS  InBPS   OutBPS
# TCP  10.96.0.1:80        10     80     80      8000    8000
```

### ipvsadm output

| Column | Ý nghĩa |
|--------|---------|
| `Prot` | Protocol (TCP, UDP) |
| `LocalAddress:Port` | Virtual server (Service IP:port) |
| `RemoteAddress:Port` | Real server (pod IP:targetPort) |
| `Scheduler` | Algorithm (rr, wrr, lc) |
| `Forward` | Masq (NAT), Route (DR), Tunnel |
| `Weight` | Weight for wrr/wlc |
| `ActiveConn` | Active connections |
| `InActConn` | Inactive connections |

> `rr` = round-robin (default). `Masq` = NAT mode (MASQUERADE). `Weight 1` = equal. ActiveConn = current connections. `--stats` = total counters. `--rate` = per-second.

## Scheduling algorithms

| Algorithm | Name | Behavior |
|-----------|------|----------|
| `rr` | Round-robin | Sequential: A → B → C → A → B → C |
| `wrr` | Weighted round-robin | Weight-based: A(weight 3) → A → A → B(weight 1) → C(weight 1) |
| `lc` | Least-connection | Pick fewest active connections |
| `wlc` | Weighted least-connection | Least-conn / weight |
| `sh` | Source hashing | Same source IP → same pod (sticky) |
| `dh` | Destination hashing | Same dest IP → same pod |
| `sed` | Shortest expected delay | Least-conn + response time |
| `nq` | Never queue | If idle → assign, else least-conn |

```bash
# Check current scheduler
sudo ipvsadm -L -n | grep "Scheduler\|rr\|lc\|sh"
# TCP  10.96.0.1:80  rr   ← round-robin

# Change scheduler (kube-proxy config, not direct ipvsadm)
# In kube-proxy config:
# ipvs:
#   scheduler: "lc"   ← least-connection
```

> Default = `rr` (round-robin). `lc` = least-connection (better for uneven load). `sh` = source hashing (sticky session). Config in kube-proxy `ipvs.scheduler`.

## kube-proxy IPVS config

```yaml
# /var/lib/kube-proxy/config.yaml
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "ipvs"               # IPVS mode
ipvs:
  scheduler: "rr"          # Round-robin (default)
  excludeCIDRs: []
  strictARP: false
  syncPeriod: 30s
  minSyncPeriod: 1s
  tcpTimeout: 0s
  tcpFinTimeout: 0s
  udpTimeout: 0s
```

### Switch to IPVS mode

```bash
# Edit kube-proxy ConfigMap
kubectl -n kube-system edit configmap kube-proxy
# Change: mode: "iptables" → mode: "ipvs"

# Or patch
kubectl -n kube-system patch configmap kube-proxy \
  --patch '{"data":{"config.conf":"mode: ipvs\n..."}}'

# Restart kube-proxy
kubectl -n kube-system rollout restart ds kube-proxy

# Verify
kubectl -n kube-system logs ds/kube-proxy | grep "Using ipvs"
# ... "Using ipvs Proxier"
```

### Verify IPVS

```bash
# Check IPVS loaded
lsmod | grep ip_vs
# ip_vs_sh               16384  0
# ip_vs_wrr              16384  0
# ip_vs_rr               16384  1
# ip_vs                 172032  6 ip_vs_sh,ip_vs_wrr,ip_vs_rr

# Check virtual servers
sudo ipvsadm -L -n
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port  Scheduler Flags
#   -> RemoteAddress:Port  Forward  Weight  ActiveConn  InActConn
# TCP  10.96.0.1:80        rr
#   -> 10.244.1.5:8080     Masq     1       0           0
```

> After switch: `lsmod | grep ip_vs` shows IPVS modules loaded. `ipvsadm -L -n` shows virtual servers (Services) + real servers (pods). No more KUBE-SVC iptables chains (only KUBE-MARK-MASQ for SNAT).

## IPVS + iptables (hybrid)

```
IPVS mode still uses iptables for:
  - SNAT (masquerade) — KUBE-MARK-MASQ + KUBE-POSTROUTING
  - NodePort — KUBE-NODEPORTS (if IPVS doesn't handle)
  - Hairpin — SNAT for hairpin

IPVS handles:
  - ClusterIP DNAT (load balancing)
  - Connection tracking (IPVS conn, not conntrack)
```

> IPVS mode không loại bỏ iptables hoàn toàn — vẫn dùng iptables cho SNAT, NodePort, hairpin. IPVS handle ClusterIP DNAT (load balancing). Hybrid: IPVS (DNAT) + iptables (SNAT).

## IPVS connection tracking

```bash
# IPVS connection table
sudo ipvsadm -L -n --connection
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port  RemoteAddress:Port  Forward  Weight  ActiveConn  InActConn
# TCP  10.96.0.1:80       10.244.1.5:43210   Masq     1       1           0
#   → 10.244.2.3:8080     (DNAT)
# TCP  10.96.0.1:80       10.244.1.6:43211   Masq     1       1           0
#   → 10.244.1.5:8080     (DNAT)

# IPVS timeout
sudo ipvsadm -L -n --timeout
# Timeout (tcp tcpfin udp): 900 120 300
#   tcp: 900s, tcpfin: 120s, udp: 300s
```

> IPVS có riêng connection tracking (không dùng netfilter conntrack). `--connection` = active connections. `--timeout` = TCP 900s, TCP-FIN 120s, UDP 300s. IPVS conn = per-connection (sticky).

## Performance comparison

```
iptables (O(n)):
  1000 Services:   ~1ms per packet (1000 rules to traverse)
  10000 Services:  ~10ms per packet
  50000 Services:  ~50ms per packet

IPVS (O(1)):
  1000 Services:   ~0.01ms per packet (hash lookup)
  10000 Services:  ~0.01ms per packet
  50000 Services:  ~0.01ms per packet
```

> iptables = linear, O(n). IPVS = hash, O(1). 10000+ Services → IPVS significantly faster. < 1000 Services → difference negligible.

## When to use IPVS

```
Use IPVS when:
  - > 1000 Services (iptables slow)
  - Need load balancing algorithm (rr, lc, sh)
  - Need connection stats (ipvsadm --stats)
  - Large cluster (10000+ Services)

Use iptables when:
  - Small cluster (< 1000 Services)
  - Maximum compatibility (iptables everywhere)
  - Don't need algorithm choice
  - Simpler debugging (iptables -S)
```

> IPVS cho large cluster (1000+ Services). iptables cho small cluster (simple, compatible). IPVS = O(1), iptables = O(n). Cả 2 đều mature.

## Liên hệ với Kubernetes

- IPVS = kernel module (`ip_vs`), L4 load balancer. O(1) hash lookup — faster than iptables O(n).
- Virtual server = Service IP. Real server = pod IP. Scheduling algorithm = rr/wrr/lc/sh.
- `ipvsadm -L -n` — xem virtual server + real server + active connections.
- Default scheduler = `rr` (round-robin). `lc` = least-connection (better for uneven load).
- Switch: `mode: ipvs` in kube-proxy config, restart kube-proxy.
- IPVS vẫn dùng iptables cho SNAT/NodePort/hairpin — hybrid. IPVS handle ClusterIP DNAT.
- IPVS có riêng connection tracking (không netfilter conntrack). `--connection` = active conns.
- IPVS cho large cluster (1000+ Services). iptables cho small cluster.
- Performance: 10000 Services → iptables ~10ms/packet, IPVS ~0.01ms/packet.
