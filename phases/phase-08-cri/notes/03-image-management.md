# 03 — Image Management

## Image pull flow

```
Kubelet → CRI: PullImage(image="nginx:1.25")
  │
  ▼
containerd:
  1. Check local cache (content store)
     ├── Cached → return imageID (no pull)
     └── Not cached → pull from registry
  2. Pull from registry:
     a. Resolve registry: docker.io/library/nginx:1.25
     b. Download manifest (list of layers)
     c. Download each layer (gzip tar)
     d. Extract layers to snapshotter (overlayfs)
     e. Store manifest + layers in content store
  3. Return imageID (sha256 digest)
```

### Image structure

```
Image = manifest + config + layers

manifest:  list of layer digests
config:    container config (entrypoint, env, layers order)
layers:    filesystem changes (gzip tar)

nginx:1.25 image:
  manifest: [layer1, layer2, layer3]
  config:   { Cmd: ["nginx"], Env: ["PATH=..."], Layers: [...] }
  layer1:   base OS (debian) — 30MB
  layer2:   nginx install — 40MB
  layer3:   config files — 1MB
```

> Image = read-only layers. Container = image + writable layer (overlayfs). Multiple container share image layers (dedup).

## Image pull policy

| Policy | Behavior | Use case |
|--------|----------|----------|
| `Always` | Always pull (even if cached) | `:latest` tag, CI/CD |
| `IfNotPresent` (default) | Pull only if not in cache | Versioned tag (`:1.25`) |
| `Never` | Never pull — use local cache only | Air-gapped, pre-pulled image |

```yaml
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    imagePullPolicy: IfNotPresent   # default for versioned tag
```

### Default policy

```
image: nginx:1.25       → imagePullPolicy: IfNotPresent (default)
image: nginx:latest     → imagePullPolicy: Always (default for :latest)
image: nginx            → imagePullPolicy: Always (default, :latest implied)
```

> `:latest` tag → `Always` (always pull latest). Versioned tag → `IfNotPresent` (pull if not cached). Explicit `imagePullPolicy` override default.

### Pull policy interaction

```
imagePullPolicy: Always
  → Kubelet gọi PullImage mỗi lần pod create
  → containerd check registry: image digest changed?
  → If changed → pull new layers
  → If same → skip (use cache, but still check registry)

imagePullPolicy: Never
  → Kubelet không gọi PullImage
  → containerd check local cache only
  → If not cached → pod fail (ErrImageNeverPull)
```

> `Always` = check registry mỗi lần (slow but always latest). `Never` = local only (fast but need pre-pull). `IfNotPresent` = pull once, reuse (default, best for versioned).

## Image pull error

| Error | Nguyên nhân | Fix |
|-------|-------------|-----|
| `ImagePullBackOff` | Registry unreachable / image not found | Check image name, registry, network |
| `ErrImagePull` | Pull fail (auth, rate limit) | Check credentials, registry rate limit |
| `ErrImageNeverPull` | `imagePullPolicy: Never` but image not cached | `crictl pull` image manually |
| `RegistryUnavailable` | Registry down | Check registry, use mirror |

```bash
# Check image pull error
kubectl describe pod web | tail -10
# Events:
#   Warning  Failed   pod/web   Error: ErrImagePull
#   Warning  Failed   pod/web   Error: ImagePullBackOff
#   Normal   BackOff  pod/web   Back-off pulling image "nginx:99.99"
```

## Image registry

### Default registry

```
image: nginx           → docker.io/library/nginx:latest
image: nginx:1.25      → docker.io/library/nginx:1.25
image: myrepo/app:v1   → docker.io/myrepo/app:v1
image: registry.local:5000/app:v1  → registry.local:5000/app:v1
```

> No registry prefix → Docker Hub (docker.io). Full registry path → custom registry.

### Private registry

```yaml
spec:
  imagePullSecrets:
  - name: registry-credentials
  containers:
  - name: app
    image: registry.private.com/app:v1
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-credentials
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <base64 encoded docker config>
```

```bash
# Create image pull secret
kubectl create secret docker-registry registry-credentials \
  --docker-server=registry.private.com \
  --docker-username=user \
  --docker-password=pass \
  --docker-email=user@example.com
```

> `imagePullSecrets` — kubelet pass credentials to CRI PullImage. CRI use credentials to authenticate with registry.

## Image store — containerd

