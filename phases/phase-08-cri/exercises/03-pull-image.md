# Exercise 03 — Pull Image & imagePullPolicy

> **Mục tiêu**: Pull image thủ công bằng `crictl pull`, deploy pod với `imagePullPolicy: Never`, quan sát dùng image local. Test `Always` vs `IfNotPresent` vs `Never`.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 7), SSH access vào worker node, `sudo` privilege

## Bối cảnh

Image pull policy control khi kubelet pull image. Bài này pull image thủ công, test 3 policy, quan sát behavior.

## Bước 1: Pull image manually (trên worker-1)

```bash
ssh worker-1

# Pull image manually via crictl
sudo crictl pull busybox:1.36
# Image is up to date for busybox:1.36 at sha256:xxx...

# Verify image in local cache
sudo crictl images | grep busybox
# IMAGE                    TAG    IMAGE ID            SIZE
# docker.io/library/busybox 1.36  sha256:xxx...       4MB

# Check image NOT in cache (pull a different one)
sudo crictl images | grep alpine
# (empty — alpine not cached)
```

**Kiểm tra**: `busybox:1.36` in local cache, `alpine` not cached.

## Bước 2: Test imagePullPolicy: Never — use local cache

```bash
# (trên master) — deploy pod with imagePullPolicy: Never
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: never-pull
spec:
  containers:
  - name: busybox
    image: busybox:1.36
    imagePullPolicy: Never
    command: ["sh", "-c", "echo 'Hello from local image'; sleep 3600"]
EOF
```

```bash
# Pod should start — image already in local cache
kubectl wait --for=condition=Ready pod never-pull --timeout=30s

# Verify
kubectl get pod never-pull
# NAME         READY   STATUS    RESTARTS   AGE
# never-pull   1/1     Running   0          10s

# Check logs
kubectl logs never-pull
# Hello from local image
```

> `imagePullPolicy: Never` → kubelet không pull, dùng local cache. Image `busybox:1.36` đã pull manually → pod starts. **No registry access needed**.

**Kiểm tra**: Pod Running với `imagePullPolicy: Never` — used local cached image.

## Bước 3: Test imagePullPolicy: Never — image not cached

```bash
# (trên master) — deploy pod with image not in cache
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: never-pull-fail
spec:
  containers:
  - name: alpine
    image: alpine:3.19
    imagePullPolicy: Never
    command: ["sh", "-c", "echo 'Hello'; sleep 3600"]
EOF
```

```bash
# Pod should FAIL — alpine not in local cache, Never = no pull
kubectl get pod never-pull-fail
# NAME               READY   STATUS              RESTARTS   AGE
# never-pull-fail    0/1     ErrImageNeverPull   0          10s

# Check events
kubectl describe pod never-pull-fail | tail -5
# Events:
#   Warning  Failed   pod/never-pull-fail   Error: ErrImageNeverPull
#   Normal   BackOff  pod/never-pull-fail   Back-off pulling image "alpine:3.19"
```

> `imagePullPolicy: Never` + image not cached → `ErrImageNeverPull`. Kubelet không pull, pod fail. **Must pre-pull image**.

**Kiểm tra**: Pod `ErrImageNeverPull` — image not in cache, Never = no pull.

## Bước 4: Fix — pull alpine manually

```bash
# (trên worker-1) — pull alpine manually
sudo crictl pull alpine:3.19

# Verify
sudo crictl images | grep alpine
# IMAGE                    TAG    IMAGE ID            SIZE
# docker.io/library/alpine 3.19   sha256:yyy...       7MB
```

```bash
# (trên master) — delete failed pod, recreate
kubectl delete pod never-pull-fail

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: never-pull-fixed
spec:
  containers:
  - name: alpine
    image: alpine:3.19
    imagePullPolicy: Never
    command: ["sh", "-c", "echo 'Hello from alpine'; sleep 3600"]
EOF
```

```bash
# Now pod should start — alpine in local cache
kubectl wait --for=condition=Ready pod never-pull-fixed --timeout=30s
kubectl logs never-pull-fixed
# Hello from alpine
```

**Kiểm tra**: After manual pull, pod starts with `imagePullPolicy: Never`.

## Bước 5: Test imagePullPolicy: IfNotPresent (default)

```bash
# (trên master) — deploy with IfNotPresent
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ifnotpresent
spec:
  containers:
  - name: busybox
    image: busybox:1.36
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "echo 'IfNotPresent'; sleep 3600"]
EOF
```

```bash
# Pod starts immediately — image already cached, no pull
kubectl wait --for=condition=Ready pod ifnotpresent --timeout=30s

# Check kubelet log — no PullImage call (image cached)
ssh worker-1 'sudo journalctl -u kubelet --no-pager -n 20 | grep -i "pull"'
# (no PullImage for busybox:1.36 — already cached)
```

> `IfNotPresent` → kubelet check local cache. Cached → no pull. Not cached → pull. **Default for versioned tag**.

**Kiểm tra**: Pod starts, no PullImage call (image cached).

## Bước 6: Test imagePullPolicy: Always

