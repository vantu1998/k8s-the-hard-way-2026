# 05 — API Flow

## Full request flow

Mọi request đến API Server đi qua **6 giai đoạn**:

```
Client (kubectl, controller, kubelet)
  │
  │  1. TLS handshake
  │  2. Authentication (who?)
  │  3. Authorization (allowed?)
  │  4. Mutating Admission (modify request)
  │  5. Validating Admission (check request)
  │  6. etcd (persist)
  │
  ▼
etcd (single source of truth)
  │
  │  7. Watch event
  │
  ▼
Controller / Kubelet (react to change)
```

## Giai đoạn 1 — TLS handshake

Client kết nối HTTPS đến API Server port 6443. TLS handshake:

```
Client                          API Server
  │                                │
  │── ClientHello ──────────────►│
  │                                │
  │◄── ServerHello + Cert ────────│  (apiserver.crt)
  │                                │
  │── Client Cert (mTLS) ────────►│  (nếu client có cert)
  │                                │
  │── Key Exchange ──────────────►│
  │                                │
  │◄── Finished ──────────────────│
  │── Finished ──────────────────►│
  │                                │
  │═══ Encrypted channel ═════════│
```

> API Server verify client cert bằng `--client-ca-file`. Nếu client không có cert → thử bearer token / OIDC / anonymous.

## Giai đoạn 2 — Authentication

API Server xác định **ai gửi request**:

```
Request arrives (HTTP request + credential)
       │
       ▼
  ┌─ Client cert? ──→ verify with --client-ca-file → CN=alice, O=dev
  │
  ┌─ Bearer token? ──→ check token file / JWT verify / webhook
  │
  ┌─ OIDC token? ──→ verify JWT with OIDC provider
  │
  └─ No credential ──→ anonymous (if --anonymous-auth=true)
       │
       ▼
  User{username, groups, uid, extra}
```

| Outcome | HTTP status |
|---------|-------------|
| Authentication success | Continue to Authorization |
| Authentication fail (no method match, anonymous disabled) | 401 Unauthorized |

> Xem chi tiết trong `02-authentication.md`.

## Giai đoạn 3 — Authorization

API Server kiểm tra **user có quyền làm action này trên resource này không**:

```
User{alice, [dev]}
       │
       ▼
  ┌─ Node authorizer ──→ alice không phải system:node → deny
  │
  └─ RBAC authorizer ──→ check Role/ClusterRole + Binding
       ├── alice → RoleBinding → Role → allow list pods in default?
       ├── If yes → Allow
       └── If no  → Deny
       │
       ▼
  Allow → continue to Admission
  Deny  → 403 Forbidden
```

| Outcome | HTTP status |
|---------|-------------|
| Authorization success (any mode allow) | Continue to Admission |
| Authorization fail (all modes deny) | 403 Forbidden |

> Xem chi tiết trong `03-authorization-rbac.md`.

## Giai đoạn 4 — Mutating Admission

Request đã được authorize. Mutating admission có thể **sửa request** trước khi validate:

```
Request (create pod, no serviceAccountName)
       │
       ▼
  Mutating Admission Plugins (thứ tự trong --enable-admission-plugins)
  ├── ServiceAccount: add serviceAccountName=default, mount token volume
  ├── DefaultTolerationSeconds: add toleration for not-ready/unreachable
  ├── MutatingAdmissionWebhook: call external webhook (inject sidecar)
  │   └── POST AdmissionReview → webhook → return JSONPatch → apply patch
  └── ...
       │
       ▼
  Request (mutated — now has serviceAccountName, tolerations, sidecar)
```

> Mỗi mutating plugin chạy theo thứ tự trong flag. Plugin sau thấy result của plugin trước. Nếu plugin fail → request bị reject (hoặc skip, tùy plugin).

## Giai đoạn 5 — Validating Admission

Request đã mutate. Validating admission **kiểm tra final result**:

