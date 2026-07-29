# 04 — IPAM (IP Address Management)

## IPAM là gì

IPAM = CNI plugin phụ trách **cấp phát IP** cho pod. CNI chính (bridge, calico) gọi IPAM plugin để lấy IP.

```
CNI bridge plugin
  │
  ├── Call IPAM plugin:
  │   exec /opt/cni/bin/host-local
  │   env: CNI_COMMAND=ADD
  │   stdin: { "type": "host-local", "ranges": [{"subnet": "10.244.1.0/24"}] }
  │   stdout: { "ips": [{"address": "10.244.1.5/24"}] }
  │
  └── Assign IP to pod eth0
```

> IPAM = separate plugin. CNI main plugin (bridge) gọi IPAM để lấy IP. Tách concern: network setup (bridge) vs IP allocation (IPAM).

## Node CIDR allocation

```
Controller Manager:
  --cluster-cidr=10.244.0.0/16       (cluster pod CIDR)
  --node-cidr-mask-size=24           (each node gets /24)

Node CIDR allocation:
  10.244.0.0/16 → split into /24 blocks
    ├── Node 1: 10.244.1.0/24   (256 IPs)
    ├── Node 2: 10.244.2.0/24   (256 IPs)
    └── Node 3: 10.244.3.0/24   (256 IPs)

Node annotation:
  kubectl get node worker-1 -o jsonpath='{.spec.podCIDR}'
  10.244.1.0/24
```

> Controller Manager chia cluster CIDR (`10.244.0.0/16`) thành /24 block per node. Node annotation `podCIDR` = CIDR range cho node đó. CNI plugin đọc `podCIDR` → IPAM cấp IP từ range đó.

```bash
# Check node pod CIDR
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
# master     10.244.0.0/24
# worker-1   10.244.1.0/24
# worker-2   10.244.2.0/24

# Controller Manager flags
ps aux | grep kube-controller-manager | grep -o '\--cluster-cidr=[^ ]*'
# --cluster-cidr=10.244.0.0/16
ps aux | grep kube-controller-manager | grep -o '\--node-cidr-mask-size=[^ ]*'
# --node-cidr-mask-size=24
```

## host-local IPAM

`host-local` = IPAM plugin cấp IP từ CIDR range, lưu state trên disk.

```json
{
  "type": "host-local",
  "ranges": [
    [{"subnet": "10.244.1.0/24", "rangeStart": "10.244.1.10", "rangeEnd": "10.244.1.200"}]
  ],
  "routes": [{"dst": "0.0.0.0/0"}],
  "dataDir": "/var/lib/cni/networks"
}
```

### State storage

```
/var/lib/cni/networks/k8s-bridge/
  ├── 10.244.1.5      ← file name = assigned IP, content = container ID
  ├── 10.244.1.6
  ├── last_reserved_ip  ← last IP allocated (for sequential allocation)
  └── lock             ← file lock (concurrent access)
```

```bash
# Check allocated IPs
ls /var/lib/cni/networks/k8s-bridge/
# 10.244.1.5   10.244.1.6   10.244.1.7   last_reserved_ip

# Check which container has which IP
cat /var/lib/cni/networks/k8s-bridge/10.244.1.5
# abc123def456  ← container ID

# IP allocation: sequential (10.244.1.5, 10.244.1.6, 10.244.1.7, ...)
cat /var/lib/cni/networks/k8s-bridge/last_reserved_ip
# 10.244.1.7
```

> host-local lưu state trên disk (`/var/lib/cni/networks/`). File name = IP, content = container ID. `last_reserved_ip` = last allocated (sequential). `lock` = concurrent access protection.

### ADD flow

```
CNI_COMMAND=ADD → host-local:
  1. Read range: 10.244.1.0/24
  2. Check /var/lib/cni/networks/ for allocated IPs
  3. Find next available IP (sequential from last_reserved_ip)
  4. Create file: /var/lib/cni/networks/k8s-bridge/10.244.1.5
     Content: container ID
  5. Update last_reserved_ip
  6. Return: { "ips": [{"address": "10.244.1.5/24"}] }
```

### DEL flow

```
CNI_COMMAND=DEL → host-local:
  1. Read container ID from env
  2. Find file with matching content (container ID)
  3. Delete file: /var/lib/cni/networks/k8s-bridge/10.244.1.5
  4. IP released back to pool
```

> DEL = xóa file → IP released. Nếu file lost (disk full, crash) → IP leak (không release). Restart node → all file lost → all IP available (no persistence across reboot).

## Calico IPAM

Calico = block-based IPAM. Cấp IP theo block (/26 = 64 IPs), không per-node /24.

