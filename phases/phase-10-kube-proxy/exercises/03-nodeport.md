# Exercise 03 — NodePort

> **Mục tiêu**: Tạo NodePort, curl từ ngoài node, trace iptables rule DNAT (KUBE-NODEPORTS → KUBE-SVC → KUBE-SEP).
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s (Phase 9), SSH access vào worker node, `sudo` privilege

## Bối cảnh

NodePort = mở port trên mọi node. Bài này tạo NodePort, curl từ ngoài, trace iptables flow.

## Bước 1: Deploy Service NodePort

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
```

```bash
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Verify Service
kubectl get svc web-nodeport
# NAME           TYPE       CLUSTER-IP    EXTERNAL-IP   PORT(S)
# web-nodeport   NodePort   10.96.0.1    <none>        80:30080/TCP
#   ↑ ClusterIP:80 (internal) + nodeIP:30080 (external)

# Get node IPs
kubectl get nodes -o wide
# NAME       INTERNAL-IP
# master     192.168.1.10
# worker-1   192.168.1.11
# worker-2   192.168.1.12
```

**Kiểm tra**: Service NodePort 30080, accessible on all nodes.

## Bước 2: Curl from inside cluster (ClusterIP)

```bash
kubectl run client --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod client --timeout=30s

# Curl ClusterIP (internal)
kubectl exec client -- wget -qO- "http://10.96.0.1:80" | head -1
# <!DOCTYPE html>   ← works via ClusterIP

# Curl nodeIP:nodePort (internal, via NodePort)
kubectl exec client -- wget -qO- "http://192.168.1.11:30080" | head -1
# <!DOCTYPE html>   ← works via NodePort
```

**Kiểm tra**: Both ClusterIP and NodePort work from inside cluster.

## Bước 3: Curl from outside cluster (NodePort)

```bash
# From host machine (outside cluster)
curl -s http://192.168.1.11:30080 | head -1
# <!DOCTYPE html>   ← works!

# Try different node
curl -s http://192.168.1.12:30080 | head -1
# <!DOCTYPE html>   ← also works! (any node)

# Try master node
curl -s http://192.168.1.10:30080 | head -1
# <!DOCTYPE html>   ← also works! (even master)
```

> NodePort accessible từ **mọi node**. `nodeIP:30080` → DNAT → pod (pod có thể trên node khác). Load balance across pods, not nodes.

**Kiểm tra**: NodePort works from outside cluster on any node.

## Bước 4: Trace iptables — KUBE-NODEPORTS (trên worker-1)

```bash
ssh worker-1

# View KUBE-NODEPORTS chain
sudo iptables -t nat -S KUBE-NODEPORTS | grep 30080
# -A KUBE-NODEPORTS -p tcp -m tcp --dport 30080 -j KUBE-SVC-ABC123DEF
```

> KUBE-NODEPORTS: match `dport 30080` → jump KUBE-SVC-ABC123DEF (same chain as ClusterIP).

**Kiểm tra**: KUBE-NODEPORTS has rule for port 30080 → KUBE-SVC chain.

## Bước 5: Full NodePort iptables flow

```bash
# Trace full flow
echo "=== NodePort iptables flow ==="
echo ""
echo "1. PREROUTING → KUBE-NODEPORTS:"
sudo iptables -t nat -S PREROUTING | grep KUBE-NODEPORTS
# -A PREROUTING -m addrtype --dst-type LOCAL -j KUBE-NODEPORTS

echo ""
echo "2. KUBE-NODEPORTS → KUBE-SVC:"
sudo iptables -t nat -S KUBE-NODEPORTS | grep 30080
# -A KUBE-NODEPORTS -p tcp --dport 30080 -j KUBE-SVC-ABC123DEF

echo ""
echo "3. KUBE-SVC → KUBE-SEP (load balance):"
SVC_CHAIN=$(sudo iptables -t nat -S KUBE-NODEPORTS | grep 30080 | grep -o 'KUBE-SVC-[A-Z0-9]*')
sudo iptables -t nat -S "${SVC_CHAIN}" | grep -v "^-N"

echo ""
echo "4. KUBE-SEP → DNAT to pod:"
for sep in $(sudo iptables -t nat -S "${SVC_CHAIN}" | grep -o 'KUBE-SEP-[A-Z0-9]*'); do
  sudo iptables -t nat -S "${sep}" | grep DNAT
done
```

Output:
```
=== NodePort iptables flow ===

1. PREROUTING → KUBE-NODEPORTS:
-A PREROUTING -m addrtype --dst-type LOCAL -j KUBE-NODEPORTS

2. KUBE-NODEPORTS → KUBE-SVC:
-A KUBE-NODEPORTS -p tcp --dport 30080 -j KUBE-SVC-ABC123DEF

3. KUBE-SVC → KUBE-SEP (load balance):
-A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.333 -j KUBE-SEP-AAA
-A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.500 -j KUBE-SEP-BBB
-A KUBE-SVC-ABC123DEF -j KUBE-SEP-CCC

