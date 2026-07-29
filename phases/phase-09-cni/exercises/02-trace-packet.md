# Exercise 02 — Trace Packet Path

> **Mục tiêu**: Tạo 2 pod khác node, trace packet path: pod → veth → bridge → route → node interface → remote node.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s 2+ node (Phase 8), SSH access vào 2 worker node, `sudo` privilege

## Bối cảnh

Cross-node pod communication: pod → bridge → node → route/tunnel → remote node → bridge → pod. Bài này trace packet path bằng `traceroute`, `tcpdump`, `ip route`.

## Prerequisites

```bash
# Verify 2+ nodes
kubectl get nodes -o wide
# NAME       STATUS   ROLES    INTERNAL IP
# master     Ready    control-plane   192.168.1.10
# worker-1   Ready    <none>          192.168.1.11
# worker-2   Ready    <none>          192.168.1.12

# Check node pod CIDR
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
# master     10.244.0.0/24
# worker-1   10.244.1.0/24
# worker-2   10.244.2.0/24
```

## Bước 1: Deploy pods on different nodes

```bash
# Pod on worker-1
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-a
  labels:
    app: pod-a
spec:
  nodeName: worker-1
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: pod-b
  labels:
    app: pod-b
spec:
  nodeName: worker-2
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sleep", "3600"]
EOF
```

```bash
kubectl wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=60s

# Get pod IPs
POD_A_IP=$(kubectl get pod pod-a -o jsonpath='{.status.podIP}')
POD_B_IP=$(kubectl get pod pod-b -o jsonpath='{.status.podIP}')
echo "Pod A (worker-1): ${POD_A_IP}"
echo "Pod B (worker-2): ${POD_B_IP}"
# Pod A (worker-1): 10.244.1.5
# Pod B (worker-2): 10.244.2.3
```

**Kiểm tra**: 2 pods Running on different nodes, different podCIDR.

## Bước 2: Traceroute — pod to pod

```bash
# Traceroute from pod-a to pod-b
kubectl exec pod-a -- traceroute "${POD_B_IP}"
# traceroute to 10.244.2.3 (10.244.2.3), 30 hops max, 46 byte packets
# 1  10.244.1.1 (10.244.1.1)   0.1 ms   ← bridge (gateway on worker-1)
# 2  192.168.1.12 (192.168.1.12)  1.2 ms  ← worker-2 node IP
# 3  10.244.2.3 (10.244.2.3)   1.5 ms   ← pod-b

# Traceroute from pod-b to pod-a
kubectl exec pod-b -- traceroute "${POD_A_IP}"
# traceroute to 10.244.1.5 (10.244.1.5), 30 hops max
# 1  10.244.2.1 (10.244.2.1)   0.1 ms   ← bridge (gateway on worker-2)
# 2  192.168.1.11 (192.168.1.11)  1.1 ms  ← worker-1 node IP
# 3  10.244.1.5 (10.244.1.5)   1.4 ms   ← pod-a
```

> Packet path: pod → bridge (gateway) → remote node → pod. Bridge = hop 1 (gateway). Remote node = hop 2 (routing). Pod = hop 3 (destination).

**Kiểm tra**: Traceroute shows bridge → remote node → pod.

## Bước 3: Check routing table (trên worker-1)

```bash
ssh worker-1

# Node routing table
ip route
# default via 192.168.1.1 dev eth0          ← default gateway (physical)
# 10.244.1.0/24 dev cbr0 proto kernel scope link src 10.244.1.1  ← local pod CIDR (bridge)
# 10.244.2.0/24 via 192.168.1.12 dev eth0     ← remote pod CIDR (route to worker-2)
# 10.244.0.0/24 via 192.168.1.10 dev eth0     ← master pod CIDR

# Route for pod-b IP
ip route get "${POD_B_IP}"
# 10.244.2.3 via 192.168.1.12 dev eth0 src 192.168.1.11
#   ← route to worker-2 (192.168.1.12) via eth0
```

