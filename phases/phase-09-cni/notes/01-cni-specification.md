# 01 — CNI Specification

## CNI là gì

CNI (Container Network Interface) là **spec** định nghĩa cách container runtime (containerd, CRI-O) gọi network plugin khi tạo/xóa pod sandbox.

```
Kubelet → CRI: RunPodSandbox
  │
  ├── Create network namespace (/var/run/netns/cni-xxx)
  ├── Call CNI plugin:
  │     exec /opt/cni/bin/bridge
  │     env: CNI_COMMAND=ADD, CNI_CONTAINERID=xxx, CNI_NETNS=/var/run/netns/cni-xxx
  │     stdin: JSON config (from /etc/cni/net.d/*.conflist)
  │     stdout: JSON result (contains IP)
  └── Parse result → sandbox has IP
```

> CNI = exec binary với env var + JSON config. Plugin return JSON chứa IP. Đơn giản, không daemon, không gRPC.

## CNI plugin là gì

CNI plugin = **binary** trong `/opt/cni/bin/`. Container runtime exec binary, truyền env var + JSON config qua stdin.

```bash
ls /opt/cni/bin/
# bridge      ← tạo bridge + veth pair
# host-local  ← IPAM (cấp IP từ CIDR range)
# loopback    ← setup lo interface
# portmap     ← port mapping (hostPort)
# firewall    ← iptables rules cho policy
# tuning      ← sysctl tuning (mtu, checksum)
```

### Built-in plugins

| Plugin | Chức năng |
|--------|-----------|
| `bridge` | Tạo Linux bridge + veth pair |
| `ptp` | Point-to-point veth (no bridge) |
| `host-local` | IPAM — cấp IP từ CIDR range |
| `loopback` | Setup `lo` interface trong netns |
| `portmap` | Port mapping (hostPort → container) |
| `firewall` | iptables rules |
| `tuning` | sysctl tuning (MTU, checksum) |
| `bandwidth` | Traffic shaping (TBF/HTB) |
| `dhcp` | IPAM qua DHCP |
| `static` | IPAM — static IP config |

> K8s default CNI = bridge + host-local + portmap + loopback. Calico/Cilium = custom binary (thay bridge + host-local).

## CNI env vars

Container runtime truyền env var khi exec CNI plugin:

| Env Var | Ý nghĩa | Ví dụ |
|---------|---------|-------|
| `CNI_COMMAND` | Operation | `ADD`, `DEL`, `VERSION`, `CHECK` |
| `CNI_CONTAINERID` | Container/pod ID | `abc123def456` |
| `CNI_NETNS` | Network namespace path | `/var/run/netns/cni-xxx` |
| `CNI_IFNAME` | Interface name | `eth0` |
| `CNI_PATH` | Plugin binary path | `/opt/cni/bin` |
| `CNI_ARGS` | Extra args | `K8S_POD_NAMESPACE=default;K8S_POD_NAME=web` |

### CNI_COMMAND

| Command | Khi nào | Plugin làm gì |
|---------|---------|---------------|
| `ADD` | Pod sandbox tạo | Tạo veth, assign IP, setup route |
| `DEL` | Pod sandbox xóa | Remove veth, release IP |
| `CHECK` | Pod status check | Verify config still valid |
| `VERSION` | Version query | Return supported CNI versions |

> `ADD` = tạo network. `DEL` = xóa network. Kubelet gọi `ADD` khi RunPodSandbox, `DEL` khi StopPodSandbox.

## CNI config

CNI config = JSON file trong `/etc/cni/net.d/`. Container runtime đọc file đầu tiên (alphabetical order).

### Single plugin (deprecated)

```json
// /etc/cni/net.d/10-bridge.conf
{
  "cniVersion": "1.0.0",
  "name": "bridge",
  "type": "bridge",
  "bridge": "cbr0",
  "isGateway": true,
  "isDefaultGateway": true,
  "ipam": {
    "type": "host-local",
    "ranges": [
      [{"subnet": "10.244.1.0/24"}]
    ],
    "routes": [{"dst": "0.0.0.0/0"}]
  }
}
```

### Plugin chain (.conflist — recommended)

```json
// /etc/cni/net.d/10-bridge.conflist
{
  "cniVersion": "1.0.0",
  "name": "k8s-bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cbr0",
      "isGateway": true,
      "isDefaultGateway": true,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "10.244.1.0/24"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
      }
    },
    {
      "type": "portmap",
      "capabilities": {"portMappings": true},
      "snat": true
    },
    {
      "type": "firewall",
      "backend": "iptables"
    },
    {
      "type": "tuning"
    }
  ]
}
```

> `.conflist` = plugin chain. Container runtime exec từng plugin theo thứ tự. Plugin 1 (bridge) tạo network, plugin 2 (portmap) thêm port mapping, plugin 3 (firewall) thêm rules, plugin 4 (tuning) adjust sysctl.

### Config fields

| Field | Ý nghĩa |
|-------|---------|
| `cniVersion` | CNI spec version (`1.0.0`) |
| `name` | Network name (unique) |
| `plugins` | List plugin config (chain) |
| `type` | Plugin binary name |
| `bridge` | Bridge name (for bridge plugin) |
| `ipam` | IPAM plugin config |
| `isGateway` | Bridge acts as gateway |
| `isDefaultGateway` | Bridge is default gateway |

## CNI result (ADD)

Plugin return JSON qua stdout:

