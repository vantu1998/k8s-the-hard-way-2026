# 02 — Bridge Network

## Bridge CNI plugin

Bridge = Linux bridge (`cbr0`). Tạo veth pair: một đầu trong pod netns, một đầu gắn bridge. Pod giao tiếp qua bridge.

```
Node (host)
  │
  ├── cbr0 (Linux bridge, IP: 10.244.1.1/24)
  │     ├── veth-aaa ──┐
  │     ├── veth-bbb ──┤
  │     └── veth-ccc ──┘
  │
  ├── eth0 (node interface, IP: 192.168.1.10)
  │
  └── Pod netns (per pod)
        ├── eth0 (veth-aaa other end, IP: 10.244.1.5/24)
        │   route: default via 10.244.1.1
        └── lo
```

> Bridge = layer 2 switch (software). Veth = virtual ethernet cable. Pod eth0 ← veth → bridge → veth → pod eth0. Pod giao tiếp qua bridge (same node).

## Veth pair

```
Veth pair = virtual ethernet cable (2 ends)
  ├── veth-xxx (in pod netns, renamed to eth0)
  └── veth-yyy (on host, attached to bridge cbr0)

Traffic: pod eth0 → veth-xxx → veth-yyy → bridge → veth-zzz → veth-www → pod eth0
```

```bash
# On host — list veth interfaces
ip link show type veth
# veth-yyy: <BROADCAST,MULTICAST> mtu 1450
# veth-zzz: <BROADCAST,MULTICAST> mtu 1450

# On pod netns — eth0 is veth other end
sudo nsenter -n -t <pause_pid> ip link show eth0
# eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
#   link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff
```

> Veth = 2 interface liên kết. Packet vào một đầu → ra đầu kia. Pod eth0 = một đầu, veth-yyy (trên host) = đầu kia, gắn vào bridge.

## Bridge — cbr0

```bash
# Check bridge on host
ip addr show cbr0
# cbr0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
#   inet 10.244.1.1/24 brd 10.244.1.255 scope global cbr0

# Bridge has all veth attached
bridge link
# veth-yyy  cbr0    state forwarding
# veth-zzz  cbr0    state forwarding

# Bridge MAC table (forwarding database)
bridge fdb show br cbr0
# aa:bb:cc:dd:ee:ff dev veth-yyy master cbr0
# 11:22:33:44:55:66 dev veth-zzz master cbr0
```

> Bridge `cbr0` = layer 2 switch. IP 10.244.1.1 = gateway cho pod. Bridge forward packet dựa trên MAC table (learning switch).

## Bridge CNI plugin flow — ADD

```
CNI_COMMAND=ADD, CNI_NETNS=/var/run/netns/cni-xxx

1. Create veth pair:
   ip link add veth-yyy type veth peer name veth-xxx

2. Attach veth-yyy to bridge:
   ip link set veth-yyy master cbr0
   ip link set veth-yyy up

3. Move veth-xxx to pod netns:
   ip link set veth-xxx netns /var/run/netns/cni-xxx

4. In pod netns:
   ip netns exec /var/run/netns/cni-xxx ip link set veth-xxx name eth0
   ip netns exec /var/run/netns/cni-xxx ip link set eth0 up
   ip netns exec /var/run/netns/cni-xxx ip link set lo up

5. Call IPAM (host-local):
   Assign IP: 10.244.1.5/24 from 10.244.1.0/24 range

6. In pod netns:
   ip netns exec /var/run/netns/cni-xxx ip addr add 10.244.1.5/24 dev eth0
   ip netns exec /var/run/netns/cni-xxx ip route add default via 10.244.1.1

7. On host (if isGateway=true):
   ip addr add 10.244.1.1/24 dev cbr0  (if not already)

8. Enable forwarding:
   sysctl net.ipv4.ip_forward=1

9. Return JSON result:
   { "ips": [{"address": "10.244.1.5/24"}], "routes": [{"dst": "0.0.0.0/0", "gw": "10.244.1.1"}] }
```

### Step-by-step verification

```bash
# 1. Before pod — no veth
ip link show type veth
# (empty)

# 2. Deploy pod
kubectl run web --image=nginx

# 3. After pod — veth created
ip link show type veth
# veth-yyy: <BROADCAST,MULTICAST,UP> mtu 1450
# veth-xxx: <BROADCAST,MULTICAST,UP> mtu 1450

# 4. Veth attached to bridge
bridge link
# veth-yyy  cbr0  state forwarding

# 5. Pod eth0 has IP
crictl inspectp <sandbox-id> -o json | jq '.status.network.ip'
# "10.244.1.5"

# 6. Pod route
sudo nsenter -n -t <pause_pid> ip route
# default via 10.244.1.1 dev eth0
# 10.244.1.0/24 dev eth0 proto kernel scope link src 10.244.1.5
```

## ARP — Address Resolution Protocol

