# Exercise 04 — Pod Anti-Affinity & Topology Spread

> **Mục tiêu**: Deploy pod với podAntiAffinity và TopologySpreadConstraints, quan sát replica spread đều ra các node.
>
> **Thời gian dự kiến**: 30 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), ít nhất 3 worker node

## Bối cảnh

Pod Anti-Affinity tách pod ra khác node. Topology Spread Constraints spread pod đều across topology domains. Bài này deploy deployment 6 replica, quan sát distribution.

## Prerequisites

```bash
kubectl get nodes
# NAME      STATUS   ROLES           AGE   VERSION
# master    Ready     control-plane   10d   v1.33.0
# worker-1  Ready     <none>          10d   v1.33.0
# worker-2  Ready     <none>          10d   v1.33.0
# worker-3  Ready     <none>          10d   v1.33.0

# Label zone
kubectl label nodes worker-1 zone=a
kubectl label nodes worker-2 zone=b
kubectl label nodes worker-3 zone=c
```

## Bước 1: Deploy KHÔNG có anti-affinity (baseline)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: no-anti-affinity
spec:
  replicas: 6
  selector:
    matchLabels:
      app: no-anti-affinity
  template:
    metadata:
      labels:
        app: no-anti-affinity
    spec:
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=no-anti-affinity --timeout=60s

# Quan sát distribution — có thể không đều
kubectl get pod -l app=no-anti-affinity -o wide
# NAME                       READY   STATUS    NODE
# no-anti-affinity-xxx-aaa   1/1     Running   worker-1
# no-anti-affinity-xxx-bbb   1/1     Running   worker-1
# no-anti-affinity-xxx-ccc   1/1     Running   worker-2
# no-anti-affinity-xxx-ddd   1/1     Running   worker-2
# no-anti-affinity-xxx-eee   1/1     Running   worker-3
# no-anti-affinity-xxx-fff   1/1     Running   worker-3

# Hoặc có thể 4 pod trên worker-1, 2 trên worker-2, 0 trên worker-3
# → không guaranteed spread
```

> Default scheduler dùng `LeastAllocated` scoring — prefer node ít utilized. Nhưng không guarantee spread đều. Có thể 4 pod lên 1 node nếu schedule gần như cùng lúc.

```bash
# Cleanup
kubectl delete deployment no-anti-affinity
```

**Kiểm tra**: Pod distribution không guaranteed đều — có thể 4-2-0 hoặc 2-2-2.

## Bước 2: Deploy với podAntiAffinity required — 1 pod/node

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anti-affinity-required
spec:
  replicas: 3
  selector:
    matchLabels:
      app: anti-affinity-required
  template:
    metadata:
      labels:
        app: anti-affinity-required
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: anti-affinity-required
            topologyKey: kubernetes.io/hostname
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=anti-affinity-required --timeout=60s

# Quan sát — mỗi node 1 pod
kubectl get pod -l app=anti-affinity-required -o wide
# NAME                            READY   STATUS    NODE
# anti-affinity-required-xxx-aaa  1/1     Running   worker-1
# anti-affinity-required-xxx-bbb  1/1     Running   worker-2
# anti-affinity-required-xxx-ccc  1/1     Running   worker-3
```

> `podAntiAffinity required` với `topologyKey: kubernetes.io/hostname` = mỗi node chỉ 1 pod `app=anti-affinity-required`. Pod thứ 4 sẽ Pending (chỉ có 3 node).

**Kiểm tra**: 3 pod trên 3 node khác nhau, mỗi node 1 pod.

## Bước 3: Test required anti-affinity — pod thứ 4 Pending

```bash
# Scale lên 4 replica
kubectl scale deployment anti-affinity-required --replicas=4

# Pod thứ 4 Pending — không đủ node
kubectl get pod -l app=anti-affinity-required
# NAME                            READY   STATUS    RESTARTS
# anti-affinity-required-xxx-aaa  1/1     Running   0
# anti-affinity-required-xxx-bbb  1/1     Running   0
# anti-affinity-required-xxx-ccc  1/1     Running   0
# anti-affinity-required-xxx-ddd  0/1     Pending   0   ← Unschedulable

kubectl describe pod -l app=anti-affinity-required | grep -A 3 "FailedScheduling"
# Warning  FailedScheduling  ...  0/4 nodes are available: 1 node(s) didn't match pod anti-affinity rules, ...
```

