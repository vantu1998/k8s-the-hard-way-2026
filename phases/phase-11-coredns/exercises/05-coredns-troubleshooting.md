# Exercise 05 — CoreDNS Troubleshooting

> **Mục tiêu**: Debug DNS issues thực tế: pod không resolve được Service, dùng `dig` + `tcpdump` + CoreDNS log để trace root cause. Xây dựng DNS troubleshooting playbook.
>
> **Thời gian dự kiến**: 40 phút
>
> **Yêu cầu**: Cluster K8s, CoreDNS running, `kubectl` + SSH access vào node

## Bối cảnh

DNS failure là một trong những issue phổ biến nhất trong Kubernetes. Pod "không connect được Service" thường là DNS failure. Bài này tạo các failure scenario và debug từng cái.

## Setup: Tạo môi trường để debug

```bash
# Deploy test Service
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
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
  name: backend-svc
  namespace: default
spec:
  selector:
    app: backend
  ports:
  - port: 80
    targetPort: 80
EOF

kubectl wait --for=condition=Ready pod -l app=backend --timeout=60s

# Debug pod
kubectl run debug-client \
  --image=busybox:1.36 \
  --command -- sleep 3600
kubectl wait --for=condition=Ready pod debug-client --timeout=30s
```

## Scenario A: Cơ bản — kiểm tra DNS hoạt động

```bash
# === Checklist DNS health ===

# 1. CoreDNS running?
kubectl -n kube-system get pod -l k8s-app=kube-dns
# Phải: Running, READY 1/1

# 2. CoreDNS Service tồn tại?
kubectl -n kube-system get svc kube-dns
# Phải: ClusterIP có giá trị (10.96.0.10)

# 3. Pod resolv.conf đúng?
kubectl exec debug-client -- cat /etc/resolv.conf
# Phải: nameserver = CoreDNS ClusterIP

# 4. Resolve K8s Service được không?
kubectl exec debug-client -- nslookup backend-svc.default.svc.cluster.local
# Phải: Address = ClusterIP của backend-svc

# 5. Resolve external domain được không?
kubectl exec debug-client -- nslookup google.com
# Phải: Address = IP public
```

## Scenario B: CoreDNS pod crash → DNS fail

```bash
# Simulate CoreDNS down
kubectl -n kube-system scale deploy coredns --replicas=0

# Đợi pod terminate
sleep 10

# Test DNS từ client pod
kubectl exec debug-client -- nslookup backend-svc.default.svc.cluster.local
# → timeout / no servers could be reached
# ← DNS fail vì không có CoreDNS pod nào running

# Debug steps:
echo "=== Step 1: Check CoreDNS pods ==="
kubectl -n kube-system get pod -l k8s-app=kube-dns
# → No pods running (0/0)

echo "=== Step 2: Check CoreDNS deployment ==="
kubectl -n kube-system get deploy coredns
# → READY 0/0 ← đây là vấn đề

echo "=== Step 3: Check events ==="
kubectl -n kube-system get events --field-selector reason=Killing --sort-by='.lastTimestamp' | tail -5

# Fix: scale back up
kubectl -n kube-system scale deploy coredns --replicas=2
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=60s

# Verify DNS hoạt động lại
kubectl exec debug-client -- nslookup backend-svc.default.svc.cluster.local
# → Address: ClusterIP ✓
```

**Root cause**: CoreDNS pod không có replica → DNS fail cluster-wide. **Fix**: Scale up CoreDNS.

## Scenario C: Service không có endpoint → DNS resolve nhưng connect fail

```bash
# Tạo Service KHÔNG có pod match (selector sai)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: broken-svc
spec:
  selector:
    app: nonexistent   # ← không có pod nào có label này
  ports:
  - port: 80
EOF

# DNS resolve được (Service exist → DNS record exist)
kubectl exec debug-client -- nslookup broken-svc.default.svc.cluster.local
# Address: 10.96.x.x   ← ClusterIP có
# DNS OK nhưng...

# Connect fail
kubectl exec debug-client -- wget -qO- http://broken-svc.default.svc.cluster.local --timeout=5
# → connect timeout

# Debug: kiểm tra endpoint
echo "=== Check endpoints ==="
kubectl get endpoints broken-svc
# NAME          ENDPOINTS   AGE
# broken-svc    <none>      10s   ← No endpoints!

echo "=== Check EndpointSlice ==="
kubectl get endpointslice -l kubernetes.io/service-name=broken-svc
# NAME              ADDRESSTYPE   PORTS   ENDPOINTS   AGE
# broken-svc-xxx    IPv4          80      <unset>     10s  ← empty

echo "=== Check selector vs pod labels ==="
echo "Service selector:"
kubectl get svc broken-svc -o jsonpath='{.spec.selector}' && echo
echo "Available pods:"
kubectl get pod --show-labels | grep backend
# backend-xxx   Running   app=backend   ← label "backend", selector wants "nonexistent"
```