```
Calico IPAM:
  Pool: 10.244.0.0/16 (cluster CIDR)
    ├── Block: 10.244.1.0/26 (64 IPs) → Node 1
    ├── Block: 10.244.1.64/26 → Node 1 (second block when first full)
    ├── Block: 10.244.2.0/26 → Node 2
    └── Block: 10.244.3.0/26 → Node 3

Block affinity: block assigned to node, but can move (borrowing)
```

```bash
# Calico IPAM — check blocks
calicoctl ipam show
# IPAM:
#   Pool: 10.244.0.0/16
#   Blocks:
#     10.244.1.0/26   → worker-1
#     10.244.2.0/26   → worker-2

# Block detail
calicoctl ipam show --ip=10.244.1.5
# IP 10.244.1.5 is in block 10.244.1.0/26 (affinity: worker-1)
```

### Block borrowing

```
Node 1: block 10.244.1.0/26 (64 IPs) — full
  → Calico assign new block: 10.244.1.128/26 → Node 1

Node 2: no free block
  → Calico borrow block from Node 3: 10.244.3.0/26 → Node 2 (temporary)
```

> Calico block-based: linh hoạt hơn host-local. Block (/26) assign per node, có thể borrow khi full. Pod IP không liên tục (block-based, không /24 per node).

## Cilium IPAM

Cilium = eBPF-based, dùng k8s podCIDR hoặc ENI (AWS).

```
Cilium IPAM modes:
  - Cluster scope: 10.244.0.0/16 → per-node /24 (like host-local)
  - ENI: AWS ENI secondary IPs (pod IP = ENI IP)
  - CRD: custom IP pool via CRD
```

```bash
# Cilium IPAM
kubectl -n kube-system exec ds/cilium -- cilium ipam list
# IP            NODE        STATUS
# 10.244.1.5    worker-1    allocated
# 10.244.2.3    worker-2    allocated
```

> Cilium: cluster scope (per-node /24, like host-local) hoặc ENI (AWS, pod IP = ENI IP). ENI mode = pod IP từ AWS ENI, không cần SNAT (pod IP visible trong VPC).

## IPAM comparison

| IPAM | Allocation | State | Persistence | Borrow | Use case |
|------|-----------|-------|-------------|--------|----------|
| **host-local** | Sequential from /24 | Disk (file) | No (lost on reboot) | No | Default, simple |
| **Calico** | Block-based (/26) | etcd/CRD | Yes (etcd) | Yes | Large cluster, flexible |
| **Cilium** | Cluster/ENI | etcd/k8s | Yes | N/A | AWS, high perf |
| **DHCP** | DHCP server | DHCP server | Yes | N/A | Enterprise DHCP |
| **static** | Config file | N/A | N/A | N/A | Debug, fixed IP |

> host-local = đơn giản, không persistent. Calico = block-based, persistent (etcd), borrow. Cilium = cluster/ENI. DHCP = enterprise. static = debug.

## IP leak

```
IP leak scenarios:
  1. Pod deleted but CNI DEL fail → IP not released → leak
  2. Node crash → /var/lib/cni/networks/ lost → all IP available (but pod gone)
  3. Disk full → can't write state file → IP not tracked → leak

Detection:
  ls /var/lib/cni/networks/k8s-bridge/ | wc -l   ← allocated IPs
  crictl pods | wc -l                              ← running pods
  If allocated > running → IP leak

Fix:
  # Find leaked IP (file exists but no matching pod)
  for ip_file in /var/lib/cni/networks/k8s-bridge/*; do
    ip=$(basename "$ip_file")
    cid=$(cat "$ip_file")
    if ! crictl ps -a -q | grep -q "$cid"; then
      echo "Leaked: $ip (container $cid not found)"
      rm "$ip_file"  # Release IP
    fi
  done
```

> IP leak = IP allocated but pod gone. host-local không persistent → node reboot = all IP available (safe). Calico = etcd persistent → no leak on reboot.

## Liên hệ với Kubernetes

- IPAM = CNI plugin cấp IP cho pod. CNI main (bridge) gọi IPAM để lấy IP.
- Controller Manager chia cluster CIDR (`--cluster-cidr=10.244.0.0/16`) thành /24 per node (`--node-cidr-mask-size=24`).
- Node annotation `podCIDR` = CIDR range cho node đó. CNI đọc → IPAM cấp IP.
- **host-local**: sequential allocation, state trên disk (`/var/lib/cni/networks/`), không persistent (reboot = lost).
- **Calico**: block-based (/26), persistent (etcd), borrow block khi full. Linh hoạt hơn.
- **Cilium**: cluster scope (per-node /24) hoặc ENI (AWS, pod IP = ENI IP).
- IP leak: pod deleted but DEL fail → IP not released. host-local: check file vs running pod.
- IPAM tách concern: network setup (bridge) vs IP allocation (IPAM). Pluggable.
