# 05 — Network Policies

## Network Policy là gì

NetworkPolicy = **Layer 3/4 firewall** cho pod. Control traffic vào (ingress) và ra (egress) pod. Default: all allowed. Policy: deny + allow pattern.

```
Default (no policy):
  All pod traffic ALLOWED (ingress + egress)

NetworkPolicy (default deny):
  All pod traffic DENIED → only allow specified

NetworkPolicy (allow):
  Allow specific traffic → deny everything else
```

> NetworkPolicy = K8s resource (YAML). CNI plugin enforce (iptables/eBPF). Nếu CNI không support NetworkPolicy (bridge only) → policy không có tác dụng.

## NetworkPolicy YAML

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-deny-all
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: web          # Apply to pods with label app=web
  policyTypes:
  - Ingress             # Control ingress
  - Egress              # Control egress
  ingress: []           # Empty = deny all ingress
  egress: []            # Empty = deny all egress
```

### Key fields

| Field | Ý nghĩa |
|-------|---------|
| `podSelector` | Pod nào bị policy apply (label match) |
| `policyTypes` | Ingress, Egress, hoặc cả 2 |
| `ingress` | Rule allow ingress (empty = deny all) |
| `egress` | Rule allow egress (empty = deny all) |
| `ingress[].from` | Source allowed (podSelector, namespaceSelector, ipBlock) |
| `egress[].to` | Destination allowed (podSelector, namespaceSelector, ipBlock) |
| `ingress[].ports` | Port allowed (protocol + port) |

> `podSelector` = chọn pod bị policy. `ingress: []` = deny all ingress. `ingress: [{from: [...]}]` = allow specified. Empty array = deny. No array = not controlled.

## Default deny all ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: default
spec:
  podSelector: {}       # All pods in namespace
  policyTypes:
  - Ingress
  ingress: []           # Deny all ingress
```

> `podSelector: {}` = all pods. `ingress: []` = deny all ingress. **All pod trong namespace không nhận traffic**.

## Default deny all egress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: default
spec:
  podSelector: {}       # All pods
  policyTypes:
  - Egress
  egress: []            # Deny all egress
```

> `egress: []` = deny all egress. Pod không connect được anywhere (including DNS, API Server).

## Allow ingress from specific pod

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-from-frontend
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend    # Only frontend can access web
    ports:
    - protocol: TCP
      port: 80              # Only port 80
```

> Allow ingress from pod `app=frontend` to pod `app=web` port 80. Everything else denied (default deny after first policy).

## Allow egress to specific pod

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-allow-to-web
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: web          # frontend can only connect to web
    ports:
    - protocol: TCP
      port: 80
  - to:                     # Allow DNS
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
```

> frontend egress: allow to web (port 80) + DNS (kube-dns port 53). Everything else denied. **Must allow DNS** — otherwise pod can't resolve Service name.

## Allow ingress from namespace

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-from-prod
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          environment: production   # All pods from production namespace
```

> `namespaceSelector` = allow from all pods trong namespace có label `environment=production`. Label namespace: `kubectl label ns production environment=production`.

## Allow ingress from IP range

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-from-corp
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress:
  - from:
    - ipBlock:
        cidr: 10.0.0.0/8           # Corporate network
        except:
        - 10.0.0.0/24              # Except DMZ
```

> `ipBlock` = allow from IP range. `except` = exclude sub-range. Dùng cho corporate network, VPN, external allowlist.

## Policy interaction — additive

```
Multiple NetworkPolicy apply to same pod → ADDITIVE:

Policy 1: web-deny-all (deny all ingress)
Policy 2: web-allow-from-frontend (allow from frontend)

Result: allow from frontend, deny everything else
```

> NetworkPolicy = **additive**. Multiple policy cho same pod → union of all allow rules. Deny = default (no allow rule match). Không có explicit deny rule — chỉ allow.

## Policy enforcement

### iptables (Calico, kube-proxy)

```
Calico enforce NetworkPolicy:
  1. Kube API → NetworkPolicy CRD
  2. Calico controller watch NetworkPolicy
  3. Calico Felix (daemon on each node) → iptables rules
  4. iptables: cali-proto chain → check source/dest → allow/drop

