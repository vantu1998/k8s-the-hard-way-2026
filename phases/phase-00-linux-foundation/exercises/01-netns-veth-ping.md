# Exercise 01 — Tạo 2 Network Namespace, nối veth pair, ping

> **Mục tiêu**: Hiểu container networking cơ bản — tạo netns (isolation), veth pair (kết nối), gán IP, ping.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Linux VM, root access, `iproute2` installed

## Bối cảnh

Khi pod start, CNI plugin tạo network namespace cho pod, tạo veth pair nối pod netns với node, gán IP. Bài này mô phỏng chính xác quá trình đó bằng tay.

## Bước 1: Tạo 2 network namespace

```bash
sudo ip netns add ns1
sudo ip netns add ns2

# Kiểm tra
ip netns list
# ns2 (id: 1)
# ns1 (id: 0)
```

**Kiểm tra**: `ip netns list` hiện cả ns1 và ns2.

## Bước 2: Xem interface trong netns mới

```bash
sudo ip netns exec ns1 ip addr
# 1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN
#     link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00

# Chỉ có lo, và lo đang DOWN. Không có eth0.
```

**Kiểm tra**: Chỉ thấy `lo` interface, state DOWN.

## Bước 3: Tạo veth pair

```bash
sudo ip link add veth-ns1 type veth peer name veth-ns2

# Kiểm tra — veth pair nằm ở host namespace (chưa chuyển vào netns)
ip link show veth-ns1
ip link show veth-ns2
```

**Kiểm tra**: Cả 2 interface `veth-ns1` và `veth-ns2` tồn tại, state DOWN.

## Bước 4: Chuyển veth vào netns

```bash
sudo ip link set veth-ns1 netns ns1
sudo ip link set veth-ns2 netns ns2

# Kiểm tra — veth không còn ở host
ip link show veth-ns1
# Device "veth-ns1" does not exist.

# Kiểm tra — veth đã ở trong netns
sudo ip netns exec ns1 ip addr
# 1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN
# 2: veth-ns1@if2: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN
```

**Kiểm tra**: `veth-ns1` xuất hiện trong ns1, `veth-ns2` xuất hiện trong ns2.

## Bước 5: Up loopback và veth

```bash
# Up lo (cần thiết cho một số app)
sudo ip netns exec ns1 ip link set lo up
sudo ip netns exec ns2 ip link set lo up

# Up veth
sudo ip netns exec ns1 ip link set veth-ns1 up
sudo ip netns exec ns2 ip link set veth-ns2 up
```

**Kiểm tra**: State của veth chuyển từ DOWN → UP.

## Bước 6: Gán IP

```bash
sudo ip netns exec ns1 ip addr add 10.0.0.1/24 dev veth-ns1
sudo ip netns exec ns2 ip addr add 10.0.0.2/24 dev veth-ns2

# Kiểm tra
sudo ip netns exec ns1 ip addr show veth-ns1
# 2: veth-ns1@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
#    inet 10.0.0.1/24 scope global veth-ns1
```

**Kiểm tra**: IP 10.0.0.1/24 trên veth-ns1, 10.0.0.2/24 trên veth-ns2.

## Bước 7: Ping!

```bash
# Ping ns1 → ns2
sudo ip netns exec ns1 ping 10.0.0.2
# PING 10.0.0.2 (10.0.0.2) 56(84) bytes of data.
# 64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=0.12 ms
# 64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=0.08 ms
# ^C
# --- 10.0.0.2 ping statistics ---
# 2 packets transmitted, 2 received, 0% packet loss

# Ping ns2 → ns1
sudo ip netns exec ns2 ping 10.0.0.1
```

**Kiểm tra**: Ping thành công 2 chiều, 0% packet loss.

## Bước 8: Xem ARP table

```bash
sudo ip netns exec ns1 ip neigh
# 10.0.0.2 dev veth-ns1 lladdr <mac-of-veth-ns2> REACHABLE

sudo ip netns exec ns2 ip neigh
# 10.0.0.1 dev veth-ns2 lladdr <mac-of-veth-ns1> REACHABLE
```

**Kiểm tra**: ARP table có entry cho IP kia với MAC address tương ứng.

## Bước 9: Xem routing table trong netns

```bash
sudo ip netns exec ns1 ip route
# 10.0.0.0/24 dev veth-ns1 proto kernel scope link src 10.0.0.1

# Route tự động tạo khi gán IP — kernel thêm "directly connected" route.
```

## Cleanup

```bash
# Xóa netns — veth bên trong tự động xóa
sudo ip netns del ns1
sudo ip netns del ns2

# Kiểm tra
ip netns list
# (empty)
```

## Câu hỏi tự kiểm tra

1. Tại sao cần up `lo` interface? Điều gì xảy ra nếu không up?
2. Nếu gán IP cùng subnet (10.0.0.1/24 và 10.0.0.1/24) → điều gì xảy ra?
3. Nếu quên up veth → ping báo lỗi gì?
4. Veth pair có thể nối 3 netns không? Cần gì để nối 3 netns?
5. So sánh: tạo netns bằng `ip netns add` vs `unshare --net` — khác gì?

## Mở rộng

- Thêm netns thứ 3 (ns3), nối vào bridge thay vì veth pair trực tiếp.
- Thêm iptables rule DROP trong ns1, test ping fail.
- Chạy HTTP server trong ns2, curl từ ns1.