```
containerd content store:
  /var/lib/containerd/io.containerd.content.v1.content/blobs/sha256/
    ├── abc123... (manifest)
    ├── def456... (config)
    └── ghi789... (layer 1)

containerd snapshotter (overlayfs):
  /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/
    ├── snapshots/1/ (layer 1 extracted)
    ├── snapshots/2/ (layer 2 extracted)
    └── snapshots/3/ (layer 3 extracted)
```

```bash
# Check image in containerd
crictl images
# IMAGE                    TAG    IMAGE ID            SIZE
# docker.io/library/nginx  1.25   sha256:abc123...    70MB

# Image detail
crictl inspecti sha256:abc123
```

> Content store = image metadata + layers (compressed). Snapshotter = extracted layers (ready to mount). Image size in `crictl` = extracted size (larger than compressed).

## Image GC — garbage collection

Kubelet chạy **image GC** định kỳ — xóa image không dùng để giải phóng disk:

```yaml
# KubeletConfiguration
imageGCHighThresholdPercent: 85   # Disk > 85% → start GC
imageGCLowThresholdPercent: 80    # Disk < 80% → stop GC
```

```
Image GC flow:
  1. Check node disk usage
  2. If disk > highThreshold (85%):
     a. List all images
     b. Sort by last used time (oldest first)
     c. Delete images not used by any container
     d. Until disk < lowThreshold (80%)
  3. If disk < highThreshold → no GC
```

> Kubelet GC xóa image cũ không dùng. Image đang có container running → không xóa. GC chỉ xóa image không referenced bởi bất kỳ container nào.

### Container GC

```yaml
# KubeletConfiguration
minimumGCAge: 0s
maxPerPodContainerCount: 5   # Giữ tối đa 5 container cũ per pod
```

> Container GC xóa container đã exit (stopped). Giữ `maxPerPodContainerCount` container cũ cho debug (logs, exit code). Container running → không xóa.

## crictl image commands

```bash
# List images
crictl images
# IMAGE                    TAG    IMAGE ID            SIZE
# docker.io/library/nginx  1.25   sha256:abc123...    70MB
# docker.io/library/busybox latest sha256:def456...   4MB

# List images (verbose)
crictl images -v

# Pull image
crictl pull nginx:1.25
# Image is up to date for nginx:1.25 at sha256:abc123

# Inspect image
crictl inspecti sha256:abc123
# {
#   "image": {
#     "id": "sha256:abc123...",
#     "repoTags": ["docker.io/library/nginx:1.25"],
#     "repoDigests": ["docker.io/library/nginx@sha256:xxx"],
#     "size": "70560000",
#     "username": ""
#   }
# }

# Remove image
crictl rmi nginx:1.25
# Deleted: nginx:1.25

# Image filesystem info
crictl imagefsinfo
# {
#   "storageStats": {
#     "usedBytes": 1073741824,
#     "inodesUsed": 50000
#   }
# }
```

## Image digest vs tag

```
Tag:    nginx:1.25       → mutable (can point to different image)
Digest: nginx@sha256:abc → immutable (always same image)
```

```bash
# Pull by tag
crictl pull nginx:1.25

# Pull by digest (immutable)
crictl pull nginx@sha256:abc123def456...

# Image ID = config digest (sha256)
crictl inspecti sha256:abc123 | jq '.image.id'
# "sha256:abc123..."
```

> Tag mutable — `nginx:1.25` có thể thay đổi (rebuild same tag). Digest immutable — `nginx@sha256:xxx` luôn same image. Production nên dùng digest cho reproducibility.

## Liên hệ với Kubernetes

- Image = manifest + config + layers (read-only). Container = image + writable layer (overlayfs).
- Image pull policy: `Always` (check registry mỗi lần), `IfNotPresent` (pull if not cached, default), `Never` (local only).
- Default: `:latest` → `Always`, versioned tag → `IfNotPresent`.
- `ImagePullBackOff` = pull fail (registry unreachable, image not found, auth fail, rate limit).
- `imagePullSecrets` — credentials cho private registry. Kubelet pass to CRI PullImage.
- containerd content store = compressed layers. Snapshotter = extracted layers (overlayfs).
- Image GC: xóa image không dùng khi disk > 85% (high), stop khi < 80% (low).
- Container GC: xóa container đã exit, giữ `maxPerPodContainerCount` cũ cho debug.
- Tag mutable, digest immutable. Production dùng digest cho reproducibility.
- `crictl images` / `crictl pull` / `crictl inspecti` / `crictl rmi` — image management CLI.
