# 03 — iptables Mode

## iptables mode — default

kube-proxy iptables mode = tạo iptables rules trên mỗi node. Mỗi Service = chain iptables. DNAT: Service IP → pod IP.

```
iptables chains for Service:
  KUBE-SERVICES       ← entry point (all Service traffic)
    ├── KUBE-SVC-<hash>  ← per Service (match dst Service IP)
    │     ├── KUBE-SEP-<hash>  ← per endpoint (DNAT to pod IP)
    │     ├── KUBE-SEP-<hash>
    │     └── KUBE-SEP-<hash>
    ├── KUBE-SVC-<hash>  ← another Service
    └── ...
  KUBE-NODEPORTS      ← NodePort entry
    └── KUBE-SVC-<hash>  ← redirect to Service chain
```

> iptables mode = chain per Service, chain per endpoint. Entry: KUBE-SERVICES (ClusterIP) or KUBE-NODEPORTS (NodePort). DNAT: Service IP → pod IP.

## KUBE-SERVICES chain

```bash
# View KUBE-SERVICES chain
sudo iptables -t nat -S KUBE-SERVICES | head -10
# -N KUBE-SERVICES
# -A KUBE-SERVICES -d 10.96.0.1/32 -p tcp -m tcp --dport 80 -j KUBE-SVC-ABC123
# -A KUBE-SERVICES -d 10.96.0.2/32 -p tcp -m tcp --dport 443 -j KUBE-SVC-DEF456
# -A KUBE-SERVICES -d 10.96.0.10/32 -p udp -m udp --dport 53 -j KUBE-SVC-GHI789
# ...
```

> KUBE-SERVICES = entry chain. Mỗi rule match `dst Service IP + port` → jump to `KUBE-SVC-<hash>`. Hash = SHA1 of Service name + namespace.

## KUBE-SVC chain — per Service

```bash
# View KUBE-SVC chain for a Service
sudo iptables -t nat -S KUBE-SVC-ABC123
# -N KUBE-SVC-ABC123
# -A KUBE-SVC-ABC123 -m statistic --mode random --probability 0.333 -j KUBE-SEP-AAA
# -A KUBE-SVC-ABC123 -m statistic --mode random --probability 0.500 -j KUBE-SEP-BBB
# -A KUBE-SVC-ABC123 -j KUBE-SEP-CCC
```

### Random probability — load balancing

```
3 endpoints (pod A, B, C):

Rule 1: probability 0.333 → KUBE-SEP-AAA (pod A)   ← 1/3 chance
Rule 2: probability 0.500 → KUBE-SEP-BBB (pod B)   ← 1/2 of remaining 2/3 = 1/3
Rule 3: (default)        → KUBE-SEP-CCC (pod C)   ← remaining 1/3

Math: 0.333 + (1-0.333)*0.500 + (1-0.333-...)*1.0 = 0.333 + 0.333 + 0.334 = 1.0
Each pod gets ~1/3 of traffic.
```

> Load balancing = `--mode random --probability`. First rule: 1/n. Second: 1/(n-1) of remaining. Last: default (remaining). Equal distribution. **Per-packet** (not per-connection) — each packet random.

## KUBE-SEP chain — per endpoint

```bash
# View KUBE-SEP chain for an endpoint
sudo iptables -t nat -S KUBE-SEP-AAA
# -N KUBE-SEP-AAA
# -A KUBE-SEP-AAA -p tcp -m tcp -j DNAT --dport 80 --to-destination 10.244.1.5:8080
#   ← DNAT: Service port 80 → pod IP 10.244.1.5, targetPort 8080
```

> KUBE-SEP = endpoint chain. DNAT: `--to-destination podIP:targetPort`. Packet dst changed from Service IP:port → pod IP:targetPort.

## Full iptables flow — ClusterIP

```
Packet: src=10.244.1.5 dst=10.96.0.1:80 (client → Service)

1. PREROUTING chain (or OUTPUT if local):
   → KUBE-SERVICES

2. KUBE-SERVICES:
   → match dst 10.96.0.1:80 → jump KUBE-SVC-ABC123

3. KUBE-SVC-ABC123:
   → random probability 0.333 → jump KUBE-SEP-AAA
   → (or 0.500 → KUBE-SEP-BBB, or default → KUBE-SEP-CCC)

4. KUBE-SEP-AAA:
   → DNAT: dst 10.96.0.1:80 → 10.244.1.5:8080

5. Packet: src=10.244.1.5 dst=10.244.1.5:8080 (client → pod)
   → routed to pod (via bridge/CNI)
```

