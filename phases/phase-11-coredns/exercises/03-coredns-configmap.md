# Exercise 03 — CoreDNS ConfigMap

> **Mục tiêu**: Sửa CoreDNS ConfigMap thêm `rewrite` rule và `hosts` entry. Quan sát hot reload. Test custom DNS resolution.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s, CoreDNS running, `kubectl` access

## Bối cảnh

CoreDNS cấu hình bằng Corefile trong ConfigMap `kube-system/coredns`. `reload` plugin watch ConfigMap → hot reload khi thay đổi (không cần restart pod). Bài này thêm plugin `rewrite` (alias DNS name) và `hosts` (static entry).

## Bước 1: Backup Corefile hiện tại

```bash
# Backup trước khi sửa
kubectl -n kube-system get cm coredns -o yaml > /tmp/coredns-backup.yaml
echo "Backup saved to /tmp/coredns-backup.yaml"

# Xem Corefile hiện tại
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
```

## Bước 2: Thêm log plugin (để xem query)

```bash
# Patch ConfigMap thêm log plugin
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | \
  sed 's/errors/errors\n    log/' | \
  kubectl -n kube-system create configmap coredns \
    --from-literal=Corefile="$(cat -)" \
    --dry-run=client -o yaml | \
  kubectl apply -f -

# Hoặc edit trực tiếp
kubectl -n kube-system edit cm coredns
# Thêm "log" sau "errors":
# .:53 {
#     errors
#     log          ← thêm dòng này
#     health {
```

```bash
# Chờ CoreDNS reload (reload plugin watch mỗi 5s)
sleep 10

# Xem CoreDNS log — thấy log queries
kubectl -n kube-system logs -f deploy/coredns --tail=5
# [INFO] plugin/reload: Running configuration MD5 = abc123...
# ↑ CoreDNS detect configmap thay đổi → reload
```

**Kiểm tra**: CoreDNS log xuất hiện "plugin/reload: Running configuration" → hot reload thành công.

## Bước 3: Test log plugin

```bash
# Trigger DNS query từ pod
kubectl run dns-debug --image=busybox:1.36 --command -- sleep 3600
kubectl wait --for=condition=Ready pod dns-debug --timeout=30s

kubectl exec dns-debug -- nslookup kubernetes.default.svc.cluster.local

# Xem CoreDNS log — thấy query
kubectl -n kube-system logs deploy/coredns --tail=10
# [INFO] 10.244.1.10:52345 - 1234 "A IN kubernetes.default.svc.cluster.local. udp 52 false 512" NOERROR qr,aa,rd 87 0.000234s
# ↑ query log: client IP, query ID, type, name, response code, size, duration
```

**Kiểm tra**: Mỗi DNS query xuất hiện trong log với response code NOERROR.

## Bước 4: Thêm rewrite plugin (DNS alias)

```bash
# Scenario: Rename Service cũ "old-api" → "new-api"
# Tạo Service mới "new-api"
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: new-api
spec:
  selector:
    app: demo
  ports:
  - port: 80
EOF
```

```bash
# Sửa Corefile thêm rewrite rule
# Rewrite: old-api.default.svc.cluster.local → new-api.default.svc.cluster.local
kubectl -n kube-system edit cm coredns
```

Corefile sau khi sửa:
```
.:53 {
    errors
    log
    health {
        lameduck 5s
    }
    ready
    rewrite name old-api.default.svc.cluster.local new-api.default.svc.cluster.local
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

```bash
# Chờ reload
sleep 10

# Test rewrite: query old-api → được redirect đến new-api
kubectl exec dns-debug -- nslookup old-api.default.svc.cluster.local
# Name: old-api.default.svc.cluster.local
# Address: {new-api ClusterIP}    ← trả IP của new-api!

# Verify new-api IP
kubectl get svc new-api
# → ClusterIP matches DNS response

# Xem CoreDNS log — thấy rewrite
kubectl -n kube-system logs deploy/coredns --tail=5
# [INFO] 10.244.1.10:... "A IN old-api.default.svc.cluster.local. ..." NOERROR
```

**Kiểm tra**: Query `old-api` → trả ClusterIP của `new-api` (rewrite trong flight).

## Bước 5: Thêm hosts plugin (static entry)

```bash
# Scenario: Muốn map custom hostname đến IP tùy ý
# Ví dụ: "legacy-db.internal" → 192.168.1.100

