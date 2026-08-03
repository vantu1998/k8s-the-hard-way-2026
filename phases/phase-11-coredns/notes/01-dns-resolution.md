# 01 — DNS Resolution

## DNS trong Kubernetes hoạt động thế nào

Mỗi pod trong Kubernetes có `/etc/resolv.conf` được kubelet inject khi tạo pod. File này chỉ đến CoreDNS như nameserver.

```
Pod → /etc/resolv.conf → CoreDNS ClusterIP → DNS response
```

```
# /etc/resolv.conf bên trong pod (điển hình)
nameserver 10.96.0.10          # CoreDNS ClusterIP
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

> kubelet inject `/etc/resolv.conf` vào pod dựa trên flag `--cluster-dns` (CoreDNS IP) và `--cluster-domain` (thường là `cluster.local`). Pod không chạm DNS hệ thống của node — luôn hỏi CoreDNS.

## resolv.conf anatomy

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

| Field | Ý nghĩa |
|-------|---------|
| `nameserver` | IP của DNS server — CoreDNS ClusterIP |
| `search` | Domain search list — append vào tên ngắn trước khi query |
| `options ndots:5` | Nếu tên có < 5 dấu chấm → thử search domain trước |

> `ndots:5` = hành vi quan trọng. `curl my-svc` → ít hơn 5 dấu chấm → thử `my-svc.default.svc.cluster.local` trước. `curl google.com` → 1 dấu chấm < 5 → thử `google.com.default.svc.cluster.local` (fail) → `google.com.svc.cluster.local` (fail) → `google.com.cluster.local` (fail) → `google.com.` (absolute, succeed).

## Search domain chain

```
Pod trong namespace "default" query "my-svc":

Step 1: my-svc.default.svc.cluster.local → CoreDNS → hit → return 10.96.0.1 ✓

Nếu step 1 fail, thử:
Step 2: my-svc.svc.cluster.local
Step 3: my-svc.cluster.local
Step 4: my-svc. (absolute)
```

### Short name resolution

```
# Từ pod trong namespace "default":
my-svc                            → my-svc.default.svc.cluster.local
my-svc.default                    → my-svc.default.svc.cluster.local
my-svc.default.svc                → my-svc.default.svc.cluster.local
my-svc.default.svc.cluster.local  → my-svc.default.svc.cluster.local (FQDN)

# Cross-namespace: pod "default" query service trong "kube-system"
kubernetes                        → kubernetes.default.svc.cluster.local  (cùng namespace)
kube-dns.kube-system              → kube-dns.kube-system.svc.cluster.local
```

> Short name resolution nhờ `search` domain. Không cần FQDN. Cross-namespace cần ít nhất `svc-name.namespace`.

## Flow đầy đủ: pod → CoreDNS → Service IP

```
1. Ứng dụng trong pod: getaddrinfo("my-svc")
   ↓
2. glibc resolver đọc /etc/resolv.conf
   - nameserver: 10.96.0.10
   - search: default.svc.cluster.local ...
   - ndots:5 → "my-svc" có 0 dấu chấm < 5
   ↓
3. Query: A my-svc.default.svc.cluster.local → 10.96.0.10:53 (UDP)
   ↓
4. CoreDNS nhận query
   - Plugin chain: errors → health → ready → kubernetes → forward → cache → loop → reload → loadbalance
   - kubernetes plugin: watch API Server, có Service "my-svc" trong namespace "default"?
   ↓
5. CoreDNS query API Server (in-cluster)
   - GET /api/v1/namespaces/default/services/my-svc
   - Lấy ClusterIP: 10.96.0.1
   ↓
6. CoreDNS trả về: A 10.96.0.1 (TTL 30s)
   ↓
7. Pod nhận DNS response: my-svc.default.svc.cluster.local → 10.96.0.1
   ↓
8. Pod connect: TCP SYN → 10.96.0.1:80
   ↓
9. iptables DNAT (kube-proxy): 10.96.0.1 → pod IP 10.244.x.x
```

> DNS query → CoreDNS → kubernetes plugin → API Server → ClusterIP → pod kết nối → iptables DNAT → pod IP thực. DNS chỉ trả ClusterIP, kube-proxy DNAT từ ClusterIP sang pod IP.

## kubelet config DNS

```bash
# kubelet flag cấu hình DNS
--cluster-dns=10.96.0.10       # CoreDNS Service IP
--cluster-domain=cluster.local  # Cluster domain

# Kubelet inject vào mỗi pod:
# nameserver 10.96.0.10
# search {pod-namespace}.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
```

```bash
# Xem kubelet config DNS
systemctl cat kubelet | grep -E 'cluster-dns|cluster-domain'
# hoặc
cat /etc/systemd/system/kubelet.service.d/10-kubeadm.conf | grep dns

# Verify CoreDNS Service IP
kubectl get svc -n kube-system kube-dns
# NAME       TYPE        CLUSTER-IP    PORT(S)
# kube-dns   ClusterIP   10.96.0.10    53/UDP,53/TCP,9153/TCP
```

> CoreDNS Service name là `kube-dns` (backward compat với kube-dns). ClusterIP là `10.96.0.10` (có thể khác tùy cluster). kubelet inject IP này vào `/etc/resolv.conf` của mọi pod.

## DNS cache và TTL

```
CoreDNS cache plugin:
  - TTL default: 30s (positive), 5s (negative)
  - Max cache size: 9984 entries

Pod-side cache (ndots):
  - glibc không cache DNS — mỗi query gọi nameserver
  - Ứng dụng thường tự cache hoặc dùng connection pool

ndots:5 implications:
  - 5 queries cho external name trước khi resolve (ndots:5 + 3 search domains)
  - Gây latency cho external DNS (google.com → 3 failed queries trước khi hit)
  - Custom pod có thể giảm ndots: dnsConfig.options[ndots:2]
```

## Liên hệ với Kubernetes

- `/etc/resolv.conf` inject bởi kubelet, point đến CoreDNS ClusterIP.
- `ndots:5` + search domain: short name → FQDN tự động. Cross-namespace cần `svc.namespace`.
- Flow: pod DNS query → CoreDNS (10.96.0.10:53) → kubernetes plugin → API Server → ClusterIP.
- CoreDNS = DaemonSet hoặc Deployment trong `kube-system`, Service `kube-dns`.
- TTL 30s: DNS response cached 30s trong CoreDNS. Sau đó query lại API Server.
- Thay đổi Service ClusterIP reflect trong DNS sau tối đa 30s (cache TTL).
