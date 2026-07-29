# Exercise 03 — Network Policy

> **Mục tiêu**: Tạo NetworkPolicy default deny ingress, test pod không nhận traffic. Add allow rule, test lại. Hiểu deny + allow pattern.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s với Calico/Cilium (NetworkPolicy support), 2+ pod

## Bối cảnh

NetworkPolicy = firewall cho pod. Bài này tạo default deny, test traffic blocked, add allow, test traffic allowed.

## Prerequisites

```bash
# Verify CNI supports NetworkPolicy
kubectl get pods -n kube-system | grep -E "(calico|cilium)"
# calico-node-xxx       1/1   Running
# OR
# cilium-xxx            1/1   Running

# If bridge CNI only (no Calico/Cilium) → NetworkPolicy won't work
# Install Calico: kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

> **Bridge CNI không support NetworkPolicy**. Cần Calico/Cilium. Nếu chỉ bridge → policy tạo được nhưng không enforce.

## Bước 1: Deploy test pods

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: web
  labels:
    app: web
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  labels:
    app: frontend
spec:
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: attacker
  labels:
    app: attacker
spec:
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sleep", "3600"]
EOF
```

```bash
kubectl wait --for=condition=Ready pod/web pod/frontend pod/attacker --timeout=60s

# Get web pod IP
WEB_IP=$(kubectl get pod web -o jsonpath='{.status.podIP}')
echo "Web IP: ${WEB_IP}"
```

## Bước 2: Test — no policy (all allowed)

```bash
# Frontend → web (should work — no policy)
kubectl exec frontend -- wget -qO- --timeout=3 "http://${WEB_IP}"
# <!DOCTYPE html>
# <html><head>...</head>...</html>   ← nginx response

# Attacker → web (should also work — no policy)
kubectl exec attacker -- wget -qO- --timeout=3 "http://${WEB_IP}"
# <!DOCTYPE html>   ← also works
```

> No policy = all traffic allowed. Cả frontend và attacker đều access web.

**Kiểm tra**: Both frontend + attacker can access web (no policy).

## Bước 3: Create default deny ingress

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-deny-all-ingress
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
  - Ingress
  ingress: []
EOF
```

> `podSelector: app=web` → policy apply to web pod. `ingress: []` → deny all ingress. Web không nhận traffic từ ai.

## Bước 4: Test — all ingress blocked

```bash
# Frontend → web (should FAIL — denied)
kubectl exec frontend -- wget -qO- --timeout=3 "http://${WEB_IP}"
# wget: download timed out   ← BLOCKED!

# Attacker → web (should FAIL — denied)
kubectl exec attacker -- wget -qO- --timeout=3 "http://${WEB_IP}"
# wget: download timed out   ← BLOCKED!
```

> Default deny: tất cả traffic đến web bị block. Cả frontend + attacker đều timeout.

**Kiểm tra**: Both frontend + attacker timeout (all ingress denied).

## Bước 5: Allow ingress from frontend

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-frontend
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
          app: frontend
    ports:
    - protocol: TCP
      port: 80
EOF
```

> Allow ingress from `app=frontend` to `app=web` port 80. Policy additive — union with deny-all. Frontend allowed, attacker still denied.

## Bước 6: Test — frontend allowed, attacker denied

```bash
# Frontend → web (should work — allowed)
kubectl exec frontend -- wget -qO- --timeout=3 "http://${WEB_IP}"
# <!DOCTYPE html>   ← WORKS! frontend allowed

# Attacker → web (should FAIL — still denied)
kubectl exec attacker -- wget -qO- --timeout=3 "http://${WEB_IP}"
# wget: download timed out   ← BLOCKED! attacker not in allow rule
```

> Policy additive: `web-deny-all` (deny all) + `web-allow-frontend` (allow frontend) = allow frontend, deny rest. Frontend works, attacker blocked.

**Kiểm tra**: Frontend can access web, attacker cannot.

## Bước 7: Test port restriction

```bash
# Frontend → web port 80 (allowed)
kubectl exec frontend -- wget -qO- --timeout=3 "http://${WEB_IP}:80"
# <!DOCTYPE html>   ← WORKS!

# Frontend → web port 443 (not in allow rule — denied)
kubectl exec frontend -- wget -qO- --timeout=3 "https://${WEB_IP}:443"
# wget: download timed out   ← BLOCKED! port 443 not allowed
```

