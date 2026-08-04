# Phase 4 — API Server · Production Review

> **Cách dùng file này**
> Đọc **scenario** → tự trả lời trong đầu (hoặc ghi ra) → mở **▶ Đáp án** để kiểm tra.
> Không cần đọc notes nữa — chỉ cần làm được các câu này là pass phase.
>
> Mỗi lần review chỉ cần 15 phút. Làm lại sau 3 ngày, sau 1 tuần, sau 2 tuần.

---

## 🔴 Block 1 — Lỗi thường gặp ngoài production

### Scenario 1.1

```
kubectl get pods -n kube-system
Error from server (Forbidden): pods is forbidden:
  User "alice" cannot list resource "pods" in API group "" in the namespace "kube-system"
```

**Câu hỏi**: Authentication thành công hay thất bại? Tại sao bạn biết? Bước tiếp theo để fix là gì?

<details>
<summary>▶ Đáp án</summary>

- **Authentication thành công** — API Server biết user là `alice` (có thể đọc tên trong message).
  - Nếu Authn fail → `401 Unauthorized`, không có username trong message.
- **Authorization fail** — alice không có RoleBinding/ClusterRoleBinding cho verb `list` trên resource `pods` trong namespace `kube-system`.
- **Fix**: Tạo RoleBinding cho alice trong namespace `kube-system`, hoặc ClusterRoleBinding nếu cần toàn cluster.

```bash
kubectl create rolebinding alice-pod-reader \
  --clusterrole=view \
  --user=alice \
  -n kube-system
```

</details>

---

### Scenario 1.2

```
kubectl apply -f deployment.yaml
Error from server (Forbidden): error when creating "deployment.yaml":
  deployments.apps is forbidden: User "system:anonymous" cannot create
  resource "deployments" in API group "apps" in the namespace "default"
```

**Câu hỏi**: Vấn đề ở đây là gì? Tại sao user lại là `system:anonymous`? Đây có phải lỗi Authorization không?

<details>
<summary>▶ Đáp án</summary>

- **Không phải Authorization fail** — đây là **Authentication fail một phần**.
- User là `system:anonymous` vì kubectl không có credential hợp lệ (kubeconfig sai, cert expired, token không hợp lệ).
- API Server fallback về anonymous user (nếu `--anonymous-auth=true`).
- **Fix**: Kiểm tra `kubectl config view`, verify cert, hoặc check token còn hạn không.

```bash
kubectl config view --minify
kubectl auth whoami  # xem mình là ai
```

</details>

---

### Scenario 1.3

```
kubectl logs my-pod
Error from server: error dialing backend: dial tcp 192.168.1.10:10250:
  connect: connection refused
```

**Câu hỏi**: API Server hay kubelet bị lỗi? Flow `kubectl logs` đi qua những component nào?

<details>
<summary>▶ Đáp án</summary>

- **Kubelet bị lỗi** (port 10250 — kubelet API).
- Flow `kubectl logs`: kubectl → API Server (6443) → **kubelet (10250)** → container runtime → log.
- API Server hoạt động bình thường (kubectl đã kết nối được). Kubelet trên node đó bị crash hoặc chưa start.

```bash
# Check kubelet trên node
systemctl status kubelet
journalctl -u kubelet -n 50
```

</details>

---

### Scenario 1.4

Pod tạo xong nhưng bạn thấy nó có thêm container `istio-proxy` mà bạn không khai báo.

**Câu hỏi**: Component nào thêm container đó vào? Thêm vào lúc nào trong request flow? Bạn tìm config của nó ở đâu?

<details>
<summary>▶ Đáp án</summary>

- **MutatingAdmissionWebhook** — cụ thể là Istio sidecar injector.
- Thêm vào ở **Mutating Admission phase** — sau Authorization, trước Validating Admission, trước khi ghi etcd.
- Config:

```bash
kubectl get mutatingwebhookconfigurations
kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o yaml
```

Kiểm tra `namespaceSelector` và `objectSelector` để biết namespace/pod nào bị inject.

</details>

---

### Scenario 1.5

