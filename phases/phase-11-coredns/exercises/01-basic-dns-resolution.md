# Exercise 01 — Basic DNS Resolution

> **Mục tiêu**: Deploy pod, kiểm tra `/etc/resolv.conf`, dùng `nslookup`/`dig` trace DNS query đến CoreDNS, hiểu flow từ pod đến ClusterIP.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s (Phase 10), CoreDNS running trong kube-system, `kubectl` access

## Bối cảnh

DNS là entry point của service discovery. Bài này trace toàn bộ flow: pod → resolv.conf → CoreDNS → API Server → ClusterIP response.

## Bước 1: Kiểm tra CoreDNS đang chạy

```bash
# Verify CoreDNS deployment
kubectl -n kube-system get deploy coredns
# NAME      READY   UP-TO-DATE   AVAILABLE
# coredns   2/2     2            2

# Lấy CoreDNS ClusterIP
COREDNS_IP=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
echo "CoreDNS ClusterIP: ${COREDNS_IP}"
# CoreDNS ClusterIP: 10.96.0.10

# Xem CoreDNS pod
kubectl -n kube-system get pod -l k8s-app=kube-dns -o wide
# NAME                       READY   STATUS    IP           NODE
# coredns-xxx-aaa            1/1     Running   10.244.1.3   master
# coredns-xxx-bbb            1/1     Running   10.244.1.4   master
```

**Kiểm tra**: CoreDNS 2 replica, Running, có ClusterIP.

## Bước 2: Xem CoreDNS Corefile (ConfigMap)

```bash
# Xem cấu hình CoreDNS
kubectl -n kube-system get cm coredns -o yaml

# Xem chỉ Corefile content
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
# .:53 {
#     errors
#     health {
#         lameduck 5s
#     }
#     ready
#     kubernetes cluster.local in-addr.arpa ip6.arpa {
#         pods insecure
#         fallthrough in-addr.arpa ip6.arpa
#         ttl 30
#     }
#     prometheus :9153
#     forward . /etc/resolv.conf {
#         max_concurrent 1000
#     }
#     cache 30
#     loop
#     reload
#     loadbalance
# }
```

**Kiểm tra**: Nhận diện được `kubernetes` plugin (serve K8s DNS) và `forward` plugin (upstream).

## Bước 3: Deploy debug pod

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dns-debug
  namespace: default
spec:
  containers:
  - name: debug
    image: tutum/dnsutils:latest
    command: [sleep, "3600"]
  restartPolicy: Never
EOF

# Hoặc dùng image nhỏ hơn
kubectl run dns-debug --image=busybox:1.36 --command -- sleep 3600

kubectl wait --for=condition=Ready pod dns-debug --timeout=60s
```

## Bước 4: Kiểm tra /etc/resolv.conf

```bash
# Xem resolv.conf được inject bởi kubelet
kubectl exec dns-debug -- cat /etc/resolv.conf
# nameserver 10.96.0.10
# search default.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5

# Phân tích từng field:
# nameserver 10.96.0.10      → CoreDNS ClusterIP
# search default.svc.cluster.local ...  → search domain chain (namespace "default")
# options ndots:5            → nếu < 5 dấu chấm → thử search domain trước
```

**Kiểm tra**: `nameserver` = CoreDNS ClusterIP. `search` domain bắt đầu bằng `{namespace}.svc.cluster.local`.

## Bước 5: nslookup các DNS name

```bash
# 1. Lookup Kubernetes API Server Service
kubectl exec dns-debug -- nslookup kubernetes.default.svc.cluster.local
# Server:    10.96.0.10        ← CoreDNS
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local
# Name:      kubernetes.default.svc.cluster.local
# Address 1: 10.96.0.1         ← API Server ClusterIP

# 2. Short name (namespace tự động append)
kubectl exec dns-debug -- nslookup kubernetes
# → nslookup thử "kubernetes.default.svc.cluster.local" trước → hit → trả 10.96.0.1

# 3. Lookup CoreDNS chính nó
kubectl exec dns-debug -- nslookup kube-dns.kube-system.svc.cluster.local
# Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

# 4. Lookup external domain (forward đến upstream)
kubectl exec dns-debug -- nslookup google.com
# Server:    10.96.0.10       ← vẫn hỏi CoreDNS
# Address 1: 142.250.x.x      ← CoreDNS forward đến upstream, trả kết quả
```

**Kiểm tra**: Internal name → ClusterIP. External → CoreDNS forward → external IP.

## Bước 6: dig — xem chi tiết DNS response

```bash
# Query chi tiết với dig
kubectl exec dns-debug -- dig kubernetes.default.svc.cluster.local
# ;; QUESTION SECTION:
# ;kubernetes.default.svc.cluster.local. IN A
#
# ;; ANSWER SECTION:
# kubernetes.default.svc.cluster.local. 30 IN A 10.96.0.1
# ↑ TTL 30s (từ CoreDNS cache plugin)
#
# ;; SERVER: 10.96.0.10#53(10.96.0.10)
# ↑ Query đến CoreDNS 10.96.0.10:53

# Xem trace — query path
kubectl exec dns-debug -- dig +trace kubernetes.default.svc.cluster.local
# ↑ +trace = theo dõi từng bước DNS resolution