```bash
# (trên master) — deploy with Always
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: always-pull
spec:
  containers:
  - name: busybox
    image: busybox:1.36
    imagePullPolicy: Always
    command: ["sh", "-c", "echo 'Always'; sleep 3600"]
EOF
```

```bash
# Pod starts — but kubelet calls PullImage (check registry)
kubectl wait --for=condition=Ready pod always-pull --timeout=30s

# Check kubelet log — PullImage called even though image cached
ssh worker-1 'sudo journalctl -u kubelet --no-pager -n 20 | grep -i "pull"'
# ... "PullImage" image="busybox:1.36"
# ... "PullImage success" image="busybox:1.36" imageID="sha256:xxx"
```

> `Always` → kubelet gọi PullImage mỗi lần pod create. Containerd check registry: if digest same → skip download (use cache). If digest changed → download new layers. **Always check registry**.

**Kiểm tra**: Pod starts, PullImage called (even though cached).

## Bước 7: Compare pull policies

```bash
# Summary table
echo "Policy         | Image Cached | Image Not Cached"
echo "---------------|--------------|------------------"
echo "Always         | Pull (check) | Pull"
echo "IfNotPresent   | No pull      | Pull"
echo "Never          | No pull      | FAIL (ErrImageNeverPull)"
```

| Policy | Image Cached | Image Not Cached |
|--------|-------------|------------------|
| `Always` | Pull (check registry) | Pull |
| `IfNotPresent` | No pull (use cache) | Pull |
| `Never` | No pull (use cache) | **FAIL** (ErrImageNeverPull) |

## Bước 8: Test default policy for :latest

```bash
# (trên master) — deploy with :latest (no explicit policy)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: latest-tag
spec:
  containers:
  - name: nginx
    image: nginx:latest
    # No imagePullPolicy — default for :latest = Always
EOF
```

```bash
# Check default policy
kubectl get pod latest-tag -o jsonpath='{.spec.containers[0].imagePullPolicy}'
# Always   ← default for :latest

# Deploy with versioned tag (no explicit policy)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: versioned-tag
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    # No imagePullPolicy — default for versioned = IfNotPresent
EOF
```

```bash
kubectl get pod versioned-tag -o jsonpath='{.spec.containers[0].imagePullPolicy}'
# IfNotPresent   ← default for versioned tag
```

> Default: `:latest` → `Always` (always check registry). Versioned tag (`:1.25`) → `IfNotPresent` (pull if not cached). Explicit `imagePullPolicy` override default.

**Kiểm tra**: `:latest` → `Always`, `:1.25` → `IfNotPresent` (default).

## Bước 9: Image GC — verify unused image removed

```bash
# (trên worker-1) — check disk usage
df -h /var/lib/containerd
# Filesystem  Size  Used  Avail  Use%
# /dev/sda1   50G   20G   30G    40%

# Image GC runs when disk > 85% (high threshold)
# For testing — check image GC config
cat /var/lib/kubelet/config.yaml | grep -i "imageGC"
# imageGCHighThresholdPercent: 85
# imageGCLowThresholdPercent: 80

# Manually remove unused image
sudo crictl rmi alpine:3.19
# Deleted: alpine:3.19

# Verify removed
sudo crictl images | grep alpine
# (empty — removed)
```

> Kubelet image GC auto-remove unused image khi disk > 85%. Image đang có container running → không xóa. `crictl rmi` = manual remove (only if no container using).

## Cleanup

```bash
kubectl delete pod never-pull never-pull-fixed ifnotpresent always-pull latest-tag versioned-tag
```

## Câu hỏi tự kiểm tra

1. `imagePullPolicy: Never` + image not cached → điều gì xảy ra? Lỗi gì?
2. `imagePullPolicy: Always` + image cached → kubelet có download lại không? Tại sao?
3. Default policy cho `nginx:latest` và `nginx:1.25` khác nhau thế nào? Tại sao?
4. `crictl pull` pull image vào đâu? Pod nào dùng được?
5. Khi nào dùng `Never`? Cho use case nào?

## Đáp án tham khảo

1. **`ErrImageNeverPull`** — kubelet không pull (Never = no pull), image not in local cache → pod fail. Fix: `crictl pull <image>` manually before deploy. Use case: air-gapped cluster, pre-pulled image.
2. **Không download lại** — kubelet gọi PullImage, containerd check registry: image digest same → skip download (use cached layers). Nhưng vẫn **check registry** (network call). `Always` = check registry mỗi lần, không phải download mỗi lần.
3. `nginx:latest` → `Always` (default for `:latest` — always check registry for latest version). `nginx:1.25` → `IfNotPresent` (default for versioned — pull if not cached, versioned tag immutable). `:latest` mutable → need to check. Versioned immutable → cache OK.
4. `crictl pull` pull image vào **containerd local cache** trên node đó. Chỉ pod scheduled trên **cùng node** dùng được. Pod trên node khác → kubelet trên node đó pull riêng (hoặc fail if Never).
5. `Never` dùng cho: **air-gapped cluster** (no registry access), **pre-pulled image** (faster startup, no network dependency), **local development** (build image locally, don't pull from registry). Must ensure image pre-pulled on all nodes.