```bash
# Trace iptables for a packet
sudo iptables -t nat -L KUBE-SERVICES -v -n | grep 10.96.0.1
#   0   0 DNAT       tcp  --  *      *       0.0.0.0/0    10.96.0.1    tcp dpt:80  → KUBE-SVC-ABC123

sudo iptables -t nat -L KUBE-SVC-ABC123 -v -n
#   0   0 KUBE-SEP-AAA  tcp  --  *      *       0.0.0.0/0    0.0.0.0/0    statistic mode random probability 0.333
#   0   0 KUBE-SEP-BBB  tcp  --  *      *       0.0.0.0/0    0.0.0.0/0    statistic mode random probability 0.500
#   0   0 KUBE-SEP-CCC  tcp  --  *      *       0.0.0.0/0    0.0.0.0/0

sudo iptables -t nat -L KUBE-SEP-AAA -v -n
#   0   0 DNAT       tcp  --  *      *       0.0.0.0/0    0.0.0.0/0    tcp dpt:80  to:10.244.1.5:8080
```

## Full iptables flow — NodePort

```
Packet: src=192.168.1.100 dst=192.168.1.10:30080 (external → NodePort)

1. PREROUTING chain:
   → KUBE-NODEPORTS

2. KUBE-NODEPORTS:
   → match dst :30080 → jump KUBE-SVC-ABC123

3. KUBE-SVC-ABC123:
   → random probability → KUBE-SEP-AAA

4. KUBE-SEP-AAA:
   → DNAT: dst 192.168.1.10:30080 → 10.244.1.5:8080

5. Packet: src=192.168.1.100 dst=10.244.1.5:8080 (external → pod)
   → routed to pod
```

```bash
# View KUBE-NODEPORTS
sudo iptables -t nat -S KUBE-NODEPORTS | grep 30080
# -A KUBE-NODEPORTS -p tcp -m tcp --dport 30080 -j KUBE-SVC-ABC123
```

> NodePort: KUBE-NODEPORTS → KUBE-SVC → KUBE-SEP → DNAT. Same chain as ClusterIP, different entry (KUBE-NODEPORTS vs KUBE-SERVICES).

## conntrack — connection tracking

```
First packet: new connection
  → iptables DNAT: Service IP → pod IP
  → conntrack record: src=client, dst=ServiceIP → src=client, dst=podIP

Subsequent packets: same connection
  → conntrack lookup: found → apply same DNAT
  → no need to traverse iptables again (fast path)

Response: pod → client
  → conntrack reverse NAT: src=podIP → src=ServiceIP
  → client sees response from Service IP
```

> conntrack = connection tracking. First packet: DNAT + record. Subsequent: fast path (conntrack lookup). Response: reverse NAT. **Same connection → same pod** (sticky). Load balancing per-connection, not per-packet.

```bash
# Check conntrack
sudo conntrack -L | grep 10.96.0.1
# tcp  6  86399  ESTABLISHED  src=10.244.1.5  dst=10.96.0.1  dport=80  src=10.244.2.3  dst=10.244.1.5  sport=8080  dport=43210  [ASSURED]
#   ↑ client → Service IP      ↑ DNAT → pod IP      ↑ reverse NAT

# Count conntrack entries
sudo conntrack -C
# 1500   ← 1500 tracked connections

# Conntrack max
sudo cat /proc/sys/net/netfilter/nf_conntrack_max
# 131072
```

> conntrack: `src=client dst=ServiceIP` → `src=client dst=podIP`. `[ASSURED]` = bidirectional (response received). conntrack max = 131072 (default). If full → new connection dropped.

## iptables rule count — O(n) problem

```
N Services × M endpoints per Service:
  KUBE-SERVICES:  N rules (1 per Service)
  KUBE-SVC-xxx:   M rules (1 per endpoint, random probability)
  KUBE-SEP-xxx:   1 rule (DNAT)
  Total: N × (M + 1) + N = O(N × M)

10000 Services × 10 endpoints = 110000 iptables rules
  → Every packet traverses KUBE-SERVICES (10000 rules)
  → O(n) lookup — slow with many Services
```