```bash
# Scale lại 3
kubectl scale deployment anti-affinity-required --replicas=3
kubectl delete deployment anti-affinity-required
```

**Kiểm tra**: Pod thứ 4 `Pending` — required anti-affinity cấm 2 pod cùng node.

## Bước 4: Deploy với podAntiAffinity preferred — best-effort spread

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: anti-affinity-preferred
spec:
  replicas: 6
  selector:
    matchLabels:
      app: anti-affinity-preferred
  template:
    metadata:
      labels:
        app: anti-affinity-preferred
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: anti-affinity-preferred
              topologyKey: kubernetes.io/hostname
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=anti-affinity-preferred --timeout=60s

# Quan sát — spread đều, 2 pod/node
kubectl get pod -l app=anti-affinity-preferred -o wide
# NAME                              READY   STATUS    NODE
# anti-affinity-preferred-xxx-aaa   1/1     Running   worker-1
# anti-affinity-preferred-xxx-bbb   1/1     Running   worker-1
# anti-affinity-preferred-xxx-ccc   1/1     Running   worker-2
# anti-affinity-preferred-xxx-ddd   1/1     Running   worker-2
# anti-affinity-preferred-xxx-eee   1/1     Running   worker-3
# anti-affinity-preferred-xxx-fff   1/1     Running   worker-3
```

> `preferred` với weight=100 → scheduler ưu tiên spread. 6 pod / 3 node = 2 pod/node. Nếu scale lên 8 → vẫn spread (3-3-2), pod không Pending.

```bash
# Scale lên 8 — vẫn spread, không Pending
kubectl scale deployment anti-affinity-preferred --replicas=8
kubectl wait --for=condition=Ready pod -l app=anti-affinity-preferred --timeout=60s

kubectl get pod -l app=anti-affinity-preferred -o wide | awk '{print $7}' | sort | uniq -c
#       3 worker-1
#       3 worker-2
#       2 worker-3
```

> Preferred: 8 pod / 3 node = 3-3-2 distribution. Không Pending (preferred = soft).

```bash
kubectl delete deployment anti-affinity-preferred
```

**Kiểm tra**: 6 pod spread 2-2-2, 8 pod spread 3-3-2. Không Pending.

## Bước 5: Deploy với TopologySpreadConstraints

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: topology-spread
spec:
  replicas: 6
  selector:
    matchLabels:
      app: topology-spread
  template:
    metadata:
      labels:
        app: topology-spread
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: topology-spread
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=topology-spread --timeout=60s

# Quan sát — spread đều across zones
kubectl get pod -l app=topology-spread -o wide
# NAME                       READY   STATUS    NODE
# topology-spread-xxx-aaa    1/1     Running   worker-1   ← zone=a
# topology-spread-xxx-bbb    1/1     Running   worker-1   ← zone=a
# topology-spread-xxx-ccc    1/1     Running   worker-2   ← zone=b
# topology-spread-xxx-ddd    1/1     Running   worker-2   ← zone=b
# topology-spread-xxx-eee    1/1     Running   worker-3   ← zone=c
# topology-spread-xxx-fff    1/1     Running   worker-3   ← zone=c
```

> `maxSkew: 1` với `topologyKey: zone` = số chênh lệch giữa zone nhiều nhất và ít nhất ≤ 1. 6 pod / 3 zone = 2-2-2 (skew=0).

**Kiểm tra**: 6 pod spread 2-2-2 across zones (a, b, c).

## Bước 6: Test maxSkew violation

```bash
# Scale lên 7 — maxSkew=1 cho phép 3-2-2 (skew=1)
kubectl scale deployment topology-spread --replicas=7
kubectl wait --for=condition=Ready pod -l app=topology-spread --timeout=60s 2>/dev/null || sleep 10

kubectl get pod -l app=topology-spread -o wide | awk '{print $7}' | sort | uniq -c
#       3 worker-1   ← zone=a: 3
#       2 worker-2   ← zone=b: 2
#       2 worker-3   ← zone=c: 2
# Skew = 3-2 = 1 ≤ maxSkew=1 → OK
```

