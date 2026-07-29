# 02 — ClusterIP & NodePort

## ClusterIP

ClusterIP = virtual IP, chỉ access trong cluster. kube-proxy iptables DNAT: ClusterIP → pod IP.

```
Client pod (10.244.1.5) → Service ClusterIP (10.96.0.1:80)
  → iptables KUBE-SERVICES chain
  → KUBE-SVC-<hash> chain (match dst 10.96.0.1:80)
  → KUBE-SEP-<hash> chain (random endpoint)
  → DNAT: 10.96.0.1:80 → 10.244.2.3:8080 (pod IP:targetPort)
  → packet to pod
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
  - port: 80           # Service port
    targetPort: 8080   # Pod port
```

```bash
kubectl get svc web-service
# NAME          TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)
# web-service   ClusterIP   10.96.0.1    <none>        80/TCP
```

> ClusterIP = `10.96.0.1` (from service CIDR `10.96.0.0/12`). Virtual — không có interface, không ping. `curl 10.96.0.1:80` → iptables DNAT → pod IP:8080.

### ClusterIP allocation

```
Controller Manager:
  --service-cluster-ip-range=10.96.0.0/12   (service CIDR)

Allocation:
  10.96.0.0/12 → 10.96.0.0 – 10.111.255.255 (1M+ IPs)
  Each Service gets 1 IP from this range

  Service 1: 10.96.0.1
  Service 2: 10.96.0.2
  Service 3: 10.96.12.5
```

> Service CIDR = riêng (không overlap pod CIDR). Controller Manager cấp IP cho Service. `--service-cluster-ip-range` flag. IP allocated dynamically, không thay đổi (stable).

### ClusterIP range

```bash
# Check service CIDR
kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.clusterIP}{"\n"}{end}' | sort | head -5
# 10.96.0.1    ← kube-dns
# 10.96.0.10   ← kube-dns
# 10.96.1.5    ← web-service

# Check controller-manager flag
ps aux | grep kube-controller-manager | grep -o '\--service-cluster-ip-range=[^ ]*'
# --service-cluster-ip-range=10.96.0.0/12
```

## NodePort

NodePort = mở port (30000-32767) trên **mọi node**. `nodeIP:nodePort` → iptables DNAT → pod IP.

```
External client → nodeIP:30080 (e.g., 192.168.1.10:30080)
  → iptables KUBE-NODEPORTS chain
  → KUBE-SVC-<hash> chain (match dst :30080)
  → KUBE-SEP-<hash> chain (random endpoint)
  → DNAT: 192.168.1.10:30080 → 10.244.2.3:8080 (pod IP:targetPort)
  → packet to pod
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  type: NodePort
  selector:
    app: web
  ports:
  - port: 80           # Service port (ClusterIP:80)
    targetPort: 8080   # Pod port
    nodePort: 30080    # Node port (nodeIP:30080)
```

```bash
kubectl get svc web-service
# NAME          TYPE       CLUSTER-IP    EXTERNAL-IP   PORT(S)
# web-service   NodePort   10.96.0.1    <none>        80:30080/TCP
#                                                  ↑ ClusterIP:80 + nodeIP:30080
```

> NodePort = ClusterIP + node port. `80:30080` = ClusterIP:80 (internal) + nodeIP:30080 (external). Access từ ngoài cluster: `curl nodeIP:30080`.

### NodePort range

```
Default range: 30000-32767
Configurable: --service-node-port-range=30000-32767 (kube-apiserver flag)
```

```bash
# Check node port range
ps aux | grep kube-apiserver | grep -o '\--service-node-port-range=[^ ]*'
# --service-node-port-range=30000-32767

# List all NodePorts
kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.type}{"\t"}{.spec.ports[0].nodePort}{"\n"}{end}' | grep NodePort
# web-service   NodePort   30080
```

> NodePort range 30000-32767 (default). Cấp dynamically (if not specified) hoặc manually (`nodePort: 30080`). Port mở trên **mọi node** — bất kỳ node nào cũng forward.

### NodePort access

```bash
# From inside cluster (ClusterIP)
kubectl exec client -- curl http://10.96.0.1:80

# From inside cluster (NodePort)
kubectl exec client -- curl http://192.168.1.10:30080

# From outside cluster (NodePort)
curl http://192.168.1.10:30080   ← from host machine
curl http://192.168.1.11:30080   ← any node works
curl http://192.168.1.12:30080   ← any node works
```

> NodePort accessible từ mọi node. `nodeIP:30080` → DNAT → pod IP (pod có thể trên node khác). Load balance across pods, not nodes.

## LoadBalancer

LoadBalancer = NodePort + cloud provider external IP.

```
External client → cloud LB IP (203.0.113.10:80)
  → cloud LB → nodeIP:30080 (NodePort)
  → iptables KUBE-NODEPORTS → KUBE-SVC → KUBE-SEP
  → DNAT → pod IP:8080
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  type: LoadBalancer
  loadBalancerIP: 203.0.113.10   # Optional (cloud assigns)
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 8080
```