```
kubectl create deployment nginx --image=nginx
error: failed to create deployment:
  Internal Server Error: pods "nginx-xxx" is forbidden:
  error looking up service account default/default:
  serviceaccount "default" not found
```

**Câu hỏi**: Tại sao lại thiếu ServiceAccount `default`? Admission plugin nào gây ra lỗi này?

<details>
<summary>▶ Đáp án</summary>

- Lỗi từ **`ServiceAccount` admission plugin** (Mutating phase).
- Plugin này cố add `serviceAccountName: default` vào pod spec, sau đó verify SA tồn tại.
- Namespace mới tạo chưa có SA `default` — thường do **controller-manager** chưa chạy (controller-manager tự tạo SA `default` khi namespace mới).

```bash
kubectl create serviceaccount default -n <namespace>
# Hoặc restart controller-manager
```

</details>

---

## 🟡 Block 2 — "Tại sao" — câu hỏi concept

### Câu 2.1

Tại sao API Server là **stateless** mà etcd lại không thể là stateless?

<details>
<summary>▶ Đáp án</summary>

- **API Server stateless**: Không lưu gì trong memory. Mọi state đọc từ etcd. → Có thể chạy N instance song song, restart không mất gì.
- **etcd phải có state**: etcd là **source of truth** — toàn bộ cluster state (pod, service, configmap...) nằm ở đây. Nếu etcd stateless → không có nơi lưu cluster state → cluster không tồn tại.
- Analogy: API Server = web server (xử lý request), etcd = database (lưu data). Web server stateless → có thể scale. Database phải giữ state.

</details>

---

### Câu 2.2

Tại sao request `kubectl get pods` **không** đi qua Admission Controller, nhưng `kubectl create pod` thì có?

<details>
<summary>▶ Đáp án</summary>

- Admission Controller chỉ chạy cho **write operations** (CREATE, UPDATE, PATCH, DELETE).
- `kubectl get pods` = READ (GET/LIST) → chỉ cần Authn + Authz → đọc từ cache/etcd → return.
- `kubectl create pod` = WRITE (CREATE) → Authn → Authz → **Mutating Admission** → **Validating Admission** → etcd.
- Lý do: Admission guards những gì đi vào etcd (state mutation). Đọc dữ liệu đã có thì không cần guard.

</details>

---

### Câu 2.3

Tại sao `system:masters` group **bypass RBAC** hoàn toàn? Điều này có nghĩa gì trong production?

<details>
<summary>▶ Đáp án</summary>

- `system:masters` là built-in superuser group — hardcoded trong API Server, không cần RBAC rule nào.
- Cert với `O=system:masters` → full admin, không check RBAC.
- **Production implication**: File `admin.conf` của kubeadm (cert CN=`kubernetes-admin`, O=`system:masters`) là **break-glass key**. Ai có file này = full cluster access.
- Best practice: Không dùng `admin.conf` hàng ngày. Tạo OIDC user cho dev/ops với quyền giới hạn. Giữ `admin.conf` an toàn.

</details>

---

### Câu 2.4

Một webhook có `failurePolicy: Fail` và service webhook bị crash. Điều gì xảy ra với cluster?

<details>
<summary>▶ Đáp án</summary>

- Mọi request CREATE/UPDATE pod (hoặc resource webhook đang watch) sẽ **fail với 503**.
- Không tạo pod được → deployment không scale được → cluster về cơ bản bị block.
- **Đây là production incident thực sự** — nhiều team bị do Istio, Kyverno, OPA webhook crash.

```bash
# Debug
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations

# Tạm thời fix: đổi failurePolicy → Ignore hoặc xóa webhook
kubectl patch validatingwebhookconfiguration <name> \
  --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
```

</details>

---

### Câu 2.5

Bạn thấy `resourceVersion: "12345"` trong output `kubectl get pod nginx -o yaml`. Cái này là gì và nó quan trọng thế nào khi viết controller?

<details>
<summary>▶ Đáp án</summary>