> Node route: `10.244.2.0/24 via 192.168.1.12` = pod CIDR worker-2 → route via worker-2 node IP. Flat network (BGP/routing). VXLAN = route via `flannel.1` (VXLAN interface).

**Kiểm tra**: Route for `10.244.2.0/24` → via worker-2 node IP.

## Bước 4: Check pod routing table

```bash
# Pod-a route (inside network namespace)
SANDBOX_A=$(sudo crictl pods --name pod-a -q)
PAUSE_A_PID=$(sudo crictl inspectp "${SANDBOX_A}" -o json | jq -r '.info.pid')

sudo nsenter -n -t "${PAUSE_A_PID}" ip route
# default via 10.244.1.1 dev eth0           ← default via bridge (gateway)
# 10.244.1.0/24 dev eth0 proto kernel scope link src 10.244.1.5  ← local subnet

# Route for pod-b
sudo nsenter -n -t "${PAUSE_A_PID}" ip route get "${POD_B_IP}"
# 10.244.2.3 via 10.244.1.1 dev eth0 src 10.244.1.5
#   ← not in 10.244.1.0/24 → default route → bridge (gateway)
```

> Pod route: `10.244.2.3` not in local subnet → default route → bridge (10.244.1.1). Bridge = gateway, forward to node routing table.

**Kiểm tra**: Pod route for remote pod → default via bridge.

## Bước 5: tcpdump — capture packet on bridge

```bash
# Terminal 1 — tcpdump on bridge cbr0 (worker-1)
sudo tcpdump -i cbr0 -n icmp host "${POD_B_IP}" &
TCPDUMP_PID=$!

# Terminal 2 — ping from pod-a to pod-b
kubectl exec pod-a -- ping -c 3 "${POD_B_IP}"
# 64 bytes from 10.244.2.3: icmp_seq=1 ttl=64 time=1.2 ms

# Terminal 1 — tcpdump output
# 10:00:00.000000 IP 10.244.1.5 > 10.244.2.3: ICMP echo request
# 10:00:00.001200 IP 10.244.2.3 > 10.244.1.5: ICMP echo reply
# 10:00:01.000000 IP 10.244.1.5 > 10.244.2.3: ICMP echo request
# 10:00:01.001200 IP 10.244.2.3 > 10.244.1.5: ICMP echo reply

# Stop tcpdump
sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null
```

> tcpdump on bridge: pod-a (10.244.1.5) → pod-b (10.244.2.3). ICMP echo request + reply. Bridge forward packet to node routing.

**Kiểm tra**: tcpdump shows ICMP request/reply between pod IPs on bridge.

## Bước 6: tcpdump — capture on node interface (eth0)

```bash
# Terminal 1 — tcpdump on eth0 (worker-1) — physical interface
sudo tcpdump -i eth0 -n icmp host "${POD_B_IP}" &
TCPDUMP_PID=$!

# Terminal 2 — ping from pod-a to pod-b
kubectl exec pod-a -- ping -c 3 "${POD_B_IP}"

# Terminal 1 — tcpdump output
# 10:00:00.000000 IP 192.168.1.11 > 192.168.1.12: ICMP echo request
#   ← SNAT? No — pod IP visible if no SNAT (flat/BGP)
#   ← Or: IP 10.244.1.5 > 10.244.2.3 (if no SNAT, flat routing)

sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null
```

> tcpdump on eth0: packet leaves node via physical interface. If flat (BGP) → pod IP visible (no SNAT). If overlay (VXLAN) → UDP 4789 encapsulated.

**Kiểm tra**: tcpdump on eth0 shows packet to remote node (pod IP or VXLAN).

## Bước 7: Check VXLAN (if overlay CNI)