```json
{
  "cniVersion": "1.0.0",
  "interfaces": [
    {
      "name": "eth0",
      "mac": "aa:bb:cc:dd:ee:ff",
      "sandbox": "/var/run/netns/cni-xxx"
    },
    {
      "name": "cbr0",
      "mac": "11:22:33:44:55:66"
    }
  ],
  "ips": [
    {
      "interface": 0,
      "address": "10.244.1.5/24",
      "gateway": "10.244.1.1"
    }
  ],
  "routes": [
    {"dst": "0.0.0.0/0", "gw": "10.244.1.1"}
  ],
  "dns": {
    "nameservers": ["10.96.0.10"],
    "search": ["default.svc.cluster.local", "svc.cluster.local"]
  }
}
```

> Result chứa: interfaces (eth0, cbr0), IPs (pod IP + gateway), routes (default route), DNS. Kubelet parse result → update pod status (`podIP`).

## CNI flow — ADD

```
1. Kubelet → CRI: RunPodSandbox
2. Containerd: create network namespace (/var/run/netns/cni-xxx)
3. Containerd: read CNI config (/etc/cni/net.d/10-bridge.conflist)
4. Containerd: exec /opt/cni/bin/bridge
   env: CNI_COMMAND=ADD
        CNI_CONTAINERID=abc123
        CNI_NETNS=/var/run/netns/cni-xxx
        CNI_IFNAME=eth0
        CNI_PATH=/opt/cni/bin
   stdin: { first plugin config from .conflist }
5. Bridge plugin:
   a. Create veth pair (veth-xxx in netns, veth-yyy on host)
   b. Attach veth-yyy to bridge cbr0
   c. Move veth-xxx to pod netns, rename to eth0
   d. Call IPAM (host-local): assign IP from 10.244.1.0/24
   e. Setup route: default via 10.244.1.1 (bridge IP)
   f. Output JSON result (IP, routes, interfaces)
6. Containerd: exec next plugin (portmap, firewall, tuning)
7. Containerd: parse result → sandbox has IP
8. Kubelet: update pod status (podIP = 10.244.1.5)
```

## CNI flow — DEL

```
1. Kubelet → CRI: StopPodSandbox
2. Containerd: exec /opt/cni/bin/bridge
   env: CNI_COMMAND=DEL
        CNI_CONTAINERID=abc123
        CNI_NETNS=/var/run/netns/cni-xxx
3. Bridge plugin:
   a. Remove veth pair (veth-xxx, veth-yyy)
   b. Call IPAM (host-local): release IP back to pool
4. Containerd: exec next plugin (portmap DEL, firewall DEL)
5. Containerd: destroy network namespace
```

> `DEL` = cleanup. Remove veth, release IP. Reverse order of ADD (last plugin DEL first, hoặc cùng thứ tự — tùy implementation).

## CNI version

| Version | Release | Key changes |
|---------|---------|-------------|
| `0.1.0` | 2015 | Initial spec |
| `0.2.0` | 2016 | Plugin chain |
| `0.3.0` | 2017 | CHECK command |
| `0.4.0` | 2019 | CHECK stable, GC |
| `1.0.0` | 2021 | Stable spec, versioned result |

```bash
# Check CNI version supported by plugin
CNI_COMMAND=VERSION CNI_PATH=/opt/cni/bin /opt/cni/bin/bridge
# {"cniVersion":"1.0.0","supportedVersions":["0.1.0","0.2.0","0.3.0","0.3.1","0.4.0","1.0.0"]}
```

> `cniVersion` trong config phải match plugin supported version. Mismatch = plugin fail.

## Multus — multi-network

```
Multus = meta-plugin, gọi multiple CNI plugin
  ├── default network (bridge/calico/cilium)
  └── additional networks (SR-IOV, MACVLAN, host-device)

NetworkAttachmentDefinition:
  apiVersion: k8s.cni.cncf.io/v1
  kind: NetworkAttachmentDefinition
  metadata:
    name: sriov-network
  spec:
    config: |
      { "type": "sriov", ... }

Pod annotation:
  k8s.v1.cni.cncf.io/networks: sriov-network
```

> Multus = CNI meta-plugin. Pod có thể attach multiple network (default + SR-IOV/DPDK). Dùng cho telco, high-performance networking.

## Liên hệ với Kubernetes

- CNI = **spec** định nghĩa cách runtime gọi network plugin. Plugin = binary, exec với env var + JSON config.
- CNI_COMMAND: `ADD` (tạo network), `DEL` (xóa network), `CHECK` (verify), `VERSION`.
- CNI config: `/etc/cni/net.d/*.conflist` — plugin chain (bridge → portmap → firewall → tuning).
- CNI result: JSON chứa IP, routes, interfaces, DNS. Kubelet parse → update pod status.
- Built-in plugin: `bridge` (veth + bridge), `host-local` (IPAM), `portmap`, `firewall`, `loopback`.
- Calico/Cilium = custom CNI plugin (thay bridge + host-local, thêm policy + overlay).
- CNI flow ADD: create netns → exec bridge plugin → veth + IP + route → exec portmap/firewall → parse result.
- CNI flow DEL: exec bridge plugin → remove veth + release IP → destroy netns.
- Multus = meta-plugin cho multi-network (default + SR-IOV/MACVLAN).
- `cniVersion: 1.0.0` — stable spec. Config version phải match plugin.
