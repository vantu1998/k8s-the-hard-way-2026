# Exercise 04 — tcpdump capture traffic giữa 2 netns, đọc TCP handshake

> **Mục tiêu**: Dùng tcpdump capture packet, đọc được TCP 3-way handshake, hiểu packet flow.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Linux VM, root access, `tcpdump`, `iproute2`, `python3`

## Bối cảnh

Debug network trong Kubernetes thường bắt đầu bằng `tcpdump` — capture packet xem cái gì đi qua, cái gì bị drop. Bài này kết hợp netns + veth + tcpdump + HTTP server.

## Bước 1: Setup 2 netns + veth (review exercise 01)

```bash
sudo ip netns add ns1
sudo ip netns add ns2

sudo ip link add veth-ns1 type veth peer name veth-ns2
sudo ip link set veth-ns1 netns ns1
sudo ip link set veth-ns2 netns ns2

sudo ip netns exec ns1 ip link set lo up
sudo ip netns exec ns2 ip link set lo up
sudo ip netns exec ns1 ip link set veth-ns1 up
sudo ip netns exec ns2 ip link set veth-ns2 up

sudo ip netns exec ns1 ip addr add 10.0.0.1/24 dev veth-ns1
sudo ip netns exec ns2 ip addr add 10.0.0.2/24 dev veth-ns2

# Verify ping
sudo ip netns exec ns1 ping -c 1 10.0.0.2
```

**Kiểm tra**: Ping thành công.

## Bước 2: Chạy HTTP server trong ns2

```bash
# Terminal 1: HTTP server trong ns2
sudo ip netns exec ns2 python3 -m http.server 80
# Serving HTTP on port 80 ...
```

**Kiểm tra**: Server đang listen.

## Bước 3: Capture ICMP trước — warm up

```bash
# Terminal 2: capture ICMP trong ns1
sudo ip netns exec ns1 tcpdump -i veth-ns1 icmp -n

# Terminal 3: ping
sudo ip netns exec ns1 ping -c 3 10.0.0.2

# Terminal 2 output:
# 10:00:01 IP 10.0.0.1 > 10.0.0.2: ICMP echo request, id 1234, seq 1, length 64
# 10:00:01 IP 10.0.0.2 > 10.0.0.1: ICMP echo reply, id 1234, seq 1, length 64
# (repeat for seq 2, 3)
```

**Kiểm tra**: Thấy echo request + reply xen kẽ.

## Bước 4: Capture TCP handshake

```bash
# Terminal 2: capture TCP SYN/ACK (handshake) + HTTP
sudo ip netns exec ns1 tcpdump -i veth-ns1 -n -A 'tcp and (port 80)'

# Terminal 3: curl HTTP server
sudo ip netns exec ns1 curl -s http://10.0.0.2/
```

### Đọc output tcpdump

```text
# === 3-way handshake ===
10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [S],     seq 1000, win 64240    ← SYN
10:00:01 IP 10.0.0.2.80 > 10.0.0.1.54321: Flags [S.],    seq 2000, ack 1001    ← SYN-ACK
10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [.],     ack 2001             ← ACK

# === HTTP request ===
10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [P.],    seq 1001:1050, ack 2001
GET / HTTP/1.1                              ← HTTP request payload (hiện nhờ -A)
Host: 10.0.0.2

10:00:01 IP 10.0.0.2.80 > 10.0.0.1.54321: Flags [.],     ack 1050             ← ACK request

# === HTTP response ===
10:00:01 IP 10.0.0.2.80 > 10.0.0.1.54321: Flags [P.],    seq 2001:2300, ack 1050
HTTP/1.0 200 OK                             ← HTTP response
Content-Length: 123
<html>...</html>                            ← HTML body

10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [.],     ack 2300             ← ACK response

# === 4-way teardown ===
10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [F.],    seq 1050, ack 2300   ← FIN
10:00:01 IP 10.0.0.2.80 > 10.0.0.1.54321: Flags [.],     ack 1051             ← ACK FIN
10:00:01 IP 10.0.0.2.80 > 10.0.0.1.54321: Flags [F.],    seq 2300, ack 1051   ← FIN
10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [.],     ack 2301             ← ACK FIN
```

**Kiểm tra**: Thấy đầy đủ 3-way handshake → data → 4-way teardown.

## Bước 5: Capture với filter nâng cao

```bash
# Chỉ capture SYN packet (không có data)
sudo ip netns exec ns1 tcpdump -i veth-ns1 -n 'tcp[tcpflags] & tcp-syn != 0'

# Capture và ghi ra file pcap
sudo ip netns exec ns1 tcpdump -i veth-ns1 -w /tmp/capture.pcap -c 50

# Đọc lại
tcpdump -r /tmp/capture.pcap -n -A
```

**Kiểm tra**: File pcap có 50 packet, đọc lại được.

## Bước 6: Capture trên cả 2 đầu — so sánh

```bash
# Terminal 2: capture ns1
sudo ip netns exec ns1 tcpdump -i veth-ns1 -n 'tcp and port 80' -c 10

# Terminal 4: capture ns2
sudo ip netns exec ns2 tcpdump -i veth-ns2 -n 'tcp and port 80' -c 10

# Terminal 3: curl
sudo ip netns exec ns1 curl -s http://10.0.0.2/

# So sánh: ns1 thấy packet đi ra, ns2 thấy packet đi vào
# src/dst đảo ngược giữa 2 capture
```

**Kiểm tra**: src/dst IP đảo ngược khi so sánh capture 2 đầu.

## Bước 7: Quan sát TIME_WAIT

```bash
# Sau khi curl xong, xem socket state trong ns1
sudo ip netns exec ns1 ss -tan

# Output:
# State       Local Address:Port  Peer Address:Port
# TIME-WAIT   10.0.0.1:54321      10.0.0.2:80        ← socket đã đóng nhưng còn TIME_WAIT
```

**Kiểm tra**: Thấy socket ở state `TIME-WAIT` sau khi connection đóng.

## Cleanup

```bash
# Kill HTTP server (Ctrl+C trong terminal 1)
sudo ip netns del ns1
sudo ip netns del ns2
rm -f /tmp/capture.pcap
```

## Câu hỏi tự kiểm tra

1. Trong tcpdump output, `Flags [S]`, `Flags [S.]`, `Flags [.]` nghĩa là gì?
2. Tại sao teardown cần 4 packet thay vì 3 như handshake?
3. `seq` và `ack` number quan hệ thế nào? Cho ví dụ từ output của bạn.
4. Nếu firewall DROP SYN packet → tcpdump thấy gì? curl báo lỗi gì?
5. TIME_WAIT ở phía nào (client hay server)? Tại sao?

## Đáp án tham khảo

1. `[S]` = SYN, `[S.]` = SYN-ACK, `[.]` = ACK, `[P.]` = PSH-ACK (data), `[F.]` = FIN-ACK.
2. Teardown 2 chiều — mỗi bên gửi FIN + ACK. Handshake 1 chiều init → 3 packet đủ.
3. `seq` = số byte đầu tiên của packet này. `ack` = số byte tiếp theo mong đợi từ peer. Ví dụ: SYN `seq=1000` → SYN-ACK `ack=1001` (mong byte 1001 tiếp theo).
4. tcpdump thấy SYN đi ra nhưng không có SYN-ACK trả về. curl: "Connection timed out".
5. Client (người đóng connection trước). TIME_WAIT đảm bảo ACK cuối đến server + tránh packet cũ nhầm connection mới.
