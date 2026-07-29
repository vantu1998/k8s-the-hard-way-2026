# Exercise 05 — eBPF Proxy Replacement (Cilium)

> **Mục tiêu**: Cài Cilium với kube-proxy replacement, delete kube-proxy, test Service vẫn hoạt động. Hiểu eBPF at socket layer.
>
> **Thời gian dự kiến**: 35 phút
>
> **Yêu cầu**: Cluster K8s (Phase 9), kernel 5.4+, `sudo` privilege

## Bối cảnh

Cilium eBPF thay kube-proxy — Service load balancing at socket layer, no iptables. Bài này install Cilium, delete kube-proxy, verify Service works.

## Prerequisites

```bash
# Check kernel version (need 5.4+)
uname -r
# 5.15.0-xxx   ← OK

# Check BTF support (needed for eBPF)
ls /sys/kernel/btf/vmlinux 2>/dev/null && echo "BTF OK" || echo "BTF missing"

# Check current kube-proxy
kubectl -n kube-system get ds kube-proxy
# NAME         DESIRED   CURRENT   READY
# kube-proxy   3         3         3
```

## Bước 1: Deploy test Service (before replacement)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s
SVC_IP=$(kubectl get svc web-service -o jsonpath='{.spec.clusterIP}')
echo "Service IP: ${SVC_IP}"

# Verify Service works (with kube-proxy)
kubectl run client --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod client --timeout=30s
kubectl exec client -- wget -qO- "http://${SVC_IP}" | head -1
# <!DOCTYPE html>   ← works with kube-proxy
```

**Kiểm tra**: Service works before Cilium replacement.

## Bước 2: Install Cilium CLI

```bash
# Install Cilium CLI
curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable/install.sh | bash
sudo mv cilium /usr/local/bin/

# Verify
cilium version
# cilium-cli v0.16.0
```

## Bước 3: Install Cilium with kube-proxy replacement

```bash
# Get API server address
API_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "API Server: ${API_SERVER}"
# https://192.168.1.10:6443

# Install Cilium with kube-proxy replacement
cilium install --version 1.16.0 \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.1.10 \
  --set k8sServicePort=6443 \
  --set ipam.mode=cluster-pool \
  --set ipam.cidr=10.244.0.0/16

# Wait for Cilium pods
kubectl wait --for=condition=Ready pod -l k8s-app=cilium -n kube-system --timeout=120s

# Verify Cilium status
cilium status
#     /¯¯\
#  /¯¯\__/¯¯\    Cilium:             1.16.0
#  \__/¯¯\__/    Operator:           1.16.0
#  /¯¯\__/¯¯\    Kernel:             5.15.0
#  \__/¯¯\__/    Kubernetes:         v1.33.0
# Controller status:  25/25 healthy
# Proxy status:       OK
# Hubble:             disabled
# Kube Proxy Replacement: True   ← eBPF replacement enabled!
```

> `kubeProxyReplacement=true` = Cilium eBPF handles Service. `k8sServiceHost` = API server (Cilium connects directly). Cilium installed with eBPF programs for Service load balancing.

**Kiểm tra**: Cilium installed, `Kube Proxy Replacement: True`.

## Bước 4: Verify Service works (with Cilium, before deleting kube-proxy)

```bash
# Test Service — both kube-proxy and Cilium running
kubectl exec client -- wget -qO- "http://${SVC_IP}" | head -1
# <!DOCTYPE html>   ← works

# Check Cilium eBPF service map
kubectl -n kube-system exec ds/cilium -- cilium bpf lb list
# Service ID   Service IP:Port   Slots   Backends
# 1            10.96.0.1:80      3       10.244.1.5:80, 10.244.2.3:80, 10.244.3.7:80
# 2            10.96.0.10:53     1       10.244.1.3:53

# Check eBPF programs loaded
kubectl -n kube-system exec ds/cilium -- cilium bpf prog list | head -10
# ID   Type              Load Time   Name
# 1    cgroup/connect4   2026-01-01  cilium_connect4
# 2    cgroup/sendmsg4   2026-01-01  cilium_sendmsg4
# 3    tc/ingress        2026-01-01  cilium_tc_ingress
# 4    tc/egress        2026-01-01  cilium_tc_egress
```

> Cilium eBPF: service map (Service → backends), socket-level programs (cgroup/connect4, sendmsg4). eBPF intercept `connect()` — rewrite dst (Service IP → pod IP) before packet created.

**Kiểm tra**: Cilium eBPF service map shows Service → pod mapping. eBPF programs loaded.

## Bước 5: Delete kube-proxy

```bash
# Delete kube-proxy DaemonSet
kubectl -n kube-system delete ds kube-proxy

# Verify kube-proxy deleted
kubectl -n kube-system get ds | grep kube-proxy
# (empty — kube-proxy deleted!)

# Check iptables — KUBE-SVC chains should be gone (Cilium cleanup)
ssh worker-1 'sudo iptables -t nat -S | grep -c KUBE-SVC'
# 0   ← no KUBE-SVC chains! Cilium manages now
```

> Delete kube-proxy. Cilium cleanup iptables KUBE-* chains. No kube-proxy = no iptables DNAT. eBPF handles everything.

**Kiểm tra**: kube-proxy deleted, no KUBE-SVC iptables chains.

## Bước 6: Verify Service works (without kube-proxy)

```bash
# Test Service — kube-proxy deleted, Cilium handles
kubectl exec client -- wget -qO- "http://${SVC_IP}" | head -1
# <!DOCTYPE html>   ← WORKS! Cilium eBPF handles Service!

# Test multiple times
for i in $(seq 1 6); do
  kubectl exec client -- wget -qO- "http://${SVC_IP}" 2>/dev/null
