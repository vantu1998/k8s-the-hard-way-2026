# Exercise 01 — Bridge CNI Manual

> **Mục tiêu**: Cài bridge CNI thủ công — viết CNI config JSON, deploy pod, `crictl inspect` xem IP gán, verify veth + bridge.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 8), SSH access vào worker node, `sudo` privilege

## Bối cảnh

Bridge CNI = built-in plugin. Bài này viết CNI config, deploy pod, verify veth pair + bridge + IP assignment.

## Prerequisites

```bash
ssh worker-1

# Check CNI plugins installed
ls /opt/cni/bin/
# bridge  host-local  loopback  portmap  firewall  tuning

# Check CNI config dir
ls /etc/cni/net.d/
# (if Calico/Cilium installed, their config here)

# Check existing bridge
ip link show type bridge
# cbr0: <BROADCAST,MULTICAST,UP,LOWER_UP>  (if bridge CNI already running)
```

## Bước 1: Backup existing CNI config

```bash
# Backup existing CNI config (if any)
sudo mkdir -p /etc/cni/net.d/backup
sudo cp /etc/cni/net.d/*.conflist /etc/cni/net.d/backup/ 2>/dev/null || true
sudo cp /etc/cni/net.d/*.conf /etc/cni/net.d/backup/ 2>/dev/null || true

# Remove existing CNI config (force bridge CNI)
sudo rm -f /etc/cni/net.d/*.conflist /etc/cni/net.d/*.conf
```

> **Warning**: Removing CNI config = existing pod lose network. Lab only. Production: don't remove.

## Bước 2: Write bridge CNI config

```bash
# Get node pod CIDR
NODE_CIDR=$(kubectl get node worker-1 -o jsonpath='{.spec.podCIDR}')
echo "Node pod CIDR: ${NODE_CIDR}"
# 10.244.1.0/24

# Write bridge CNI config
sudo cat > /etc/cni/net.d/10-bridge.conflist <<EOF
{
  "cniVersion": "1.0.0",
  "name": "k8s-bridge",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cbr0",
      "isGateway": true,
      "isDefaultGateway": true,
      "isBroadcast": true,
      "mtu": 1450,
      "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "${NODE_CIDR}"}]
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
      "type": "loopback"
    }
  ]
}
EOF
```

### Config explanation

| Field | Value | Ý nghĩa |
|-------|-------|---------|
| `cniVersion` | `1.0.0` | CNI spec version |
| `name` | `k8s-bridge` | Network name |
| `bridge` | `cbr0` | Linux bridge name |
| `isGateway` | `true` | Bridge acts as gateway |
| `mtu` | `1450` | MTU (1450 for overlay, 1500 for flat) |
| `ipam.type` | `host-local` | IPAM plugin |
| `ipam.ranges` | `10.244.1.0/24` | IP range from node podCIDR |

**Kiểm tra**: Config file exists, valid JSON.

## Bước 3: Restart kubelet — pick up new CNI config

```bash
# Restart kubelet to pick up new CNI config
sudo systemctl restart kubelet
sleep 5

# Verify kubelet running
sudo systemctl is-active kubelet
# active
```

## Bước 4: Deploy pod (trên master)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: bridge-test
  labels:
    app: bridge-test
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    ports:
    - containerPort: 80
EOF
```

```bash
kubectl wait --for=condition=Ready pod bridge-test --timeout=60s

# Verify pod IP
kubectl get pod bridge-test -o wide
# NAME          READY   STATUS    IP            NODE
# bridge-test   1/1     Running   10.244.1.5    worker-1
```

**Kiểm tra**: Pod Running, IP assigned from node podCIDR (10.244.1.x).

## Bước 5: Verify bridge + veth (trên worker-1)

```bash
# Check bridge cbr0
ip addr show cbr0
# cbr0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
#   inet 10.244.1.1/24 brd 10.244.1.255 scope global cbr0

# Check veth pair
ip link show type veth
# veth-xxx: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
# veth-yyy: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450

# Check bridge has veth attached
bridge link
# veth-yyy  cbr0  state forwarding

# Check IPAM state
ls /var/lib/cni/networks/k8s-bridge/
# 10.244.1.5   last_reserved_ip
cat /var/lib/cni/networks/k8s-bridge/10.244.1.5
# <container-id>  ← IP allocated to this container
```

**Kiểm tra**: Bridge `cbr0` exists with IP 10.244.1.1, veth pair created, IPAM file exists.

## Bước 6: Verify pod network namespace

```bash
# Get sandbox ID
SANDBOX_ID=$(sudo crictl pods --name bridge-test -q)

# Inspect sandbox — check IP
sudo crictl inspectp "${SANDBOX_ID}" -o json | jq '.status.network.ip'
# "10.244.1.5"

# Get pause container PID
PAUSE_PID=$(sudo crictl inspectp "${SANDBOX_ID}" -o json | jq -r '.info.pid')

# Enter network namespace — check eth0
sudo nsenter -n -t "${PAUSE_PID}" ip addr show eth0
# eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
#   inet 10.244.1.5/24 brd 10.244.1.255 scope global eth0
#   link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff

# Check route
sudo nsenter -n -t "${PAUSE_PID}" ip route
# default via 10.244.1.1 dev eth0
# 10.244.1.0/24 dev eth0 proto kernel scope link src 10.244.1.5