4. KUBE-SEP → DNAT to pod:
-A KUBE-SEP-AAA -p tcp -j DNAT --dport 80 --to-destination 10.244.1.5:80
-A KUBE-SEP-BBB -p tcp -j DNAT --dport 80 --to-destination 10.244.2.3:80
-A KUBE-SEP-CCC -p tcp -j DNAT --dport 80 --to-destination 10.244.3.7:80
```

> Flow: PREROUTING → KUBE-NODEPORTS → KUBE-SVC → KUBE-SEP → DNAT. Same KUBE-SVC/KUBE-SEP as ClusterIP — different entry (KUBE-NODEPORTS vs KUBE-SERVICES).

## Bước 6: Verify DNAT with tcpdump

```bash
# Get pod IPs
POD_IPS=$(kubectl get pod -l app=web -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}')
echo "Pod IPs: ${POD_IPS}"

# tcpdump on bridge — see both NodePort and pod traffic
sudo tcpdump -i cbr0 -n port 80 or port 30080 -c 10 &
TCPDUMP_PID=$!

# From outside — curl NodePort
curl -s http://192.168.1.11:30080 > /dev/null

# tcpdump output
# 10:00:00.000000 IP 192.168.1.100.43210 > 192.168.1.11.30080  ← external → NodePort
# 10:00:00.000100 IP 192.168.1.100.43210 > 10.244.2.3.80      ← DNAT → pod IP
# 10:00:00.001000 IP 10.244.2.3.80 > 192.168.1.100.43210      ← response

sudo kill "${TCPDUMP_PID}" 2>/dev/null
wait "${TCPDUMP_PID}" 2>/dev/null
```

> tcpdump: external (192.168.1.100) → NodePort (192.168.1.11:30080) → DNAT → pod (10.244.2.3:80). Response: pod → external (reverse NAT via conntrack).

**Kiểm tra**: tcpdump shows DNAT: nodeIP:30080 → podIP:80.

## Bước 7: Test NodePort on non-pod node

```bash
# Pod on worker-1, worker-2, worker-3
# Curl NodePort on master (no pod on master)
curl -s http://192.168.1.10:30080 | head -1
# <!DOCTYPE html>   ← works! master forwards to pod on worker

# Check conntrack on master
ssh master 'sudo conntrack -L | grep 30080'
# tcp  6  86399  ESTABLISHED  src=192.168.1.100  dst=192.168.1.10  dport=30080
#   src=192.168.1.100  dst=10.244.2.3  sport=80  dport=43210  [ASSURED]
#   ↑ external → master:30080      ↑ DNAT → pod on worker-2
```

> Master (no pod) receives NodePort traffic → DNAT → pod on worker-2. Master forwards to worker-2 via routing. **Any node can forward to any pod**.

**Kiểm tra**: NodePort on master (no pod) → forwards to pod on worker.

## Bước 8: NodePort + ClusterIP relationship

```bash
# NodePort = ClusterIP + node port
# Both use same KUBE-SVC chain

# ClusterIP entry: KUBE-SERVICES → KUBE-SVC
sudo iptables -t nat -S KUBE-SERVICES | grep "10.96.0.1"
# -A KUBE-SERVICES -d 10.96.0.1/32 -p tcp --dport 80 -j KUBE-SVC-ABC123DEF

# NodePort entry: KUBE-NODEPORTS → KUBE-SVC (same chain!)
sudo iptables -t nat -S KUBE-NODEPORTS | grep 30080
# -A KUBE-NODEPORTS -p tcp --dport 30080 -j KUBE-SVC-ABC123DEF

# Same KUBE-SVC-ABC123DEF → same KUBE-SEP → same DNAT
echo "Both ClusterIP and NodePort → same KUBE-SVC chain → same pods"
```

> NodePort và ClusterIP dùng **same KUBE-SVC chain**. Different entry (KUBE-SERVICES vs KUBE-NODEPORTS), same load balancing, same pods. NodePort = ClusterIP + external access.

## Cleanup

```bash
kubectl delete deployment web
kubectl delete svc web-nodeport
kubectl delete pod client
```

## Câu hỏi tự kiểm tra

1. NodePort mở port trên node nào? Tất cả hay chỉ node có pod?
2. `curl nodeIP:30080` → pod trên node khác — làm sao? Trace iptables flow.
3. KUBE-NODEPORTS vs KUBE-SERVICES — khác nhau thế nào? Cùng KUBE-SVC không?
4. Master node (không có pod) — NodePort có work không? Tại sao?
5. NodePort range default? Làm sao thay đổi?

## Đáp án tham khảo

1. **Tất cả node** — kube-proxy tạo KUBE-NODEPORTS rule trên mọi node. `iptables -t nat -S KUBE-NODEPORTS` on any node shows rule. Port mở trên mọi node, bất kể pod ở đâu.
2. Flow: `PREROUTING → KUBE-NODEPORTS (match :30080) → KUBE-SVC (random) → KUBE-SEP (DNAT) → pod IP`. DNAT đổi dst từ `nodeIP:30080` → `podIP:80`. Pod có thể trên node khác — node forward via routing.
3. **KUBE-NODEPORTS** = entry cho NodePort (match `dport 30080`). **KUBE-SERVICES** = entry cho ClusterIP (match `dst ClusterIP`). Cả 2 → **same KUBE-SVC chain** → same KUBE-SEP → same pods. NodePort = ClusterIP + external entry.
4. **Có work** — master có KUBE-NODEPORTS rule (kube-proxy on every node). Master receive traffic → DNAT → pod on worker. Master forward via routing (pod CIDR route). **Any node can forward to any pod**.
5. Default: `30000-32767`. Change: `--service-node-port-range=20000-32767` (kube-apiserver flag). Check: `ps aux | grep kube-apiserver | grep service-node-port-range`. Must restart kube-apiserver to apply.
