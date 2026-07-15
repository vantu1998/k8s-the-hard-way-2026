# Phase 0 — Linux Foundation

> Nền tảng Linux kernel primitives cần thiết trước khi đi sâu vào Kubernetes.
>
> **Mục tiêu**: Hiểu container = namespaces + cgroups + overlayfs, và từng cái làm gì. Tạo được 2 netns nối veth, ping thành công, capture packet bằng tcpdump. Viết được systemd unit file. Đọc được iptables rules.

## Cấu trúc thư mục

```
phase-00-linux-foundation/
├── README.md                  # File này — tracking tiến độ
├── notes/                     # Lý thuyết chi tiết từng chủ đề
│   ├── 01-process-thread.md
│   ├── 02-namespaces.md
│   ├── 03-cgroups.md
│   ├── 04-capabilities.md
│   ├── 05-overlayfs.md
│   ├── 06-systemd.md
│   ├── 07-tcpip.md
│   ├── 08-bridge-veth-netns.md
│   ├── 09-routing-arp.md
│   ├── 10-iptables.md
│   └── 11-tools.md
├── exercises/                 # Bài thực hành hands-on
│   ├── 01-netns-veth-ping.md
│   ├── 02-cgroup-cpu-limit.md
│   ├── 03-overlayfs-mount.md
│   ├── 04-tcpdump-handshake.md
│   ├── 05-systemd-unit.md
│   └── 06-unshare-pid-ns.md
└── scripts/                   # Helper scripts
    ├── setup-netns.sh
    ├── cgroup-cpu-limit.sh
    ├── overlayfs-mount.sh
    └── simple-service.py
```

## Tiến độ học tập

### Lý thuyết (notes/)

- [ ] 01 — Process & Thread: fork/exec/wait, signal, zombie/orphan
- [ ] 02 — Linux Namespaces: PID, NET, MNT, IPC, UTS, USER, CGROUP
- [ ] 03 — cgroups v2: cấu trúc, tạo cgroup, limit CPU/memory
- [ ] 04 — Linux Capabilities: CAP_NET_ADMIN, CAP_SYS_ADMIN, drop capability
- [ ] 05 — OverlayFS: lowerdir, upperdir, mergeddir, whiteout
- [ ] 06 — systemd: unit file, systemctl, journalctl, cgroup integration
- [ ] 07 — TCP/IP stack: handshake, TIME_WAIT, socket states
- [ ] 08 — Bridge, veth, Network Namespace: tạo netns, veth pair, bridge
- [ ] 09 — Routing & ARP: routing table, ARP table, packet flow
- [ ] 10 — iptables/nftables: table, chain, rule, target, NAT
- [ ] 11 — Tools: tcpdump, ss, iproute2

### Thực hành (exercises/)

- [ ] 01 — Tạo 2 netns, nối veth pair, ping qua lại
- [ ] 02 — Tạo cgroup v2, giới hạn CPU, quan sát throttling
- [ ] 03 — Mount overlayfs bằng tay, quan sát whiteout
- [ ] 04 — tcpdump capture traffic giữa 2 netns, đọc TCP handshake
- [ ] 05 — Viết systemd unit file cho script Python, enable & start
- [ ] 06 — unshare tạo process với PID namespace riêng

### Checkpoint hoàn thành phase

- [ ] Giải thích được container = namespaces + cgroups + overlayfs, và từng cái làm gì
- [ ] Tạo được 2 netns nối veth, ping thành công, capture được packet bằng tcpdump
- [ ] Viết được systemd unit file chạy service tự động restart
- [ ] Đọc được iptables rules và hiểu flow packet đi qua chain nào

## Yêu cầu môi trường

- Linux VM (Ubuntu 22.04+ hoặc Debian 12+) — **không dùng WSL** vì WSL hạn chế network namespace và systemd
- Root access (sudo)
- Packages: `iproute2`, `iptables`, `tcpdump`, `python3`, `systemd`, `util-linux` (cho `unshare`)