```
Pod A (10.244.1.5) → Pod B (10.244.1.6) — same node:

1. Pod A: ARP request "who has 10.244.1.6?"
   → broadcast on bridge cbr0
2. Bridge: forward ARP to all veth
3. Pod B: ARP reply "10.244.1.6 is at <mac-b>"
   → unicast back to Pod A
4. Pod A: cache ARP (10.244.1.6 → <mac-b>)
5. Pod A: send packet to 10.244.1.6
   → eth0 → veth → bridge → veth → Pod B eth0
```

> Bridge = layer 2. Pod giao tiếp qua MAC address (ARP resolve IP → MAC). Bridge learning MAC → forward chỉ đến đúng port (không broadcast sau khi learn).

## Same-node pod communication

```
Pod A (10.244.1.5) → Pod B (10.244.1.6) — same node:

Pod A eth0 → veth-aaa → bridge cbr0 → veth-bbb → Pod B eth0

# Trace
sudo nsenter -n -t <pod_a_pid> ping 10.244.1.6
# 64 bytes from 10.244.1.6: icmp_seq=1 ttl=64 time=0.1 ms

# Packet path (same node, no routing, layer 2 bridge)
# Pod A → eth0 → veth → bridge → veth → Pod B → eth0
```

> Same node: pod → veth → bridge → veth → pod. Layer 2 (bridge forward). **No routing** — bridge switch packet directly. < 0.1ms latency.

## Pod to node communication

```
Pod (10.244.1.5) → Node (192.168.1.10):

1. Pod: route lookup — 192.168.1.10 not in 10.244.1.0/24
   → default route via 10.244.1.1 (bridge cbr0)
2. Pod: send to gateway 10.244.1.1
   → eth0 → veth → bridge
3. Bridge cbr0: receive packet, dest IP = 192.168.1.10
   → bridge is gateway, route to eth0
4. Node: iptables/nat (MASQUERADE)
   → SNAT: 10.244.1.5 → 192.168.1.10
5. Node eth0: send to 192.168.1.10 (or external)
```

> Pod → external: pod → bridge (gateway) → node → SNAT → external. Bridge = gateway. Node iptables MASQUERADE (SNAT pod IP → node IP).

## MTU

```
MTU (Maximum Transmission Unit):
  eth0 (node):     1500 bytes
  cbr0 (bridge):   1450 bytes  ← 50 bytes overhead (VXLAN) or 1500 (bridge only)
  eth0 (pod):      1450 bytes  ← match bridge MTU

If MTU mismatch:
  Pod sends 1500 byte packet → bridge drops (exceeds 1450 MTU)
  → Pod: fragmentation or connection fail
```

```bash
# Check MTU
ip link show cbr0 | grep mtu
# cbr0: mtu 1450

# Pod MTU
sudo nsenter -n -t <pause_pid> ip link show eth0 | grep mtu
# eth0: mtu 1450

# Node MTU
ip link show eth0 | grep mtu
# eth0: mtu 1500
```

> Bridge MTU = min(node MTU, pod MTU). Overlay (VXLAN) = 50 bytes overhead → 1450. Bridge only = 1500. MTU mismatch = packet drop, connection fail.

## Bridge config

```json
{
  "type": "bridge",
  "bridge": "cbr0",
  "isGateway": true,
  "isDefaultGateway": true,
  "isBroadcast": true,
  "hairpinMode": false,
  "ipMasq": false,
  "mtu": 1450,
  "ipam": {
    "type": "host-local",
    "ranges": [[{"subnet": "10.244.1.0/24"}]],
    "routes": [{"dst": "0.0.0.0/0"}]
  }
}
```

| Config | Ý nghĩa |
|--------|---------|
| `bridge` | Bridge name (cbr0) |
| `isGateway` | Assign IP to bridge (act as gateway) |
| `isDefaultGateway` | Set bridge as default gateway in pod |
| `hairpinMode` | Allow pod to access itself via Service IP |
| `ipMasq` | SNAT pod traffic (masquerade) |
| `mtu` | MTU for veth + bridge |

> `isGateway: true` = bridge có IP (gateway). `isDefaultGateway: true` = pod default route via bridge. `hairpinMode` = pod access Service IP → DNAT → back to same pod (hairpin).

## Liên hệ với Kubernetes

- Bridge = Linux bridge (`cbr0`), layer 2 switch. Veth pair = virtual cable (pod eth0 ↔ bridge).
- Bridge flow ADD: create veth → attach to bridge → move to netns → rename eth0 → IPAM assign IP → setup route.
- Same-node pod: eth0 → veth → bridge → veth → eth0 (layer 2, no routing, < 0.1ms).
- Pod → external: eth0 → bridge (gateway) → node → SNAT → external.
- Bridge IP = pod gateway (10.244.1.1). Pod default route via bridge.
- ARP: bridge learning MAC → forward chỉ đến đúng port.
- MTU: bridge 1450 (overlay) hoặc 1500 (bridge only). Mismatch = packet drop.
- `isGateway: true` = bridge có IP. `isDefaultGateway: true` = pod default route via bridge.
- `hairpinMode` = pod access Service IP → DNAT → back to same pod.
- Calico/Cilium không dùng bridge — dùng veth trực tiếp + routing/eBPF.
