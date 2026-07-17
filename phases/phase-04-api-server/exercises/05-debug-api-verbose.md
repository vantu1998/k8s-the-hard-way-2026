# Exercise 05 — Debug API với kubectl --v=8

> **Mục tiêu**: Dùng `kubectl --v=8` xem HTTP request/response đầy đủ đến API Server. Hiểu flow request từ client đến server.
>
> **Thời gian dự kiến**: 20 phút
>
> **Yêu cầu**: Kubernetes cluster đang chạy, `kubectl` admin access

## Bối cảnh

`kubectl --v=8` log toàn bộ HTTP request/response — URL, headers, body. Bài này dùng verbose logging để hiểu chính xác kubectl gọi API Server gì, nhận gì trả về.

## Bước 1: kubectl --v=8 — GET (list pods)

```bash
# Tạo pod trước
kubectl run nginx --image=nginx -n default

# List pods với verbose
kubectl get pods -n default --v=8 2>&1 | head -30
```

### Output:

```
I0101 12:00:00.000001  1234 round_trippers.go:55] GET https://192.168.56.11:6443/api/v1/namespaces/default/pods?limit=500
I0101 12:00:00.000002  1234 round_trippers.go:62] Request Headers:
I0101 12:00:00.000003  1234 round_trippers.go:65]     Accept: application/json, */*
I0101 12:00:00.000004  1234 round_trippers.go:65]     User-Agent: kubectl/v1.33.0 (linux/amd64) kubernetes/abc123
I0101 12:00:00.000005  1234 round_trippers.go:77] Response Status: 200 OK in 5 milliseconds
I0101 12:00:00.000006  1234 round_trippers.go:78] Response Headers:
I0101 12:00:00.000007  1234 round_trippers.go:81]     Content-Type: application/json
I0101 12:00:00.000008  1234 round_trippers.go:81]     X-Kubernetes-Pf-Flashed-Parameters: ...
I0101 12:00:00.000009  1234 cached_discovery.go:99] 200 OK
```

### Phân tích:

| Log line | Ý nghĩa |
|----------|---------|
| `GET https://...:6443/api/v1/namespaces/default/pods?limit=500` | HTTP GET request đến API Server |
| `Accept: application/json` | Client muốn nhận JSON response |
| `User-Agent: kubectl/v1.33.0` | Client identity |
| `Response Status: 200 OK` | API Server trả 200 — success |
| `Content-Type: application/json` | Response body là JSON |

> kubectl dùng `?limit=500` — pagination. Nếu > 500 pod, kubectl tự fetch tiếp (`?continue=...`).

## Bước 2: kubectl --v=8 — POST (create pod)

```bash
kubectl run test-pod --image=nginx -n default --v=8 2>&1 | head -40
```

### Output:

```
I0101 12:00:00.000001  1234 round_trippers.go:55] POST https://192.168.56.11:6443/api/v1/namespaces/default/pods
I0101 12:00:00.000002  1234 round_trippers.go:62] Request Headers:
I0101 12:00:00.000003  1234 round_trippers.go:65]     Accept: application/json, */*
I0101 12:00:00.000004  1234 round_trippers.go:65]     Content-Type: application/json
I0101 12:00:00.000005  1234 round_trippers.go:65]     User-Agent: kubectl/v1.33.0
I0101 12:00:00.000006  1234 request_body.go:45] Request Body: {"kind":"Pod","apiVersion":"v1","metadata":{"name":"test-pod","namespace":"default",...},"spec":{"containers":[{"name":"test-pod","image":"nginx"}],...}}
I0101 12:00:00.000100  1234 round_trippers.go:77] Response Status: 201 Created in 10 milliseconds
I0101 12:00:00.000101  1234 round_trippers.go:78] Response Headers:
I0101 12:00:00.000102  1234 round_trippers.go:81]     Content-Type: application/json
I0101 12:00:00.000103  1234 round_trippers.go:81]     Location: /api/v1/namespaces/default/pods/test-pod
```

### Phân tích:

| Log line | Ý nghĩa |
|----------|---------|
| `POST https://...:6443/api/v1/namespaces/default/pods` | HTTP POST — create resource |
| `Content-Type: application/json` | Request body là JSON |
| `Request Body: {"kind":"Pod",...}` | Full Pod object gửi lên |
| `Response Status: 201 Created` | 201 = resource created thành công |
| `Location: /api/v1/.../pods/test-pod` | URL của resource mới tạo |