```bash
# Check if VXLAN interface exists (Flannel, Calico VXLAN)
ip link show type vxlan
# flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
#   vxlan id 1 dev eth0 srcport 0-0 dstport 4789

# If VXLAN — tcpdump on flannel.1
sudo tcpdump -i flannel.1 -n host "${POD_B_IP}" &
TCPDUMP_PID=$!
kubectl exec pod-a -- ping -c 3 "${POD_B_IP}"
# 10:00:00.000000 IP 10.244.1.5 > 10.244.2.3: ICMP echo request
#   ← inner packet (pod IP) on VXLAN interface
sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null

# tcpdump on eth0 — see VXLAN encapsulated (UDP 4789)
sudo tcpdump -i eth0 -n udp port 4789 &
TCPDUMP_PID=$!
kubectl exec pod-a -- ping -c 3 "${POD_B_IP}"
# 10:00:00.000000 IP 192.168.1.11.4789 > 192.168.1.12.4789: OTV, ...
#   ← outer packet (node IP, UDP 4789)
sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null
```

> VXLAN: inner packet (pod IP) on `flannel.1`. Outer packet (node IP, UDP 4789) on `eth0`. Pod IP hidden trong tunnel.

## Bước 8: Full packet path diagram

```
Pod A (10.244.1.5, worker-1) → Pod B (10.244.2.3, worker-2):

[Worker-1]
  Pod A eth0 (10.244.1.5)
    → veth-aaa (pod netns)
    → veth-bbb (host)
    → bridge cbr0 (10.244.1.1)     ← hop 1: gateway
    → route: 10.244.2.0/24 via 192.168.1.12
    → eth0 (192.168.1.11)          ← physical interface
    → [network]                    ← VXLAN tunnel (UDP 4789) or direct

[Worker-2]
  eth0 (192.168.1.12)              ← receive packet
    → route: 10.244.2.0/24 dev cbr0
    → bridge cbr0 (10.244.2.1)     ← hop 2: gateway
    → veth-ccc (host)
    → veth-ddd (pod netns)
    → Pod B eth0 (10.244.2.3)      ← hop 3: destination
```

## Cleanup

```bash
kubectl delete pod pod-a pod-b
```

## Câu hỏi tự kiểm tra

1. Traceroute từ pod-a đến pod-b — hop đầu là gì? Tại sao?
2. Node routing table — route cho remote pod CIDR đi đâu? (bridge hay eth0?)
3. Pod routing table — route cho remote pod IP đi đâu? (bridge hay direct?)
4. Flat (BGP) vs Overlay (VXLAN) — tcpdump trên eth0 khác nhau thế nào?
5. VXLAN encapsulate — inner IP là gì? Outer IP là gì? Port nào?

## Đáp án tham khảo

1. **Bridge (gateway)** — hop đầu = 10.244.1.1 (bridge cbr0 IP). Pod default route via bridge. Bridge = gateway, forward to node routing table. Hop 2 = remote node IP (routing). Hop 3 = destination pod.
2. Route cho `10.244.2.0/24` (remote pod CIDR) → `via 192.168.1.12 dev eth0` (remote node IP, physical interface). **Not bridge** — bridge chỉ cho local pod CIDR. Remote = node routing (eth0).
3. Pod route cho remote pod IP → **default route via bridge** (10.244.1.1). Pod không biết remote pod CIDR — chỉ biết default route. Bridge = gateway, node route table handle rest.
4. **Flat (BGP)**: tcpdump on eth0 shows pod IP (10.244.1.5 → 10.244.2.3) — no encapsulation, pod IP visible. **Overlay (VXLAN)**: tcpdump on eth0 shows node IP + UDP 4789 (192.168.1.11:4789 → 192.168.1.12:4789) — pod IP hidden inside tunnel.
5. **Inner IP**: pod IP (10.244.1.5 → 10.244.2.3) — original packet. **Outer IP**: node IP (192.168.1.11 → 192.168.1.12) — tunnel. **Port**: UDP 4789 (VXLAN standard port). Inner = passenger, outer = vehicle.
