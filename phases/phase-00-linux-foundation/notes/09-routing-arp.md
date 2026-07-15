# 09 — Routing & ARP

## Routing — packet đi đâu

Routing table quyết định packet đi ra interface nào, đến gateway nào.

```bash
# Xem routing table
ip route
# default via 192.168.1.1 dev eth0        ← default route
# 10.244.0.0/24 dev cbr0 proto kernel     ← pod CIDR, đi qua bridge
# 192.168.1.0/24 dev eth0 proto kernel    ← local subnet

# Xem routing cache (kernel cache)
ip route get 10.244.0.5
# 10.244.0.5 dev cbr0 src 10.244.0.1
#    cache
```

### Routing decision flow

1. Kernel nhận packet cần gửi.
2. Lookup routing table: match destination IP với longest prefix.
3. Nếu match → gửi ra interface, qua gateway (nếu cần).
4. Nếu không match → default route (nếu có).
5. Nếu không có default route → `EHOSTUNREACH` / `ENETUNREACH`.

### Route types

| Type | Ý nghĩa |
|------|---------|
| `default` | Route mặc định khi không match gì khác |
| `via <gateway>` | Gửi qua gateway (router next hop) |
| `dev <interface>` | Gửi trực tiếp ra interface (cùng subnet) |
| `proto kernel` | Kernel tự tạo (khi gán IP cho interface) |
| `scope link` | Đích trong cùng link/subnet |
| `scope host` | Đích là local host |

### Thêm/xóa route

```bash
# Thêm route
sudo ip route add 10.244.1.0/24 via 192.168.1.10 dev eth0

# Xóa route
sudo ip route del 10.244.1.0/24

# Thêm default route
sudo ip route add default via 192.168.1.1

# Xem route cho 1 đích cụ thể
ip route get 8.8.8.8
```

## ARP — IP → MAC

ARP (Address Resolution Protocol) ánh xạ IP → MAC address trên cùng subnet (layer 2).

### Tại sao cần ARP

Ethernet frame cần MAC address đích, nhưng chúng ta chỉ biết IP. ARP hỏi: "Ai có IP 10.0.0.2? Cho tôi MAC của bạn."

### ARP flow

```
Host A (10.0.0.1)              Host B (10.0.0.2)
     |                              |
     |  ARP Request (broadcast)     |
     |  "Who has 10.0.0.2?"        |
     |----------------------------->|  (broadcast đến tất cả)
     |                              |
     |  ARP Reply (unicast)         |
     |  "10.0.0.2 is at aa:bb:cc"  |
     |<-----------------------------|  (chỉ gửi cho A)
     |                              |
     |  ICMP Echo (unicast)         |
     |  dst MAC = aa:bb:cc          |
     |----------------------------->|
```

### Xem ARP table

```bash
ip neigh
# 10.0.0.2 dev veth-pod1 lladdr aa:bb:cc:dd:ee:ff REACHABLE
# 192.168.1.1 dev eth0 lladdr 11:22:33:44:55:66 STALE

# Hoặc:
arp -n

# Xóa ARP entry
sudo ip neigh del 10.0.0.2 dev veth-pod1

# Flush ARP cache
sudo ip neigh flush all
```

### ARP states

| State | Ý nghĩa |
|-------|---------|
| `REACHABLE` | Đã xác nhận, có thể dùng |
| `STALE` | Quá lâu không dùng, cần xác nhận lại |
| `DELAY` | Đang chờ xác nhận |
| `PROBE` | Đang gửi ARP probe |
| `FAILED` | Không trả lời |
| `INCOMPLETE` | Đã request, chưa nhận reply |

## Packet flow: Pod → Pod khác node

```
Pod A (10.244.0.5) trên Node 1 → Pod B (10.244.1.3) trên Node 2

1. Pod A: ping 10.244.1.3
2. Pod A netns: ip route → default via 10.244.0.1 (bridge)
3. Pod A: ARP request "Who has 10.244.0.1?" → bridge reply MAC
4. Pod A: ICMP packet → veth → bridge (Node 1)
5. Node 1: ip route → 10.244.1.0/24 via <node2-ip> dev eth0
6. Node 1: ARP request "Who has <node2-ip>?" → Node 2 reply
7. Node 1: ICMP packet encapsulated trong Ethernet frame → eth0 → wire
8. Node 2: nhận packet, ip route → 10.244.1.0/24 dev cbr0
9. Node 2: ARP request "Who has 10.244.1.3?" → Pod B reply
10. Node 2: packet → bridge → veth → Pod B
```

### Với overlay (VXLAN)

```
Pod A → Pod B (khác node, VXLAN tunnel)

1-5. Same as above
6. Node 1: route 10.244.1.0/24 → vxlan0 (VXLAN interface)
7. Node 1: encapsulate packet trong UDP VXLAN → gửi đến Node 2 IP:4789
8. Node 2: nhận UDP packet, decapsulate → original packet
9-10. Same as above
```

## Liên hệ với Kubernetes

### Pod CIDR

Mỗi node nhận một **pod CIDR range** (ví dụ: node1 = 10.244.0.0/24, node2 = 10.244.1.0/24). Controller manager cấp CIDR, kubelet report, CNI gán IP từ range này.

```bash
# Xem pod CIDR của node
kubectl get node <node> -o jsonpath='{.spec.podCIDR}'
# 10.244.0.0/24
```

### Routing trong CNI

| CNI | Routing method |
|-----|---------------|
| Bridge CNI | Bridge + route trên node |
| Flannel | VXLAN overlay hoặc host-gw (direct routing) |
| Calico | BGP — node quảng bá pod CIDR cho nhau |
| Cilium | eBPF direct routing hoặc VXLAN |

### Debug routing

```bash
# Xem route trên node
ip route

# Xem route trong pod netns
nsenter -t <pid> -n ip route

# Trace packet path
ip route get <pod-ip-remote-node>

# Xem ARP
ip neigh

# tcpdump trên interface
sudo tcpdump -i eth0 icmp -n
```
