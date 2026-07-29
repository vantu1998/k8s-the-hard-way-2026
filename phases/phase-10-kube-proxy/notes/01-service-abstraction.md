# 01 — Service Abstraction

## Service là gì

Service = **stable IP + DNS** cho一组 pod. Pod IP thay đổi (restart, reschedule), Service IP cố định. Client connect Service IP → kube-proxy DNAT → pod IP.

```
Client → Service IP (10.96.0.1) → kube-proxy (iptables) → Pod IP (10.244.1.5)

Service không tồn tại trong network:
  - Không có process listen trên Service IP
  - Không có interface có Service IP
  - Service IP = virtual IP, chỉ tồn tại trong iptables rule
  - kube-proxy tạo iptables rule trên mỗi node
```

> Service = abstraction. Không phải process, không phải pod. Service = iptables rule trên mỗi node. `curl 10.96.0.1` → iptables DNAT → pod IP. Service IP "không tồn tại" — không ping được, không listen.

## Tại sao cần Service

```
Without Service:
  Pod A (10.244.1.5) → Pod B (10.244.2.3)
  Pod B crash → restart → new IP (10.244.2.7)
  Pod A still connects to 10.244.2.3 → FAIL (old IP)

With Service:
  Pod A → Service (web-service: 10.96.0.1)
  Pod B crash → restart → new IP (10.244.2.7)
  EndpointSlice updates → Service now points to 10.244.2.7
  Pod A connects to 10.96.0.1 → DNAT → 10.244.2.7 → WORKS
```

> Pod IP ephemeral (thay đổi khi restart/reschedule). Service IP stable. Client connect Service IP → luôn reach pod (kube-proxy DNAT). Service = stable endpoint cho dynamic pod.

## Service YAML

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-service
  namespace: default
spec:
  type: ClusterIP              # Service type
  selector:
    app: web                   # Select pods with label app=web
  ports:
  - name: http
    port: 80                   # Service port
    targetPort: 8080           # Pod port (container port)
    protocol: TCP
```

### Key fields

| Field | Ý nghĩa |
|-------|---------|
| `type` | ClusterIP, NodePort, LoadBalancer, ExternalName |
| `selector` | Label selector — chọn pod nào receive traffic |
| `ports[].port` | Service port (client connect) |
| `ports[].targetPort` | Pod port (container listen) |
| `ports[].protocol` | TCP, UDP, SCTP |

> `selector` = label match. Service forward traffic đến pod có label match. `targetPort` = container port. `port` = Service port (client connect).

## EndpointSlice

EndpointSlice = API object track pod IP sẵn sàng receive traffic cho Service.

```bash
# Service
kubectl get svc web-service
# NAME          TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)
# web-service   ClusterIP   10.96.0.1    <none>        80/TCP

# EndpointSlice
kubectl get endpointslice -l kubernetes.io/service-name=web-service
# NAME              ADDRESSTYPE   PORTS   ENDPOINTS
# web-service-xxx   IPv4          80      10.244.1.5,10.244.2.3,10.244.3.7

# Endpoint detail
kubectl get endpointslice -l kubernetes.io/service-name=web-service -o yaml | grep -A 5 "addresses"
# addresses:
# - 10.244.1.5
# - 10.244.2.3
# - 10.244.3.7
# conditions:
#   ready: true
```

> EndpointSlice = list pod IP ready. kube-proxy watch EndpointSlice → update iptables/IPVS rules. Pod ready → IP in EndpointSlice. Pod not ready → IP removed.

### Endpoint vs EndpointSlice

```
Endpoints (old):  1 object per Service, all endpoints in 1 object
EndpointSlice (new):  multiple slices per Service, max 100 endpoints per slice

EndpointSlice advantages:
  - Scalable (split large Service into slices)
  - Efficient watch (only changed slice)
  - Topology info (node, zone)
  - Multi-port support
```

> EndpointSlice = newer, scalable. K8s 1.33 uses EndpointSlice by default. Endpoints still exist (for backward compat) but EndpointSlice is primary.

## Service type

| Type | Access | IP | Use case |
|------|--------|-----|----------|
| **ClusterIP** | Cluster only | Virtual IP (10.96.x.x) | Internal service |
| **NodePort** | Cluster + node IP:port | ClusterIP + node port (30000-32767) | External access (simple) |
| **LoadBalancer** | Cluster + external IP | NodePort + cloud LB IP | Cloud external access |
| **ExternalName** | DNS CNAME | No IP, DNS redirect | External service (database) |
| **Headless** | Pod IP directly | ClusterIP=None | StatefulSet, pod DNS |

### ClusterIP

```yaml
spec:
  type: ClusterIP
  clusterIP: 10.96.0.1   # Optional (auto-assigned if not set)