```bash
# Count iptables rules
sudo iptables -t nat -S | grep -c KUBE
# 50000   ← 50000 rules for 5000 Services

# Measure iptables traversal time
sudo iptables -t nat -L KUBE-SERVICES -v -n | wc -l
# 5000   ← 5000 rules in KUBE-SERVICES chain
```

> iptables = O(n). Every packet traverses KUBE-SERVICES (N rules). 10000 Services = 10000 rules per packet. Slow. IPVS = O(1) — solve this.

## kube-proxy config — iptables mode

```yaml
# /var/lib/kube-proxy/config.yaml
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "iptables"              # iptables mode
iptables:
  masqueradeAll: false
  masqueradeBit: 14
  minSyncDuration: 1s
  syncDuration: 30s
conntrack:
  maxPerCore: 32768
  min: 131072
  tcpCloseTimeout: 10s
  tcpEstablishedTimeout: 86400s   # 24h
```

| Config | Ý nghĩa |
|--------|---------|
| `mode` | `iptables`, `ipvs`, `ebpf` |
| `masqueradeAll` | SNAT all Service traffic |
| `syncDuration` | How often to sync rules |
| `conntrack.maxPerCore` | Max conntrack entries per CPU core |
| `conntrack.tcpEstablishedTimeout` | TCP connection timeout (24h default) |

> kube-proxy config: `mode: iptables` (default). `syncDuration: 30s` — resync rules every 30s. `conntrack.maxPerCore: 32768` — 32K entries per core.

## Debugging iptables

```bash
# List all KUBE chains
sudo iptables -t nat -S | grep "^-N KUBE" | head -20
# -N KUBE-SERVICES
# -N KUBE-NODEPORTS
# -N KUBE-SVC-ABC123
# -N KUBE-SEP-AAA
# -N KUBE-SEP-BBB
# -N KUBE-POSTROUTING

# Trace a Service
SVC_IP=$(kubectl get svc web-service -o jsonpath='{.spec.clusterIP}')
SVC_PORT=$(kubectl get svc web-service -o jsonpath='{.spec.ports[0].port}')
echo "Service: ${SVC_IP}:${SVC_PORT}"

# Find matching KUBE-SVC chain
sudo iptables -t nat -S KUBE-SERVICES | grep "${SVC_IP}"
# -A KUBE-SERVICES -d 10.96.0.1/32 -p tcp --dport 80 -j KUBE-SVC-ABC123

# View KUBE-SVC chain (endpoints)
SVC_CHAIN=$(sudo iptables -t nat -S KUBE-SERVICES | grep "${SVC_IP}" | grep -o 'KUBE-SVC-[A-Z0-9]*')
sudo iptables -t nat -S "${SVC_CHAIN}"

# View KUBE-SEP chains (DNAT)
for sep in $(sudo iptables -t nat -S "${SVC_CHAIN}" | grep -o 'KUBE-SEP-[A-Z0-9]*'); do
  echo "--- ${sep} ---"
  sudo iptables -t nat -S "${sep}"
done

# Count rules per Service
sudo iptables -t nat -S "${SVC_CHAIN}" | wc -l
# 4   ← 3 endpoints + 1 chain declaration
```

> Debug: find KUBE-SVC chain (match Service IP) → view endpoints (random probability) → view KUBE-SEP (DNAT to pod IP). Trace: Service IP → pod IP.

## Liên hệ với Kubernetes

- iptables mode = default. Mỗi Service = KUBE-SVC chain, mỗi endpoint = KUBE-SEP chain.
- Flow: KUBE-SERVICES → KUBE-SVC-<hash> → KUBE-SEP-<hash> → DNAT (Service IP → pod IP).
- Load balancing = `--mode random --probability`. Per-packet random. 3 endpoints: 0.333, 0.500, default.
- **conntrack** = connection tracking. First packet DNAT + record. Subsequent: fast path. Same connection → same pod (sticky).
- O(n) problem: N Services × M endpoints = N×M rules. Every packet traverses KUBE-SERVICES. Slow with many Services.
- NodePort: KUBE-NODEPORTS → KUBE-SVC → KUBE-SEP → DNAT. Same chain, different entry.
- `mode: iptables` in kube-proxy config. `syncDuration: 30s` — resync rules.
- Debug: `iptables -t nat -S KUBE-SERVICES` → find Service → KUBE-SVC → KUBE-SEP → DNAT.
- IPVS mode = O(1) — solve iptables O(n) problem. Xem notes 04.
