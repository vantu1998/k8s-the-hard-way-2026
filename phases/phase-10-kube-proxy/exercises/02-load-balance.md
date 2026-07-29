# Exercise 02 — Load Balance Verification

> **Mục tiêu**: Curl ClusterIP nhiều lần, quan sát traffic chia đều ra 3 pod (xem access log). Verify random probability load balancing.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Cluster K8s (Phase 9), kube-proxy iptables mode

## Bối cảnh

iptables random probability = load balancing. Bài này curl Service nhiều lần, xem traffic chia đều ra pod.

## Bước 1: Deploy pods with unique response

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
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        volumeMounts:
        - name: config
          mountPath: /usr/share/nginx/html/index.html
          subPath: index.html
      volumes:
      - name: config
        configMap:
          name: web-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
data:
  index.html: |
    Served by {{ POD_NAME }} at {{ POD_IP }}
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

> ConfigMap with `{{ POD_NAME }}` — nginx serve template. But nginx doesn't render templates. Use a simpler approach:

```bash
# Delete and use command approach
kubectl delete deployment web
kubectl delete svc web-service
kubectl delete cm web-config

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
      - name: web
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          echo "Served by $(hostname) at $(hostname -i)" > /var/www/index.html
          while true; do
            echo "Served by $(hostname) at $(hostname -i)"
            cat /var/www/index.html
            nc -l -p 80 < /var/www/index.html
          done
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

kubectl get pod -l app=web -o wide
# NAME        IP            NODE
# web-aaa     10.244.1.5    worker-1
# web-bbb     10.244.2.3    worker-2
# web-ccc     10.244.3.7    worker-3
```

## Bước 2: Curl Service — single request

```bash
# Single curl — see which pod served
kubectl run client --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod client --timeout=30s

kubectl exec client -- wget -qO- "http://${SVC_IP}"
# Served by web-aaa at 10.244.1.5   ← pod aaa served this request
```

> One curl → one pod. Random probability → which pod is random.

## Bước 3: Curl 30 times — count distribution

```bash
# Curl 30 times, count which pod served each
for i in $(seq 1 30); do
  kubectl exec client -- wget -qO- "http://${SVC_IP}" 2>/dev/null
done | sort | uniq -c | sort -rn
#   12 Served by web-aaa at 10.244.1.5
#   10 Served by web-bbb at 10.244.2.3
#    8 Served by web-ccc at 10.244.3.7
```

> 30 requests → ~10 per pod (1/3 each). Random probability → approximately equal. Not exactly 10/10/10 (random), but close.

**Kiểm tra**: ~10 requests per pod (approximately 1/3 each).

## Bước 4: Verify with iptables counters

```bash
ssh worker-1

# Get KUBE-SVC chain
SVC_CHAIN=$(sudo iptables -t nat -S KUBE-SERVICES | grep "10.96.0.1" | grep -o 'KUBE-SVC-[A-Z0-9]*')

# View counters — packets per endpoint
sudo iptables -t nat -L "${SVC_CHAIN}" -v -n
# Chain KUBE-SVC-ABC123 (1 references)
#  pkts  bytes  target         prot  opt  in  out  source  destination
#    12   720   KUBE-SEP-AAA  tcp   --   *   *    0/0     0/0    statistic mode random probability 0.333
#     8   480   KUBE-SEP-BBB  tcp   --   *   *    0/0     0/0    statistic mode random probability 0.500
#    10   600   KUBE-SEP-CCC  tcp   --   *   *    0/0     0/0
```

> `pkts` column = packets per endpoint. 12 + 8 + 10 = 30 total. ~1/3 each. Counters match our curl test.

**Kiểm tra**: iptables counters show ~equal distribution across endpoints.

## Bước 5: Test sticky connection (conntrack)