```bash
kubectl get svc web-service
# NAME          TYPE           CLUSTER-IP    EXTERNAL-IP    PORT(S)
# web-service   LoadBalancer   10.96.0.1    203.0.113.10   80:30080/TCP
#                                              ↑ cloud LB IP  ↑ NodePort
```

> LoadBalancer = cloud LB (AWS ELB, GCP Network LB) → NodePort → pod. Cloud provider provision LB automatically. `EXTERNAL-IP` = cloud LB IP. Bare metal: MetalLB.

### MetalLB (bare metal)

```bash
# Install MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml

# Configure IP pool
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - 192.168.1.100-192.168.1.200   # IP range for LoadBalancer
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system
spec:
  ipAddressPools:
  - default
EOF
```

> MetalLB = LoadBalancer cho bare metal. ARP/NDP advertise external IP. `192.168.1.100-200` = IP pool. MetalLB assign IP, ARP respond. Works like cloud LB.

## ExternalName

```yaml
apiVersion: v1
kind: Service
metadata:
  name: database
spec:
  type: ExternalName
  externalName: db.example.com
```

```bash
# DNS resolution
kubectl exec client -- nslookup database.default.svc.cluster.local
# Name: db.example.com
# Address: 93.184.216.34   ← external IP (CNAME)

# Connect
kubectl exec client -- curl http://database.default.svc.cluster.local
# → DNS CNAME → db.example.com → 93.184.216.34
```

> ExternalName = DNS CNAME. Không có IP, không iptables. Pod connect `database.default.svc.cluster.local` → DNS resolve → `db.example.com` → external. Dùng cho external service (database, API).

## Headless Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-headless
spec:
  clusterIP: None    # Headless
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 8080
```

```bash
# DNS resolution — returns pod IPs (not virtual IP)
kubectl exec client -- nslookup web-headless.default.svc.cluster.local
# Name: web-headless.default.svc.cluster.local
# Address: 10.244.1.5    ← pod IP 1
# Address: 10.244.2.3    ← pod IP 2
# Address: 10.244.3.7    ← pod IP 3

# No ClusterIP
kubectl get svc web-headless
# NAME           TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)
# web-headless   ClusterIP   None         <none>        80/TCP
```

> Headless (`clusterIP: None`) = không virtual IP. DNS return **pod IP directly** (A record). Client connect trực tiếp pod IP — no load balancing, no DNAT. Dùng cho StatefulSet (pod cần individual DNS: `web-0.web-headless`).

### StatefulSet + Headless

```
StatefulSet (web-0, web-1, web-2) + Headless Service (web-headless):

DNS:
  web-0.web-headless.default.svc.cluster.local → 10.244.1.5  (pod 0 IP)
  web-1.web-headless.default.svc.cluster.local → 10.244.2.3  (pod 1 IP)
  web-2.web-headless.default.svc.cluster.local → 10.244.3.7  (pod 2 IP)

  web-headless.default.svc.cluster.local → 10.244.1.5, 10.244.2.3, 10.244.3.7
    (all pod IPs — client pick one, no load balancing)
```

> StatefulSet pod có individual DNS (`web-0.web-headless`). Client connect specific pod. Dùng cho database (master/slave), Kafka (broker), ZooKeeper.

## Hairpin

```
Pod → Service IP → DNAT → same pod (hairpin):

Pod (10.244.1.5) → Service (10.96.0.1)
  → iptables DNAT → 10.244.1.5 (same pod!)
  → packet goes out and back to same pod

Without hairpinMode: packet dropped (source = dest, loop)
With hairpinMode: iptables SNAT → packet works
```

> Hairpin = pod access Service IP → DNAT → back to same pod. `hairpinMode: true` in CNI config (kube-proxy flag `--hairpin-mode`). Without hairpin = packet dropped (source = dest).

## Liên hệ với Kubernetes

- **ClusterIP** = virtual IP, internal only. iptables DNAT: ClusterIP → pod IP. Không ping, không listen.
- Service CIDR = `10.96.0.0/12` (controller-manager `--service-cluster-ip-range`).
- **NodePort** = port (30000-32767) trên mọi node. `nodeIP:nodePort` → DNAT → pod. Access từ ngoài.
- **LoadBalancer** = cloud LB → NodePort → pod. Cloud provision external IP. MetalLB cho bare metal.
- **ExternalName** = DNS CNAME → external. Không IP, không iptables.
- **Headless** (`clusterIP: None`) = DNS return pod IP directly. No load balancing. Dùng cho StatefulSet.
- StatefulSet + Headless: `web-0.web-headless` → individual pod DNS. Client connect specific pod.
- Hairpin = pod → Service → DNAT → same pod. `hairpinMode: true` required.
- NodePort accessible từ mọi node — DNAT → pod (pod có thể trên node khác).
