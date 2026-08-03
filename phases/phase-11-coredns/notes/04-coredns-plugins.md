# 04 — CoreDNS Plugins

## CoreDNS là gì

CoreDNS = DNS server được viết bằng Go, dùng plugin architecture. Kubernetes deploy CoreDNS thay thế kube-dns từ v1.13+.

```
CoreDNS architecture:
  Server (listen :53 UDP/TCP)
    └── Plugin Chain (middleware pattern)
          errors → health → ready → kubernetes → forward → cache → loop → reload → loadbalance
          ↑ mỗi query đi qua chain từ trái sang phải
          ↑ plugin có thể handle hoặc pass-through đến plugin tiếp theo
```

> Plugin chain = middleware pipeline. Query đến → plugin 1 process → (pass) → plugin 2 process → ... → response trả về. Plugin có thể: answer query (kubernetes plugin), forward query (forward plugin), cache result (cache plugin), hoặc log (log plugin).

## Corefile — cấu hình CoreDNS

Corefile = file config của CoreDNS. Trong Kubernetes, lưu trong ConfigMap `kube-system/coredns`.

```bash
# Xem Corefile hiện tại
kubectl -n kube-system get cm coredns -o yaml
```

```
# Corefile mặc định (kubeadm)
.:53 {
    errors
    health {
        lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
        fallthrough in-addr.arpa ip6.arpa
        ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
        max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

> `.:53` = server block. `. ` = match tất cả domain. `:53` = port. Trong block = list plugin theo thứ tự.

## Từng plugin giải thích

### errors
```
errors
```
Log DNS error vào stderr. Query SERVFAIL, REFUSED, NXDOMAIN... → log. Không cần config, bật là chạy.

### health
```
health {
    lameduck 5s
}
```
Expose HTTP endpoint `/health` ở port 8080. Kubernetes liveness probe check endpoint này.
- `lameduck 5s`: khi graceful shutdown, chờ 5s trước khi dừng accept connection.

```bash
# Check health từ node
curl http://$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}'):8080/health
# OK
```

### ready
```
ready
```
Expose `/ready` ở port 8181. Kubernetes readiness probe. Return 200 khi tất cả plugin sẵn sàng. Trả 503 khi plugin chưa init xong (kubernetes plugin chưa sync API Server).

### kubernetes (plugin quan trọng nhất)
```
kubernetes cluster.local in-addr.arpa ip6.arpa {
    pods insecure
    fallthrough in-addr.arpa ip6.arpa
    ttl 30
}
```

kubernetes plugin = engine serve DNS từ Kubernetes API:
- Watch API Server: Services, Endpoints, Pods
- Sinh A/AAAA/SRV/PTR record theo spec
- `cluster.local in-addr.arpa ip6.arpa` = các zone mà plugin handle
- `pods insecure` = cho phép pod DNS (`10-244-1-5.namespace.pod.cluster.local`), không verify pod IP
- `pods verified` = verify pod IP match API (chặt hơn, chậm hơn)
- `fallthrough in-addr.arpa ip6.arpa` = reverse lookup không match → pass đến plugin tiếp (forward)
- `ttl 30` = TTL cho DNS response (giây)

```bash
# kubernetes plugin watch API Server
# Khi Service mới được tạo → plugin tự pick up → DNS record available ngay
kubectl create svc clusterip new-svc --tcp=80:8080
# Sau vài giây:
kubectl exec debug -- nslookup new-svc.default.svc.cluster.local
# → trả ClusterIP ngay (không cần restart CoreDNS)
```

### prometheus
```
prometheus :9153
```
Expose Prometheus metrics ở `:9153/metrics`. Metrics: cache hit/miss, query count, duration, error rate.

```bash
# Xem CoreDNS metrics
kubectl -n kube-system exec $(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}') \
  -- wget -qO- http://localhost:9153/metrics | head -30
```

### forward
```
forward . /etc/resolv.conf {
    max_concurrent 1000
}
```
Forward query không resolve được (external domain) đến upstream DNS.
- `.` = match tất cả domain (catch-all)
- `/etc/resolv.conf` = đọc nameserver từ node's resolv.conf (DNS của node = upstream)
- `max_concurrent 1000` = max concurrent queries đến upstream

> kubernetes plugin không biết `google.com` → pass đến forward plugin → forward đến node DNS (8.8.8.8 hoặc corporate DNS). CoreDNS = split DNS: internal K8s names qua kubernetes plugin, external qua forward.

```
# Custom upstream (thay vì node resolv.conf)
forward . 8.8.8.8 8.8.4.4 {
    max_concurrent 1000
}
```

### cache
```
cache 30
```
Cache DNS response trong 30s. Giảm query đến kubernetes plugin (API Server) và upstream.

```
cache behavior:
  - Positive cache: successful response cached 30s
  - Negative cache: NXDOMAIN cached (default 5s)
  - Max entries: 9984