```
Request (mutated pod)
       │
       ▼
  Validating Admission Plugins
  ├── NamespaceLifecycle: namespace default exists, not deleting → pass
  ├── ResourceQuota: namespace default not over quota → pass
  ├── LimitRanger: container resource request within LimitRange → pass
  ├── NodeRestriction: (only for kubelet request) → pass
  ├── ValidatingAdmissionWebhook: call external webhook (check policy)
  │   └── POST AdmissionReview → webhook → return allowed/denied
  └── ...
       │
       ▼
  All pass → continue to etcd
  Any fail → 403 Forbidden (with message from plugin)
```

> Validating plugin **không sửa** request — chỉ allow/deny. Nếu 1 plugin deny → request bị reject ngay, không cần check plugin còn lại.

## Giai đoạn 6 — etcd (persist)

Request pass all admission. API Server ghi object vào etcd:

```
API Server
       │
       │  encode object → protobuf
       │
       ▼
  etcd: PUT /registry/pods/default/nginx → <protobuf>
       │
       │  Raft replicate to all etcd members
       │
       ▼
  etcd returns: {revision: 12345}
       │
       ▼
  API Server returns to client: 201 Created + Pod object (JSON)
```

| Operation | etcd action | Key |
|-----------|-------------|-----|
| CREATE | PUT (new key) | `/registry/pods/default/nginx` |
| UPDATE | PUT (overwrite) | `/registry/pods/default/nginx` |
| PATCH | PUT (merge patch) | `/registry/pods/default/nginx` |
| DELETE | DELETE | `/registry/pods/default/nginx` |

> etcd lưu object dạng **protobuf** (không phải JSON). API Server encode JSON → protobuf khi ghi, decode protobuf → JSON khi đọc. Xem `phase-03-etcd/notes/06-k8s-data-in-etcd.md`.

## Giai đoạn 7 — Watch event

Sau khi etcd ghi, API Server forward watch event đến client đang watch:

```
etcd: PUT /registry/pods/default/nginx
       │
       ▼
  API Server (watch proxy)
       │
       ├── Controller Manager: watch /registry/pods/ → "Pod nginx created"
       ├── Kubelet (node-1): watch /registry/pods/ (filter: node=node-1) → "Pod nginx assigned to me"
       └── Other watchers (custom controller, dashboard...)
```

> API Server **proxy** watch từ client đến etcd. Controller/kubelet không watch etcd trực tiếp. API Server filter event theo field selector (e.g. `spec.nodeName=node-1` cho kubelet).

## Read vs Write flow

### Write flow (CREATE, UPDATE, PATCH, DELETE)

```
Client → TLS → Authn → Authz → Mutating → Validating → etcd → Watch event
```

### Read flow (GET, LIST, WATCH)

```
Client → TLS → Authn → Authz → etcd (read) → return to client
```

> Read request **không qua Admission** — admission chỉ cho write operation. Read chỉ cần Authn + Authz.

## Cache layer — watch cache

API Server có **watch cache** để tránh đọc etcd cho mỗi request:

```
Client: kubectl get pods
       │
       ▼
  API Server
  ├── Check watch cache (in-memory)
  │   ├── Cache hit → return from cache (fast)
  │   └── Cache miss → read from etcd (slow)
  └── Return to client
```

| Request type | Cache behavior |
|-------------|----------------|
| `GET /pods` (LIST) | Serve from cache if consistent, else read etcd |
| `GET /pods/nginx` (GET) | Serve from cache if consistent, else read etcd |
| `WATCH /pods` | Serve from cache (cache maintains watch state) |
| `POST /pods` (CREATE) | Always write to etcd (no cache) |

> Watch cache giảm load etcd — hàng nghìn `kubectl get pods` không gây hàng nghìn etcd read. Cache invalidate khi etcd event arrive.

## kubectl --v=8 — xem full flow

`kubectl --v=8` log HTTP request/response đầy đủ:

