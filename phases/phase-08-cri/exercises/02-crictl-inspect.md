# Exercise 02 — crictl Inspect

> **Mục tiêu**: Deploy pod, dùng `crictl inspect` xem sandbox + container detail. Hiểu network namespace, cgroup, pause container.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 7), SSH access vào worker node, `sudo` privilege, `crictl` installed

## Bối cảnh

`crictl inspect` cho thấy chi tiết sandbox (pod) và container từ CRI perspective. Bài này deploy pod, inspect sandbox, inspect container, xem network namespace, cgroup, pause container.

## Bước 1: Deploy pod (trên master)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: inspect-demo
  labels:
    app: inspect-demo
spec:
  containers:
  - name: nginx
    image: nginx:1.25
    ports:
    - containerPort: 80
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
EOF
```

```bash
kubectl wait --for=condition=Ready pod inspect-demo --timeout=60s

# Verify pod scheduled on worker-1
kubectl get pod inspect-demo -o wide
# NAME           READY   STATUS    NODE
# inspect-demo   1/1     Running   worker-1

# Get pod IP
kubectl get pod inspect-demo -o jsonpath='{.status.podIP}'
# 10.244.1.5
```

**Kiểm tra**: Pod Running on worker-1, pod IP = 10.244.1.5.

## Bước 2: crictl pods — find sandbox (trên worker-1)

```bash
ssh worker-1

# List sandboxes — find inspect-demo
sudo crictl pods --name inspect-demo
# POD ID       CREATED    STATE    NAME             NAMESPACE
# xyz789abc    5m ago     Ready    inspect-demo     default

# Save sandbox ID
SANDBOX_ID=$(sudo crictl pods --name inspect-demo -q)
echo "${SANDBOX_ID}"
# xyz789abc
```

**Kiểm tra**: Sandbox `inspect-demo` found, state `Ready`.

## Bước 3: crictl inspectp — inspect sandbox

```bash
# Inspect sandbox
sudo crictl inspectp "${SANDBOX_ID}"
```

Key output:
```json
{
  "status": {
    "id": "xyz789abc",
    "metadata": {
      "name": "inspect-demo",
      "namespace": "default",
      "uid": "xxx-xxx-xxx",
      "attempt": 1
    },
    "state": "SANDBOX_READY",
    "createdAt": "2026-01-01T00:00:00Z",
    "network": {
      "ip": "10.244.1.5"
    },
    "linux": {
      "namespaces": {
        "network": "/var/run/netns/cni-xxx",
        "ipc": "/proc/123/ns/ipc",
        "pid": "/proc/123/ns/pid",
        "uts": "/proc/123/ns/uts"
      },
      "cgroupParent": "/kubepods/burstable/podxxx"
    }
  },
  "info": {
    "config": {
      "logDirectory": "/var/log/pods/default_inspect-demo/xxx",
      "dns": {
        "servers": ["10.96.0.10"],
        "searches": ["default.svc.cluster.local", "svc.cluster.local", "cluster.local"]
      }
    },
    "runtimeSpec": {
      "linux": {
        "namespaces": [
          {"type": "network", "path": "/var/run/netns/cni-xxx"},
          {"type": "ipc"},
          {"type": "uts"},
          {"type": "pid"}
        ]
      }
    }
  }
}
```

### Key fields to note

| Field | Value | Ý nghĩa |
|-------|-------|---------|
| `status.network.ip` | `10.244.1.5` | Pod IP (sandbox IP) |
| `status.linux.namespaces.network` | `/var/run/netns/cni-xxx` | Network namespace path |
| `status.linux.cgroupParent` | `/kubepods/burstable/podxxx` | Cgroup path (QoS=burstable) |
| `info.config.logDirectory` | `/var/log/pods/default_inspect-demo/xxx` | Log path |
| `info.config.dns.servers` | `10.96.0.10` | DNS server (CoreDNS) |

**Kiểm tra**: Sandbox IP = pod IP, network namespace path exists, cgroup path = burstable QoS.

## Bước 4: crictl ps — find container

```bash
# List containers in sandbox
sudo crictl ps --pod "${SANDBOX_ID}"
# CONTAINER    IMAGE    CREATED   STATE    NAME    POD ID
# def456ghi    nginx    5m ago    Running  nginx   xyz789abc

