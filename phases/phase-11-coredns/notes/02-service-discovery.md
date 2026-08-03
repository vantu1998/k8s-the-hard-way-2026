# 02 — Service Discovery

## Service Discovery là gì

Service Discovery = cách pod tìm địa chỉ của Service khác mà không cần hardcode IP. Kubernetes dùng DNS làm primary service discovery mechanism.

```
Traditional (hardcode IP):
  app.env: DB_HOST=192.168.1.100  ← IP thay đổi khi DB restart
  Problem: IP ephemeral, config phải update

Kubernetes DNS:
  app.env: DB_HOST=postgres.default.svc.cluster.local
  DNS resolve → ClusterIP → kube-proxy DNAT → pod IP
  Pod restart → IP mới, nhưng DNS name không đổi → ✓
```

> DNS-based service discovery: dùng tên thay IP. Service tên cố định, DNS giải ra ClusterIP (stable), kube-proxy DNAT sang pod IP (dynamic). App không biết pod IP — chỉ cần DNS name.

## DNS record cho Service thông thường (ClusterIP)

```
Service: web-service (namespace: default, ClusterIP: 10.96.0.1)

DNS records CoreDNS sinh ra:
  A record:   web-service.default.svc.cluster.local → 10.96.0.1
  AAAA record: web-service.default.svc.cluster.local → (IPv6 nếu dual-stack)

Query:
  nslookup web-service.default.svc.cluster.local
  Server: 10.96.0.10
  Address: 10.96.0.10#53
  Name: web-service.default.svc.cluster.local
  Address: 10.96.0.1  ← ClusterIP
```

```bash
# Verify từ trong pod
kubectl exec -it debug-pod -- nslookup web-service
# Server: 10.96.0.10
# Address: 10.96.0.10#53
# Name: web-service.default.svc.cluster.local
# Address: 10.96.0.1

# Dùng dig để xem thêm detail
kubectl exec -it debug-pod -- dig web-service.default.svc.cluster.local
# ;; ANSWER SECTION:
# web-service.default.svc.cluster.local. 30 IN A 10.96.0.1
```

> A record: Service name → ClusterIP. TTL 30s (CoreDNS cache). Thay đổi ClusterIP (hiếm) reflect sau 30s.

## Headless Service — DNS trả pod IP trực tiếp

Headless Service: `clusterIP: None` → không có virtual IP → DNS trả **tất cả pod IP** trực tiếp.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-headless
spec:
  clusterIP: None    # ← Headless
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
```

```
DNS record cho Headless Service:
  web-headless.default.svc.cluster.local → 10.244.1.5 (pod 1 IP)
                                         → 10.244.2.3 (pod 2 IP)
                                         → 10.244.3.7 (pod 3 IP)
  ← Multiple A records, mỗi record = 1 pod IP

So sánh với ClusterIP Service:
  web-service.default.svc.cluster.local → 10.96.0.1 (ClusterIP duy nhất)
```

```bash
# Headless Service DNS response
kubectl exec -it debug-pod -- dig web-headless.default.svc.cluster.local
# ;; ANSWER SECTION:
# web-headless.default.svc.cluster.local. 30 IN A 10.244.1.5
# web-headless.default.svc.cluster.local. 30 IN A 10.244.2.3
# web-headless.default.svc.cluster.local. 30 IN A 10.244.3.7

# Normal Service DNS response
kubectl exec -it debug-pod -- dig web-service.default.svc.cluster.local
# ;; ANSWER SECTION:
# web-service.default.svc.cluster.local. 30 IN A 10.96.0.1  ← chỉ 1 record
```

> Headless = nhiều A record (all pod IPs). Client chọn pod IP trực tiếp. DNS-based load balance (round-robin hoặc random tùy client resolver). Không qua kube-proxy DNAT. Use case: StatefulSet, gRPC, DB cluster member discovery.

## StatefulSet pod DNS

StatefulSet + Headless Service → mỗi pod có DNS tên riêng (stable identity).

```yaml
# StatefulSet postgres
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres-headless    # ← phải match Headless Service name
  replicas: 3
  ...
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-headless
spec:
  clusterIP: None
  selector:
    app: postgres
