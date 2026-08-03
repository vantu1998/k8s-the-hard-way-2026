# Exercise 04 — DNS Policy

> **Mục tiêu**: Deploy pod với 4 loại dnsPolicy khác nhau, so sánh `/etc/resolv.conf`, hiểu impact của từng policy.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s, CoreDNS running, `kubectl` access

## Bối cảnh

`dnsPolicy` trong Pod spec quyết định kubelet inject resolv.conf như thế nào. Sai policy → pod không resolve K8s Service hoặc không resolve external DNS. Hiểu policy giúp debug DNS issues trong production.

## Bước 1: Deploy 4 pod với 4 dnsPolicy

```bash
cat <<'EOF' | kubectl apply -f -
# Pod 1: ClusterFirst (default)
apiVersion: v1
kind: Pod
metadata:
  name: dns-clusterfirst
spec:
  dnsPolicy: ClusterFirst
  containers:
  - name: debug
    image: busybox:1.36
    command: [sleep, "3600"]
---
# Pod 2: Default (node DNS)
apiVersion: v1
kind: Pod
metadata:
  name: dns-default
spec:
  dnsPolicy: Default
  containers:
  - name: debug
    image: busybox:1.36
    command: [sleep, "3600"]
---
# Pod 3: None + custom dnsConfig
apiVersion: v1
kind: Pod
metadata:
  name: dns-none
spec:
  dnsPolicy: None
  dnsConfig:
    nameservers:
    - 8.8.8.8
    - 8.8.4.4
    searches:
    - custom.internal
    options:
    - name: ndots
      value: "2"
    - name: timeout
      value: "5"
  containers:
  - name: debug
    image: busybox:1.36
    command: [sleep, "3600"]
---
# Pod 4: ClusterFirst + custom dnsConfig (hybrid)
apiVersion: v1
kind: Pod
metadata:
  name: dns-hybrid
spec:
  dnsPolicy: ClusterFirst
  dnsConfig:
    nameservers:
    - 1.1.1.1         # Thêm Cloudflare DNS (append sau CoreDNS)
    searches:
    - extra.domain.local   # Thêm search domain
    options:
    - name: ndots
      value: "3"      # Giảm từ 5 → 3
  containers:
  - name: debug
    image: busybox:1.36
    command: [sleep, "3600"]
EOF

kubectl wait --for=condition=Ready pod \
  dns-clusterfirst dns-default dns-none dns-hybrid \
  --timeout=60s
```

## Bước 2: So sánh /etc/resolv.conf

```bash
# In resolv.conf của tất cả 4 pod
for pod in dns-clusterfirst dns-default dns-none dns-hybrid; do
  echo "================================================================"
  echo "=== ${pod} ==="
  echo "================================================================"
  kubectl exec ${pod} -- cat /etc/resolv.conf
  echo ""
done
```

Expected output:
```
=== dns-clusterfirst ===
nameserver 10.96.0.10                          ← CoreDNS
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5

=== dns-default ===
nameserver 8.8.8.8                             ← Node's DNS (Google DNS)
search home.example.com                        ← Node's search domain
options ...

=== dns-none ===
nameserver 8.8.8.8                             ← Custom (dari dnsConfig)
nameserver 8.8.4.4
search custom.internal
options ndots:2 timeout:5

=== dns-hybrid ===
nameserver 10.96.0.10                          ← CoreDNS (dari ClusterFirst)
nameserver 1.1.1.1                             ← Tambahan dari dnsConfig
search default.svc.cluster.local svc.cluster.local cluster.local extra.domain.local
options ndots:3                                ← Override dari 5 → 3
```

**Kiểm tra**: Mỗi pod có resolv.conf khác nhau tùy policy.

## Bước 3: Test DNS resolution từ mỗi pod