> DNS resolve thành công nhưng no endpoints → connection timeout. DNS ≠ connectivity. Luôn check endpoints khi Service unreachable.

**Root cause**: `spec.selector` không match pod labels → no endpoints → kube-proxy không có DNAT rule → connection timeout. **Fix**: Sửa selector hoặc pod labels.

## Scenario D: Cross-namespace DNS sai

```bash
# Tạo Service trong namespace khác
kubectl create namespace staging
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: staging    # ← namespace staging
spec:
  selector:
    app: backend
  ports:
  - port: 80
EOF

# Pod trong default namespace cố resolve sai
kubectl exec debug-client -- nslookup backend-svc
# → backend-svc.default.svc.cluster.local → ClusterIP của default namespace Service
# → KHÔNG phải staging namespace

# Lỗi cross-namespace DNS phổ biến:
kubectl exec debug-client -- nslookup backend-svc.staging
# → thử: backend-svc.staging.default.svc.cluster.local → NXDOMAIN
# → thử: backend-svc.staging.svc.cluster.local → hit! → ClusterIP của staging

# Debug: tại sao?
kubectl exec debug-client -- cat /etc/resolv.conf
# search default.svc.cluster.local svc.cluster.local cluster.local
# → "backend-svc.staging" + ".svc.cluster.local" = "backend-svc.staging.svc.cluster.local" ✓

# FQDN cross-namespace
kubectl exec debug-client -- nslookup backend-svc.staging.svc.cluster.local
# → Address: ClusterIP của staging Service ✓

# Short name cross-namespace (works via search domain)
kubectl exec debug-client -- nslookup backend-svc.staging
# → Cũng works (nhờ search domain "svc.cluster.local")
```

> Cross-namespace: `{svc}.{namespace}` hoặc FQDN. Short name `{svc}` chỉ resolve trong cùng namespace. Lỗi: app dùng short name → resolve namespace mình → không phải Service muốn.

## Scenario E: DNS packet capture — trace end-to-end

```bash
# Bật CoreDNS log
kubectl -n kube-system edit cm coredns
# Thêm "log" vào plugin chain
sleep 10

# Capture DNS traffic trên CoreDNS pod
COREDNS_POD=$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}')
echo "CoreDNS pod: ${COREDNS_POD}"

# Capture trên CoreDNS pod
kubectl -n kube-system exec ${COREDNS_POD} -- sh -c "
  apk add --no-cache tcpdump 2>/dev/null || apt-get install -y tcpdump 2>/dev/null
  tcpdump -i any -n 'port 53' -c 20 -w /tmp/dns.pcap
" &

# Trigger DNS query từ client
kubectl exec debug-client -- nslookup backend-svc.default.svc.cluster.local
kubectl exec debug-client -- nslookup google.com

# Xem pcap
sleep 5
kubectl -n kube-system exec ${COREDNS_POD} -- tcpdump -r /tmp/dns.pcap -n 2>/dev/null | head -30
# IP 10.244.1.10.52345 > 10.244.1.3.53: A? backend-svc.default.svc.cluster.local.
# IP 10.244.1.3.53 > 10.244.1.10.52345: 10.96.X.X
# IP 10.244.1.10.52346 > 10.244.1.3.53: A? google.com.default.svc.cluster.local.
# IP 10.244.1.3.53 > 10.244.1.10.52346: NXDOMAIN
# ... (search domain attempts)
# IP 10.244.1.3.53 > 10.96.0.10.xxxxx: A? google.com.  (forward đến upstream)

# Xem CoreDNS log
kubectl -n kube-system logs deploy/coredns --tail=20
# [INFO] 10.244.1.10:52345 "A IN backend-svc.default.svc.cluster.local." NOERROR 30ms
# [INFO] 10.244.1.10:52346 "A IN google.com.default.svc.cluster.local." NXDOMAIN 1ms
# ...
```

## Scenario F: CoreDNS ConfigMap bị corrupt

```bash
# Simulate: ConfigMap syntax error
kubectl -n kube-system edit cm coredns
# Sửa Corefile thành có lỗi:
# .:53 {
#     errors
#     kubernetes cluster.local {   ← thiếu closing brace hoặc syntax error
# }

# CoreDNS sẽ không reload (giữ cấu hình cũ vì reload plugin)
sleep 15

# Xem CoreDNS log
kubectl -n kube-system logs deploy/coredns --tail=10
# [ERROR] plugin/reload: Config file changed but reload failed: ...parse error...
# ← CoreDNS vẫn running với config cũ, không crash

# Kiểm tra DNS vẫn hoạt động (config cũ)
kubectl exec debug-client -- nslookup backend-svc.default.svc.cluster.local
# → Vẫn resolve được (config cũ đang dùng)

# Fix: restore ConfigMap
kubectl apply -f /tmp/coredns-backup.yaml
sleep 10
# CoreDNS reload thành công với config tốt
```

