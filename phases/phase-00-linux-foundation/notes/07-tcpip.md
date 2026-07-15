# 07 — TCP/IP Stack

## OSI vs TCP/IP Model

| OSI (7 layer) | TCP/IP (4 layer) | Ví dụ protocol |
|---------------|------------------|----------------|
| Application | Application | HTTP, DNS, gRPC, SSH |
| Presentation | Application | TLS, JSON serialization |
| Session | Application | Socket session |
| Transport | Transport | TCP, UDP |
| Network | Internet | IP, ICMP |
| Data Link | Link | Ethernet, ARP, MAC |
| Physical | Link | Cable, fiber, WiFi radio |

Kubernetes chủ yếu làm việc ở **Transport** (Service, port) và **Network/Internet** (Pod IP, routing) layer.

## TCP Handshake — 3-way

```
Client                              Server
  |                                   |
  |  SYN (seq=x)                      |
  |---------------------------------->|  Server: "client muốn kết nối"
  |                                   |
  |  SYN-ACK (seq=y, ack=x+1)        |
  |<----------------------------------|  Server: "OK, tôi cũng muốn"
  |                                   |
  |  ACK (ack=y+1)                    |
  |---------------------------------->|  Client: "OK, kết nối established"
  |                                   |
  |  === Data flowing ===             |
  |<--------------------------------->|
```

### Wireshark / tcpdump thấy gì

```
10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [S],     seq 1000, win 64240  ← SYN
10:00:01 IP 10.0.0.2.80 > 10.0.0.1.54321: Flags [S.],    seq 2000, ack 1001  ← SYN-ACK
10:00:01 IP 10.0.0.1.54321 > 10.0.0.2.80: Flags [.],     ack 2001           ← ACK
```

Flags: `S` = SYN, `S.` = SYN-ACK, `.` = ACK, `P.` = PSH-ACK (data), `F.` = FIN-ACK.

## TCP Teardown — 4-way

```
Client                              Server
  |                                   |
  |  FIN (seq=x)                      |
  |---------------------------------->|  Client: "Tôi hết gửi rồi"
  |                                   |
  |  ACK (ack=x+1)                    |
  |<----------------------------------|  Server: "OK"
  |                                   |
  |  FIN (seq=y)                      |
  |<----------------------------------|  Server: "Tôi cũng hết gửi"
  |                                   |
  |  ACK (ack=y+1)                    |
  |---------------------------------->|  Client: "OK"
  |                                   |
  |  === TIME_WAIT (2*MSL) ===        |
  |                                   |
```

## TIME_WAIT — tại sao tồn tại

Sau khi đóng kết nối, client vào **TIME_WAIT** state trong khoảng 2×MSL (thường 60s).

**Mục đích**:
1. Đảm bảo ACK cuối cùng đến server (nếu mất, server re-send FIN, client re-ACK).
2. Tránh packet cũ từ connection trước bị nhầm với connection mới cùng (src IP, src port, dst IP, dst port).

**Vấn đề trong Kubernetes**:
- Pod mở nhiều connection ngắn → nhiều socket TIME_WAIT → hết ephemeral port.
- Giải pháp: connection pooling, tăng `net.ipv4.ip_local_port_range`, giảm `net.ipv4.tcp_fin_timeout`.

## Socket states

```bash
# Xem socket states
ss -tan | head
# State   Local Address:Port  Peer Address:Port
# LISTEN  0.0.0.0:80          0.0.0.0:*
# ESTAB   10.0.0.1:54321      10.0.0.2:80
# TIME-WAIT 10.0.0.1:54322    10.0.0.2:80
```

| State | Ý nghĩa |
|-------|---------|
| `LISTEN` | Server chờ kết nối |
| `SYN-SENT` | Client gửi SYN, chờ SYN-ACK |
| `SYN-RECV` | Server nhận SYN, gửi SYN-ACK |
| `ESTABLISHED` | Kết nối đã thiết lập, data flowing |
| `FIN-WAIT-1` | Gửi FIN, chờ ACK |
| `FIN-WAIT-2` | Nhận ACK, chờ FIN từ peer |
| `TIME-WAIT` | Đóng rồi, chờ 2×MSL trước khi xóa |
| `CLOSE-WAIT` | Peer gửi FIN, chờ local close |
| `LAST-ACK` | Gửi FIN, chờ ACK cuối |
| `CLOSED` | Hoàn toàn đóng |

## TCP vs UDP

| | TCP | UDP |
|---|-----|-----|
| Kết nối | Có (handshake) | Không |
| Reliable | Có (retransmit) | Không |
| Order | Có (seq number) | Không |
| Flow control | Có (sliding window) | Không |
| Overhead | Cao | Thấp |
| Kubernetes | Service TCP mặc định | Service `type: UDP` |

## Liên hệ với Kubernetes

- **Service** = TCP/UDP load balancer (kube-proxy tạo iptables rule DNAT).
- **EndpointSlice** = danh sách pod IP:port sẵn sàng nhận traffic.
- **Readiness probe** = kiểm tra TCP/HTTP endpoint ready → thêm vào EndpointSlice.
- **Connection tracking** (conntrack) = kernel theo dõi TCP connection, kube-proxy NAT cần conntrack để return packet đi đúng.
- **conntrack table full** = lỗi phổ biến — node xử lý nhiều connection → table đầy → drop packet.
