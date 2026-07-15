# 10 — iptables / nftables

## iptables là gì

iptables là **firewall + NAT** ở kernel level — packet filtering framework. Kubernetes dùng iptables (hoặc IPVS, hoặc eBPF) để implement Service abstraction.

## Cấu trúc: Table → Chain → Rule → Target

```
iptables
├── table: filter       ← filtering (accept/drop)
│   ├── chain: INPUT        ← packet đến local
│   ├── chain: FORWARD      ← packet đi qua (routing)
│   └── chain: OUTPUT       ← packet đi ra từ local
├── table: nat          ← Network Address Translation
│   ├── chain: PREROUTING   ← trước routing (DNAT)
│   ├── chain: POSTROUTING  ← sau routing (SNAT/MASQUERADE)
│   ├── chain: OUTPUT       ← NAT packet local tạo ra
│   └── chain: INPUT
├── table: mangle       ← sửa packet (TOS, TTL, mark)
│   └── (all chains)
└── table: raw          ← trước conntrack
    └── (PREROUTING, OUTPUT)
```

### Packet flow

```
Packet đến interface
    │
    ▼
  raw PREROUTING ──→ mangle PREROUTING ──→ nat PREROUTING (DNAT)
    │
    ▼
  Routing decision (đi đến local hay forward?)
    │                         │
    ▼                         ▼
  mangle INPUT            mangle FORWARD
    │                         │
    ▼                         ▼
  filter INPUT            filter FORWARD
    │                         │
    ▼                         ▼
  Local process           mangle POSTROUTING
    │                         │
    ▼                         ▼
  mangle OUTPUT          nat POSTROUTING (SNAT/MASQUERADE)
    │                         │
    ▼                         ▼
  nat OUTPUT              Packet ra interface
    │
    ▼
  filter OUTPUT
    │
    ▼
  mangle POSTROUTING
    │
    ▼
  nat POSTROUTING
    │
    ▼
  Packet ra interface
```

## Rule structure

```bash
# Cú pháp:
iptables -t <table> -A <chain> <match conditions> -j <target>

# Ví dụ:
iptables -t filter -A INPUT -p tcp --dport 22 -j ACCEPT
#         ^table    ^chain  ^protocol ^port    ^target

iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
#         ^table  ^chain         ^source       ^out-if ^target
```

### Match conditions

| Match | Ý nghĩa |
|-------|---------|
| `-p tcp/udp/icmp` | Protocol |
| `--dport 80` | Destination port |
| `--sport 1024` | Source port |
| `-s 10.0.0.0/24` | Source IP |
| `-d 192.168.1.1` | Destination IP |
| `-i eth0` | Input interface |
| `-o eth0` | Output interface |
| `-m state --state ESTABLISHED,RELATED` | Conntrack state |
| `-m conntrack --ctstate NEW` | Conntrack (modern) |

### Targets

| Target | Ý nghĩa |
|--------|---------|
| `ACCEPT` | Cho packet qua |
| `DROP` | Hủy packet silently |
| `REJECT` | Hủy + gửi ICMP error |
| `MASQUERADE` | SNAT động (dùng IP của out interface) |
| `SNAT --to-source <ip>` | SNAT cố định |
| `DNAT --to-destination <ip:port>` | Đổi destination |
| `LOG` | Ghi log kernel, packet vẫn tiếp tục |
| `MARK --set-mark <n>` | Đánh dấu packet (dùng cho routing sau) |
| `RETURN` | Thoát chain hiện tại, quay về chain gọi |
| `<custom-chain>` | Jump sang chain tự tạo |

## Xem rules

```bash
# Xem tất cả rules
sudo iptables-save

# Xem theo table
sudo iptables -t nat -L -n -v
sudo iptables -t filter -L -n -v

# -n: không resolve IP → hostname (nhanh hơn)
# -v: verbose (hiện packet count, byte count, interface)
# --line-numbers: hiện số thứ tự rule

sudo iptables -t nat -L PREROUTING -n -v --line-numbers
```

### Đọc iptables-save output

```bash
# Format:
# *<table>
# :<chain> <policy> [<counter>]
# -A <chain> <rule spec>
# COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.0.0.2:8080
-A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
COMMIT
```

## Kubernetes iptables chains

