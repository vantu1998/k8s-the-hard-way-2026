# Exercise 02 — Headless Service DNS

> **Mục tiêu**: Tạo Headless Service, quan sát DNS trả pod IP trực tiếp thay vì ClusterIP, so sánh với normal Service. Hiểu khi nào cần dùng Headless.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s (Phase 10), CoreDNS running, `kubectl` access, `dns-debug` pod hoặc busybox pod

## Bối cảnh

Headless Service (`clusterIP: None`) → DNS trả nhiều A record (pod IP). Client kết nối trực tiếp pod — không qua kube-proxy DNAT. Critical cho StatefulSet (database cluster, Kafka, ZooKeeper).

## Bước 1: Deploy Deployment + normal ClusterIP Service

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
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web-clusterip
spec:
  type: ClusterIP     # Normal Service
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF

kubectl wait --for=condition=Ready pod -l app=web --timeout=60s

# Lấy ClusterIP và pod IPs để so sánh sau
echo "ClusterIP Service:"
kubectl get svc web-clusterip
echo ""
echo "Pod IPs:"
kubectl get pod -l app=web -o wide | awk '{print $1, $6}'
```

## Bước 2: Deploy Headless Service

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web-headless
spec:
  clusterIP: None     # ← Headless
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF

# Verify headless — ClusterIP = None
kubectl get svc web-headless
# NAME           TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)
# web-headless   ClusterIP   None         <none>        80/TCP
#                            ↑ None = Headless
```

**Kiểm tra**: `CLUSTER-IP` = `None` cho Headless Service.

## Bước 3: So sánh DNS response

```bash
# Deploy debug pod
kubectl run dns-debug --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod dns-debug --timeout=30s

# === Normal ClusterIP Service ===
echo "=== ClusterIP Service DNS ==="
kubectl exec dns-debug -- dig web-clusterip.default.svc.cluster.local +short
# 10.96.0.X    ← 1 IP duy nhất = ClusterIP

# === Headless Service ===
echo ""
echo "=== Headless Service DNS ==="
kubectl exec dns-debug -- dig web-headless.default.svc.cluster.local +short
# 10.244.1.5   ← pod 1 IP
# 10.244.2.3   ← pod 2 IP
# 10.244.3.7   ← pod 3 IP
# ↑ Multiple A records — tất cả pod IP

# Full detail
kubectl exec dns-debug -- dig web-headless.default.svc.cluster.local
# ;; ANSWER SECTION:
# web-headless.default.svc.cluster.local. 5 IN A 10.244.1.5
# web-headless.default.svc.cluster.local. 5 IN A 10.244.2.3
# web-headless.default.svc.cluster.local. 5 IN A 10.244.3.7
# ↑ TTL 5s (ngắn hơn ClusterIP's 30s vì pod IP dynamic)
```

**Kiểm tra**: ClusterIP Service → 1 A record. Headless → 3 A record (mỗi pod IP). TTL 5s vs 30s.

## Bước 4: Verify pod IPs match DNS response

```bash
# Lấy pod IPs từ API
POD_IPS=$(kubectl get pod -l app=web -o jsonpath='{.items[*].status.podIP}')
echo "Pod IPs from API: ${POD_IPS}"

# Lấy IPs từ DNS
DNS_IPS=$(kubectl exec dns-debug -- dig web-headless.default.svc.cluster.local +short)
echo "Pod IPs from DNS: ${DNS_IPS}"

# So sánh (sắp xếp để dễ so)
echo "--- API ---"
echo "${POD_IPS}" | tr ' ' '\n' | sort
echo "--- DNS ---"
echo "${DNS_IPS}" | sort
# Kết quả phải khớp nhau
```

**Kiểm tra**: DNS response = pod IPs từ API. CoreDNS lấy pod IP từ EndpointSlice.

## Bước 5: Quan sát load balancing khác nhau

```bash
# Headless: client chọn pod IP trực tiếp (DNS round-robin)
# Query nhiều lần — thứ tự IP rotate
for i in $(seq 1 5); do
  echo "Query ${i}:"
  kubectl exec dns-debug -- dig web-headless.default.svc.cluster.local +short
  echo "---"
done
# Query 1: 10.244.1.5, 10.244.2.3, 10.244.3.7
# Query 2: 10.244.2.3, 10.244.3.7, 10.244.1.5  ← shuffle (loadbalance plugin)
# Query 3: 10.244.3.7, 10.244.1.5, 10.244.2.3  ← rotate
# ↑ loadbalance plugin của CoreDNS shuffle thứ tự

# ClusterIP: client luôn nhận 1 IP (kube-proxy handle LB)
for i in $(seq 1 5); do
  echo "Query ${i}:"
  kubectl exec dns-debug -- dig web-clusterip.default.svc.cluster.local +short
  echo "---"
done
# Luôn: 10.96.0.X (1 IP)
```