iptables -S | grep cali
# -A cali-fw-cali-xxx -m comment --comment "cali:xxx" -j MARK
# -A cali-proto -m comment --comment "cali:policy" -j cali-from-hosts-endpoint
```

### eBPF (Cilium)

```
Cilium enforce NetworkPolicy:
  1. Kube API → NetworkPolicy CRD
  2. Cilium agent watch NetworkPolicy
  3. Cilium → compile eBPF program
  4. eBPF program at socket layer → check policy → allow/drop

No iptables — eBPF program in kernel, faster
```

| Enforcement | Mechanism | Performance | Complexity |
|-------------|-----------|-------------|-----------|
| **iptables** (Calico) | iptables rules | O(n) rules | Simple, mature |
| **eBPF** (Cilium) | eBPF program | O(1) lookup | Complex, faster |

> Calico = iptables (mature, simple). Cilium = eBPF (faster, no iptables). Cả 2 enforce NetworkPolicy — mechanism khác nhau.

## CNI support

| CNI | NetworkPolicy support |
|-----|---------------------|
| **Calico** | ✅ Full (ingress + egress) |
| **Cilium** | ✅ Full (ingress + egress) |
| **Flannel** | ❌ No (need Calico for policy) |
| **Bridge** | ❌ No (built-in CNI, no policy) |
| **Weave** | ✅ Full |
| **Antrea** | ✅ Full (OVS-based) |

> Built-in bridge CNI **không support** NetworkPolicy. Cần Calico/Cilium cho policy. Flannel = no policy (need Calico addon).

## Debugging NetworkPolicy

```bash
# List policies
kubectl get networkpolicy -A
# NAMESPACE   NAME                  POD-SELECTOR   AGE
# default     web-deny-all          app=web        5m
# default     web-allow-frontend    app=web        5m

# Describe policy
kubectl describe networkpolicy web-deny-all

# Check if policy applies to pod
kubectl get pod web -o jsonpath='{.metadata.labels}'
# {"app":"web"}  ← matches podSelector

# Test ingress — from another pod
kubectl exec frontend -- curl -s --max-time 3 http://web.default.svc.cluster.local
# (if allowed → response, if denied → timeout)

# Calico — check policy
calicoctl get networkpolicy -A

# Cilium — check policy
kubectl -n kube-system exec ds/cilium -- cilium policy get
```

## Common patterns

### 1. Default deny + allow all

```yaml
# Step 1: Default deny
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress: []
  egress: []
---
# Step 2: Allow specific (per app)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-frontend
spec:
  podSelector:
    matchLabels: {app: web}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector:
        matchLabels: {app: frontend}
```

### 2. DNS always allowed

```yaml
# Must allow DNS egress — otherwise pod can't resolve
egress:
- to:
  - namespaceSelector: {}
    podSelector:
      matchLabels: {k8s-app: kube-dns}
  ports:
  - protocol: UDP
    port: 53
  - protocol: TCP
    port: 53
```

> **Always allow DNS** — pod cần DNS để resolve Service. Nếu deny egress without DNS allow → pod can't connect to anything (can't resolve).

## Liên hệ với Kubernetes

- NetworkPolicy = Layer 3/4 firewall cho pod. Control ingress + egress.
- Default: **all allowed**. Policy: deny + allow pattern. Empty `ingress: []` = deny all.
- NetworkPolicy = **additive** — multiple policy union of allow rules. No explicit deny — chỉ allow.
- `podSelector` = pod bị policy. `namespaceSelector` = namespace source/dest. `ipBlock` = IP range.
- **Must allow DNS** egress — otherwise pod can't resolve Service name.
- CNI enforce: Calico (iptables), Cilium (eBPF). Built-in bridge CNI **không support** NetworkPolicy.
- Flannel = no policy (need Calico addon). Calico/Cilium = full support.
- Common pattern: default deny all → allow specific per app.
- `kubectl get networkpolicy` — list. `kubectl describe networkpolicy` — detail. Test: `curl` from allowed/denied pod.