- `resourceVersion` = etcd revision khi object được ghi gần nhất.
- **Optimistic concurrency control**: Khi UPDATE, kubectl/controller gửi `resourceVersion` hiện tại. Nếu ai đó đã update trước (revision đã tăng) → `409 Conflict`.
- Controller phải GET lại, merge, rồi UPDATE lại.
- Quan trọng khi viết controller: Không giữ object lâu rồi UPDATE — có thể bị 409 nếu object đã changed. Dùng `retry.RetryOnConflict()` trong client-go.

</details>

---

## 🟢 Block 3 — Quick Drills

### HTTP status → nguyên nhân

Điền HTTP status code vào chỗ trống (không xem notes):

| Tình huống | HTTP Code |
|---|---|
| kubectl không có cert/token hợp lệ | ??? |
| alice có cert nhưng không có quyền | ??? |
| ValidatingWebhook từ chối pod | ??? |
| Tạo pod thành công | ??? |
| GET pod không tồn tại | ??? |
| UPDATE pod với resourceVersion cũ | ??? |
| etcd down, API Server không lưu được | ??? |

<details>
<summary>▶ Đáp án</summary>

| Tình huống | HTTP Code |
|---|---|
| kubectl không có cert/token hợp lệ | **401** Unauthorized |
| alice có cert nhưng không có quyền | **403** Forbidden |
| ValidatingWebhook từ chối pod | **403** Forbidden (với message từ webhook) |
| Tạo pod thành công | **201** Created |
| GET pod không tồn tại | **404** Not Found |
| UPDATE pod với resourceVersion cũ | **409** Conflict |
| etcd down, API Server không lưu được | **500** Internal Server Error |

</details>

---

### Cert CN/O → component

| CN | O | Component là gì? |
|---|---|---|
| `system:kube-controller-manager` | `system:authenticated` | ??? |
| `system:node:worker-1` | `system:nodes` | ??? |
| `kubernetes-admin` | `system:masters` | ??? |
| `alice` | `dev` | ??? |
| `system:kube-scheduler` | `system:authenticated` | ??? |

<details>
<summary>▶ Đáp án</summary>

| CN | O | Component |
|---|---|---|
| `system:kube-controller-manager` | `system:authenticated` | **kube-controller-manager** |
| `system:node:worker-1` | `system:nodes` | **kubelet** trên node `worker-1` |
| `kubernetes-admin` | `system:masters` | **Admin user** (kubeadm admin.conf) |
| `alice` | `dev` | **Custom user** `alice`, thuộc group `dev` |
| `system:kube-scheduler` | `system:authenticated` | **kube-scheduler** |

</details>

---

## 📋 Checkpoint tự đánh giá

Đánh dấu khi bạn **nói được không cần nhìn notes**:

- [ ] Vẽ flow: Client → Authn → Authz → Mutating → Validating → etcd → Watch (30 giây, không nhìn)
- [ ] Phân biệt 401 vs 403 và nguyên nhân của từng cái
- [ ] Giải thích `system:masters` bypass RBAC và tại sao nguy hiểm
- [ ] Giải thích Mutating trước Validating — tại sao thứ tự này đúng
- [ ] Giải thích `failurePolicy: Fail` gây ra vấn đề gì nếu webhook crash
- [ ] Đọc được `kubectl get csr` và biết đây là bước nào trong TLS bootstrap
- [ ] Giải thích pod tự có `istio-proxy` mà không khai báo

> **Quy tắc pass phase**: Tự giải thích được 5/7 điểm trên cho người khác (không nhìn tài liệu) = **PASS**.
> Không cần hoàn hảo — cần đủ để debug thực tế.

---

## ⏰ Lịch review gợi ý

| Lần | Thời điểm | Làm gì |
|---|---|---|
| **1** | Ngay sau khi học xong | Làm Block 1 + Block 2 |
| **2** | 3 ngày sau | Làm Block 2 + Quick drill |
| **3** | 1 tuần sau | Làm toàn bộ, đo thời gian |
| **4** | 2 tuần sau | Chỉ làm Checkpoint — nếu pass 5/7 → **sang Phase 5** |