```bash
kubectl get pods --v=8
# I0101 12:00:00.000000  1234 round_trippers.go:55] GET https://192.168.56.11:6443/api/v1/namespaces/default/pods?limit=500
# I0101 12:00:00.000001  1234 round_trippers.go:62] Request Headers:
# I0101 12:00:00.000002  1234 round_trippers.go:65]     Accept: application/json
# I0101 12:00:00.000003  1234 round_trippers.go:65]     User-Agent: kubectl/v1.33.0 (linux/amd64) kubernetes/abc123
# I0101 12:00:00.000004  1234 round_trippers.go:65]     Authorization: Bearer <masked>
# I0101 12:00:00.000100  1234 round_trippers.go:77] Response Status: 200 OK in 5 milliseconds
# I0101 12:00:00.000101  1234 round_trippers.go:78] Response Headers:
# I0101 12:00:00.000102  1234 round_trippers.go:81]     Content-Type: application/json
# I0101 12:00:00.000103  1234 round_trippers.go:81]     X-Kubernetes-Pf-Flashed-Parameters: ...
```

| Verbosity | Log level |
|-----------|-----------|
| `--v=1` | Basic info |
| `--v=4` | Debug — high-level flow |
| `--v=6` | Show HTTP request URL |
| `--v=7` | Show HTTP request + response headers |
| `--v=8` | Show HTTP request + response headers + body |
| `--v=10` | Show everything — tracing, connection detail |

> Xem exercise 05 để thực hành `kubectl --v=8`.

## API Server response codes

| HTTP status | Ý nghĩa | Khi nào |
|-------------|---------|---------|
| 200 OK | Success | GET, LIST success |
| 201 Created | Success | CREATE success |
| 204 No Content | Success | DELETE success |
| 400 Bad Request | Client error | Malformed request, invalid JSON |
| 401 Unauthorized | Authn fail | Missing/invalid credential |
| 403 Forbidden | Authz fail or Admission deny | No permission, admission reject |
| 404 Not Found | Resource not found | GET non-existent resource |
| 409 Conflict | Version conflict | Update with stale resourceVersion |
| 422 Unprocessable Entity | Validation fail | Invalid field value |
| 500 Internal Server Error | Server error | API Server bug, etcd error |
| 503 Service Unavailable | Server overloaded | API Server starting, etcd unavailable |

## resourceVersion — optimistic concurrency

Mỗi object có `resourceVersion` = etcd revision. Khi UPDATE, client phải gửi `resourceVersion` hiện tại. Nếu etcd revision đã thay đổi (ai đó update trước) → 409 Conflict.

```
Client A: GET pod → resourceVersion: "100"
Client B: GET pod → resourceVersion: "100"
Client A: UPDATE pod (resourceVersion: "100") → etcd revision 101 → success
Client B: UPDATE pod (resourceVersion: "100") → 409 Conflict (stale version)
```

> Client B phải GET lại (resourceVersion: "101"), merge change, UPDATE lại. Đây là **optimistic concurrency control** — tránh overwrite thay đổi của người khác.

## Dry-run

```bash
# Dry-run — simulate request nhưng không ghi etcd
kubectl apply -f pod.yaml --dry-run=server
```

> Dry-run chạy qua Authn → Authz → Mutating → Validating — nhưng **không ghi etcd**. Hữu ích để test admission webhook mà không tạo resource thật.

## API Server proxy

API Server có thể proxy request đến pod/service:

```bash
# Proxy đến pod
kubectl proxy
# Starting to serve on 127.0.0.1:8001

# Access pod qua proxy
curl http://localhost:8001/api/v1/namespaces/default/pods/nginx:80/proxy/
```

```
Client → kubectl proxy (localhost:8001) → API Server → Pod (port 80)
```

> API Server proxy hữu ích khi pod không expose Service — truy cập trực tiếp qua API Server proxy.

## Liên hệ với Kubernetes

- Request flow: **TLS → Authn → Authz → Mutating → Validating → etcd → Watch**.
- Read request (GET/LIST/WATCH) **không qua Admission** — chỉ Authn + Authz.
- Watch cache giảm load etcd — hàng nghìn read không gây hàng nghìn etcd query.
- `resourceVersion` = etcd revision — optimistic concurrency control.
- `kubectl --v=8` xem full HTTP request/response — debug tool quan trọng.
- Dry-run chạy qua tất cả admission nhưng không ghi etcd — test webhook.
- API Server proxy cho phép truy cập pod trực tiếp qua API Server.
- 401 = Authn fail, 403 = Authz fail hoặc Admission deny, 409 = version conflict.
