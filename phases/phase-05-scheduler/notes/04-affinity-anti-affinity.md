# 04 — Pod Affinity & Anti-Affinity

## Pod Affinity là gì

Pod Affinity/Anti-Affinity cho phép scheduling decision dựa trên **pod đã chạy trên node**, thay vì chỉ dựa trên node label (như nodeAffinity).

- **Pod Affinity**: Co-locate pod cùng node (hoặc cùng zone) với pod khác.
- **Pod Anti-Affinity**: Tách pod ra khác node (hoặc khác zone) với pod khác.

```
Pod Affinity:    app=web muốn chạy cùng node với app=cache (low latency)
Pod Anti-Affinity: app=web không muốn chạy 2 replica cùng node (high availability)
```

## Cú pháp

```yaml
spec:
  affinity:
    podAffinity:        # Co-locate
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: cache
        topologyKey: kubernetes.io/hostname
    podAntiAffinity:    # Tách ra
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: web
          topologyKey: kubernetes.io/hostname
```

### Các thành phần

| Field | Ý nghĩa |
|-------|---------|
| `labelSelector` | Chọn pod target (pod đã chạy để check affinity) |
| `topologyKey` | Topology domain — node label dùng để group node |
| `namespaces` | Namespace chứa pod target (mặc định = pod's namespace) |
| `namespaceSelector` | Chọn namespace động (v1.25+) |

> `topologyKey` là **bắt buộc** — xác định "topology domain" nào dùng để check affinity. `kubernetes.io/hostname` = per-node. `topology.kubernetes.io/zone` = per-zone.

## Required vs Preferred

| | Required | Preferred |
|---|---|---|
| **Field** | `requiredDuringSchedulingIgnoredDuringExecution` | `preferredDuringSchedulingIgnoredDuringExecution` |
| **Constraint** | Hard — fail = Pending | Soft — fail = vẫn schedule |
| **Weight** | Không có | 1–100 |
| **Use case** | Bắt buộc co-locate/tách | Prefer co-locate/tách |

## Pod Affinity — co-locate

### Required: web phải chạy cùng node với cache

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: cache
            topologyKey: kubernetes.io/hostname
      containers:
      - name: web
        image: nginx
```

> Pod `app=web` **chỉ** schedule lên node đã có pod `app=cache` chạy. Nếu không node nào có cache pod → web pod Pending.

### Preferred: web prefer cùng zone với cache

```yaml
affinity:
  podAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            app: cache
        topologyKey: topology.kubernetes.io/zone
```

> Pod `app=web` prefer chạy cùng **zone** với `app=cache`. Nếu không có cache pod trong zone nào → vẫn schedule lên zone khác.

## Pod Anti-Affinity — tách ra

### Required: web replica không chạy cùng node

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: web
            topologyKey: kubernetes.io/hostname
      containers:
      - name: web
        image: nginx
```

> Mỗi node chỉ chạy **1 pod** `app=web`. Nếu cluster có 2 node và replicas=3 → pod thứ 3 Pending (Unschedulable).

### Preferred: web replica prefer khác node

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            app: web
        topologyKey: kubernetes.io/hostname
```

> Scheduler **thử** spread pod ra khác node. Nếu không đủ node → vẫn schedule 2 pod cùng node (thay vì Pending).

### Preferred: spread across zones

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            app: web
        topologyKey: topology.kubernetes.io/zone
```

> Prefer spread pod ra khác **zone** (khác vùng datacenter). Tăng high availability — nếu 1 zone down, pod ở zone khác vẫn chạy.

## topologyKey — quan trọng

`topologyKey` quyết định "domain" nào dùng để group:

| topologyKey | Domain | Use case |
|-------------|--------|----------|
| `kubernetes.io/hostname` | Per-node | Spread replica ra khác node |
| `topology.kubernetes.io/zone` | Per-zone | Spread replica ra khác zone (HA) |
| `topology.kubernetes.io/region` | Per-region | Spread replica ra khác region |
| `kubernetes.io/os` | Per-OS | (Ít dùng) |

> Nếu node **không có** topologyKey label → node bị loại khỏi scheduling cho pod có affinity dùng key đó. Đảm bảo tất cả node có label tương ứng.

## Namespace scope

Mặc định, pod affinity chỉ check pod trong **cùng namespace** với pod mới. Có thể chỉ định namespace khác:

```yaml
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
        app: cache
    topologyKey: kubernetes.io/hostname
    namespaces: ["cache-ns", "shared-ns"]
```

> Pod `app=web` trong namespace `web-ns` co-locate với pod `app=cache` trong namespace `cache-ns` hoặc `shared-ns`.

### NamespaceSelector (v1.25+)

```yaml
podAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
        app: cache
    topologyKey: kubernetes.io/hostname
    namespaceSelector:
      matchLabels:
        shared: "true"
```

> Check pod `app=cache` trong **tất cả namespace** có label `shared=true`.

## Topology Spread Constraints

`topologySpreadConstraints` là cách **mạnh hơn** để spread pod across topology domains:

```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: web
    minDomains: 1
    nodeAffinityPolicy: Honor
    nodeTaintsPolicy: Honor
```

| Field | Ý nghĩa |
|-------|---------|
| `maxSkew` | Số chênh lệch tối đa giữa domain nhiều nhất và ít nhất |
| `topologyKey` | Topology domain để spread |
| `whenUnsatisfiable` | `DoNotSchedule` (hard) hoặc `ScheduleAnyway` (soft) |
| `labelSelector` | Chọn pod để đếm |
| `minDomains` | Số domain tối thiểu (nếu ít hơn, không enforce) |
| `nodeAffinityPolicy` | `Honor` (respect nodeAffinity) hoặc `Ignore` |
| `nodeTaintsPolicy` | `Honor` (respect taint) hoặc `Ignore` |

### Ví dụ: spread across zones

```
3 zones: zone-a, zone-b, zone-c
maxSkew: 1

Current: zone-a=3, zone-b=2, zone-c=1
→ Skew = 3-1 = 2 > 1 → FAIL
→ Pod mới phải schedule lên zone-c (để giảm skew)
```

> Pod Anti-Affinity chỉ nói "không cùng node", Topology Spread nói "số chênh lệch không quá maxSkew" — kiểm soát distribution chính xác hơn.

### whenUnsatisfiable

| Value | Behavior |
|-------|----------|
| `DoNotSchedule` | Hard constraint — nếu spread không thỏa → Pending |
| `ScheduleAnyway` | Soft — vẫn schedule, nhưng scheduler ưu tiên domain ít pod hơn |

> `DoNotSchedule` + `maxSkew: 1` = strict spread. `ScheduleAnyway` = best-effort spread.

## Pod Anti-Affinity vs Topology Spread

| | Pod Anti-Affinity | Topology Spread |
|---|---|---|
| **Logic** | "Không cùng domain với pod X" | "Số chênh lệch giữa domain ≤ maxSkew" |
| **Granularity** | Binary (cấm/cho phép) | Numeric (đếm số pod) |
| **Scale** | O(pods × nodes) — chậm với nhiều pod | O(domains) — nhanh hơn |
| **Use case** | Đảm bảo 1 pod/domain | Spread đều N pod across M domain |

> Khuyến nghị: dùng **Topology Spread** cho distribution. Dùng **Pod Anti-Affinity required** khi cần strict "1 pod/node".

## Performance consideration

Pod Anti-Affinity **rất tốn CPU** với cluster lớn — scheduler phải check tất cả pod match labelSelector trên tất cả node:

```
Cluster: 1000 nodes, 10000 pods
Pod mới có antiAffinity → scheduler check 10000 pods × 1000 nodes = 10M comparisons
```

> Với cluster lớn (>100 nodes), dùng **Topology Spread** thay vì Pod Anti-Affinity — hiệu suất tốt hơn đáng kể.

## Liên hệ với Kubernetes

- Pod Affinity = co-locate (low latency), Pod Anti-Affinity = tách ra (high availability).
- `topologyKey` xác định domain — `hostname` = per-node, `zone` = per-zone.
- Required = hard (Pending nếu fail), Preferred = soft (weight 1–100).
- Topology Spread Constraints mạnh hơn Pod Anti-Affinity cho distribution — dùng khi có thể.
- Pod Anti-Affinity tốn CPU với cluster lớn — tránh dùng required với cluster >100 nodes.
- `IgnoredDuringExecution` = pod đã chạy không bị evict khi pod mới thay đổi affinity.
- Namespace scope mặc định = same namespace, có thể mở rộng với `namespaces` hoặc `namespaceSelector`.
