# Exercise 01 — iptables Rules for Service

> **Mục tiêu**: Tạo Service ClusterIP + 3 pod, `iptables-save | grep KUBE-SVC` xem rule DNAT. Đọc iptables chain, hiểu flow DNAT.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s (Phase 9), kube-proxy iptables mode, SSH access vào worker node

## Bối cảnh

Mỗi Service = iptables chain. Bài này tạo Service + 3 pod, đọc iptables rules, trace DNAT flow.

## Bước 1: Deploy Deployment + Service

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
  type: ClusterIP
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Verify Service + endpoints
kubectl get svc web-service
# NAME          TYPE        CLUSTER-IP    PORT(S)
# web-service   ClusterIP   10.96.0.1     80/TCP

kubectl get endpointslice -l kubernetes.io/service-name=web-service
# NAME              ADDRESSTYPE   PORTS   ENDPOINTS
# web-service-xxx   IPv4          80      10.244.1.5,10.244.2.3,10.244.3.7

# Get pod IPs
kubectl get pod -l app=web -o wide
# NAME        IP            NODE
# web-aaa     10.244.1.5    worker-1
# web-bbb     10.244.2.3    worker-2
# web-ccc     10.244.3.7    worker-3
```

**Kiểm tra**: Service ClusterIP 10.96.0.1, 3 pod endpoints.

## Bước 2: View KUBE-SERVICES chain (trên worker-1)

```bash
ssh worker-1

# View KUBE-SERVICES — find our Service
SVC_IP="10.96.0.1"
sudo iptables -t nat -S KUBE-SERVICES | grep "${SVC_IP}"
# -A KUBE-SERVICES -d 10.96.0.1/32 -p tcp -m tcp --dport 80 -j KUBE-SVC-ABC123DEF
```

> KUBE-SERVICES: match `dst 10.96.0.1:80` → jump `KUBE-SVC-ABC123DEF`. Hash = SHA1 of `Service name:namespace`.

**Kiểm tra**: KUBE-SERVICES has rule matching Service IP → KUBE-SVC chain.

## Bước 3: View KUBE-SVC chain — endpoints

```bash
# Get KUBE-SVC chain name
SVC_CHAIN=$(sudo iptables -t nat -S KUBE-SERVICES | grep "${SVC_IP}" | grep -o 'KUBE-SVC-[A-Z0-9]*')
echo "Service chain: ${SVC_CHAIN}"

# View KUBE-SVC chain — random probability per endpoint
sudo iptables -t nat -S "${SVC_CHAIN}"
# -N KUBE-SVC-ABC123DEF
# -A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.333 -j KUBE-SEP-AAA
# -A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.500 -j KUBE-SEP-BBB
# -A KUBE-SVC-ABC123DEF -j KUBE-SEP-CCC
```

> 3 endpoints: 0.333 (1/3) → KUBE-SEP-AAA, 0.500 (1/2 of remaining 2/3 = 1/3) → KUBE-SEP-BBB, default (remaining 1/3) → KUBE-SEP-CCC. Equal distribution.

**Kiểm tra**: KUBE-SVC has 3 rules with random probability 0.333, 0.500, default.

## Bước 4: View KUBE-SEP chain — DNAT

```bash
# View each KUBE-SEP chain — DNAT to pod IP
for sep in $(sudo iptables -t nat -S "${SVC_CHAIN}" | grep -o 'KUBE-SEP-[A-Z0-9]*'); do
  echo "--- ${sep} ---"
  sudo iptables -t nat -S "${sep}" | grep DNAT
done
# --- KUBE-SEP-AAA ---
# -A KUBE-SEP-AAA -p tcp -m tcp -j DNAT --dport 80 --to-destination 10.244.1.5:80
# --- KUBE-SEP-BBB ---
# -A KUBE-SEP-BBB -p tcp -m tcp -j DNAT --dport 80 --to-destination 10.244.2.3:80
# --- KUBE-SEP-CCC ---
# -A KUBE-SEP-CCC -p tcp -m tcp -j DNAT --dport 80 --to-destination 10.244.3.7:80
```

> KUBE-SEP = DNAT: `--to-destination podIP:port`. 3 endpoints → 3 DNAT rules. Pod IP matches `kubectl get pod -l app=web -o wide`.

**Kiểm tra**: 3 KUBE-SEP chains, each DNAT to a pod IP.

## Bước 5: Full iptables flow trace

```bash
# Trace: client → Service IP → pod IP
echo "=== Full DNAT flow for ${SVC_IP}:80 ==="
echo ""
echo "1. KUBE-SERVICES (entry):"
sudo iptables -t nat -S KUBE-SERVICES | grep "${SVC_IP}"
echo ""
echo "2. ${SVC_CHAIN} (load balance):"
sudo iptables -t nat -S "${SVC_CHAIN}" | grep -v "^-N"
echo ""
echo "3. KUBE-SEP (DNAT to pod):"
for sep in $(sudo iptables -t nat -S "${SVC_CHAIN}" | grep -o 'KUBE-SEP-[A-Z0-9]*'); do
  sudo iptables -t nat -S "${sep}" | grep DNAT
done
```

Output:
```
=== Full DNAT flow for 10.96.0.1:80 ===