> Policy allow port 80 only. Port 443 denied (not in `ports` list). Port restriction = Layer 4 firewall.

**Kiểm tra**: Port 80 allowed, port 443 denied.

## Bước 8: Default deny egress

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-deny-all-egress
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress: []
EOF
```

```bash
# Frontend → web (should FAIL — egress denied)
kubectl exec frontend -- wget -qO- --timeout=3 "http://${WEB_IP}"
# wget: download timed out   ← BLOCKED! egress denied

# Frontend → DNS (should also FAIL — egress denied)
kubectl exec frontend -- nslookup kubernetes.default
# Server: 10.96.0.10
# ;; connection timed out   ← DNS also blocked!
```

> Egress deny = frontend không connect được anywhere, including DNS. **Must allow DNS** — otherwise pod can't resolve.

## Bước 9: Allow egress — web + DNS

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-allow-egress
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
  - Egress
  egress:
  # Allow to web pod
  - to:
    - podSelector:
        matchLabels:
          app: web
    ports:
    - protocol: TCP
      port: 80
  # Allow DNS (kube-dns)
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
EOF
```

```bash
# Frontend → web (should work — egress allowed)
kubectl exec frontend -- wget -qO- --timeout=3 "http://${WEB_IP}"
# <!DOCTYPE html>   ← WORKS!

# Frontend → DNS (should work — DNS allowed)
kubectl exec frontend -- nslookup kubernetes.default
# Name: kubernetes.default.svc.cluster.local
# Address: 10.96.0.1   ← DNS works!

# Frontend → external (should FAIL — not in egress allow)
kubectl exec frontend -- wget -qO- --timeout=3 "http://example.com"
# wget: download timed out   ← BLOCKED! external not allowed
```

> Egress allow: web (port 80) + DNS (port 53). External denied. **Always allow DNS** — pod cần DNS để resolve Service.

**Kiểm tra**: Frontend can access web + DNS, but not external.

## Bước 10: Namespace isolation

```bash
# Create production namespace
kubectl create namespace production
kubectl label namespace production environment=production

# Policy: only allow ingress from production namespace
cat <<'EOF' | kubectl apply -f -
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
          environment: production
EOF
```

> `namespaceSelector: environment=production` = allow from all pods trong namespace có label `environment=production`. Namespace isolation.

## Cleanup

```bash
kubectl delete pod web frontend attacker
kubectl delete networkpolicy --all
kubectl delete namespace production
```

## Câu hỏi tự kiểm tra

1. Default (no policy) — pod có nhận traffic không? Tại sao?
2. `ingress: []` vs `ingress:` (not set) — khác nhau thế nào?
3. NetworkPolicy additive — 2 policy (deny all + allow frontend) → kết quả gì?
4. Egress deny all — tại sao phải allow DNS? Nếu không allow DNS → điều gì xảy ra?
5. Bridge CNI (no Calico/Cilium) — NetworkPolicy có work không? Tại sao?

## Đáp án tham khảo

1. **All allowed** — default K8s = no network isolation. Pod nhận traffic từ mọi pod. NetworkPolicy phải được tạo để deny. K8s design: default open, opt-in security.
2. `ingress: []` = **deny all** ingress (empty array = no allow rule = all denied). `ingress:` not set = **not controlled** (policy doesn't manage ingress). `policyTypes: [Ingress]` + `ingress: []` = deny. `policyTypes: [Ingress]` + no `ingress` field = also deny (default empty).
3. **Additive** — union of allow rules. `deny-all` (no allow) + `allow-frontend` (allow frontend) = allow frontend, deny rest. Deny = default (no matching allow rule). No explicit deny rule.
4. DNS = UDP/TCP port 53 to CoreDNS. Egress deny all = block DNS → pod can't resolve Service name → `nslookup` timeout → can't connect to Service. **Must allow DNS** egress: `to: kube-dns, port: 53`. Without DNS = pod broken.
5. **No** — bridge CNI không implement NetworkPolicy enforcement. Policy tạo thành công (API Server accept) nhưng không enforce (no iptables/eBPF rules). CNI phải support: Calico (iptables), Cilium (eBPF). Bridge = no policy.