```

```
DNS records sinh ra:
  postgres-0.postgres-headless.default.svc.cluster.local → pod-0 IP
  postgres-1.postgres-headless.default.svc.cluster.local → pod-1 IP
  postgres-2.postgres-headless.default.svc.cluster.local → pod-2 IP

Format: {pod-name}.{headless-svc-name}.{namespace}.svc.{cluster-domain}
```

```bash
# Verify StatefulSet pod DNS
kubectl exec -it postgres-0 -- nslookup postgres-1.postgres-headless
# Server: 10.96.0.10
# Name: postgres-1.postgres-headless.default.svc.cluster.local
# Address: 10.244.2.5   ← pod-1 IP trực tiếp
```

> StatefulSet pod DNS = stable identity. Pod restart giữ tên DNS (postgres-0, postgres-1...) dù IP thay đổi. Primary use case: database cluster (postgres-0 là primary, postgres-1/2 là replica).

## SRV record — port discovery

SRV record = DNS record chứa port + hostname của service. Kubernetes tự sinh SRV record cho named port.

```yaml
# Service với named port
spec:
  ports:
  - name: http        # ← named port
    port: 80
    targetPort: 8080
  - name: https
    port: 443
    targetPort: 8443
```

```
SRV records:
  _http._tcp.web-service.default.svc.cluster.local → 0 100 80 web-service.default.svc.cluster.local
  _https._tcp.web-service.default.svc.cluster.local → 0 100 443 web-service.default.svc.cluster.local

Format: _{port-name}._{protocol}.{service-name}.{namespace}.svc.{cluster-domain}
         priority  weight  port  target-hostname
```

```bash
# Query SRV record
kubectl exec -it debug-pod -- dig SRV _http._tcp.web-service.default.svc.cluster.local
# ;; ANSWER SECTION:
# _http._tcp.web-service.default.svc.cluster.local. 30 IN SRV 0 100 80 web-service.default.svc.cluster.local.
# ;; ADDITIONAL SECTION:
# web-service.default.svc.cluster.local. 30 IN A 10.96.0.1
```

> SRV record: client tự động discover port number mà không cần config. Dùng cho: Etcd cluster discovery, gRPC name resolution, Consul-style discovery.

## ExternalName Service — DNS CNAME

```yaml
spec:
  type: ExternalName
  externalName: database.example.com
```

```
DNS response:
  my-db.default.svc.cluster.local → CNAME → database.example.com
  database.example.com → (resolve ở upstream DNS)

Client:
  1. Query my-db.default.svc.cluster.local
  2. CoreDNS trả CNAME: database.example.com
  3. Client resolve database.example.com (external DNS)
  4. Connect đến external IP
```

```bash
# ExternalName DNS response
kubectl exec -it debug-pod -- dig my-db.default.svc.cluster.local
# ;; ANSWER SECTION:
# my-db.default.svc.cluster.local. 30 IN CNAME database.example.com.
```

> ExternalName = DNS CNAME không có virtual IP. Dùng để abstract external service (on-prem database, third-party API). Không qua kube-proxy.

## Liên hệ với Kubernetes

- **ClusterIP Service**: 1 A record → ClusterIP. Client → ClusterIP → kube-proxy DNAT → pod.
- **Headless Service**: nhiều A record → tất cả pod IP. Client trực tiếp connect pod. Không qua kube-proxy.
- **StatefulSet**: mỗi pod có DNS name riêng (stable). `pod-0.svc.namespace.svc.cluster.local`.
- **SRV record**: named port → port number via DNS. Client tự discover port.
- **ExternalName**: CNAME → external hostname. Abstract external service.
- DNS format: `{svc}.{ns}.svc.{cluster-domain}` cho Service, `{pod}.{svc}.{ns}.svc.{cluster-domain}` cho StatefulSet pod.