# Query trực tiếp CoreDNS (bypass resolv.conf)
kubectl exec dns-debug -- dig @10.96.0.10 kubernetes.default.svc.cluster.local
```

**Kiểm tra**: TTL 30s. Server = CoreDNS IP. Answer section có ClusterIP.

## Bước 7: Capture DNS packet bằng tcpdump

```bash
# SSH vào worker node đang chạy dns-debug pod
NODE=$(kubectl get pod dns-debug -o jsonpath='{.spec.nodeName}')
echo "Pod running on: ${NODE}"
ssh ${NODE}

# Trên node: capture DNS traffic
sudo tcpdump -i any -n 'port 53' &
TCPDUMP_PID=$!

# Trigger DNS query
kubectl exec dns-debug -- nslookup kubernetes.default.svc.cluster.local

# Xem capture
sleep 2
sudo kill ${TCPDUMP_PID}
# Output:
# 15:23:01 IP 10.244.1.10.52345 > 10.96.0.10.53: A? kubernetes.default.svc.cluster.local
#   ↑ pod IP                    ↑ CoreDNS IP
# 15:23:01 IP 10.96.0.10.53 > 10.244.1.10.52345: A 10.96.0.1
#   ↑ CoreDNS trả response            ↑ ClusterIP
```

> tcpdump capture: pod gửi UDP query đến CoreDNS, CoreDNS trả A record. DNS = UDP port 53 (mặc định), fallback TCP khi response > 512 bytes.

**Kiểm tra**: Packet: pod → CoreDNS:53 (UDP). Response: CoreDNS → pod (ClusterIP trong answer).

## Bước 8: Quan sát search domain chain

```bash
# Thử tên không tồn tại để thấy search domain chain
kubectl exec dns-debug -- nslookup nonexistent-service 2>&1
# Server:    10.96.0.10
# nslookup: can't resolve 'nonexistent-service'
# → Thử: nonexistent-service.default.svc.cluster.local → NXDOMAIN
# → Thử: nonexistent-service.svc.cluster.local → NXDOMAIN
# → Thử: nonexistent-service.cluster.local → NXDOMAIN
# → Thử: nonexistent-service (absolute) → NXDOMAIN

# Bật log trong CoreDNS để thấy tất cả query
kubectl -n kube-system edit cm coredns
# Thêm "log" vào plugin chain (sau "errors"):
# .:53 {
#     errors
#     log       ← thêm vào đây
#     ...

# Xem log CoreDNS
kubectl -n kube-system logs -f deploy/coredns --tail=20
# [INFO] 10.244.1.10:52346 - 1234 "A IN nonexistent-service.default.svc.cluster.local. udp 60 false 512" NXDOMAIN qr,aa,rd 155 0.000123s
# [INFO] 10.244.1.10:52347 - 1235 "A IN nonexistent-service.svc.cluster.local. udp 56 false 512" NXDOMAIN
# [INFO] 10.244.1.10:52348 - 1236 "A IN nonexistent-service.cluster.local. udp 52 false 512" NXDOMAIN
# → 3 query thất bại (search domain) trước khi fail hoàn toàn

# Sau khi debug xong, xóa "log" plugin (quá nhiều log)
kubectl -n kube-system edit cm coredns
```

**Kiểm tra**: Mỗi nslookup fail sinh 3-4 DNS query (search domain chain). Thấy NXDOMAIN cho mỗi attempt.

## Cleanup

```bash
kubectl delete pod dns-debug

# Nếu đã thêm log plugin, xóa đi
kubectl -n kube-system edit cm coredns
# Xóa dòng "log"
```

## Câu hỏi tự kiểm tra

1. `nameserver` trong resolv.conf là IP gì? Tại sao là CoreDNS không phải 8.8.8.8?
2. ndots:5 nghĩa là gì? Tại sao `nslookup kubernetes` hoạt động được?
3. CoreDNS resolve `kubernetes.default.svc.cluster.local` như thế nào (plugin nào, flow)?
4. Tại sao `nslookup google.com` vẫn hoạt động khi CoreDNS không biết về `google.com`?
5. TTL 30 trong DNS response nghĩa là gì?

## Đáp án tham khảo

1. **nameserver** = CoreDNS ClusterIP (10.96.0.10). kubelet inject từ flag `--cluster-dns`. Pod không dùng node's DNS — luôn hỏi CoreDNS để resolve K8s internal name.

2. **ndots:5**: nếu hostname có < 5 dấu chấm → thêm search domain trước. `kubernetes` có 0 dấu chấm < 5 → thử `kubernetes.default.svc.cluster.local` trước → hit → return. Không cần FQDN.

3. **CoreDNS flow**: nhận query `kubernetes.default.svc.cluster.local` → kubernetes plugin match zone `cluster.local` → lookup Service `kubernetes` trong namespace `default` → ClusterIP 10.96.0.1 → trả A record.

4. **External DNS**: CoreDNS kubernetes plugin không match `google.com` (không phải zone `cluster.local`) → pass đến `forward` plugin → forward đến upstream (node DNS / 8.8.8.8) → upstream resolve → trả response.

5. **TTL 30**: client (pod) cache DNS result 30s. Query trong 30s → dùng cached result, không hỏi lại CoreDNS. Sau 30s → query lại. Từ `cache 30` trong Corefile.