# Check DNS
sudo nsenter -n -t "${PAUSE_PID}" cat /etc/resolv.conf
# nameserver 10.96.0.10
# search default.svc.cluster.local svc.cluster.local cluster.local
```

**Kiểm tra**: Pod eth0 has IP 10.244.1.5/24, default route via 10.244.1.1, DNS configured.

## Bước 7: Test connectivity

```bash
# Pod → bridge (gateway)
sudo nsenter -n -t "${PAUSE_PID}" ping -c 1 10.244.1.1
# 64 bytes from 10.244.1.1: icmp_seq=1 ttl=64 time=0.1 ms

# Pod → pod (same node, if 2 pods)
kubectl run test2 --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod test2 --timeout=30s

SANDBOX2=$(sudo crictl pods --name test2 -q)
PAUSE2_PID=$(sudo crictl inspectp "${SANDBOX2}" -o json | jq -r '.info.pid')
POD2_IP=$(sudo crictl inspectp "${SANDBOX2}" -o json | jq -r '.status.network.ip')
echo "Pod2 IP: ${POD2_IP}"

# Ping pod2 from pod1
sudo nsenter -n -t "${PAUSE_PID}" ping -c 3 "${POD2_IP}"
# 64 bytes from ${POD2_IP}: icmp_seq=1 ttl=64 time=0.1 ms
```

**Kiểm tra**: Pod can ping gateway + other pod on same node.

## Bước 8: Manually call CNI plugin (advanced)

```bash
# Create a test network namespace
sudo ip netns add test-netns

# Call bridge CNI plugin manually
CNI_COMMAND=ADD \
CNI_CONTAINERID=test123 \
CNI_NETNS=/var/run/netns/test-netns \
CNI_IFNAME=eth0 \
CNI_PATH=/opt/cni/bin \
sudo /opt/cni/bin/bridge <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "test-bridge",
  "type": "bridge",
  "bridge": "test-br",
  "isGateway": true,
  "isDefaultGateway": true,
  "ipam": {
    "type": "host-local",
    "ranges": [[{"subnet": "10.99.0.0/24"}]]
  }
}
EOF

# Output:
# {
#   "cniVersion": "1.0.0",
#   "interfaces": [...],
#   "ips": [{"address": "10.99.0.2/24", ...}],
#   "routes": [{"dst": "0.0.0.0/0", "gw": "10.99.0.1"}]
# }

# Verify
sudo ip netns exec test-netns ip addr show eth0
# eth0: inet 10.99.0.2/24

# Cleanup
CNI_COMMAND=DEL \
CNI_CONTAINERID=test123 \
CNI_NETNS=/var/run/netns/test-netns \
CNI_IFNAME=eth0 \
CNI_PATH=/opt/cni/bin \
sudo /opt/cni/bin/bridge <<'EOF'
{
  "cniVersion": "1.0.0",
  "name": "test-bridge",
  "type": "bridge",
  "bridge": "test-br",
  "ipam": {"type": "host-local", "ranges": [[{"subnet": "10.99.0.0/24"}]]}
}
EOF

sudo ip netns del test-netns
sudo ip link del test-br 2>/dev/null || true
```

> Manual CNI call: exec binary, pass env + JSON stdin. Plugin return JSON stdout. Same flow kubelet uses.

## Cleanup

```bash
# (trên master)
kubectl delete pod bridge-test test2

# (trên worker-1) — restore original CNI config
sudo cp /etc/cni/net.d/backup/* /etc/cni/net.d/ 2>/dev/null || true
sudo rm -f /etc/cni/net.d/10-bridge.conflist
sudo systemctl restart kubelet
```

## Câu hỏi tự kiểm tra

1. CNI config file đặt ở đâu? Container runtime đọc file nào?
2. Bridge `cbr0` có IP gì? Pod default route đi đâu?
3. Veth pair — đầu nào trong pod, đầu nào trên host? Tên interface trong pod là gì?
4. IPAM `host-local` lưu state ở đâu? IP allocated cho container nào?
5. Manually call CNI plugin — cần truyền env var gì? Input/output format gì?

## Đáp án tham khảo

1. `/etc/cni/net.d/*.conflist` (chain) hoặc `*.conf` (single). Runtime đọc file đầu tiên (alphabetical order). `10-bridge.conflist` = priority 10 (lower = higher priority).
2. Bridge `cbr0` IP = first IP in podCIDR (10.244.1.1 for 10.244.1.0/24). Pod default route: `default via 10.244.1.1` (bridge = gateway). `isGateway: true` → bridge có IP. `isDefaultGateway: true` → pod default route via bridge.
3. Veth pair: một đầu trong pod netns (renamed `eth0`), một đầu trên host (veth-xxx, gắn vào bridge `cbr0`). Pod interface = `eth0` (CNI_IFNAME=eth0). Host interface = `veth-xxx` (random name, attached to bridge).
4. `/var/lib/cni/networks/<network-name>/`. File name = IP, content = container ID. `10.244.1.5` file → content = container ID. `last_reserved_ip` = last allocated (sequential). DEL = xóa file → IP released.
5. Env: `CNI_COMMAND=ADD`, `CNI_CONTAINERID`, `CNI_NETNS`, `CNI_IFNAME`, `CNI_PATH`. Input (stdin): JSON config. Output (stdout): JSON result (IP, routes, interfaces). `CNI_COMMAND=DEL` → cleanup.
