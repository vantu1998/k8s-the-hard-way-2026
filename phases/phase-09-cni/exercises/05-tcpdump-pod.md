# Exercise 05 — tcpdump Pod Traffic

> **Mục tiêu**: `tcpdump` trên veth interface của pod, capture traffic giữa 2 pod. Phân tích packet bằng Wireshark/tcpdump.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s (Phase 8), SSH access vào worker node, `sudo` privilege, `tcpdump` installed

## Bối cảnh

tcpdump trên veth interface = xem packet thực tế giữa pod. Bài này capture ICMP (ping) + HTTP (curl) traffic, phân tích packet.

## Prerequisites

```bash
ssh worker-1

# Install tcpdump if not present
sudo apt install -y tcpdump 2>/dev/null || sudo yum install -y tcpdump

# Verify
tcpdump --version
```

## Bước 1: Deploy pods (trên master)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: server
  labels:
    app: server
spec:
  nodeName: worker-1
  containers:
  - name: nginx
    image: nginx:1.25
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels:
    app: client
spec:
  nodeName: worker-1
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sleep", "3600"]
EOF
```

```bash
kubectl wait --for=condition=Ready pod/server pod/client --timeout=60s

SERVER_IP=$(kubectl get pod server -o jsonpath='{.status.podIP}')
CLIENT_IP=$(kubectl get pod client -o jsonpath='{.status.podIP}')
echo "Server IP: ${SERVER_IP}, Client IP: ${CLIENT_IP}"
```

## Bước 2: Find veth interface (trên worker-1)

```bash
# Find server sandbox
SERVER_SANDBOX=$(sudo crictl pods --name server -q)
SERVER_PID=$(sudo crictl inspectp "${SERVER_SANDBOX}" -o json | jq -r '.info.pid')

# Find client sandbox
CLIENT_SANDBOX=$(sudo crictl pods --name client -q)
CLIENT_PID=$(sudo crictl inspectp "${CLIENT_SANDBOX}" -o json | jq -r '.info.pid')

# Find veth on host — match pod eth0 MAC
SERVER_MAC=$(sudo nsenter -n -t "${SERVER_PID}" ip link show eth0 | grep -oP 'link/\K[^ ]+')
echo "Server eth0 MAC: ${SERVER_MAC}"

# Find host veth with matching MAC
SERVER_VETH=$(ip -o link show | grep -B1 "${SERVER_MAC}" | awk -F': ' '{print $2}' | head -1)
echo "Server veth: ${SERVER_VETH}"

# Alternatively — find veth by peer
for veth in $(ip -o link show | grep veth | awk -F': ' '{print $2}'); do
  peer_ifindex=$(ethtool -S "${veth}" 2>/dev/null | grep peer_ifindex | awk '{print $2}')
  if [ -n "${peer_ifindex}" ]; then
    echo "${veth} → peer ifindex ${peer_ifindex}"
  fi
done
```

> Veth pair: pod eth0 MAC match host veth MAC. Find host veth by matching MAC. Or use `ethtool -S` to find peer ifindex.

**Kiểm tra**: Found veth interface name on host for server pod.

## Bước 3: tcpdump — capture ICMP (ping)

```bash
# Terminal 1 — tcpdump on server veth
sudo tcpdump -i "${SERVER_VETH}" -n -v icmp &
TCPDUMP_PID=$!

# Terminal 2 — ping from client to server
kubectl exec client -- ping -c 5 "${SERVER_IP}"
# 64 bytes from 10.244.1.5: icmp_seq=1 ttl=64 time=0.1 ms
# 64 bytes from 10.244.1.5: icmp_seq=2 ttl=64 time=0.1 ms
# ...

# Terminal 1 — tcpdump output
# 10:00:00.000000 IP (tos 0x0, ttl 64, id 12345, offset 0, flags [none], proto ICMP (1), length 84)
#     10.244.1.6 > 10.244.1.5: ICMP echo request, id 123, seq 1, length 64
# 10:00:00.000100 IP (tos 0x0, ttl 64, id 54321, offset 0, flags [none], proto ICMP (1), length 84)
#     10.244.1.5 > 10.244.1.6: ICMP echo reply, id 123, seq 1, length 64

# Stop tcpdump
sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null
```

> tcpdump on veth: ICMP echo request (client → server) + reply (server → client). TTL=64 (no routing, same node). Proto=ICMP (1).

**Kiểm tra**: tcpdump shows ICMP request/reply between pod IPs.

## Bước 4: tcpdump — capture HTTP

```bash
# Terminal 1 — tcpdump on server veth, port 80
sudo tcpdump -i "${SERVER_VETH}" -n -v port 80 &
TCPDUMP_PID=$!

