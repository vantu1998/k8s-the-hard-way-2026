# Exercise 04 — IPVS Mode

> **Mục tiêu**: Chuyển kube-proxy sang IPVS mode, `ipvsadm -L -n` xem virtual server + real server. Compare with iptables mode.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s (Phase 9), `sudo` privilege, `ipvsadm` installed

## Bối cảnh

IPVS = O(1) load balancing. Bài này switch kube-proxy sang IPVS, xem virtual/real server, compare with iptables.

## Prerequisites

```bash
ssh worker-1

# Install ipvsadm
sudo apt install -y ipvsadm 2>/dev/null || sudo yum install -y ipvsadm

# Verify
ipvsadm --version
# ipvsadm v1.31

# Check current mode
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep mode
# mode: iptables   ← current mode
```

## Bước 1: Deploy test Service (iptables mode)

```bash
# (trên master) — deploy before switching
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

SVC_IP=$(kubectl get svc web-service -o jsonpath='{.spec.clusterIP}')
echo "Service IP: ${SVC_IP}"
```

## Bước 2: Verify iptables mode (before)

```bash
ssh worker-1

# Check iptables rules exist
sudo iptables -t nat -S KUBE-SERVICES | grep "${SVC_IP}"
# -A KUBE-SERVICES -d 10.96.0.1/32 -p tcp --dport 80 -j KUBE-SVC-ABC123

# IPVS not loaded yet
lsmod | grep ip_vs
# (empty — IPVS not used in iptables mode)

# ipvsadm — empty
sudo ipvsadm -L -n
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port Scheduler Flags
#   -> RemoteAddress:Port  Forward Weight ActiveConn InActConn
# (empty — no virtual servers)
```

> iptables mode: KUBE-SVC chains in iptables. IPVS not loaded. `ipvsadm` empty.

**Kiểm tra**: iptables rules exist, IPVS empty.

## Bước 3: Switch to IPVS mode

```bash
# (trên master) — edit kube-proxy ConfigMap
kubectl -n kube-system edit configmap kube-proxy
# Find: mode: "iptables"
# Change to: mode: "ipvs"
# Save and exit

# Or patch directly
kubectl -n kube-system patch configmap kube-proxy --type=strategic \
  --patch='{"data":{"config\.conf":"apiVersion: kubeproxy.config.k8s.io/v1alpha1\nkind: KubeProxyConfiguration\nmode: ipvs\nipvs:\n  scheduler: rr\n"}}'

# Restart kube-proxy to pick up new config
kubectl -n kube-system rollout restart ds kube-proxy

# Wait for kube-proxy restart
kubectl -n kube-system rollout status ds/kube-proxy --timeout=60s
```

> Switch: edit ConfigMap `mode: ipvs`, restart kube-proxy. Kube-proxy reload config, switch from iptables to IPVS.

## Bước 4: Verify IPVS mode

```bash
ssh worker-1

# Check IPVS modules loaded
lsmod | grep ip_vs
# ip_vs_sh               16384  0
# ip_vs_wrr              16384  0
# ip_vs_rr               16384  1
# ip_vs                 172032  6 ip_vs_sh,ip_vs_wrr,ip_vs_rr
# nf_conntrack          172032  1 ip_vs

# Check kube-proxy log
sudo journalctl -u kube-proxy --no-pager -n 10 | grep -i "ipvs\|proxier"
# ... "Using ipvs Proxier"
# ... "ipvs scheduler: rr"
```

> After switch: IPVS modules loaded (`ip_vs_rr`, `ip_vs`, `nf_conntrack`). Kube-proxy log: "Using ipvs Proxier".

**Kiểm tra**: IPVS modules loaded, kube-proxy using IPVS.

## Bước 5: ipvsadm — view virtual servers

```bash
# List virtual servers (Services)
sudo ipvsadm -L -n
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port  Scheduler Flags
#   -> RemoteAddress:Port  Forward  Weight  ActiveConn  InActConn
# TCP  10.96.0.1:80        rr
#   -> 10.244.1.5:80       Masq     1       0           0
#   -> 10.244.2.3:80       Masq     1       0           0
#   -> 10.244.3.7:80       Masq     1       0           0
# TCP  10.96.0.10:53       rr
#   -> 10.244.1.3:53       Masq     1       0           0
# UDP  10.96.0.10:53       rr
#   -> 10.244.1.3:53       Masq     1       0           0
```

