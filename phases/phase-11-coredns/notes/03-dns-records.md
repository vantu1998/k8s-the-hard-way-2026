# 03 — DNS Records

## Loại DNS record trong Kubernetes

| Record Type | Dùng cho | Ví dụ |
|-------------|---------|-------|
| **A** | Service → ClusterIP (IPv4) | `web.default.svc.cluster.local` → `10.96.0.1` |
| **AAAA** | Service → ClusterIP (IPv6, dual-stack) | `web.default.svc.cluster.local` → `fd00::1` |
| **SRV** | Named port discovery | `_http._tcp.web.default.svc.cluster.local` → port 80 |
| **PTR** | Reverse lookup (IP → name) | `1.0.96.10.in-addr.arpa` → `web.default.svc.cluster.local` |
| **CNAME** | ExternalName Service | `my-db.default.svc.cluster.local` → CNAME `database.example.com` |

## A record — Service

### ClusterIP Service

```
Service: web-service
  namespace: default
  ClusterIP: 10.96.0.1
  port: 80/TCP

A record:
  web-service.default.svc.cluster.local.    30    IN    A    10.96.0.1
  ↑ FQDN                                    ↑TTL  ↑class ↑type ↑value
```

```bash
# Query A record
dig +short web-service.default.svc.cluster.local @10.96.0.10
# 10.96.0.1

# Full output
dig web-service.default.svc.cluster.local @10.96.0.10
# ;; QUESTION SECTION:
# ;web-service.default.svc.cluster.local. IN A
#
# ;; ANSWER SECTION:
# web-service.default.svc.cluster.local. 30 IN A 10.96.0.1
#
# ;; SERVER: 10.96.0.10#53(10.96.0.10)
```

### Headless Service

```
Service: web-headless (clusterIP: None)
  Pods: 10.244.1.5, 10.244.2.3, 10.244.3.7

A records (multiple):
  web-headless.default.svc.cluster.local.  5  IN  A  10.244.1.5
  web-headless.default.svc.cluster.local.  5  IN  A  10.244.2.3
  web-headless.default.svc.cluster.local.  5  IN  A  10.244.3.7
  ↑ TTL ngắn hơn (5s) vì pod IP dynamic
```

> Headless TTL ngắn hơn (5s) so với ClusterIP (30s) vì pod IP thay đổi thường xuyên hơn ClusterIP.

## SRV record — port discovery

### Format

```
SRV record format:
  _port-name._proto.service.namespace.svc.cluster.local
  priority  weight  port  target-hostname

Ví dụ:
  _http._tcp.web-service.default.svc.cluster.local.  30  IN  SRV  0  100  80  web-service.default.svc.cluster.local.
  ↑ service spec:                                                    ↑pri ↑wt  ↑port ↑hostname
    - name: http
    - protocol: TCP
    - port: 80
```

### Khi nào CoreDNS sinh SRV

```yaml
# Service cần có named port mới có SRV record
spec:
  ports:
  - name: http    # ← named port → SRV record sinh ra
    port: 80
  - name: grpc    # ← named port → SRV record sinh ra
    port: 9090
  - port: 443     # ← unnamed port → KHÔNG có SRV record
```

```bash
# Query SRV
dig SRV _http._tcp.web-service.default.svc.cluster.local @10.96.0.10
# ;; ANSWER SECTION:
# _http._tcp.web-service.default.svc.cluster.local. 30 IN SRV 0 100 80 web-service.default.svc.cluster.local.
# ;; ADDITIONAL SECTION:
# web-service.default.svc.cluster.local. 30 IN A 10.96.0.1
```

## PTR record — reverse DNS

PTR record: IP → DNS name (reverse lookup).

```
ClusterIP 10.96.0.1 → PTR lookup:
  Reverse zone: 1.0.96.10.in-addr.arpa
  PTR: 1.0.96.10.in-addr.arpa → web-service.default.svc.cluster.local.

Pod IP 10.244.1.5 → PTR lookup:
  5.1.244.10.in-addr.arpa → 10-244-1-5.default.pod.cluster.local.
```

