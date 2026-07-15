# 11 — Tools: tcpdump, ss, iproute2

## tcpdump — packet capture

tcpdump capture packet trên interface, hiển thị hoặc ghi ra file. **Công cụ số 1 để debug network.**

### Cú pháp cơ bản

```bash
tcpdump -i <interface> [filter] [options]

# Ví dụ:
sudo tcpdump -i eth0 -n
sudo tcpdump -i eth0 -n port 80
sudo tcpdump -i eth0 -n host 10.0.0.2
sudo tcpdump -i eth0 -n icmp
```

### Options quan trọng

| Option | Ý nghĩa |
|--------|---------|
| `-i <if>` | Interface (hoặc `any` cho tất cả) |
| `-n` | Không resolve IP → hostname |
| `-nn` | Không resolve port → service name |
| `-v` / `-vv` / `-vvv` | Verbose (hiện thêm TTL, ID, options) |
| `-c <n>` | Dừng sau n packet |
| `-w <file>` | Ghi ra file pcap (mở bằng Wireshark) |
| `-r <file>` | Đọc từ file pcap |
| `-e` | Hiện MAC address (layer 2) |
| `-X` | Hex + ASCII dump |
| `-A` | ASCII dump (đọc HTTP payload) |
| `-l` | Line-buffered (pipe được) |

### Filter expression (BPF — Berkeley Packet Filter)

```bash
# Theo protocol
tcpdump -i eth0 tcp
tcpdump -i eth0 udp
tcpdump -i eth0 icmp
tcpdump -i eth0 arp

# Theo host
tcpdump -i eth0 host 10.0.0.2
tcpdump -i eth0 src 10.0.0.2
tcpdump -i eth0 dst 10.0.0.2

# Theo port
tcpdump -i eth0 port 80
tcpdump -i eth0 src port 80
tcpdump -i eth0 dst port 80

# Combine (AND, OR, NOT)
tcpdump -i eth0 'host 10.0.0.2 and port 80'
tcpdump -i eth0 'tcp and port 80 or port 443'
tcpdump -i eth0 'not port 22'           ← bỏ SSH noise
tcpdump -i eth0 'host 10.0.0.2 and not port 22'

# Theo TCP flag
tcpdump -i eth0 'tcp[tcpflags] & tcp-syn != 0'        ← chỉ SYN
tcpdump -i eth0 'tcp[tcpflags] & (tcp-syn|tcp-fin) != 0'  ← SYN hoặc FIN
```

### Capture TCP handshake

```bash
# Terminal 1: capture
sudo tcpdump -i eth0 -n 'tcp[tcpflags] & (tcp-syn|tcp-ack) != 0 and port 80'

# Terminal 2: tạo connection
curl http://10.0.0.2/

# Output:
# 10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [S], seq 1000    ← SYN
# 10:00:01 IP 10.0.0.2.80 > 10.0.0.1.54321: Flags [S.], seq 2000  ← SYN-ACK
# 10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [.], ack 2001   ← ACK
```

### Ghi ra file pcap để phân tích bằng Wireshark

```bash
# Capture 1000 packet, ghi ra file
sudo tcpdump -i eth0 -w /tmp/capture.pcap -c 1000

# Đọc lại
tcpdump -r /tmp/capture.pcap -n

# Mở bằng Wireshark (trên desktop)
# wireshark /tmp/capture.pcap
```

## ss — socket statistics

`ss` thay thế `netstat` — nhanh hơn, đọc trực tiếp từ kernel.

### Cú pháp

```bash
# TCP socket
ss -t          # TCP connected
ss -ta         # TCP tất cả (LISTEN + ESTAB + TIME_WAIT...)
ss -tan        # không resolve, numeric

# UDP socket
ss -u
ss -uan

# Tất cả
ss -a

# Theo port
ss -tan '( sport = :80 )'
ss -tan '( dport = :80 )'

# Theo process
ss -tanp       # hiện PID/process name

# Theo state
ss -t state established
ss -t state time-wait
ss -t state listening

# Thống kê socket
ss -s
# Total: 50
# TCP:   15 (estab 10, closed 3, orphaned 0, timewait 3)
# UDP:   2
```

### Đọc output

```bash
ss -tanp
# State   Local Address:Port   Peer Address:Port  Process
# LISTEN  0.0.0.0:80           0.0.0.0:*          users:(("nginx",pid=1234,fd=6))
# ESTAB   10.0.0.1:54321       10.0.0.2:80        users:(("curl",pid=5678,fd=3))
# TIME-WAIT 10.0.0.1:54322     10.0.0.2:80
```

### Debug Kubernetes với ss

```bash
# Xem kubelet listening port
ss -tlnp | grep kubelet

# Xem API server port
ss -tlnp | grep 6443

# Đếm connection đến API server
ss -tnp '( dport = :6443 )' | wc -l

# Xem TIME_WAIT count (nhiều = cần tune)
ss -tan state time-wait | wc -l
```

## iproute2 — `ip` command

### ip addr — quản lý IP

```bash
# Xem tất cả interface + IP
ip addr
ip a              # shorthand

# Xem 1 interface
ip addr show eth0

# Thêm IP
sudo ip addr add 10.0.0.1/24 dev eth0

# Xóa IP
sudo ip addr del 10.0.0.1/24 dev eth0
```

### ip link — quản lý interface

```bash
# Xem tất cả interface
ip link show

# Up/down interface
sudo ip link set eth0 up
sudo ip link set eth0 down

# Tạo veth pair
sudo ip link add veth0 type veth peer name veth1

# Tạo bridge
sudo ip link add br0 type bridge

# Gán interface vào bridge
sudo ip link set veth0 master br0

# Đổi MAC
sudo ip link set dev eth0 address aa:bb:cc:dd:ee:ff

# Xóa interface
sudo ip link del veth0
```

### ip route — quản lý routing

```bash
# Xem routing table
ip route
ip r              # shorthand

# Xem route cho 1 đích
ip route get 10.0.0.2

# Thêm route
sudo ip route add 10.0.0.0/24 via 192.168.1.1 dev eth0
sudo ip route add default via 192.168.1.1

# Xóa route
sudo ip route del 10.0.0.0/24
```

### ip neigh — quản lý ARP

```bash
# Xem ARP table
ip neigh
ip n              # shorthand

# Xóa ARP entry
sudo ip neigh del 10.0.0.2 dev eth0

# Flush
sudo ip neigh flush all
```

### ip netns — quản lý network namespace

```bash
# Tạo
sudo ip netns add ns1

# List
ip netns list

# Exec
sudo ip netns exec ns1 ip addr

# Xóa
sudo ip netns del ns1

# Xem PID của process trong netns
ip netns pids ns1
```

## Cheat sheet tổng hợp

```bash
# "Pod không ping được pod khác node" — debug flow:

# 1. Xem route trong pod netns
nsenter -t <pid> -n ip route

# 2. Capture packet trong pod netns
nsenter -t <pid> -n tcpdump -i any icmp -n

# 3. Xem route trên node
ip route get <remote-pod-ip>

# 4. Capture trên node interface
sudo tcpdump -i eth0 icmp -n

# 5. Xem ARP
ip neigh

# 6. Xem iptables (có rule drop không?)
sudo iptables-save | grep -i drop

# 7. Xem socket
ss -tnp | grep <remote-pod-ip>
```