> `reload` plugin bảo vệ: nếu config mới lỗi → giữ config cũ, không crash. Cluster vẫn hoạt động. Log "reload failed" → check syntax Corefile.

## DNS Troubleshooting Playbook

```bash
# === PLAYBOOK: Pod không resolve được Service ===

# Step 1: Verify pod có DNS config đúng
kubectl exec PROBLEM-POD -- cat /etc/resolv.conf
# Check: nameserver = CoreDNS IP? search domain có cluster.local?

# Step 2: Test DNS resolution từ problem pod
kubectl exec PROBLEM-POD -- nslookup TARGET-SVC.TARGET-NAMESPACE.svc.cluster.local
# NOERROR → DNS ok, vấn đề ở connection/network
# NXDOMAIN → Service không tồn tại, namespace sai, hoặc CoreDNS fail
# timeout → CoreDNS không reach được

# Step 3: CoreDNS healthy?
kubectl -n kube-system get pod -l k8s-app=kube-dns
kubectl -n kube-system get endpoints kube-dns
# Check: pods running, endpoints có IP

# Step 4: Test DNS từ debug pod (isolate problem pod)
kubectl run tmp-debug --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup TARGET-SVC.TARGET-NAMESPACE.svc.cluster.local
# Nếu debug pod ok nhưng problem pod fail → issue ở problem pod (dnsPolicy, custom resolv.conf)
# Nếu cả 2 fail → CoreDNS vấn đề

# Step 5: Kiểm tra Service và endpoints
kubectl get svc TARGET-SVC -n TARGET-NAMESPACE
kubectl get endpoints TARGET-SVC -n TARGET-NAMESPACE
# Endpoints = <none> → selector không match pod

# Step 6: CoreDNS logs
kubectl -n kube-system logs deploy/coredns --tail=50 | grep "ERROR\|SERVFAIL"

# Step 7: CoreDNS config đúng không?
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
# Check: kubernetes plugin có zone cluster.local? forward plugin có upstream?
```

## Cleanup

```bash
# Restore CoreDNS (xóa log plugin nếu còn)
kubectl -n kube-system edit cm coredns  # Xóa "log"

# Cleanup resources
kubectl delete deployment backend
kubectl delete svc backend-svc broken-svc
kubectl delete pod debug-client
kubectl delete namespace staging
```

## Câu hỏi tự kiểm tra

1. DNS resolve thành công nhưng connection timeout — vấn đề ở đâu?
2. `nslookup my-svc` return NXDOMAIN — liệt kê 3 nguyên nhân possible?
3. CoreDNS config lỗi syntax → cluster DNS fail không? Tại sao?
4. Cross-namespace DNS: pod trong `frontend` resolve Service trong `backend` namespace bằng tên ngắn được không?
5. Khi nào dùng `dig` thay vì `nslookup` để debug DNS?

## Đáp án tham khảo

1. **DNS ok, connection timeout**: Service tồn tại (DNS record có) nhưng endpoints = `<none>`. selector không match pod labels → no endpoints → kube-proxy không tạo DNAT rule → TCP connection không reach pod → timeout. Kiểm tra: `kubectl get endpoints SVCNAME`.

2. **NXDOMAIN causes**: (a) Service chưa tạo hoặc tên sai. (b) Namespace sai (short name → default namespace, Service ở namespace khác). (c) CoreDNS kubernetes plugin không sync (CoreDNS pod crash, API Server unreachable).

3. **Config lỗi syntax → không crash**: `reload` plugin validate config mới trước khi apply. Nếu lỗi → log error, giữ config cũ, tiếp tục chạy. Cluster DNS không bị ảnh hưởng. Graceful degradation.

4. **Cross-namespace short name**: `my-svc` (short name) → append namespace mình → `my-svc.frontend.svc.cluster.local` → không resolve (Service ở backend namespace). Cần `my-svc.backend` (namespace qualified) hoặc FQDN.

5. **dig vs nslookup**: `dig` cho output chi tiết (TTL, record type, query time, flags, server used). Dùng `dig +short` cho output ngắn, `dig +trace` để trace DNS path, `dig ANY` xem tất cả record type. `nslookup` đơn giản hơn, output ít detail. Prefer `dig` để debug.