```bash
# PTR lookup cho ClusterIP
dig PTR 1.0.96.10.in-addr.arpa @10.96.0.10
# ;; ANSWER SECTION:
# 1.0.96.10.in-addr.arpa. 30 IN PTR web-service.default.svc.cluster.local.

# Dùng -x flag (shortcut)
dig -x 10.96.0.1 @10.96.0.10
# ;; ANSWER SECTION:
# 1.0.96.10.in-addr.arpa. 30 IN PTR web-service.default.svc.cluster.local.
```

> CoreDNS kubernetes plugin tự sinh PTR record cho ClusterIP và pod IP. Dùng để: audit log (IP → service name), debugging, reverse DNS lookup.

## Pod DNS records

Pod có thể có DNS name riêng theo format đặc biệt.

### Format

```
Pod IP: 10.244.1.5
Namespace: default

Pod DNS name (dashed IP):
  10-244-1-5.default.pod.cluster.local → 10.244.1.5

StatefulSet pod (với subdomain):
  pod-name.subdomain.namespace.svc.cluster.local → pod IP
```

### Pod hostname + subdomain

```yaml
# Pod spec với hostname và subdomain
spec:
  hostname: my-pod-0
  subdomain: my-subdomain   # Phải match một Service name
  # → DNS: my-pod-0.my-subdomain.namespace.svc.cluster.local
```

```yaml
# Service cần có cùng tên với subdomain
apiVersion: v1
kind: Service
metadata:
  name: my-subdomain    # ← phải match pod.spec.subdomain
spec:
  clusterIP: None       # Headless
  selector:
    app: my-app
```

```bash
# Pod DNS với hostname + subdomain
kubectl exec -it debug -- nslookup my-pod-0.my-subdomain.default.svc.cluster.local
# Name: my-pod-0.my-subdomain.default.svc.cluster.local
# Address: 10.244.1.5    ← pod IP trực tiếp
```

> Pod DNS với subdomain chỉ hoạt động nếu có Headless Service cùng tên với subdomain. Mechanism tương tự StatefulSet.

## DNS format tổng hợp

```
Service:
  {service-name}.{namespace}.svc.{cluster-domain}
  kubernetes.default.svc.cluster.local → 10.96.0.1

StatefulSet pod:
  {pod-name}.{headless-svc}.{namespace}.svc.{cluster-domain}
  postgres-0.postgres-headless.default.svc.cluster.local → 10.244.1.5

Pod (dashed IP):
  {ip-dashed}.{namespace}.pod.{cluster-domain}
  10-244-1-5.default.pod.cluster.local → 10.244.1.5

SRV:
  _{port-name}._{proto}.{service-name}.{namespace}.svc.{cluster-domain}
  _http._tcp.web.default.svc.cluster.local → port 80 at web.default.svc.cluster.local

Reverse (PTR):
  {reversed-ip}.in-addr.arpa
  1.0.96.10.in-addr.arpa → web.default.svc.cluster.local
```

## Xem tất cả DNS record của cluster

```bash
# Port-forward CoreDNS để query trực tiếp
kubectl -n kube-system port-forward svc/kube-dns 5353:53 &

# Query A record
dig @127.0.0.1 -p 5353 kubernetes.default.svc.cluster.local

# Query tất cả record type
dig @127.0.0.1 -p 5353 web-service.default.svc.cluster.local ANY

# Check CoreDNS cache (plugin cache stats)
kubectl -n kube-system exec ds/coredns -- wget -qO- http://localhost:9153/metrics | grep coredns_cache
# coredns_cache_size{server="dns://:53",type="denial"} 0
# coredns_cache_size{server="dns://:53",type="success"} 42
# coredns_cache_hits_total{...} 1234
# coredns_cache_misses_total{...} 56
```

## Liên hệ với Kubernetes

- **A record**: Service → ClusterIP (ClusterIP Service) hoặc pod IPs (Headless Service).
- **SRV record**: named port → port number + hostname. Named port bắt buộc.
- **PTR record**: reverse lookup. Tự sinh bởi kubernetes plugin.
- **Pod DNS**: `{ip-dashed}.{ns}.pod.{domain}` hoặc `{name}.{subdomain}.{ns}.svc.{domain}` (cần Headless Service).
- **CNAME**: chỉ cho ExternalName Service.
- TTL: 30s (ClusterIP Service), 5s (Headless/pod — dynamic).
