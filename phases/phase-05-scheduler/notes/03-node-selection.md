# 03 — Node Selection

## nodeSelector — đơn giản nhất

`nodeSelector` là cách đơn giản nhất để chỉ định pod chạy trên node có label cụ thể. Logic: **AND** tất cả key-value.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  nodeSelector:
    disktype: ssd
    zone: a
  containers:
  - name: nginx
    image: nginx
```

> Pod chỉ schedule lên node có **cả hai** label `disktype=ssd` AND `zone=a`. Nếu không node nào match → pod Pending.

### Label node

```bash
# Label node
kubectl label nodes node-1 disktype=ssd
kubectl label nodes node-1 zone=a

# Xem label
kubectl get nodes --show-labels
# NAME     STATUS   ROLES    AGE   VERSION   LABELS
# node-1   Ready    <none>   10m   v1.33.0   disktype=ssd,zone=a,...
```

### Built-in node labels

| Label | Ví dụ | Ý nghĩa |
|-------|-------|---------|
| `kubernetes.io/hostname` | `node-1` | Tên node |
| `kubernetes.io/os` | `linux` | Hệ điều hành |
| `kubernetes.io/arch` | `amd64` | Kiến trúc CPU |
| `topology.kubernetes.io/zone` | `us-east-1a` | Zone (cloud) |
| `topology.kubernetes.io/region` | `us-east-1` | Region (cloud) |
| `node.kubernetes.io/instance-type` | `m5.large` | Instance type (cloud) |
| `beta.kubernetes.io/instance-type` | `m5.large` | (deprecated) Instance type |

> Cloud provider tự động add zone/region label. On-prem phải label thủ công.

## nodeAffinity — mạnh hơn nodeSelector

`nodeAffinity` hỗ trợ:
- **Operator**: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`
- **Required** (hard) vs **Preferred** (soft)
- **Multiple terms**: OR logic giữa terms, AND logic trong term

### Required — hard constraint

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-required
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: In
            values:
            - ssd
            - nvme
          - key: zone
            operator: In
            values:
            - a
            - b
  containers:
  - name: nginx
    image: nginx
```

> Node phải có `disktype` IN (ssd, nvme) **AND** `zone` IN (a, b). Giống nodeSelector nhưng hỗ trợ nhiều giá trị.

### Preferred — soft constraint

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-preferred
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
          - key: zone
            operator: In
            values:
            - a
      - weight: 20
        preference:
          matchExpressions:
          - key: disktype
            operator: In
            values:
            - ssd
  containers:
  - name: nginx
    image: nginx
```

> Scheduler **thử** schedule lên node match preferred (zone=a +80, disktype=ssd +20). Nếu không node nào match, vẫn schedule lên node khác (khác nodeSelector/required).

### Operators

| Operator | Ý nghĩa | Ví dụ |
|----------|---------|-------|
| `In` | Label value nằm trong danh sách | `zone In [a, b]` → zone=a hoặc zone=b |
| `NotIn` | Label value không nằm trong danh sách | `zone NotIn [a]` → zone≠a (hoặc không có label zone) |
| `Exists` | Label key tồn tại (không quan tâm value) | `key=zone, operator=Exists` → node có label zone |
| `DoesNotExist` | Label key không tồn tại | `key=zone, operator=DoesNotExist` → node không có label zone |
| `Gt` | Label value > value (số) | `cpu Gt 4` → label cpu > 4 |
| `Lt` | Label value < value (số) | `cpu Lt 8` → label cpu < 8 |

> `Gt` / `Lt` so sánh **số nguyên** — label value phải là số.

### Multiple terms — OR logic

```yaml
requiredDuringSchedulingIgnoredDuringExecution:
  nodeSelectorTerms:
  - matchExpressions:          # Term 1: AND logic trong term
    - key: zone
      operator: In
      values: ["a"]
  - matchExpressions:          # Term 2: OR logic giữa terms
    - key: dedicated
      operator: In
      values: ["gpu"]
```

> Node match **Term 1** (zone=a) **OR** **Term 2** (dedicated=gpu) → pass Filter. Bên trong term: AND. Giữa terms: OR.

### nodeSelector vs nodeAffinity

| | nodeSelector | nodeAffinity |
|---|---|---|
| **Operator** | Chỉ `=` (equal) | `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt` |
| **Logic** | AND tất cả | AND trong term, OR giữa terms |
| **Soft/Hard** | Chỉ hard | Cả hard (required) + soft (preferred) |
| **Weight** | Không có | Preferred có weight (1–100) |
| **Complexity** | Đơn giản | Phức tạp hơn |

> Khuyến nghị: dùng `nodeAffinity` cho mọi use case mới. `nodeSelector` giữ cho backward compatibility.

## `IgnoredDuringExecution` — ý nghĩa

Tên đầy đủ: `requiredDuringSchedulingIgnoredDuringExecution`

- **DuringScheduling**: Rule áp dụng khi scheduler chọn node cho pod mới.
- **IgnoredDuringExecution**: Sau khi pod đã chạy, nếu node label thay đổi → **không evict pod**.

```
1. Pod schedule lên node-1 (zone=a) — match required affinity
2. Admin xóa label zone=a khỏi node-1
3. Pod vẫn chạy trên node-1 — không bị evict
```

> Tên "IgnoredDuringExecution" nói rằng rule chỉ áp dụng lúc scheduling, không áp dụng lúc đang chạy. Tương lai sẽ có `RequiredDuringExecution` (evict pod khi label thay đổi), nhưng chưa implement.

## Use cases

### 1. Pod chạy trên node có SSD

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
    - matchExpressions:
      - key: disktype
        operator: In
        values: ["ssd", "nvme"]
```

### 2. Pod prefer zone gần user

```yaml
nodeAffinity:
  preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    preference:
      matchExpressions:
      - key: topology.kubernetes.io/zone
        operator: In
        values: ["us-east-1a"]
  - weight: 50
    preference:
      matchExpressions:
      - key: topology.kubernetes.io/zone
        operator: In
        values: ["us-east-1b"]
```

> Prefer zone `us-east-1a` (weight 100), fallback `us-east-1b` (weight 50), fallback zone khác (weight 0).

### 3. Pod không chạy trên ARM node

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
    - matchExpressions:
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
```

> Hoặc dùng `NotIn`:
> ```yaml
> - key: kubernetes.io/arch
>   operator: NotIn
>   values: ["arm64"]
> ```

### 4. Pod chỉ chạy trên GPU node

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
    - matchExpressions:
      - key: accelerator
        operator: In
        values: ["nvidia"]
```

> Kết hợp với taint `dedicated=gpu:NoSchedule` để đảm bảo chỉ pod có toleration mới schedule lên GPU node. Xem `05-taints-tolerations.md`.

## Liên hệ với Kubernetes

- `nodeSelector` = simple, `nodeAffinity` = advanced — dùng `nodeAffinity` cho use case mới.
- `required` = hard constraint (fail = Pending), `preferred` = soft (fail = vẫn schedule).
- `IgnoredDuringExecution` = node label thay đổi sau khi pod chạy → không evict.
- Multiple `nodeSelectorTerms` = OR. Multiple `matchExpressions` trong term = AND.
- `Exists`/`DoesNotExist` chỉ kiểm tra key, không quan tâm value.
- Kết hợp `nodeAffinity` + taint/toleration để control scheduling chặt chẽ hơn.
- Scheduler log `--v=5` thấy `NodeAffinity` plugin pass/fail cho từng node.