```bash
# Test: resolve K8s Service (kubernetes API Server)
echo "=== Resolve kubernetes.default.svc.cluster.local ==="
for pod in dns-clusterfirst dns-default dns-none dns-hybrid; do
  echo "--- ${pod} ---"
  kubectl exec ${pod} -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -E "Address|error" || echo "FAILED"
done

# Expected:
# --- dns-clusterfirst --- → Address: 10.96.0.1 ✓ (CoreDNS biết K8s)
# --- dns-default ---      → FAILED ✗ (node DNS không biết K8s internal)
# --- dns-none ---         → FAILED ✗ (8.8.8.8 không biết K8s internal)
# --- dns-hybrid ---       → Address: 10.96.0.1 ✓ (CoreDNS biết K8s)
```

```bash
# Test: resolve external domain (google.com)
echo "=== Resolve google.com ==="
for pod in dns-clusterfirst dns-default dns-none dns-hybrid; do
  echo "--- ${pod} ---"
  kubectl exec ${pod} -- nslookup google.com 2>&1 | grep -E "Address|error" | head -2 || echo "FAILED"
done

# Expected:
# --- dns-clusterfirst --- → Address: 142.250.x.x ✓ (CoreDNS forward → upstream)
# --- dns-default ---      → Address: 142.250.x.x ✓ (node DNS resolve trực tiếp)
# --- dns-none ---         → Address: 142.250.x.x ✓ (8.8.8.8 resolve external)
# --- dns-hybrid ---       → Address: 142.250.x.x ✓ (CoreDNS forward)
```

**Kiểm tra**: `ClusterFirst` và `hybrid` resolve cả K8s internal và external. `Default` và `None` chỉ resolve external.

## Bước 4: ndots impact — so sánh dns-clusterfirst vs dns-hybrid

```bash
# Bật CoreDNS log tạm thời
kubectl -n kube-system edit cm coredns
# Thêm "log" vào plugin chain
sleep 10  # Chờ reload

# Pod clusterfirst: ndots:5 — external query tốn bao nhiêu DNS query?
echo "=== ClusterFirst (ndots:5) - query google.com ==="
kubectl exec dns-clusterfirst -- nslookup google.com
kubectl -n kube-system logs deploy/coredns --tail=10 | grep "google.com"
# Thấy 4 query:
# google.com.default.svc.cluster.local. → NXDOMAIN
# google.com.svc.cluster.local.         → NXDOMAIN
# google.com.cluster.local.             → NXDOMAIN
# google.com.                           → NOERROR (cuối cùng mới hit)

echo ""
echo "=== Hybrid (ndots:3) - query google.com ==="
kubectl -n kube-system logs deploy/coredns --tail=0 -f &
LOG_PID=$!
kubectl exec dns-hybrid -- nslookup google.com
sleep 2
kill ${LOG_PID}
# "google.com" có 1 dấu chấm < 3 (ndots) → thử search domain trước
# google.com.default.svc.cluster.local. → NXDOMAIN (1)
# google.com.svc.cluster.local.         → NXDOMAIN (2)
# google.com.cluster.local.             → NXDOMAIN (3)
# google.com.extra.domain.local.        → NXDOMAIN (4)
# google.com.                           → NOERROR (5) — vẫn nhiều!

# Giải pháp: dùng FQDN với trailing dot
kubectl exec dns-hybrid -- nslookup google.com.   # ← trailing dot
# → 1 query: google.com. → NOERROR ngay (absolute name)
```

> `ndots` giảm không giúp nhiều nếu search domain nhiều hơn ndots. FQDN với trailing dot (`.`) = absolute name, skip search domain hoàn toàn.

## Bước 5: Pod với hostNetwork (ClusterFirstWithHostNet)

```bash
# hostNetwork pod với ClusterFirst — DNS sẽ sai
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dns-hostnet-wrong
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirst   # ← WRONG cho hostNetwork
  containers:
  - name: debug
    image: busybox:1.36
    command: [sleep, "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: dns-hostnet-correct
spec:
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet   # ← CORRECT
  containers:
  - name: debug
    image: busybox:1.36
    command: [sleep, "3600"]
EOF

kubectl wait --for=condition=Ready pod dns-hostnet-wrong dns-hostnet-correct --timeout=60s
```