1. KUBE-SERVICES (entry):
-A KUBE-SERVICES -d 10.96.0.1/32 -p tcp --dport 80 -j KUBE-SVC-ABC123DEF

2. KUBE-SVC-ABC123DEF (load balance):
-A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.333 -j KUBE-SEP-AAA
-A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.500 -j KUBE-SEP-BBB
-A KUBE-SVC-ABC123DEF -j KUBE-SEP-CCC

3. KUBE-SEP (DNAT to pod):
-A KUBE-SEP-AAA -p tcp -j DNAT --dport 80 --to-destination 10.244.1.5:80
-A KUBE-SEP-BBB -p tcp -j DNAT --dport 80 --to-destination 10.244.2.3:80
-A KUBE-SEP-CCC -p tcp -j DNAT --dport 80 --to-destination 10.244.3.7:80
```

## Bước 6: Verify with conntrack

```bash
# Generate traffic
kubectl run client --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod client --timeout=30s
kubectl exec client -- wget -qO- "http://${SVC_IP}" > /dev/null

# Check conntrack — see DNAT
sudo conntrack -L | grep "${SVC_IP}"
# tcp  6  86399  ESTABLISHED  src=10.244.1.10  dst=10.96.0.1  dport=80
#   src=10.244.1.10  dst=10.244.1.5  sport=80  dport=43210  [ASSURED]
#   ↑ client → Service IP      ↑ DNAT → pod IP (10.244.1.5)

# Count conntrack entries for this Service
sudo conntrack -L | grep -c "${SVC_IP}"
# 1   ← 1 connection tracked
```

> conntrack: `dst=10.96.0.1` (Service IP) → `dst=10.244.1.5` (pod IP). DNAT applied. `[ASSURED]` = bidirectional. Same connection → same pod (sticky via conntrack).

**Kiểm tra**: conntrack shows DNAT: Service IP → pod IP.

## Bước 7: Scale Service — watch iptables update

```bash
# Scale to 5 replicas
kubectl scale deployment web --replicas=5

# Wait for new pods
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Check iptables — now 5 endpoints
sudo iptables -t nat -S "${SVC_CHAIN}" | grep -v "^-N"
# -A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.200 -j KUBE-SEP-DDD
# -A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.250 -j KUBE-SEP-EEE
# -A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.333 -j KUBE-SEP-AAA
# -A KUBE-SVC-ABC123DEF -m statistic --mode random --probability 0.500 -j KUBE-SEP-BBB
# -A KUBE-SVC-ABC123DEF -j KUBE-SEP-CCC
#   ← 5 endpoints: 0.200, 0.250, 0.333, 0.500, default = 1/5 each
```

> Scale 3 → 5: kube-proxy update iptables. 5 rules: 0.200 (1/5), 0.250 (1/4 of 4/5), 0.333 (1/3 of 3/5), 0.500 (1/2 of 2/5), default (1/5). Equal distribution.

**Kiểm tra**: 5 endpoints, probability adjusted (0.200, 0.250, 0.333, 0.500, default).

## Cleanup

```bash
kubectl delete deployment web
kubectl delete svc web-service
kubectl delete pod client
```

## Câu hỏi tự kiểm tra

1. KUBE-SERVICES → KUBE-SVC → KUBE-SEP — mỗi chain làm gì?
2. 3 endpoints — probability 0.333, 0.500, default — làm sao mỗi pod nhận 1/3?
3. Scale 3 → 5 — probability thay đổi thế nào? Tại sao không phải 0.200 cho tất cả?
4. conntrack — connection đầu tiên vs connection tiếp theo, khác nhau thế nào?
5. `iptables -t nat -S` vs `iptables -t nat -L` — khác nhau?

## Đáp án tham khảo

1. **KUBE-SERVICES** = entry chain, match dst Service IP:port → jump KUBE-SVC. **KUBE-SVC** = per Service, random probability → jump KUBE-SEP (load balance). **KUBE-SEP** = per endpoint, DNAT: Service IP:port → pod IP:targetPort.
2. 0.333 = 1/3 (first pod). 0.500 = 1/2 of remaining 2/3 = 1/3 (second pod). Default = remaining 1/3 (third pod). 0.333 + 0.333 + 0.334 = 1.0. Each pod ~1/3.
3. Probability = 1/n, 1/(n-1), 1/(n-2)... 5 endpoints: 0.200 (1/5), 0.250 (1/4), 0.333 (1/3), 0.500 (1/2), default (1/1). Not 0.200 for all — iptables `statistic` module: each rule is conditional on previous not matching. 0.200 = 1/5 of total. 0.250 = 1/4 of remaining 4/5. Etc.
4. **First packet**: traverse iptables (KUBE-SERVICES → KUBE-SVC → KUBE-SEP → DNAT) + conntrack record. **Subsequent**: conntrack fast path (lookup, apply same DNAT, skip iptables). Same connection → same pod (sticky). Faster for established connections.
5. `iptables -t nat -S` = **show rules** (script format, `-A CHAIN ...`). `iptables -t nat -L` = **list rules** (table format, with counters). `-S` = parseable, `-L` = human-readable with packet/byte counters. Use `-S` for scripting, `-L -v -n` for debugging.