kubectl -n kube-system edit cm coredns
```

Corefile sau khi thêm hosts:
```
.:53 {
    errors
    log
    health {
        lameduck 5s
    }
    ready
    rewrite name old-api.default.svc.cluster.local new-api.default.svc.cluster.local
    hosts {
        192.168.1.100   legacy-db.internal
        192.168.1.101   backup-db.internal
        fallthrough
    }
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

```bash
# Chờ reload
sleep 10

# Test hosts entry
kubectl exec dns-debug -- nslookup legacy-db.internal
# Server:    10.96.0.10
# Name:      legacy-db.internal
# Address 1: 192.168.1.100    ← static IP từ hosts plugin!

kubectl exec dns-debug -- nslookup backup-db.internal
# Address 1: 192.168.1.101
```

**Kiểm tra**: `legacy-db.internal` → 192.168.1.100 (static). Không cần DNS server ngoài.

## Bước 6: Xem plugin chain execution

```bash
# Test: query nonexistent name — xem fallthrough chain
kubectl exec dns-debug -- dig nonexistent.internal

# CoreDNS log:
# "A IN nonexistent.internal. udp..." NXDOMAIN

# hosts plugin check "nonexistent.internal" → không match → fallthrough
# kubernetes plugin check → không match zone → pass
# forward plugin → forward đến upstream → upstream NXDOMAIN
# → trả NXDOMAIN về client
```

```bash
# Test: external domain (qua forward)
kubectl exec dns-debug -- dig google.com +short
# 142.250.x.x

# CoreDNS log:
# "A IN google.com. udp..." NOERROR
# → forward plugin send đến upstream → get response → return
```

## Bước 7: Thêm custom upstream cho specific domain

```bash
# Scenario: queries cho ".company.internal" → forward đến corporate DNS (10.0.0.1)
# Thay vì node DNS

kubectl -n kube-system edit cm coredns
```

Corefile với custom zone forward:
```
# Server block riêng cho internal domain
company.internal:53 {
    errors
    forward . 10.0.0.1        # Corporate DNS server
}

# Default server block
.:53 {
    errors
    log
    health {
        lameduck 5s
    }
    ready
    hosts {
        192.168.1.100   legacy-db.internal
        fallthrough
    }
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

> Nhiều server block = split DNS. `.company.internal` → corporate DNS. Mọi thứ khác → default block. Kubernetes `cluster.local` → kubernetes plugin.

## Bước 8: Restore về cấu hình gốc

```bash
# Restore từ backup
kubectl apply -f /tmp/coredns-backup.yaml

# Chờ reload
sleep 10

# Verify cấu hình gốc
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
# Không còn log, rewrite, hosts

# Test hoạt động bình thường
kubectl exec dns-debug -- nslookup kubernetes.default.svc.cluster.local
```

## Cleanup

```bash
kubectl delete pod dns-debug
kubectl delete svc new-api
```

## Câu hỏi tự kiểm tra

1. `reload` plugin hoạt động thế nào? CoreDNS restart hay không khi sửa ConfigMap?
2. `rewrite` plugin so với tạo Service với alias — khác nhau gì?
3. `hosts` plugin vs ExternalName Service — khi nào dùng cái nào?
4. `fallthrough` trong `hosts` plugin có nghĩa gì? Nếu bỏ thì sao?
5. Nhiều server block trong Corefile — CoreDNS match block nào cho query `google.com`?

## Đáp án tham khảo

1. **reload plugin**: Watch ConfigMap mỗi 5s. Khi detect thay đổi (MD5 hash khác) → reload Corefile trong goroutine mới → atomic swap → không restart process. Pod vẫn running, không downtime.

2. **rewrite vs alias Service**: `rewrite` = DNS-level redirect (không tạo K8s object). Alias Service = ExternalName Service (`spec.type: ExternalName`, CNAME). `rewrite` cho phép redirect trong K8s DNS space. ExternalName cho external hostname.

3. **hosts vs ExternalName**: `hosts` plugin = CoreDNS-level static mapping (giống `/etc/hosts`). ExternalName Service = K8s object (CNAME). Dùng `hosts` khi không muốn tạo K8s Service object (external IP static). Dùng ExternalName khi muốn K8s-native object (audit, RBAC, namespace-scoped).

4. **fallthrough**: nếu không match trong `hosts` plugin → tiếp tục plugin chain tiếp theo (kubernetes, forward). Nếu không có `fallthrough` → return NXDOMAIN ngay (không thử plugin sau). `fallthrough` = necessary để plugin chain hoạt động đúng.

5. **Server block matching**: CoreDNS match query với server block theo zone (longest match). `google.com` → không match `company.internal` → match `.:53` (catch-all). `api.company.internal` → match `company.internal:53` (more specific). Multiple blocks chạy song song, mỗi query chỉ đến 1 block.