```bash
# So sánh resolv.conf
echo "=== hostNetwork + ClusterFirst (WRONG) ==="
kubectl exec dns-hostnet-wrong -- cat /etc/resolv.conf
# nameserver 8.8.8.8   ← node's DNS (vì hostNetwork share host resolv.conf)
# ← KHÔNG có CoreDNS!

echo ""
echo "=== hostNetwork + ClusterFirstWithHostNet (CORRECT) ==="
kubectl exec dns-hostnet-correct -- cat /etc/resolv.conf
# nameserver 10.96.0.10  ← CoreDNS ✓
# search default.svc.cluster.local ...

# Test resolve K8s Service
echo ""
echo "--- dns-hostnet-wrong: resolve kubernetes ---"
kubectl exec dns-hostnet-wrong -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -E "Address|error"
# FAILED ✗

echo ""
echo "--- dns-hostnet-correct: resolve kubernetes ---"
kubectl exec dns-hostnet-correct -- nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -E "Address|error"
# Address: 10.96.0.1 ✓
```

**Kiểm tra**: `hostNetwork: true` + `ClusterFirst` → dùng node DNS (không có CoreDNS). Phải dùng `ClusterFirstWithHostNet`.

## Bước 6: Bỏ log plugin, cleanup

```bash
# Restore CoreDNS ConfigMap (xóa log plugin)
kubectl -n kube-system edit cm coredns
# Xóa dòng "log"
sleep 10  # Chờ reload

# Cleanup pods
kubectl delete pod \
  dns-clusterfirst dns-default dns-none dns-hybrid \
  dns-hostnet-wrong dns-hostnet-correct
```

## Câu hỏi tự kiểm tra

1. Pod với `dnsPolicy: Default` có resolve được `kubernetes.default.svc.cluster.local` không? Tại sao?
2. Khi nào cần `ClusterFirstWithHostNet`? Use case thực tế?
3. `dnsPolicy: None` phải khai báo gì thêm? Nếu không khai báo sẽ lỗi gì?
4. `dnsConfig` với `dnsPolicy: ClusterFirst` → nameserver nào đứng trước trong resolv.conf?
5. ndots:5 vs ndots:2 — external DNS query khác nhau thế nào?

## Đáp án tham khảo

1. **Default không resolve K8s internal**: `Default` copy node's resolv.conf — nameserver là node DNS (8.8.8.8 hoặc corporate DNS). Node DNS không biết `cluster.local` zone → NXDOMAIN. Để resolve K8s internal luôn cần `ClusterFirst`.

2. **ClusterFirstWithHostNet use case**: DaemonSet network plugin (Cilium agent, Flannel, Calico) dùng `hostNetwork: true` để access host network. Cần resolve K8s Service (API Server) → cần `ClusterFirstWithHostNet`. Thiếu → agent không resolve `kubernetes.default.svc.cluster.local`.

3. **dnsPolicy: None + thiếu dnsConfig**: Kubernetes validate pod spec → error: `dnsConfig is required when dnsPolicy is "None"`. Pod không được create. Phải khai báo ít nhất 1 `nameservers` entry.

4. **dnsConfig + ClusterFirst nameserver order**: CoreDNS IP đứng trước (từ ClusterFirst), custom nameservers append sau. resolv.conf: `nameserver <CoreDNS>`, `nameserver <custom>`. glibc dùng nameserver đầu tiên, fallback sang tiếp theo nếu timeout.

5. **ndots impact**: `ndots:5` — external `google.com` (1 dot < 5) → thử 3+ search domain → 4 queries total. `ndots:2` — `google.com` (1 dot < 2) → thử search domain → vẫn nhiều query. FQDN (`google.com.`) = bypass ndots hoàn toàn → 1 query.
