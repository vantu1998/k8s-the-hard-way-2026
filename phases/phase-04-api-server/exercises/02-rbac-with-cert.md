# Exercise 02 — RBAC với User Cert

> **Mục tiêu**: Tạo user cert với CN=`alice`, O=`dev`, tạo RoleBinding, test RBAC — alice có quyền gì, không có quyền gì.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: API Server đang chạy (exercise 01), Kubernetes CA + CA key

## Bối cảnh

Kubernetes không có User resource — user tồn tại trong cert (CN=username, O=group). Bài này tạo user `alice` thuộc group `dev`, cấp quyền đọc pod, test RBAC.

## Bước 1: Tạo user cert cho alice

```bash
# Tạo private key
openssl genrsa -out /tmp/alice-key.pem 2048

# Tạo CSR — CN=alice, O=dev
openssl req -new -key /tmp/alice-key.pem -out /tmp/alice.csr \
  -subj "/CN=alice/O=dev"

# Ký CSR bằng Kubernetes CA
openssl x509 -req -in /tmp/alice.csr \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca-key.pem \
  -CAcreateserial -out /tmp/alice.pem -days 365

# Verify
openssl verify -CAfile /etc/kubernetes/pki/ca.crt /tmp/alice.pem
# /tmp/alice.pem: OK

# Xem cert info
openssl x509 -in /tmp/alice.pem -noout -subject
# subject=CN=alice, O=dev
```

**Kiểm tra**: `openssl verify` trả về `OK`, subject là `CN=alice, O=dev`.

## Bước 2: Tạo kubeconfig cho alice

```bash
# Set cluster (dùng CA chung)
kubectl config set-cluster k8s-lab \
  --server=https://127.0.0.1:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=/tmp/alice.kubeconfig

# Set credentials (dùng alice cert)
kubectl config set-credentials alice \
  --client-certificate=/tmp/alice.pem \
  --client-key=/tmp/alice-key.pem \
  --embed-certs=true \
  --kubeconfig=/tmp/alice.kubeconfig

# Set context
kubectl config set-context alice@k8s-lab \
  --cluster=k8s-lab \
  --user=alice \
  --kubeconfig=/tmp/alice.kubeconfig

# Use context
kubectl config use-context alice@k8s-lab \
  --kubeconfig=/tmp/alice.kubeconfig
```

**Kiểm tra**: `/tmp/alice.kubeconfig` tồn tại, context `alice@k8s-lab` active.

## Bước 3: Test — alice chưa có quyền

```bash
export KUBECONFIG=/tmp/alice.kubeconfig

# Alice thử list pods
kubectl get pods -n default
# Error from server (Forbidden): pods is forbidden: User "alice" cannot list resource "pods" in API group "" in the namespace "default"

# Alice thử create pod
kubectl run test --image=nginx -n default
# Error from server (Forbidden): pods is forbidden: User "alice" cannot create resource "pods" in API group "" in the namespace "default"
```

> Authentication **thành công** (API Server biết là `alice`), nhưng Authorization **fail** (alice chưa có RoleBinding). Lỗi 403 Forbidden.

**Kiểm tra**: Lỗi `Forbidden: User "alice" cannot list resource "pods"` — xác nhận Authn thành công, Authz fail.

## Bước 4: Tạo Role — pod-reader

```bash
# Dùng admin kubeconfig
export KUBECONFIG=/tmp/admin.kubeconfig

cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: default
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
EOF

# Verify
kubectl get roles -n default
# NAME         CREATED AT
# pod-reader   2026-01-01T00:00:00Z
```

**Kiểm tra**: Role `pod-reader` tồn tại trong namespace `default`.

## Bước 5: Tạo RoleBinding — bind alice → pod-reader

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: alice-pod-reader
  namespace: default
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF

# Verify
kubectl get rolebindings -n default
# NAME               ROLE              AGE
# alice-pod-reader   Role/pod-reader   5s
```

**Kiểm tra**: RoleBinding `alice-pod-reader` tồn tại, bind user `alice` → Role `pod-reader`.

## Bước 6: Test — alice có quyền đọc pod

```bash
# Chuyển sang alice kubeconfig
export KUBECONFIG=/tmp/alice.kubeconfig

# Alice list pods — nên thành công
kubectl get pods -n default
# NAME    READY   STATUS    RESTARTS   AGE
# nginx   1/1     Running   0          10m

# Alice get pod detail
kubectl get pod nginx -n default -o yaml
# apiVersion: v1
# kind: Pod
# metadata:
#   name: nginx
#   namespace: default
# ...

# Alice xem log
kubectl logs nginx -n default
# <nginx access log>
```

> Alice giờ có quyền `get`, `list`, `watch` pod + `pods/log` trong namespace `default`.

**Kiểm tra**: `kubectl get pods` thành công, trả về pod list.

## Bước 7: Test — alice không có quyền create/delete

```bash
# Alice thử create pod — nên fail
kubectl run test --image=nginx -n default
# Error from server (Forbidden): pods is forbidden: User "alice" cannot create resource "pods" in API group "" in the namespace "default"

# Alice thử delete pod — nên fail
kubectl delete pod nginx -n default
# Error from server (Forbidden): pods is forbidden: User "alice" cannot delete resource "pods" in API group "" in the namespace "default"
```

> Role `pod-reader` chỉ có `get`, `list`, `watch` — không có `create`, `delete`.

**Kiểm tra**: `kubectl run` và `kubectl delete` fail với 403 Forbidden.

## Bước 8: Test — alice không có quyền ở namespace khác

```bash
# Alice list pods trong kube-system — nên fail
kubectl get pods -n kube-system
# Error from server (Forbidden): pods is forbidden: User "alice" cannot list resource "pods" in API group "" in the namespace "kube-system"
```

> Role `pod-reader` chỉ bind trong namespace `default`. Namespace khác → không có quyền.

**Kiểm tra**: `kubectl get pods -n kube-system` fail với 403 Forbidden.

## Bước 9: Dùng kubectl auth can-i

```bash
# Admin kiểm tra quyền của alice
export KUBECONFIG=/tmp/admin.kubeconfig

kubectl auth can-i list pods --as=alice -n default
# yes

kubectl auth can-i create pods --as=alice -n default
# no

kubectl auth can-i delete pods --as=alice -n default
# no

kubectl auth can-i list pods --as=alice -n kube-system
# no

# List tất cả quyền của alice trong default
kubectl auth can-i --list --as=alice -n default
# Resources       Non-Resource URLs   Resource Names   Verbs
# pods            []                  []               [get list watch]
# pods/log        []                  []               [get list watch]
```

> `kubectl auth can-i --as=alice` impersonate alice để test quyền — không cần alice kubeconfig.

**Kiểm tra**: `can-i list pods --as=alice` = yes, `can-i create pods --as=alice` = no.

## Bước 10: Mở rộng — cấp quyền cho group dev

```bash
export KUBECONFIG=/tmp/admin.kubeconfig

# Tạo ClusterRole — đọc pod tất cả namespace
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pod-reader-global
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list", "watch"]
EOF

# Bind ClusterRole cho group dev
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dev-pod-reader-global
subjects:
- kind: Group
  name: dev
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: pod-reader-global
  apiGroup: rbac.authorization.k8s.io
EOF
```

```bash
# Test — alice (group dev) giờ list pod tất cả namespace
export KUBECONFIG=/tmp/alice.kubeconfig

kubectl get pods -n kube-system
# NAME           READY   STATUS    RESTARTS   AGE
# <pods>