### ipvsadm output

| Column | Value | Ý nghĩa |
|--------|-------|---------|
| `Prot` | TCP/UDP | Protocol |
| `LocalAddress:Port` | `10.96.0.1:80` | Virtual server (Service IP:port) |
| `Scheduler` | `rr` | Round-robin |
| `RemoteAddress:Port` | `10.244.1.5:80` | Real server (pod IP:port) |
| `Forward` | `Masq` | NAT mode (MASQUERADE) |
| `Weight` | `1` | Equal weight |
| `ActiveConn` | `0` | Active connections |

> Virtual server = Service IP. Real server = pod IP. `rr` = round-robin. `Masq` = NAT. `Weight 1` = equal. Each Service = 1 virtual server, each pod = 1 real server.

**Kiểm tra**: ipvsadm shows virtual server (Service IP) + real servers (pod IPs).

## Bước 6: Compare iptables vs IPVS

```bash
# Check iptables — KUBE-SVC chains gone (or minimal)
sudo iptables -t nat -S | grep -c KUBE-SVC
# 0   ← no KUBE-SVC chains in IPVS mode!

# Only KUBE-MARK-MASQ for SNAT
sudo iptables -t nat -S | grep KUBE
# -N KUBE-MARK-DROP
# -N KUBE-MASQUERADE
# -N KUBE-POSTROUTING
# -A KUBE-POSTROUTING -m mark ! --mark 0x4000/0x4000 -j RETURN
# -A KUBE-POSTROUTING -j MARK --set-xmark 0x4000/0x4000
# -A KUBE-POSTROUTING -m comment --comment "kubernetes service traffic requiring SNAT" -j MASQUERADE
#   ← only SNAT, no DNAT (IPVS handles DNAT)

# IPVS handles DNAT — iptables only SNAT
echo "=== iptables rules ==="
sudo iptables -t nat -S | grep -c KUBE
# 5   ← only 5 rules (SNAT only)

echo "=== IPVS entries ==="
sudo ipvsadm -L -n | grep -c "^TCP\|^UDP"
# 5   ← 5 virtual servers (Services)
```

> IPVS mode: iptables chỉ có SNAT rules (KUBE-POSTROUTING). DNAT = IPVS. No KUBE-SVC/KUBE-SEP chains. Fewer iptables rules.

**Kiểm tra**: iptables has minimal rules (SNAT only), IPVS handles DNAT.

## Bước 7: Test connectivity — IPVS mode

```bash
# (trên master) — test Service still works
kubectl run client --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod client --timeout=30s

# Curl Service
kubectl exec client -- wget -qO- "http://${SVC_IP}" | head -1
# <!DOCTYPE html>   ← works via IPVS!

# Curl 10 times
for i in $(seq 1 10); do
  kubectl exec client -- wget -qO- "http://${SVC_IP}" 2>/dev/null
done | sort | uniq -c
#   4 Served by web-aaa   ← round-robin distribution
#   3 Served by web-bbb
#   3 Served by web-ccc
```

> IPVS mode: Service works. Round-robin distribution (vs random probability in iptables). `rr` scheduler = sequential A→B→C→A→B→C.

**Kiểm tra**: Service works in IPVS mode, round-robin distribution.

## Bước 8: Verify round-robin (vs random)