**Kiểm tra**: Headless → thứ tự IP rotate. ClusterIP → luôn 1 IP cố định.

## Bước 6: Headless + StatefulSet (pod tên riêng)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: postgres-headless
spec:
  clusterIP: None
  selector:
    app: postgres
  ports:
  - port: 5432
    name: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres-headless    # ← phải match headless Service name
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16-alpine
        env:
        - name: POSTGRES_PASSWORD
          value: "password"
        ports:
        - containerPort: 5432
EOF

kubectl wait --for=condition=Ready pod -l app=postgres --timeout=120s
```

```bash
# StatefulSet pod DNS — mỗi pod có DNS name riêng
echo "=== StatefulSet pod DNS ==="
for pod in postgres-0 postgres-1 postgres-2; do
  echo "--- ${pod} ---"
  kubectl exec dns-debug -- nslookup ${pod}.postgres-headless.default.svc.cluster.local 2>&1 | grep Address
done
# --- postgres-0 ---
# Address: 10.244.1.10    ← postgres-0 IP
# --- postgres-1 ---
# Address: 10.244.2.15    ← postgres-1 IP
# --- postgres-2 ---
# Address: 10.244.3.8     ← postgres-2 IP

# Headless Service — tất cả pod IPs
echo ""
echo "=== Headless Service DNS (all pods) ==="
kubectl exec dns-debug -- dig postgres-headless.default.svc.cluster.local +short
# 10.244.1.10
# 10.244.2.15
# 10.244.3.8
```

**Kiểm tra**: `{pod-name}.{headless-svc}.{namespace}.svc.cluster.local` → pod IP riêng. Headless Service → tất cả pod IPs.

## Bước 7: Simulate pod restart — DNS update

```bash
# Lấy IP pod postgres-0 trước khi restart
OLD_IP=$(kubectl get pod postgres-0 -o jsonpath='{.status.podIP}')
echo "postgres-0 IP before restart: ${OLD_IP}"

# Xóa pod (StatefulSet sẽ tự tạo lại)
kubectl delete pod postgres-0

# Chờ pod mới
kubectl wait --for=condition=Ready pod postgres-0 --timeout=60s

# Lấy IP mới
NEW_IP=$(kubectl get pod postgres-0 -o jsonpath='{.status.podIP}')
echo "postgres-0 IP after restart: ${NEW_IP}"

# DNS đã update chưa?
kubectl exec dns-debug -- nslookup postgres-0.postgres-headless.default.svc.cluster.local 2>&1 | grep Address
# → Trả IP mới (NEW_IP) sau khi CoreDNS sync từ API Server
# TTL 5s → DNS update nhanh sau restart
```

**Kiểm tra**: Pod restart → IP mới → DNS cập nhật IP mới (TTL 5s). DNS name ổn định dù IP thay đổi.

## Cleanup

```bash
kubectl delete deployment web
kubectl delete svc web-clusterip web-headless
kubectl delete statefulset postgres
kubectl delete svc postgres-headless
kubectl delete pod dns-debug
```

## Câu hỏi tự kiểm tra

1. Headless Service DNS trả gì khác ClusterIP Service?
2. TTL 5s (Headless) vs 30s (ClusterIP) — tại sao khác?
3. StatefulSet cần Headless Service để làm gì?
4. Khi pod restart, DNS update sau bao lâu? Tại sao?
5. Client nào nên dùng Headless Service? (gRPC vs HTTP/1.1)

## Đáp án tham khảo

1. **Headless**: nhiều A record (tất cả pod IP). **ClusterIP**: 1 A record (virtual IP). Headless = direct pod access, ClusterIP = virtual IP → kube-proxy DNAT.

2. **TTL khác nhau**: Pod IP động (thay đổi khi restart/reschedule). TTL 5s → client hết cache nhanh → pick up IP mới. ClusterIP ổn định (không đổi khi pod restart) → TTL 30s okay.

3. **StatefulSet + Headless**: mỗi pod StatefulSet cần DNS name riêng (`postgres-0.svc`). Headless Service = subdomain cho pod DNS. `serviceName` trong StatefulSet spec phải match Headless Service name. Thiếu Headless Service → pod không có DNS name riêng.

4. **DNS update**: CoreDNS kubernetes plugin watch EndpointSlice. Pod ready → EndpointSlice update → CoreDNS pick up ngay → DNS response thay đổi. Client cần hết TTL (5s) mới dùng IP mới (nếu đã cache cũ). Thực tế: < 10s.

5. **gRPC nên dùng Headless**: gRPC dùng HTTP/2 → 1 connection long-lived → kube-proxy DNAT chọn pod 1 lần → không load balance tiếp theo. Headless → client tự connect tất cả pod (client-side LB). HTTP/1.1 dùng ClusterIP vẫn ok vì nhiều connection ngắn → mỗi connection kube-proxy chọn pod khác nhau.