kubectl auth can-i list pods --as=alice -n kube-system
# yes  ← giờ có quyền vì group dev được bind ClusterRole
```

> Alice thuộc group `dev` (từ cert O=dev). ClusterRoleBinding bind group `dev` → ClusterRole `pod-reader-global`. Alice thừa hưởng quyền cluster-wide.

**Kiểm tra**: `kubectl get pods -n kube-system` thành công sau khi bind group `dev`.

## Bước 11: Tạo user bob cùng group dev — test group inheritance

```bash
export KUBECONFIG=/tmp/admin.kubeconfig

# Tạo cert cho bob (CN=bob, O=dev)
openssl genrsa -out /tmp/bob-key.pem 2048
openssl req -new -key /tmp/bob-key.pem -out /tmp/bob.csr \
  -subj "/CN=bob/O=dev"
openssl x509 -req -in /tmp/bob.csr \
  -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca-key.pem \
  -CAcreateserial -out /tmp/bob.pem -days 365

# Tạo kubeconfig cho bob
kubectl config set-cluster k8s-lab \
  --server=https://127.0.0.1:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt \
  --embed-certs=true \
  --kubeconfig=/tmp/bob.kubeconfig

kubectl config set-credentials bob \
  --client-certificate=/tmp/bob.pem \
  --client-key=/tmp/bob-key.pem \
  --embed-certs=true \
  --kubeconfig=/tmp/bob.kubeconfig

kubectl config set-context bob@k8s-lab \
  --cluster=k8s-lab \
  --user=bob \
  --kubeconfig=/tmp/bob.kubeconfig

kubectl config use-context bob@k8s-lab \
  --kubeconfig=/tmp/bob.kubeconfig

# Bob list pods — nên thành công (group dev có ClusterRoleBinding)
export KUBECONFIG=/tmp/bob.kubeconfig
kubectl get pods -n default
# NAME    READY   STATUS    RESTARTS   AGE
# nginx   1/1     Running   0          30m

kubectl get pods -n kube-system
# NAME           READY   STATUS    RESTARTS   AGE
# <pods>
```

> Bob chưa có RoleBinding riêng, nhưng thuộc group `dev` → thừa hưởng ClusterRoleBinding `dev-pod-reader-global`.

**Kiểm tra**: Bob list pods thành công ở mọi namespace — group inheritance hoạt động.

## Câu hỏi tự kiểm tra

1. Tại sao alice ban đầu không list pod được dù Authentication thành công?
2. Role vs ClusterRole khác nhau thế nào? Khi nào dùng cái nào?
3. Alice có Role `pod-reader` trong `default` + ClusterRole `pod-reader-global`. Tổng quyền của alice là gì?
4. Nếu xóa RoleBinding `alice-pod-reader`, alice còn list pod trong `default` không?
5. `system:masters` group bypass RBAC — tại sao không nên cấp group này cho user thường?

## Đáp án tham khảo

1. Authentication thành công (API Server biết là alice), nhưng Authorization fail — alice chưa có Role/RoleBinding. 403 Forbidden = Authz deny, không phải Authn fail.
2. Role = namespace-scoped (chỉ 1 namespace). ClusterRole = cluster-scoped (tất cả namespace hoặc cluster resource như Node, Namespace). Dùng Role khi user chỉ cần quyền trong 1 namespace. Dùng ClusterRole khi cần quyền cluster-wide hoặc trên cluster-scoped resource.
3. Alice có quyền `get/list/watch` pod trong `default` (từ Role) + `get/list/watch` pod ở **tất cả** namespace (từ ClusterRole). Tổng quyền = union của tất cả Role/ClusterRole binding.
4. Có — alice vẫn có quyền qua ClusterRoleBinding `dev-pod-reader-global` (group dev). RoleBinding chỉ thêm quyền, không subtract. Xóa RoleBinding = mất quyền extra, nhưng ClusterRoleBinding vẫn còn.
5. `system:masters` bypass RBAC entirely — có mọi quyền mà không cần RoleBinding. Nếu cấp cho user thường, user đó có superuser — nguy hiểm. Chỉ dùng cho admin cert (kubeadm admin.conf).