```bash
# IPVS rr = true round-robin (sequential)
# iptables random = random probability (not sequential)

# Curl 9 times, see exact round-robin
for i in $(seq 1 9); do
  kubectl exec client -- wget -qO- "http://${SVC_IP}" 2>/dev/null
done
# Served by web-aaa   ← 1
# Served by web-bbb   ← 2
# Served by web-ccc   ← 3
# Served by web-aaa   ← 4 (back to aaa)
# Served by web-bbb   ← 5
# Served by web-ccc   ← 6
# Served by web-aaa   ← 7
# Served by web-bbb   ← 8
# Served by web-ccc   ← 9
#   ← exact round-robin: A,B,C,A,B,C,A,B,C

# Check IPVS stats
sudo ipvsadm -L -n --stats
# IP Virtual Server version 1.2.1 (size=4096)
# Prot LocalAddress:Port  Conns  InPkts  OutPkts  InBytes  OutBytes
# TCP  10.96.0.1:80        9      63      63       5600     5600
#   -> 10.244.1.5:80       3      21      21       1900     1900   ← 3 conns
#   -> 10.244.2.3:80       3      21      21       1900     1900   ← 3 conns
#   -> 10.244.3.7:80       3      21      21       1900     1900   ← 3 conns
#   ← exactly 3 per pod (round-robin)
```

> IPVS `rr` = exact round-robin (A,B,C,A,B,C). iptables random = random (12,10,8). IPVS = deterministic, iptables = probabilistic.

**Kiểm tra**: IPVS round-robin = exact 3/3/3 (deterministic), vs iptables random ~10/10/10 (probabilistic).

## Bước 9: Change scheduler — least-connection

```bash
# (trên master) — change scheduler to lc (least-connection)
kubectl -n kube-system edit configmap kube-proxy
# Change: scheduler: "rr" → scheduler: "lc"
# Save

# Restart kube-proxy
kubectl -n kube-system rollout restart ds/kube-proxy
kubectl -n kube-system rollout status ds/kube-proxy --timeout=60s

# Verify scheduler
ssh worker-1 'sudo ipvsadm -L -n | head -5'
# Prot LocalAddress:Port  Scheduler Flags
# TCP  10.96.0.1:80        lc         ← least-connection
#   -> 10.244.1.5:80       Masq     1       0           0
```

> `lc` = least-connection. IPVS picks pod with fewest active connections. Better for uneven load (some connections long, some short). `rr` = sequential, `lc` = adaptive.

## Cleanup

```bash
# (trên master)
kubectl delete deployment web
kubectl delete svc web-service
kubectl delete pod client

# Switch back to iptables mode (optional)
kubectl -n kube-system edit configmap kube-proxy
# Change: mode: "ipvs" → mode: "iptables"
kubectl -n kube-system rollout restart ds/kube-proxy
```

## Câu hỏi tự kiểm tra

1. IPVS mode — iptables có còn KUBE-SVC chains không? Tại sao?
2. `ipvsadm -L -n` — virtual server là gì? Real server là gì?
3. IPVS `rr` vs iptables random — khác nhau thế nào? Cái nào chính xác hơn?
4. `lc` (least-connection) khác `rr` (round-robin) thế nào? Khi nào dùng `lc`?
5. Switch iptables → IPVS — cần làm gì? Có downtime không?

## Đáp án tham khảo

1. **Không** — IPVS handle DNAT (virtual server → real server). iptables chỉ còn SNAT (KUBE-POSTROUTING, MASQUERADE). No KUBE-SVC/KUBE-SEP chains. IPVS = data plane for DNAT, iptables = SNAT only. Fewer iptables rules.
2. **Virtual server** = Service IP:port (10.96.0.1:80). **Real server** = pod IP:port (10.244.1.5:80). Virtual = frontend (client connect). Real = backend (pod). IPVS DNAT: virtual → real.
3. **IPVS rr** = exact round-robin (A,B,C,A,B,C — deterministic). **iptables random** = random probability (12,10,8 — probabilistic). IPVS chính xác hơn (exact distribution). iptables xấp xỉ (law of large numbers).
4. **rr** = sequential (A,B,C,A,B,C). **lc** = pick fewest active connections (adaptive). `lc` better cho uneven load (some connections long, some short). `rr` = equal, `lc` = adaptive. Dùng `lc` khi pod có uneven connection duration.
5. Edit ConfigMap `mode: ipvs`, restart kube-proxy. **No downtime** — existing connections via conntrack/IPVS conn (sticky). New connections via IPVS. Brief moment during restart = new connections might fail (kube-proxy restarting). < 1s downtime.