```bash
# Curl same Service multiple times from same client
# First curl — new connection
kubectl exec client -- wget -qO- "http://${SVC_IP}"
# Served by web-aaa at 10.244.1.5   ← pod aaa

# Second curl — SAME connection (conntrack sticky)
kubectl exec client -- wget -qO- "http://${SVC_IP}"
# Served by web-aaa at 10.244.1.5   ← SAME pod! conntrack sticky

# Third curl — still same pod
kubectl exec client -- wget -qO- "http://${SVC_IP}"
# Served by web-aaa at 10.244.1.5   ← SAME pod!
```

> Same client → same pod (conntrack sticky). First request: random → pod aaa. Subsequent: conntrack fast path → same pod aaa. **Load balancing per-connection, not per-request**.

**Kiểm tra**: Same client always reaches same pod (conntrack sticky).

## Bước 6: Test from different clients

```bash
# Client 1
kubectl exec client -- wget -qO- "http://${SVC_IP}"
# Served by web-aaa

# Client 2 (different source)
kubectl run client2 --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod client2 --timeout=30s
kubectl exec client2 -- wget -qO- "http://${SVC_IP}"
# Served by web-bbb   ← different pod (different connection)

# Client 3
kubectl run client3 --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod client3 --timeout=30s
kubectl exec client3 -- wget -qO- "http://${SVC_IP}"
# Served by web-ccc   ← different pod
```

> Different clients → different connections → different pods (load balancing). Same client → same pod (sticky). Load balancing = per-connection.

**Kiểm tra**: Different clients reach different pods.

## Bước 7: Scale and verify rebalancing

```bash
# Scale to 5
kubectl scale deployment web --replicas=5
kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Curl 50 times from different clients
for i in $(seq 1 50); do
  kubectl exec "client$((i % 3 + 1))" -- wget -qO- "http://${SVC_IP}" 2>/dev/null
done | sort | uniq -c | sort -rn
#   12 Served by web-aaa
#   11 Served by web-bbb
#   10 Served by web-ccc
#    9 Served by web-ddd
#    8 Served by web-eee
```

> Scale 3 → 5: traffic rebalanced across 5 pods. ~10 per pod (1/5 each). New pods (ddd, eee) receive traffic immediately.

**Kiểm tra**: 5 pods, ~10 requests each (1/5 distribution).

## Cleanup

```bash
kubectl delete deployment web
kubectl delete svc web-service
kubectl delete pod client client2 client3
```

## Câu hỏi tự kiểm tra

1. 30 curl → 12/10/8 — tại sao không phải 10/10/10? Load balancing chính xác hay xấp xỉ?
2. Same client curl 3 lần → same pod — tại sao? Conntrack làm gì?
3. Different client → different pod — tại sao? Mỗi connection có conntrack entry riêng?
4. Scale 3 → 5 — traffic rebalance ngay không? Pod mới nhận traffic khi nào?
5. `iptables -L -v -n` — cột `pkts` có ý nghĩa gì? Làm sao verify load balancing?

## Đáp án tham khảo

1. **Xấp xỉ** — random probability = mỗi packet random. 30 requests → ~10 per pod, nhưng random → 12/10/8 (not exactly 10/10/10). Law of large numbers: 300 requests → closer to 100/100/100. Random = distribution xấp xỉ, không chính xác.
2. **Conntrack sticky** — first request: random → pod aaa. conntrack record: `client → Service IP` = `client → pod aaa`. Subsequent requests: conntrack fast path → same DNAT → pod aaa. Same connection = same pod. Load balancing per-connection, không per-request.
3. **Different connection** — mỗi client = different source IP/port = different conntrack entry. Different entry → different DNAT → different pod. Load balancing = per-connection. New connection = new random selection.
4. **Ngay lập tức** — kube-proxy watch EndpointSlice. Pod ready → EndpointSlice update → kube-proxy update iptables → new pod in KUBE-SEP. Next new connection → can hit new pod. Existing connections → still old pod (conntrack sticky).
5. `pkts` = **packet count** per rule. `iptables -L -v -n` show counters. KUBE-SVC chain: `pkts` per KUBE-SEP = traffic per endpoint. Verify: total pkts = sum of endpoint pkts. Distribution = pkts per endpoint / total. `bytes` = byte count (for bandwidth analysis).