cache 30 {
    positive_ttl 30s
    negative_ttl 5s
    prefetch 10 1m   # pre-fetch popular records
}
```

### loop
```
loop
```
Detect và break DNS query loops (CoreDNS forward → loop back to CoreDNS). Nếu detect loop → crash (để Kubernetes restart pod). Bảo vệ tránh infinite loop.

### reload
```
reload
```
Watch ConfigMap thay đổi, tự reload Corefile mà không cần restart pod. Hot reload config.

```bash
# Sửa ConfigMap → CoreDNS tự pick up trong ~30s (không cần restart)
kubectl -n kube-system edit cm coredns
# Sau ~30s: CoreDNS log "Reloading"
```

### loadbalance
```
loadbalance
```
Shuffle thứ tự A record trong response. DNS round-robin cho Headless Service (random thứ tự pod IP trả về). Không thay đổi nội dung, chỉ shuffle order.

## Plugin bổ sung hay dùng

### log — debug DNS query
```
log
```
Log tất cả DNS query vào stdout. Dùng để debug, không bật production (quá nhiều log).

```bash
# Bật log tạm thời
kubectl -n kube-system edit cm coredns
# Thêm "log" vào plugin chain:
# .:53 {
#     errors
#     log             # ← thêm vào đây
#     health
#     ...
# }
```

### rewrite — DNS rewrite
```
rewrite name my-old-svc.default.svc.cluster.local my-new-svc.default.svc.cluster.local
```
Rewrite DNS name trước khi resolve. Use case: migration (old name → new name), alias.

```
# Rewrite query: old-api.default → new-api.default
rewrite name old-api.default.svc.cluster.local new-api.default.svc.cluster.local

# Regex rewrite
rewrite name regex (.*)\.old\.cluster\.local {1}.new.cluster.local
```

### hosts — static host entries
```
hosts {
    192.168.1.100  legacy-db.internal
    fallthrough
}
```
Static DNS entries như `/etc/hosts`. `fallthrough` = nếu không match → tiếp tục plugin chain.

### autopath — reduce DNS queries
```
autopath @kubernetes
```
Tự thử search domain path bên trong CoreDNS thay vì client phải thử từng cái. Giảm DNS query từ 5 (client-side) xuống 1-2 (server-side). Cần kubernetes plugin phía sau.

## Plugin chain execution flow

```
Query: A web-service.default.svc.cluster.local từ pod

1. errors plugin: register error handler, pass through
2. health plugin: không affect query, pass through  
3. ready plugin: không affect query, pass through
4. kubernetes plugin:
   → "web-service.default.svc.cluster.local" match zone "cluster.local"
   → Lookup Service "web-service" trong namespace "default"
   → Found: ClusterIP 10.96.0.1
   → Return A record: 10.96.0.1
   → STOP (query answered, không tiếp tục chain)
   
Query: A google.com từ pod

1. errors plugin: pass through
2. health plugin: pass through
3. ready plugin: pass through
4. kubernetes plugin:
   → "google.com" không match zone "cluster.local"
   → PASS (không answer)
5. forward plugin:
   → Forward đến upstream (node DNS / 8.8.8.8)
   → Nhận response từ upstream
   → Return A record: 142.250.185.78
   → STOP

6. cache plugin: cache result 30s
7. loadbalance plugin: shuffle records
8. Return to client
```

> Plugin chain: kubernetes handle internal DNS, forward handle external DNS. Nếu kubernetes plugin không match (external domain) → forward đến upstream. Cache giảm repeat query.

## Liên hệ với Kubernetes

- **Corefile** = ConfigMap `kube-system/coredns`. `kubectl -n kube-system edit cm coredns` để sửa.
- **kubernetes plugin** = watch API Server, serve A/AAAA/SRV/PTR cho K8s resources.
- **forward plugin** = upstream DNS cho external domain. Default: node's `/etc/resolv.conf`.
- **cache plugin** = cache 30s, giảm load API Server.
- **reload plugin** = hot reload ConfigMap, không cần restart CoreDNS pod.
- Thêm plugin (log, rewrite, hosts) = sửa ConfigMap → reload tự động.
- CoreDNS là Deployment (2 replica), Service `kube-dns` (ClusterIP 10.96.0.10).