> `POST` = create. `201 Created` = success. API Server trả về full Pod object (đã qua admission, có thêm field).

## Bước 3: kubectl --v=8 — DELETE

```bash
kubectl delete pod test-pod -n default --v=8 2>&1 | head -20
```

### Output:

```
I0101 12:00:00.000001  1234 round_trippers.go:55] DELETE https://192.168.56.11:6443/api/v1/namespaces/default/pods/test-pod
I0101 12:00:00.000002  1234 round_trippers.go:62] Request Headers:
I0101 12:00:00.000003  1234 round_trippers.go:65]     Accept: application/json, */*
I0101 12:00:00.000004  1234 round_trippers.go:77] Response Status: 200 OK in 8 milliseconds
```

| Log line | Ý nghĩa |
|----------|---------|
| `DELETE https://.../pods/test-pod` | HTTP DELETE — xóa resource cụ thể |
| `Response Status: 200 OK` | 200 = deleted thành công |

## Bước 4: kubectl --v=8 — 403 Forbidden (RBAC deny)

```bash
# Dùng alice kubeconfig (chỉ có quyền read, không có quyền create)
export KUBECONFIG=/tmp/alice.kubeconfig

kubectl run test --image=nginx -n default --v=8 2>&1 | head -20
```

### Output:

```
I0101 12:00:00.000001  1234 round_trippers.go:55] POST https://192.168.56.11:6443/api/v1/namespaces/default/pods
I0101 12:00:00.000002  1234 round_trippers.go:62] Request Headers:
I0101 12:00:00.000003  1234 round_trippers.go:65]     Accept: application/json, */*
I0101 12:00:00.000004  1234 round_trippers.go:65]     Authorization: Bearer <masked>
I0101 12:00:00.000100  1234 round_trippers.go:77] Response Status: 403 Forbidden in 3 milliseconds
I0101 12:00:00.000101  1234 round_trippers.go:78] Response Headers:
I0101 12:00:00.000102  1234 round_trippers.go:81]     Content-Type: application/json
I0101 12:00:00.000103  1234 request_body.go:45] Response Body: {"kind":"Status","apiVersion":"v1","metadata":{},"status":"Failure","message":"pods is forbidden: User \"alice\" cannot create resource \"pods\"...","reason":"Forbidden","code":403}
```

### Phân tích:

| Log line | Ý nghĩa |
|----------|---------|
| `POST https://.../pods` | Request gửi thành công (TLS + Authn pass) |
| `Response Status: 403 Forbidden` | Authorization deny — alice không có quyền create |
| `Response Body: {"message":"pods is forbidden..."}` | Error message từ API Server |

> 403 = Authn success (API Server biết là alice) nhưng Authz fail (alice không có quyền create pod).

## Bước 5: kubectl --v=8 — API discovery

```bash
export KUBECONFIG=/tmp/admin.kubeconfig

# kubectl get api resources — triggers API discovery
kubectl api-resources --v=8 2>&1 | head -30
```

### Output:

```
I0101 12:00:00.000001  1234 round_trippers.go:55] GET https://192.168.56.11:6443/api
I0101 12:00:00.000002  1234 round_trippers.go:77] Response Status: 200 OK
I0101 12:00:00.000003  1234 round_trippers.go:55] GET https://192.168.56.11:6443/apis
I0101 12:00:00.000004  1234 round_trippers.go:77] Response Status: 200 OK
I0101 12:00:00.000005  1234 round_trippers.go:55] GET https://192.168.56.11:6443/apis/apps/v1
I0101 12:00:00.000006  1234 round_trippers.go:77] Response Status: 200 OK
I0101 12:00:00.000007  1234 round_trippers.go:55] GET https://192.168.56.11:6443/apis/batch/v1
I0101 12:00:00.000008  1234 round_trippers.go:77] Response Status: 200 OK
...
```

> kubectl discovery: GET `/api` → list core versions. GET `/apis` → list API groups. GET từng group → list resources. Nhiều HTTP request — kubectl cache kết quả.

## Bước 6: kubectl --v=10 — maximum verbosity

```bash
kubectl get pods -n default --v=10 2>&1 | head -50
```

### Output thêm:

```
I0101 12:00:00.000001  1234 cert_rotation.go:137] Starting client cert rotation
I0101 12:00:00.000002  1234 round_trippers.go:55] GET https://192.168.56.11:6443/api/v1/namespaces/default/pods?limit=500
I0101 12:00:00.000003  1234 transport.go:55] TLS handshake complete
I0101 12:00:00.000004  1234 dial.go:55] Dialing tcp 192.168.56.11:6443
I0101 12:00:00.000005  1234 conn.go:55] Connection established
...
```

> `--v=10` log thêm: TLS handshake, TCP dial, connection detail. Hữu ích để debug network issue.

## Bước 7: curl — gọi API trực tiếp

```bash
# Get token từ kubeconfig
TOKEN=$(kubectl config view -o jsonpath='{.users[0].user.client-certificate-data}' --raw 2>/dev/null)
# Hoặc dùng cert trực tiếp:
curl -k \
  --cert /tmp/admin.pem \
  --key /tmp/admin-key.pem \
  https://127.0.0.1:6443/api/v1/namespaces/default/pods | jq .

# Response:
# {
#   "kind": "PodList",
#   "apiVersion": "v1",
#   "metadata": {
#     "resourceVersion": "12345",
#     "continue": "..."
#   },
#   "items": [
#     {
#       "metadata": {"name": "nginx", "namespace": "default", ...},
#       "spec": {...},
#       "status": {...}
#     }
#   ]
# }
```

> curl gọi API trực tiếp — không qua kubectl. Hữu ích để debug khi kubectl có issue.

## Bước 8: kubectl explain — xem API schema

```bash
# Xem Pod spec
kubectl explain pod.spec --v=8 2>&1 | head -20

# kubectl fetch OpenAPI spec
# GET https://...:6443/openapi/v2
```

```bash
# Xem container spec
kubectl explain pod.spec.containers
# KIND:     Pod
# VERSION:  v1
# DESCRIPTION:
#     List of containers belonging to the pod...
# FIELDS:
#   name <string> -required-
#   image <string>
#   command <[]string>
#   ...
```

> `kubectl explain` đọc OpenAPI spec từ API Server — biết field nào required, type gì, description.

## Bước 9: kubectl --dry-run=server

```bash
# Dry-run — simulate qua admission nhưng không ghi etcd
kubectl run dry-run-test --image=nginx -n default --dry-run=server --v=8 2>&1 | head -20
```

### Output:

```
I0101 12:00:00.000001  1234 round_trippers.go:55] POST https://192.168.56.11:6443/api/v1/namespaces/default/pods?dryRun=All
I0101 12:00:00.000002  1234 round_trippers.go:77] Response Status: 201 Created
```

> `?dryRun=All` trong URL — API Server chạy qua Authn → Authz → Mutating → Validating nhưng **không ghi etcd**. Response trả về object như đã create, nhưng etcd không có.

## Câu hỏi tự kiểm tra

1. `kubectl get pods` dùng HTTP method nào? Tại sao không phải POST?
2. `kubectl run` trả về 201 — tại sao 201 mà không 200?
3. 403 Forbidden trong `--v=8` cho biết điều gì? Authn hay Authz fail?
4. `?dryRun=All` trong URL làm gì? Tại sao hữu ích?
5. `kubectl api-resources` gửi bao nhiêu HTTP request? Tại sao nhiều?

## Đáp án tham khảo

1. GET — `kubectl get` là read operation, dùng HTTP GET. POST chỉ cho create. API Server phân biệt: GET = read, POST = create, PUT = update, PATCH = patch, DELETE = delete.
2. 201 Created = HTTP status cho resource mới tạo. 200 OK = success cho read/update/delete. API Server tuân thủ HTTP semantic — 201 cho POST thành công.
3. 403 Forbidden = Authz fail (Authorization deny). Authn đã thành công (API Server biết user là alice). Nếu Authn fail → 401 Unauthorized. 403 = "bạn là ai tôi biết, nhưng bạn không có quyền".
4. `dryRun=All` — API Server chạy qua Authn → Authz → Mutating → Validating nhưng không ghi etcd. Hữu ích để test admission webhook, validate YAML, check RBAC — mà không tạo resource thật.
5. Nhiều request — kubectl discovery: GET `/api` (core versions), GET `/apis` (API groups), GET từng API group (resources per group). Tổng số = 1 + 1 + N (N = số API group). kubectl cache kết quả để không discovery lại mỗi lần.