# Save container ID
CONTAINER_ID=$(sudo crictl ps --pod "${SANDBOX_ID}" -q)
echo "${CONTAINER_ID}"
# def456ghi
```

**Kiểm tra**: Container `nginx` found, belongs to sandbox `xyz789abc`.

## Bước 5: crictl inspect — inspect container

```bash
# Inspect container
sudo crictl inspect "${CONTAINER_ID}"
```

Key output:
```json
{
  "status": {
    "id": "def456ghi",
    "metadata": {
      "name": "nginx",
      "attempt": 1
    },
    "state": "CONTAINER_RUNNING",
    "createdAt": "2026-01-01T00:00:00Z",
    "startedAt": "2026-01-01T00:00:01Z",
    "image": {
      "image": "docker.io/library/nginx:1.25"
    },
    "imageRef": "sha256:abc123..."
  },
  "info": {
    "runtimeSpec": {
      "process": {
        "args": ["/sbin/nginx", "-g", "daemon off;"],
        "env": [
          "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          "NGINX_VERSION=1.25",
          "KUBERNETES_SERVICE_HOST=10.96.0.1"
        ]
      },
      "linux": {
        "resources": {
          "cpu": {"quota": 20000, "period": 100000},
          "memory": {"limit": 268435456}
        },
        "namespaces": [
          {"type": "network", "path": "/var/run/netns/cni-xxx"},
          {"type": "pid"},
          {"type": "ipc"},
          {"type": "uts"}
        ]
      },
      "mounts": [
        {"destination": "/var/log/pods", "source": "/var/log/pods", "type": "bind"},
        {"destination": "/etc/nginx", "source": "overlayfs/...", "type": "overlay"}
      ]
    }
  }
}
```

### Key fields to note

| Field | Value | Ý nghĩa |
|-------|-------|---------|
| `status.state` | `CONTAINER_RUNNING` | Container running |
| `status.imageRef` | `sha256:abc123...` | Image digest |
| `info.runtimeSpec.process.args` | `["/sbin/nginx", "-g", "daemon off;"]` | Container command |
| `info.runtimeSpec.process.env` | `["KUBERNETES_SERVICE_HOST=10.96.0.1", ...]` | Env vars (auto-injected) |
| `info.runtimeSpec.linux.resources.cpu.quota` | `20000` | CPU limit: 200ms per 100ms = 200m |
| `info.runtimeSpec.linux.resources.memory.limit` | `268435456` | Memory limit: 256Mi |
| `info.runtimeSpec.linux.namespaces` | network + pid + ipc + uts | Container namespaces |

**Kiểm tra**: Container running, CPU/memory limit match pod spec, network namespace = sandbox namespace.

## Bước 6: Verify network namespace sharing

```bash
# Get pause container PID (sandbox container)
PAUSE_PID=$(sudo crictl inspectp "${SANDBOX_ID}" -o json | jq -r '.info.pid')
echo "Pause PID: ${PAUSE_PID}"

# Get nginx container PID
NGINX_PID=$(sudo crictl inspect "${CONTAINER_ID}" -o json | jq -r '.info.pid')
echo "Nginx PID: ${NGINX_PID}"

# Compare network namespace — should be SAME
sudo ls -la /proc/${PAUSE_PID}/ns/net
# lrwxrwxrwx 1 root root 0 ... /proc/123/ns/net -> net:[402653xxx]

sudo ls -la /proc/${NGINX_PID}/ns/net
# lrwxrwxrwx 1 root root 0 ... /proc/456/ns/net -> net:[402653xxx]   ← SAME inode!

# Compare PID namespace — should be DIFFERENT
sudo ls -la /proc/${PAUSE_PID}/ns/pid
# /proc/123/ns/pid -> pid:[402653aaa]

sudo ls -la /proc/${NGINX_PID}/ns/pid
# /proc/456/ns/pid -> pid:[402653bbb]   ← DIFFERENT inode!
```

> Network namespace: SAME inode = share network. PID namespace: DIFFERENT inode = separate PID. Container share network với sandbox, riêng PID.

**Kiểm tra**: Network namespace inode match (pause + nginx). PID namespace inode different.

## Bước 7: Enter network namespace

```bash
# Enter sandbox network namespace
sudo nsenter -n -t "${PAUSE_PID}" ip addr
# 1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536
#     inet 127.0.0.1/8 scope host lo
# 3: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450
#     inet 10.244.1.5/24 brd 10.244.1.255 scope global eth0
#     link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff

# Verify — same IP as pod
echo "Pod IP from kubectl: $(kubectl get pod inspect-demo -o jsonpath='{.status.podIP}')"
# Pod IP from kubectl: 10.244.1.5
echo "Pod IP from namespace: $(sudo nsenter -n -t ${PAUSE_PID} ip -4 addr show eth0 | grep inet | awk '{print $2}')"
# Pod IP from namespace: 10.244.1.5/24
```

> `nsenter -n` = enter network namespace. `eth0` = pod interface (veth). IP = 10.244.1.5 = pod IP. CNI tạo veth + assign IP.

**Kiểm tra**: Network namespace có `eth0` với IP = pod IP (10.244.1.5).

## Bước 8: Check cgroup

```bash
# Pod cgroup
sudo crictl inspectp "${SANDBOX_ID}" -o json | jq -r '.status.linux.cgroupParent'
# /kubepods/burstable/podxxx

# Container cgroup
sudo crictl inspect "${CONTAINER_ID}" -o json | jq -r '.status.linux.cgroup'
# /kubepods/burstable/podxxx/def456ghi

# Check cgroup CPU limit
sudo cat /sys/fs/cgroup/kubepods/burstable/podxxx/def456ghi/cpu.max
# 20000 100000   ← 200ms per 100ms = 200m (2 cores * 100ms)

# Check cgroup memory limit
sudo cat /sys/fs/cgroup/kubepods/burstable/podxxx/def456ghi/memory.max
# 268435456   ← 256Mi
```

> Cgroup path: `/kubepods/burstable/podxxx/container-id`. `burstable` = QoS class (request < limit). CPU/memory limit = pod spec limit.

**Kiểm tra**: Cgroup CPU = 20000/100000 (200m), memory = 268435456 (256Mi) — match pod spec.

## Bước 9: Check pause container

```bash
# List all containers including pause
sudo crictl ps -a --pod "${SANDBOX_ID}"
# CONTAINER    IMAGE                    CREATED   STATE    NAME         ATTEMPT
# def456ghi    nginx                    5m ago    Running  nginx        1
# pause123     registry.k8s.io/pause    5m ago    Running  k8s_POD_...  0   ← pause container

# Inspect pause container
sudo crictl inspect pause123 -o json | jq '.status.metadata.name'
# "k8s_POD_inspect-demo_default_xxx"

# Pause container command
sudo crictl inspect pause123 -o json | jq '.info.runtimeSpec.process.args'
# ["/pause"]
```

> Pause container = `registry.k8s.io/pause:3.9`, command `/pause` (sleep infinity). Giữ network namespace alive. Name = `k8s_POD_<pod-name>_<namespace>_<uid>`.

**Kiểm tra**: Pause container running, command = `/pause`.

## Cleanup

```bash
# (trên master)
kubectl delete pod inspect-demo
```

## Câu hỏi tự kiểm tra

1. `crictl inspectp` vs `crictl inspect` — khác nhau thế nào? Inspect cái nào cho pod-level info?
2. Network namespace của pause container và nginx container — same hay different? Tại sao?
3. PID namespace của pause container và nginx container — same hay different? Tại sao?
4. Cgroup path `/kubepods/burstable/podxxx/` — `burstable` có ý nghĩa gì? Khi nào là `besteffort`?
5. Pause container chạy gì? Tại sao cần pause container?

## Đáp án tham khảo

1. `crictl inspectp <sandbox-id>` = inspect **sandbox** (pod-level: network namespace, IP, cgroup parent, DNS). `crictl inspect <container-id>` = inspect **container** (container-level: command, env, resources, mounts). Pod-level info (IP, network) → `inspectp`. Container-level info (command, limit) → `inspect`.
2. **Same** network namespace — container share sandbox network. Inode match. Tất cả container trong pod share IP, `localhost`, `eth0`. Nên container communicate qua `localhost`.
3. **Different** PID namespace — mỗi container có riêng PID namespace. Container 1 không thấy process của container 2. Pause container có PID 1 = `/pause`. Nginx container có PID 1 = `nginx master`.
4. `burstable` = QoS class — pod có request < limit (có thể burst). `besteffort` = pod không có request/limit (lowest priority, evict first). `guaranteed` = request = limit (highest priority, evict last). QoS determines cgroup path + eviction order.
5. Pause container chạy `/pause` (sleep infinity). Giữ **network namespace alive** — nếu app container crash, pause vẫn chạy → network namespace không bị destroy → container restart rejoin same network (same IP). Không có pause → container crash = network namespace destroyed = IP lost.