```

> Default type. Virtual IP, chỉ access trong cluster. iptables DNAT: ClusterIP → pod IP.

### NodePort

```yaml
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080   # Optional (auto-assigned if not set)
```

> Mở port (30000-32767) trên **mọi node**. `nodeIP:30080` → iptables DNAT → ClusterIP → pod IP. Access từ ngoài cluster.

### LoadBalancer

```yaml
spec:
  type: LoadBalancer
  loadBalancerIP: 203.0.113.10   # Optional (cloud assigns)
```

> Cloud provider cấp external IP (AWS ELB, GCP LB). Traffic → external IP → NodePort → ClusterIP → pod. Bare metal: MetalLB.

### ExternalName

```yaml
spec:
  type: ExternalName
  externalName: database.example.com
```

> Không có IP. DNS CNAME: `web-service.default.svc.cluster.local` → `database.example.com`. Pod connect Service name → DNS resolve → external database.

### Headless

```yaml
spec:
  clusterIP: None    # Headless
  selector:
    app: web
```

> `clusterIP: None` = headless. Không có virtual IP. DNS return **pod IP directly** (A record). Dùng cho StatefulSet (pod cần individual DNS).

## Service + selector

```yaml
# Service selects pods by label
spec:
  selector:
    app: web
    tier: frontend

# Pod with matching labels
metadata:
  labels:
    app: web
    tier: frontend
# → Pod in EndpointSlice → receive traffic
```

> Service = label selector. Pod có label match → in EndpointSlice → receive traffic. Pod không match → excluded. Label change → pod added/removed dynamically.

### No selector

```yaml
# Service without selector — manual endpoints
spec:
  ports:
  - port: 80
    targetPort: 80
# No selector → no auto endpoints
---
apiVersion: v1
kind: Endpoints
metadata:
  name: external-service
subsets:
- addresses:
  - ip: 192.168.1.100    # Manual endpoint
  ports:
  - port: 80
```

> Service without selector = manual endpoints. Dùng cho external service (database, legacy app). Manually create Endpoints object with external IP.

## Service discovery — DNS

```
Pod resolve Service by name:
  my-service.default.svc.cluster.local → 10.96.0.1

DNS search domains (from /etc/resolv.conf):
  search default.svc.cluster.local svc.cluster.local cluster.local

Short name resolution:
  my-service              → my-service.default.svc.cluster.local
  my-service.default       → my-service.default.svc.cluster.local
  my-service.default.svc   → my-service.default.svc.cluster.local
```

> Pod resolve Service by name. CoreDNS serve A record: Service name → ClusterIP. Short name works via search domains. Xem Phase 11 cho CoreDNS chi tiết.

## kube-proxy

kube-proxy = daemon trên mỗi node, watch Service + EndpointSlice, tạo iptables/IPVS rules.

```
kube-proxy (DaemonSet, 1 per node):
  1. Watch API Server for Service + EndpointSlice changes
  2. Generate iptables/IPVS rules
  3. Apply rules to node kernel
  4. Rules DNAT: Service IP → pod IP

Modes:
  - iptables (default) — iptables rules, O(n)
  - IPVS — IPVS kernel module, O(1)
  - eBPF (Cilium) — eBPF at socket layer, no kube-proxy
```

> kube-proxy = control plane for Service. Watch API → generate rules → apply to kernel. Data plane = iptables/IPVS/eBPF. Mỗi node có kube-proxy → rules on every node.

## Liên hệ với Kubernetes

- Service = **stable IP + DNS** cho dynamic pod. Không tồn tại trong network — iptables rule.
- EndpointSlice = track pod IP ready. kube-proxy watch → update rules. Pod ready → in EndpointSlice.
- Service type: ClusterIP (internal), NodePort (node port), LoadBalancer (cloud LB), ExternalName (DNS CNAME), Headless (pod IP directly).
- `selector` = label match. Pod có label match → receive traffic. No selector = manual endpoints.
- DNS: `my-service.default.svc.cluster.local` → ClusterIP. Short name via search domains.
- kube-proxy = daemon per node, watch Service + EndpointSlice, generate iptables/IPVS rules.
- Modes: iptables (default, O(n)), IPVS (O(1), faster), eBPF (Cilium, no kube-proxy).
- Service IP không ping được, không listen — chỉ iptables DNAT. `curl` works (DNAT → pod).