# Terminal 2 — curl from client to server
kubectl exec client -- wget -qO- "http://${SERVER_IP}/" > /dev/null

# Terminal 1 — tcpdump output
# 10:00:01.000000 IP (tos 0x0, ttl 64, id 23456, offset 0, flags [DF], proto TCP (6), length 60)
#     10.244.1.6.43210 > 10.244.1.5.80: Flags [S], cksum 0x1234, seq 1234567890, win 64240, length 0
#     ← SYN (TCP handshake)
# 10:00:01.000100 IP (tos 0x0, ttl 64, id 1, offset 0, flags [DF], proto TCP (6), length 60)
#     10.244.1.5.80 > 10.244.1.6.43210: Flags [S.], cksum 0x5678, seq 9876543210, ack 1234567891, win 65160, length 0
#     ← SYN-ACK
# 10:00:01.000200 IP (tos 0x0, ttl 64, id 2, offset 0, flags [DF], proto TCP (6), length 52)
#     10.244.1.6.43210 > 10.244.1.5.80: Flags [.], cksum 0x9abc, ack 1, win 502, length 0
#     ← ACK (handshake done)
# 10:00:01.000300 IP (tos 0x0, ttl 64, id 3, offset 0, flags [DF], proto TCP (6), length 100)
#     10.244.1.6.43210 > 10.244.1.5.80: Flags [P.], cksum 0xdef0, seq 1:49, ack 1, win 502, length 48
#     ← HTTP GET (push data)
# 10:00:01.000400 IP (tos 0x0, ttl 64, id 4, offset 0, flags [DF], proto TCP (6), length 200)
#     10.244.1.5.80 > 10.244.1.6.43210: Flags [P.], cksum 0x1111, seq 1:149, ack 49, win 502, length 148
#     ← HTTP response (nginx HTML)

sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null
```

> TCP flow: SYN → SYN-ACK → ACK (handshake) → PSH (HTTP GET) → PSH (HTTP response) → FIN. TTL=64 (same node, no routing).

**Kiểm tra**: tcpdump shows TCP handshake + HTTP request/response.

## Bước 5: tcpdump — capture to file (pcap)

```bash
# Capture to pcap file
sudo tcpdump -i "${SERVER_VETH}" -w /tmp/pod-traffic.pcap &
TCPDUMP_PID=$!

# Generate traffic
kubectl exec client -- ping -c 3 "${SERVER_IP}"
kubectl exec client -- wget -qO- "http://${SERVER_IP}/" > /dev/null

# Stop capture
sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null

# Verify pcap file
sudo tcpdump -r /tmp/pod-traffic.pcap -n | head -10
# 10:00:00.000000 IP 10.244.1.6 > 10.244.1.5: ICMP echo request
# 10:00:00.000100 IP 10.244.1.5 > 10.244.1.6: ICMP echo reply
# 10:00:01.000000 IP 10.244.1.6.43210 > 10.244.1.5.80: Flags [S]
# ...

# Download pcap for Wireshark (from local machine)
# scp worker-1:/tmp/pod-traffic.pcap ./
# Open in Wireshark for detailed analysis
```

> pcap file = packet capture (binary). Open in Wireshark for GUI analysis. Filter by protocol (ICMP, TCP, HTTP), follow TCP stream, see payload.

## Bước 6: tcpdump on bridge — capture all pod traffic

```bash
# tcpdump on bridge cbr0 — see all pod traffic (all pods on node)
sudo tcpdump -i cbr0 -n host "${SERVER_IP}" &
TCPDUMP_PID=$!

# Generate traffic from multiple sources
kubectl exec client -- ping -c 2 "${SERVER_IP}"

# If another pod on same node, also captures
# kubectl exec other-pod -- wget -qO- "http://${SERVER_IP}/"

sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null
```

> Bridge cbr0 = all pod traffic on node. tcpdump on bridge = see traffic from all pods. Filter by `host <IP>` for specific pod.

## Bước 7: Analyze packet structure

```bash
# Detailed packet dump — show all headers
sudo tcpdump -i "${SERVER_VETH}" -n -vvv -XX icmp -c 1 &
TCPDUMP_PID=$!
kubectl exec client -- ping -c 1 "${SERVER_IP}"
wait "${TCPDUMP_PID}" 2>/dev/null