done | sort | uniq -c
#   2 Served by web-aaa
#   2 Served by web-bbb
#   2 Served by web-ccc
#   ← load balancing works (round-robin via eBPF)
```

> kube-proxy deleted, Service still works! Cilium eBPF at socket layer handles `connect()` → rewrite dst → pod IP. No iptables, no conntrack.

**Kiểm tra**: Service works without kube-proxy, load balancing via eBPF.

## Bước 7: Test NodePort (without kube-proxy)

```bash
# Create NodePort Service
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web-nodeport
spec:
  type: NodePort
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
EOF

# Get node IP
NODE_IP=$(kubectl get node worker-1 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IP: ${NODE_IP}"

# Curl NodePort from outside
curl -s "http://${NODE_IP}:30080" | head -1
# <!DOCTYPE html>   ← NodePort works! Cilium handles NodePort too!
```

> Cilium handles NodePort too — eBPF at TC (traffic control) layer. No KUBE-NODEPORTS iptables. eBPF program intercept packet at TC, DNAT to pod.

**Kiểm tra**: NodePort works without kube-proxy.

## Bước 8: Enable Hubble — flow visibility

```bash
# Enable Hubble
cilium hubble enable

# Wait for Hubble
cilium status | grep Hubble
# Hubble:     OK   ← enabled

# Port forward Hubble
cilium hubble port-forward &
sleep 3

# View Service flows
hubble observe --type flow | grep "${SVC_IP}" | head -10
# TIMESTAMP            SRC              DST              POLICY   VERDICT
# 2026-01-01T00:00:00  10.244.1.10:80  10.96.0.1:80     allow    FORWARDED
#   → DNAT to 10.244.2.3:80
# 2026-01-01T00:00:01  10.244.1.10:80  10.96.0.1:80     allow    FORWARDED
#   → DNAT to 10.244.1.5:80

# Hubble UI
cilium hubble ui
# Open browser: http://localhost:12000
# Visualize Service → pod traffic
```

> Hubble = real-time flow visibility. See every packet: src, dst, Service DNAT, policy verdict. UI for visualization. No equivalent in kube-proxy/iptables.

## Bước 9: Compare — before vs after

```bash
echo "=== Before (kube-proxy + iptables) ==="
echo "  kube-proxy: running"
echo "  iptables KUBE-SVC: $(ssh worker-1 'sudo iptables -t nat -S | grep -c KUBE-SVC')"
echo "  conntrack: $(ssh worker-1 'sudo conntrack -C')"
echo ""
echo "=== After (Cilium eBPF) ==="
echo "  kube-proxy: deleted"
echo "  iptables KUBE-SVC: $(ssh worker-1 'sudo iptables -t nat -S | grep -c KUBE-SVC')"
echo "  eBPF programs: $(kubectl -n kube-system exec ds/cilium -- cilium bpf prog list | wc -l)"
echo "  Hubble flows: real-time visibility"
```

| Feature | kube-proxy (iptables) | Cilium (eBPF) |
|---------|----------------------|---------------|
| kube-proxy | Required | Deleted |
| iptables KUBE-SVC | Yes (O(n)) | No (eBPF) |
| conntrack | Yes | No (socket-level) |
| Load balancing | Random probability | Round-robin / Maglev |
| Visibility | iptables logs | Hubble (real-time) |
| Components | kube-proxy + iptables | Cilium only |

## Cleanup

```bash
# (optional) Restore kube-proxy
kubectl -n kube-system apply -f https://raw.githubusercontent.com/kubernetes/kubernetes/master/cluster/addons/kube-proxy/kube-proxy-daemonset.yaml

# Uninstall Cilium
# cilium uninstall

# Delete test resources
kubectl delete deployment web
kubectl delete svc web-service web-nodeport
kubectl delete pod client
```

## Câu hỏi tự kiểm tra

1. eBPF replacement — kube-proxy có cần không? Tại sao?
2. eBPF intercept ở layer nào? `connect()` hay packet? Khác iptables thế nào?
3. Delete kube-proxy — Service có work không? NodePort có work không?
4. Hubble cho thấy gì? kube-proxy/iptables có tương đương không?
5. eBPF yêu cầu gì? Kernel version? BTF?

## Đáp án tham khảo

1. **Không cần** — Cilium eBPF thay thế hoàn toàn kube-proxy. eBPF program at socket layer handle Service load balancing. `kubectl delete ds kube-proxy` → Service vẫn work. Fewer components, less CPU.
2. **Socket layer** — eBPF intercept `connect()` syscall (cgroup/connect4). Rewrite dst (Service IP → pod IP) **before packet created**. iptables = intercept packet (after created, traverse chain). eBPF = earlier (before packet), faster (no iptables traversal, no conntrack).
3. **Cả hai work** — Service (ClusterIP) + NodePort đều work without kube-proxy. Cilium eBPF: socket layer (ClusterIP) + TC layer (NodePort). eBPF program at TC intercept packet, DNAT to pod. No KUBE-NODEPORTS iptables.
4. **Hubble** = real-time flow visibility — every packet, src/dst, Service DNAT, policy verdict (allow/deny). UI (hubble-ui). kube-proxy/iptables = logs only (text, manual grep). No real-time flow viewer. Hubble = big advantage.
5. **Kernel 5.4+** (cgroup/connect4, BTF). **BTF** (BPF Type Format) — `/sys/kernel/btf/vmlinux`. **Cilium 1.16+** (stable kube-proxy replacement). Check: `uname -r` (5.4+), `ls /sys/kernel/btf/vmlinux` (BTF). Older kernel → fallback to iptables mode.
