# 05 — DNS Policy

## dnsPolicy là gì

`dnsPolicy` trong Pod spec quyết định cách kubelet cấu hình `/etc/resolv.conf` cho pod.

```yaml
spec:
  dnsPolicy: ClusterFirst   # default
```

| Policy | resolv.conf | Use case |
|--------|------------|---------|
| `ClusterFirst` | CoreDNS nameserver + K8s search domain | Default — mọi pod thông thường |
| `ClusterFirstWithHostNet` | CoreDNS nameserver + K8s search domain | Pod dùng `hostNetwork: true` |
| `Default` | Giống node's `/etc/resolv.conf` | Pod cần resolve DNS như node (external only) |
| `None` | Hoàn toàn custom (phải dùng `dnsConfig`) | Custom DNS hoàn toàn |

## ClusterFirst (default)

```yaml
spec:
  dnsPolicy: ClusterFirst   # mặc định nếu không khai báo
```

```
/etc/resolv.conf của pod:
  nameserver 10.96.0.10          ← CoreDNS ClusterIP
  search default.svc.cluster.local svc.cluster.local cluster.local
  options ndots:5
```

> Default. Mọi pod đều dùng CoreDNS. Internal name → CoreDNS kubernetes plugin. External name → CoreDNS forward → upstream. Không cần khai báo rõ.

## ClusterFirstWithHostNet

```yaml
spec:
  hostNetwork: true             # Pod dùng network namespace của node
  dnsPolicy: ClusterFirstWithHostNet
```

```
Vấn đề:
  hostNetwork: true + dnsPolicy: ClusterFirst
  → resolv.conf lấy từ host (node DNS) vì pod share host network
  → KHÔNG dùng CoreDNS

Fix:
  hostNetwork: true + dnsPolicy: ClusterFirstWithHostNet
  → resolv.conf dùng CoreDNS (giống ClusterFirst)
  → Pod dùng host network nhưng vẫn resolve K8s DNS
```

```
/etc/resolv.conf của pod với ClusterFirstWithHostNet:
  nameserver 10.96.0.10          ← CoreDNS (không phải node DNS)
  search default.svc.cluster.local svc.cluster.local cluster.local
  options ndots:5
```

> `hostNetwork: true` thường dùng cho DaemonSet cần access host network (metrics collector, network plugin). Phải dùng `ClusterFirstWithHostNet` để vẫn resolve K8s Service name.

## Default

```yaml
spec:
  dnsPolicy: Default
```

```
/etc/resolv.conf của pod — COPY từ node:
  nameserver 8.8.8.8             ← node's DNS (ví dụ Google DNS)
  nameserver 8.8.4.4
  search home.example.com
  options ...
```

> Pod không biết về CoreDNS, không resolve được Service name. Dùng khi pod chỉ cần resolve external DNS (không cần K8s internal). Hiếm dùng — hầu hết pod cần ClusterFirst.

**Cảnh báo**: `Default` ≠ "default value". Default value của `dnsPolicy` là `ClusterFirst`.

## None — hoàn toàn custom

```yaml
spec:
  dnsPolicy: None
  dnsConfig:
    nameservers:
    - 192.168.1.53      # Custom DNS server
    searches:
    - custom.domain.local
    options:
    - name: ndots
      value: "2"        # Giảm xuống 2 thay vì 5
    - name: timeout
      value: "5"
```

```
/etc/resolv.conf của pod:
  nameserver 192.168.1.53
  search custom.domain.local
  options ndots:2 timeout:5
```

> `None` = tự define hoàn toàn. Phải khai báo `dnsConfig`. Dùng khi: custom corporate DNS, cần giảm ndots (giảm DNS query overhead), testing.

## dnsConfig — tùy chỉnh thêm

`dnsConfig` có thể dùng với **bất kỳ** `dnsPolicy` nào để thêm/override settings:

```yaml
spec:
  dnsPolicy: ClusterFirst       # Vẫn dùng CoreDNS
  dnsConfig:
    nameservers:
    - 1.2.3.4                   # Thêm nameserver (APPEND sau CoreDNS)
    searches:
    - my-custom.domain          # Thêm search domain
    options:
    - name: ndots
      value: "3"                # Override ndots từ 5 → 3
    - name: timeout
      value: "5"
```

```
/etc/resolv.conf kết quả (ClusterFirst + dnsConfig):
  nameserver 10.96.0.10         ← CoreDNS (từ ClusterFirst)
  nameserver 1.2.3.4            ← thêm từ dnsConfig.nameservers
  search default.svc.cluster.local svc.cluster.local cluster.local my-custom.domain
  options ndots:3 timeout:5
```

> dnsConfig = additional config, không replace (trừ policy None). Hay dùng: giảm ndots (tăng performance external DNS), thêm search domain, thêm fallback nameserver.

## ndots performance implication

```
ndots:5 (default) — External DNS vấn đề:

Query "google.com" từ pod:
  Attempt 1: google.com.default.svc.cluster.local → NXDOMAIN
  Attempt 2: google.com.svc.cluster.local → NXDOMAIN
  Attempt 3: google.com.cluster.local → NXDOMAIN
  Attempt 4: google.com. (absolute) → 142.250.185.78 ✓
  Total: 4 DNS queries

Tác động:
  - Mỗi external DNS query tốn 4x queries
  - Latency tăng (mỗi NXDOMAIN cần round-trip đến CoreDNS)
  - CoreDNS load tăng

Giải pháp 1: Dùng FQDN với trailing dot
  curl google.com.   ← trailing dot = absolute, bỏ qua ndots
  → Chỉ 1 query: google.com. → 142.250.185.78

Giải pháp 2: Giảm ndots
  dnsConfig:
    options:
    - name: ndots
      value: "2"   ← chỉ thử search domain nếu có < 2 dấu chấm
  → "google.com" (1 dấu chấm) ≥ 2 → không thử search domain → trực tiếp resolve
  → 1 query thay vì 4
```

## So sánh thực tế

```bash
# Deploy 4 pod với 4 dnsPolicy khác nhau
cat <<'EOF' | kubectl apply -f -
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
apiVersion: v1
kind: Pod
metadata:
  name: dns-none
spec:
  dnsPolicy: None
  dnsConfig:
    nameservers:
    - 8.8.8.8
    searches:
    - custom.local
    options:
    - name: ndots
      value: "2"
  containers:
  - name: debug
    image: busybox:1.36
    command: [sleep, "3600"]
EOF

# So sánh /etc/resolv.conf
for pod in dns-clusterfirst dns-default dns-none; do
  echo "=== ${pod} ==="
  kubectl exec ${pod} -- cat /etc/resolv.conf
  echo ""
done
```

## Liên hệ với Kubernetes

- `ClusterFirst` = default, dùng CoreDNS, có K8s search domain. **Mọi pod thông thường**.
- `ClusterFirstWithHostNet` = giống ClusterFirst nhưng cho pod `hostNetwork: true`. **DaemonSet network plugin**.
- `Default` = dùng node DNS, không biết K8s Service. **Hiếm dùng**.
- `None` + `dnsConfig` = hoàn toàn custom. **Corporate DNS, performance tuning**.
- `dnsConfig` bổ sung config cho bất kỳ policy. **Giảm ndots, thêm search domain**.
- ndots:5 gây 4 queries cho external domain. Giảm ndots hoặc dùng FQDN với trailing dot để tăng performance.