```bash
# Scale lên 8 — 3-3-2 (skew=1)
kubectl scale deployment topology-spread --replicas=8
kubectl wait --for=condition=Ready pod -l app=topology-spread --timeout=60s 2>/dev/null || sleep 10

kubectl get pod -l app=topology-spread -o wide | awk '{print $7}' | sort | uniq -c
#       3 worker-1
#       3 worker-2
#       2 worker-3
# Skew = 3-2 = 1 ≤ maxSkew=1 → OK
```

```bash
# Scale lên 10 — 4-3-3 (skew=1)
kubectl scale deployment topology-spread --replicas=10
kubectl wait --for=condition=Ready pod -l app=topology-spread --timeout=60s 2>/dev/null || sleep 10

kubectl get pod -l app=topology-spread -o wide | awk '{print $7}' | sort | uniq -c
#       4 worker-1
#       3 worker-2
#       3 worker-3
# Skew = 4-3 = 1 ≤ maxSkew=1 → OK
```

> `maxSkew: 1` + `DoNotSchedule` = strict spread. Scheduler luôn giữ skew ≤ 1. Nếu không thể → pod Pending.

**Kiểm tra**: Distribution tuân thủ `maxSkew: 1` ở mọi scale.

## Bước 7: Test ScheduleAnyway (soft spread)

```bash
kubectl delete deployment topology-spread

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: topology-spread-soft
spec:
  replicas: 6
  selector:
    matchLabels:
      app: topology-spread-soft
  template:
    metadata:
      labels:
        app: topology-spread-soft
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: zone
        whenUnsatisfiable: ScheduleAnyway
        labelSelector:
          matchLabels:
            app: topology-spread-soft
      containers:
      - name: nginx
        image: nginx
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod -l app=topology-spread-soft --timeout=60s

# Spread đều nhưng không strict — scheduler ưu tiên spread, không cấm
kubectl get pod -l app=topology-spread-soft -o wide | awk '{print $7}' | sort | uniq -c
#       2 worker-1
#       2 worker-2
#       2 worker-3
```

> `ScheduleAnyway` = scheduler ưu tiên spread (score cao hơn cho domain ít pod), nhưng pod không bao giờ Pending vì skew.

## Cleanup

```bash
kubectl delete deployment topology-spread-soft
kubectl label nodes worker-1 zone- worker-2 zone- worker-3 zone-
```

## Câu hỏi tự kiểm tra

1. `podAntiAffinity required` vs `preferred` khác nhau thế nào? Pod Pending khi nào?
2. `topologyKey: kubernetes.io/hostname` vs `topologyKey: topology.kubernetes.io/zone` khác nhau?
3. `maxSkew: 2` cho phép distribution nào? Ví dụ với 3 zone?
4. `DoNotSchedule` vs `ScheduleAnyway` khác nhau?
5. Pod Anti-Affinity vs Topology Spread — khi nào dùng cái nào?

## Đáp án tham khảo

1. `required` = hard constraint, 2 pod cùng topology = Pending. `preferred` = soft, scheduler ưu tiên spread nhưng pod không Pending (2 pod cùng node nếu không đủ node). Pending chỉ khi `required` và không đủ domain.
2. `hostname` = per-node (mỗi node 1 domain). `zone` = per-zone (nhiều node cùng zone = 1 domain). `hostname` spread pod ra khác node. `zone` spread pod ra khác zone (HA across datacenter).
3. `maxSkew: 2` cho phép chênh lệch tối đa 2 giữa zone nhiều nhất và ít nhất. Ví dụ: zone-a=5, zone-b=3, zone-c=3 → skew=5-3=2 ≤ 2 → OK. zone-a=6, zone-b=3, zone-c=3 → skew=3 > 2 → FAIL.
4. `DoNotSchedule` = hard, nếu skew > maxSkew → pod Pending. `ScheduleAnyway` = soft, scheduler ưu tiên domain ít pod hơn (score), nhưng pod không Pending dù skew lớn.
5. Pod Anti-Affinity: đơn giản "không cùng domain" — dùng khi cần strict 1 pod/domain. Topology Spread: numeric "skew ≤ maxSkew" — dùng khi cần spread đều N pod across M domain. Topology Spread hiệu suất tốt hơn với cluster lớn (O(domains) vs O(pods×nodes)).