# Output (hex + ASCII):
# 10:00:00.000000 IP (tos 0x0, ttl 64, id 12345, offset 0, flags [none], proto ICMP (1), length 84)
#     10.244.1.6 > 10.244.1.5: ICMP echo request, id 123, seq 1, length 64
#         0x0000:  aa bb cc dd ee ff  11 22 33 44 55 66  08 00  45 00  ............E.
#         0x0010:  00 54  30 39 00 00  40 01  xx xx  0a f4 01 06  .T09..@.......
#         0x0020:  0a f4 01 05  08 00  f1 5e  00 7b  00 01  ......^.{..
#                    ↑              ↑     ↑
#                    src IP          ICMP  echo request
#                                    type  (8=request)
```

### Packet layers

```
Ethernet frame:
  | dst MAC | src MAC | ethertype (0x0800=IPv4) |

IP header:
  | version | tos | total length | id | flags | offset | ttl | proto (1=ICMP, 6=TCP) | checksum | src IP | dst IP |

ICMP header:
  | type (8=request, 0=reply) | code | checksum | id | seq | data |
```

> Packet = Ethernet + IP + ICMP/TCP/UDP. tcpdump `-XX` = hex + ASCII. Analyze: MAC (layer 2) → IP (layer 3) → ICMP/TCP (layer 4).

## Bước 8: Filter tcpdump

```bash
# Filter by source IP
sudo tcpdump -i "${SERVER_VETH}" -n src "${CLIENT_IP}" -c 5

# Filter by destination port
sudo tcpdump -i "${SERVER_VETH}" -n dst port 80 -c 5

# Filter by protocol
sudo tcpdump -i "${SERVER_VETH}" -n icmp -c 5
sudo tcpdump -i "${SERVER_VETH}" -n tcp -c 5

# Filter by specific pod IP (both directions)
sudo tcpdump -i "${SERVER_VETH}" -n host "${SERVER_IP}" -c 10

# Combine filters (AND)
sudo tcpdump -i "${SERVER_VETH}" -n "src ${CLIENT_IP} and dst port 80" -c 5

# Exclude filter (NOT)
sudo tcpdump -i "${SERVER_VETH}" -n "host ${SERVER_IP} and not port 22" -c 10
```

> tcpdump filter (BPF syntax): `host`, `src`, `dst`, `port`, `proto`, `and`, `or`, `not`. Filter at capture = less data, better performance.

## Cleanup

```bash
# (trên master)
kubectl delete pod server client

# (trên worker-1)
rm -f /tmp/pod-traffic.pcap
```

## Câu hỏi tự kiểm tra

1. Tìm veth interface trên host cho pod — làm thế nào? (2 cách)
2. tcpdump trên veth vs bridge — khác nhau thế nào? Cái nào thấy nhiều traffic hơn?
3. ICMP echo request — TTL bao nhiêu? Tại sao? Nếu cross-node TTL sẽ gì?
4. TCP handshake — 3 packet nào? Flag gì? (SYN, SYN-ACK, ACK)
5. pcap file — mở bằng gì? Lợi ích so với tcpdump terminal?

## Đáp án tham khảo

1. **Cách 1**: Match MAC — pod `eth0` MAC = host veth MAC. `ip link show` + grep MAC. **Cách 2**: `ethtool -S <veth>` → `peer_ifindex` → find peer interface. Veth pair liên kết bằng ifindex.
2. **Veth** = chỉ traffic của 1 pod (pod đó gửi/nhận). **Bridge** = traffic của tất cả pod trên node (bridge = hub). Bridge thấy nhiều traffic hơn. Veth = isolate 1 pod. Bridge = all pods.
3. TTL=64 (same node, no routing). Mỗi hop router giảm TTL 1. Cross-node: pod → bridge (TTL 64) → node route → remote node → bridge → pod (TTL 63 hoặc 64 tùy implementation). Default Linux TTL=64.
4. **SYN** (client → server, Flags [S]) → **SYN-ACK** (server → client, Flags [S.]) → **ACK** (client → server, Flags [.]). 3 packet = TCP handshake. Sau handshake → data transfer (PSH).
5. **Wireshark** — GUI packet analyzer. Lợi ích: filter GUI, follow TCP stream, decode protocol (HTTP, DNS, TLS), see payload, color coding. tcpdump terminal = text only, limited. pcap = standard format, open in any analyzer.
