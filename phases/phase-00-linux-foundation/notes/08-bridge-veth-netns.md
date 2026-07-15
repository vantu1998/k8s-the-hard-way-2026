# 08 — Bridge, veth, Network Namespace

## Đây là cốt lõi container networking

Container networking = **network namespace** (isolation) + **veth pair** (kết nối) + **bridge** (switch ảo) + **routing** (định tuyến).

Khi pod start:
1. CRI tạo network namespace cho pod.
2. CNI plugin tạo **veth pair** — một đầu trong pod netns, một đầu gắn **bridge** trên node.
3. CNI gán IP cho veth trong pod, thêm route.
4. Pod có thể giao tiếp với pod khác qua bridge/routing.

## Bridge — switch ảo

Bridge hoạt động như **switch layer 2** — forward frame dựa trên MAC address.

```bash
# Tạo bridge
sudo ip link add name br0 type bridge

# Up bridge
sudo ip link set br0 up

# Gán IP cho bridge (gateway cho pod)
sudo ip addr add 10.244.0.1/24 dev br0

# Xem bridge
ip link show br0
bridge link show
bridge fdb show br br0    # MAC forwarding table
```

### Bridge forwarding logic

1. Frame đến bridge port (veth).
2. Bridge đọc MAC đích.
3. Nếu MAC có trong forwarding table → forward đến port đó.
4. Nếu không có → flood ra tất cả port (như hub).
5. Bridge học MAC nguồn → cập nhật forwarding table.

## veth pair — cáp nối ảo

veth (virtual ethernet) pair = **2 interface nối nhau** — gì vào đầu này ra đầu kia. Dùng để nối 2 network namespace.

```bash
# Tạo veth pair: veth0 ↔ veth1
sudo ip link add veth0 type veth peer name veth1

# veth0 ở host namespace, veth1 sẽ chuyển sang pod netns
sudo ip link set veth0 up

# Xem
ip link show veth0
ip link show veth1
```

## Network Namespace (netns) — review

```bash
# Tạo netns
sudo ip netns add pod1

# Chạy lệnh trong netns
sudo ip netns exec pod1 ip addr

# Vào shell trong netns
sudo ip netns exec pod1 bash
```

## Kết nối 2 netns bằng veth — step by step

```bash
# 1. Tạo 2 netns
sudo ip netns add ns1
sudo ip netns add ns2

# 2. Tạo veth pair
sudo ip link add veth-ns1 type veth peer name veth-ns2

# 3. Chuyển mỗi đầu vào 1 netns
sudo ip link set veth-ns1 netns ns1
sudo ip link set veth-ns2 netns ns2

# 4. Gán IP cho mỗi đầu
sudo ip netns exec ns1 ip addr add 10.0.0.1/24 dev veth-ns1
sudo ip netns exec ns2 ip addr add 10.0.0.2/24 dev veth-ns2

# 5. Up interface
sudo ip netns exec ns1 ip link set veth-ns1 up
sudo ip netns exec ns2 ip link set veth-ns2 up

# 6. Up loopback (cần thiết cho một số app)
sudo ip netns exec ns1 ip link set lo up
sudo ip netns exec ns2 ip link set lo up

# 7. Ping!
sudo ip netns exec ns1 ping 10.0.0.2
# PING 10.0.0.2 56(84) bytes of data.
# 64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=0.12 ms
```

## Kết nối nhiều netns qua bridge

```bash
# 1. Tạo bridge trên host
sudo ip link add br0 type bridge
sudo ip link set br0 up
sudo ip addr add 10.0.0.254/24 dev br0

# 2. Tạo 2 netns
sudo ip netns add pod1
sudo ip netns add pod2

# 3. Tạo veth pair cho pod1, một đầu gắn bridge
sudo ip link add veth-pod1 type veth peer name veth-pod1-br
sudo ip link set veth-pod1 netns pod1
sudo ip link set veth-pod1-br master br0
sudo ip link set veth-pod1-br up

# 4. Tạo veth pair cho pod2
sudo ip link add veth-pod2 type veth peer name veth-pod2-br
sudo ip link set veth-pod2 netns pod2
sudo ip link set veth-pod2-br master br0
sudo ip link set veth-pod2-br up

# 5. Gán IP
sudo ip netns exec pod1 ip addr add 10.0.0.1/24 dev veth-pod1
sudo ip netns exec pod1 ip link set veth-pod1 up
sudo ip netns exec pod1 ip link set lo up

sudo ip netns exec pod2 ip addr add 10.0.0.2/24 dev veth-pod2
sudo ip netns exec pod2 ip link set veth-pod2 up
sudo ip netns exec pod2 ip link set lo up

# 6. Ping pod1 → pod2 (qua bridge)
sudo ip netns exec pod1 ping 10.0.0.2

# 7. Ping pod1 → host (qua bridge → br0)
sudo ip netns exec pod1 ping 10.0.0.254
```

## Sơ đồ network

```
┌─────────────────────────────────────────────────┐
│                    Host                          │
│                                                  │
│   ┌──────────┐    ┌──────────┐                  │
│   │  pod1    │    │  pod2    │                  │
│   │ netns    │    │ netns    │                  │
│   │10.0.0.1  │    │10.0.0.2  │                  │
│   └────┬─────┘    └────┬─────┘                  │
│        │ veth-pod1    │ veth-pod2               │
│        │              │                         │
│   ┌────┴──────────────┴─────┐                   │
│   │       br0 (bridge)      │                   │
│   │       10.0.0.254        │                   │
│   └──────────────────────────┘                  │
│                  │                              │
│              eth0 (host)                        │
└──────────────────────────────────────────────────┘
```

## Liên hệ với Kubernetes

### Pod networking model

- Mỗi pod có IP riêng (không NAT).
- Pod trong cùng node → giao tiếp qua bridge (hoặc eBPF direct routing).
- Pod khác node → giao tiếp qua routing/overlay (Calico BGP, Cilium eBPF, Flannel VXLAN).
- Node → pod: qua bridge, route trong node.

### CNI plugin làm gì

Khi pod start, CRI gọi CNI plugin với `CNI_COMMAND=ADD`:
1. Tạo veth pair.
2. Một đầu vào pod netns, một đầu gắn bridge (hoặc direct routing).
3. Gán IP (từ IPAM).
4. Thêm route default qua bridge.
5. Trả về JSON chứa IP + interface.

### Debug pod network

```bash
# Tìm netns của container
crictl inspect <container_id> | grep netns

# Vào netns
nsenter -t <pid> -n ip addr
nsenter -t <pid> -n ip route
nsenter -t <pid> -n ping <pod-ip>

# Xem veth trên node
ip link show | grep veth
# veth<hash@if<peer>>: <BROADCAST,MULTICAST,UP,LOWER_UP>

# Xem bridge
bridge fdb show
# Xem MAC → port mapping
```