kube-proxy tạo chain riêng — prefix `KUBE-`:

```bash
sudo iptables-save | grep KUBE | head -30

# Chain chính:
# KUBE-SERVICES     ← entry point cho Service traffic
# KUBE-SVC-<hash>   ← per Service chain
# KUBE-SEP-<hash>   ← per Service endpoint (pod)
# KUBE-NODEPORTS    ← NodePort traffic
# KUBE-POSTROUTING  ← MASQUERADE cho pod traffic
# KUBE-MARK-MASQ    ← đánh dấu packet cần MASQUERADE
```

### Service ClusterIP flow

```bash
# Ví dụ: Service ClusterIP 10.96.0.10:80 → 3 pod 10.244.0.5, 10.244.0.6, 10.244.0.7

# KUBE-SERVICES chain:
-A KUBE-SERVICES -d 10.96.0.10/32 -p tcp --dport 80 -j KUBE-SVC-ABCD1234

# KUBE-SVC-ABCD1234 chain (load balance = random probability):
-A KUBE-SVC-ABCD1234 -m statistic --mode random --probability 0.33 -j KUBE-SEP-AAAA
-A KUBE-SVC-ABCD1234 -m statistic --mode random --probability 0.50 -j KUBE-SEP-BBBB
-A KUBE-SVC-ABCD1234 -j KUBE-SEP-CCCC

# KUBE-SEP-AAAA chain (DNAT đến pod):
-A KUBE-SEP-AAAA -p tcp -j DNAT --to-destination 10.244.0.5:80
-A KUBE-SEP-AAAA -p tcp -j DNAT --to-destination 10.244.0.6:80
-A KUBE-SEP-CCCC -p tcp -j DNAT --to-destination 10.244.0.7:80
```

### Đọc flow:

1. Packet đến `10.96.0.10:80` → match `KUBE-SERVICES`.
2. Jump `KUBE-SVC-ABCD1234` → random chọn 1 trong 3 endpoint.
3. Jump `KUBE-SEP-XXXX` → DNAT đổi destination thành pod IP.
4. Packet tiếp tục routing → đi đến pod.

## nftables — thế hệ tiếp theo

nftables thay thế iptables (từ kernel 3.13, production từ kernel 5.x):

| | iptables | nftables |
|---|---------|----------|
| Syntax | `-A CHAIN -j TARGET` | Ngôn ngữ thống nhất, flexible hơn |
| Performance | O(n) rule lookup | O(1) với set/map |
| Table/chain | Fixed (filter, nat, mangle, raw) | Tự tạo tùy ý |
| Backend | Per-table module | Unified bytecode (BPF-like) |

```bash
# Xem nftables rules
sudo nft list ruleset

# Kubernetes có thể dùng nftables backend (kube-proxy --proxy-mode=iptables với nft backend)
# Hoặc IPVS mode
```

## Liên hệ với Kubernetes

- **kube-proxy iptables mode** (mặc định): tạo iptables rules cho mỗi Service. O(n) rule → chậm khi nhiều Service.
- **kube-proxy IPVS mode**: dùng IPVS kernel module, O(1) lookup, hỗ trợ algorithm (rr, wrr, lc, sh).
- **Cilium eBPF**: bypass iptables entirely, eBPF program ở socket/TC layer.
- **NetworkPolicy**: CNI plugin tạo iptables rules (hoặc eBPF) để enforce policy.
- **Debug**: `iptables-save | grep KUBE-SVC-<hash>` để xem Service rule, `iptables-save | grep KUBE-SEP` để xem endpoint.

## Thực hành

```bash
# Tạo rule: drop tất cả SSH từ 10.0.0.5
sudo iptables -A INPUT -s 10.0.0.5 -p tcp --dport 22 -j DROP

# Tạo rule: NAT traffic từ 10.0.0.0/24 ra eth0
sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE

# Tạo rule: forward port 8080 → 10.0.0.2:80
sudo iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 10.0.0.2:80

# Xem packet count per rule
sudo iptables -L -n -v

# Xóa rule (cần chỉ định chính xác)
sudo iptables -D INPUT -s 10.0.0.5 -p tcp --dport 22 -j DROP

# Lưu rules (persist sau reboot)
sudo iptables-save > /etc/iptables/rules.v4
```
