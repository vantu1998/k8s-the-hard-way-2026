# 04 — Pod Sandbox

## Pod Sandbox là gì

Pod Sandbox = **network namespace + IPC namespace** cho pod. Tất cả container trong pod share sandbox. CRI tạo sandbox trước, container sau.

```
Pod Sandbox (network namespace + IPC namespace)
  │
  ├── Container 1 (nginx)     ── share network namespace
  ├── Container 2 (sidecar)   ── share network namespace
  └── Container 3 (init)      ── share network namespace (if restartPolicy)

All containers in pod:
  ├── Same IP (sandbox IP)
  ├── Same network namespace (can communicate via localhost)
  ├── Same IPC namespace (can share System V semaphores)
  └── Separate PID namespace (each container has own PID 1)
```

> Sandbox = "network holder". Pause container giữ sandbox alive. Container trong pod share IP + localhost. Mỗi container có riêng PID namespace.

## Tại sao cần sandbox

```
Without sandbox:
  Container 1 start → network namespace created
  Container 1 crash → network namespace destroyed
  Container 2 start → new network namespace (different IP!)
  → Container IP changes when container restarts

With sandbox:
  Sandbox created → network namespace (IP assigned)
  Container 1 start → join sandbox network namespace
  Container 1 crash → sandbox still alive (pause container)
  Container 1 restart → join same sandbox (same IP!)
  → Container IP stable across restarts
```

> Sandbox giải quyết: container restart không mất IP. Pause container giữ network namespace alive. Container crash/restart → rejoin sandbox → same IP.

## Sandbox lifecycle

```
1. RunPodSandbox
   ├── Create network namespace
   ├── CNI: assign IP, create veth, setup route
   ├── Create pause container (sleep infinity)
   └── Sandbox running

2. CreateContainer (per container in pod)
   ├── Build OCI spec (share network namespace with sandbox)
   ├── runc create (join sandbox network namespace)
   └── Container created

3. StartContainer
   ├── runc start
   └── Container running (in sandbox network namespace)

4. StopContainer → RemoveContainer (per container)
   ├── Stop container (SIGTERM → SIGKILL)
   └── Remove container (cleanup)

5. StopPodSandbox → RemovePodSandbox
   ├── Stop pause container
   ├── CNI: teardown network (release IP, remove veth)
   └── Remove sandbox (destroy network namespace)
```

## Sandbox ID vs Container ID

```bash
# List sandboxes (pods)
crictl pods
# POD ID       CREATED    STATE    NAME              NAMESPACE
# xyz789       10m ago    Ready    web-default       default

# List containers
crictl ps
# CONTAINER    IMAGE    CREATED   STATE    NAME    POD ID
# abc123       nginx    10m ago   Running  nginx   xyz789   ← belongs to sandbox xyz789

# Inspect sandbox
crictl inspectp xyz789

# Inspect container
crictl inspect abc123
```

> Sandbox ID = pod-level (network namespace). Container ID = container-level (process). Container thuộc sandbox (POD ID column).

## crictl inspect sandbox

```bash
crictl inspectp xyz789
```

```json
{
  "status": {
    "id": "xyz789abc",
    "metadata": {
      "name": "web",
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
    "runtimeSpec": {
      "linux": {
        "namespaces": [
          {"type": "network", "path": "/var/run/netns/cni-xxx"},
          {"type": "ipc"},
          {"type": "uts"},
          {"type": "pid"}
        ]
      }
    },
    "config": {
      "logDirectory": "/var/log/pods/default_web/xxx",
      "dns": {
        "servers": ["10.96.0.10"],
        "searches": ["default.svc.cluster.local", "svc.cluster.local", "cluster.local"]
      }
    }
  }
}
```

### Key fields

| Field | Ý nghĩa |
|-------|---------|
| `status.network.ip` | Pod IP (sandbox IP) |
| `status.linux.namespaces.network` | Network namespace path |
| `status.linux.cgroupParent` | Cgroup path |
| `info.config.logDirectory` | Log path |
| `info.config.dns` | DNS config (servers, searches) |

> Sandbox IP = pod IP. Tất cả container trong pod share IP này. Network namespace path = `/var/run/netns/cni-xxx`.

## Network namespace sharing

```bash
# Enter sandbox network namespace
sudo nsenter -n -t $(pgrep -f "pause" | head -1) ip addr
# 1: lo: <LOOPBACK,UP> mtu 65536
# 3: eth0: <BROADCAST,MULTICAST,UP> mtu 1450
#    inet 10.244.1.5/24 brd 10.244.1.255 scope global eth0

# Container 1 (nginx) — same network namespace
sudo nsenter -n -t $(pgrep -f "nginx: master" | head -1) ip addr
# 1: lo: <LOOPBACK,UP>
# 3: eth0: <BROADCAST,MULTICAST,UP>
#    inet 10.244.1.5/24   ← same IP!

# Container 2 (sidecar) — same network namespace
sudo nsenter -n -t $(pgrep -f "sidecar" | head -1) ip addr
# 3: eth0: inet 10.244.1.5/24   ← same IP!
```

> Tất cả container trong pod share network namespace → same IP, same `eth0`, same `localhost`. Container 1 listen port 80, container 2 connect `localhost:80` → reach container 1.

## localhost communication

```yaml
# Pod with 2 containers — communicate via localhost
apiVersion: v1
kind: Pod
metadata:
  name: multi-container
spec:
  containers:
  - name: app
    image: my-app
    ports:
    - containerPort: 8080
  - name: sidecar
    image: busybox
    command: ["sh", "-c", "while true; do wget -qO- localhost:8080/health; sleep 5; done"]
```

> Sidecar connect `localhost:8080` → reach app container (same network namespace). **No need for Service** — localhost works within pod.

## Sandbox states

| State | Ý nghĩa |
|-------|---------|
| `SANDBOX_NOT_READY` | Sandbox created but not ready (CNI not setup) |
| `SANDBOX_READY` | Sandbox running, container can join |

```
Sandbox state transition:
  RunPodSandbox → SANDBOX_NOT_READY → (CNI setup) → SANDBOX_READY
  StopPodSandbox → SANDBOX_NOT_READY
  RemovePodSandbox → (deleted)
```

## Container states (CRI)

| State | Ý nghĩa |
|-------|---------|
| `CONTAINER_CREATED` | Container created but not started |
| `CONTAINER_RUNNING` | Container running |
| `CONTAINER_EXITED` | Container exited (exit code in status) |
| `CONTAINER_UNKNOWN` | State unknown (runtime error) |

```bash
crictl ps -a
# CONTAINER   IMAGE   CREATED   STATE           NAME    ATTEMPT
# abc123      nginx   10m ago   CONTAINER_RUNNING    nginx   1
# def456      busybox 20m ago   CONTAINER_EXITED     init    0
```

## Sandbox and CNI

```
RunPodSandbox:
  1. Create network namespace (/var/run/netns/cni-xxx)
  2. Call CNI plugin:
     ├── CNI_COMMAND=ADD
     ├── CNI_CONTAINERID=xyz789
     ├── CNI_NETNS=/var/run/netns/cni-xxx
     ├── CNI_IFNAME=eth0
     ├── CNI_PATH=/opt/cni/bin
     └── CNI config: /etc/cni/net.d/*.conflist
  3. CNI plugin:
     ├── Create veth pair (one in namespace, one on node bridge)
     ├── Assign IP (from IPAM)
     ├── Setup route (pod → bridge → node)
     └── Return: { "ips": ["10.244.1.5"], "interfaces": [...] }
  4. Sandbox has IP → SANDBOX_READY
```

> CNI chạy trong RunPodSandbox — CRI gọi CNI plugin. CNI = separate from CRI (network vs runtime). Xem Phase 9 cho CNI chi tiết.

## Sandbox and cgroup

```
Pod cgroup hierarchy:
  /kubepods/                          (all pods)
    ├── /kubepods/pod<uid>/           (pod-level cgroup)
    │     ├── /kubepods/pod<uid>/<container-id-1>/  (container 1)
    │     └── /kubepods/pod<uid>/<container-id-2>/  (container 2)
    └── /kubepods/burstable/pod<uid>/ (burstable QoS)
```

```bash
# Check pod cgroup
crictl inspectp xyz789 | jq '.status.linux.cgroupParent'
# "/kubepods/burstable/podxxx"

# Check container cgroup
crictl inspect abc123 | jq '.status.linux.cgroup'
# "/kubepods/burstable/podxxx/abc123"
```

> Pod cgroup = parent. Container cgroup = child. QoS class (Guaranteed, Burstable, BestEffort) determines cgroup path. Resource limit applied at container cgroup.

## Liên hệ với Kubernetes

- Pod Sandbox = network namespace + IPC namespace. Tất cả container trong pod share sandbox.
- **Pause container** (sandbox container) = `sleep infinity`, giữ network namespace alive. Container restart → rejoin sandbox → same IP.
- Sandbox tạo trước (RunPodSandbox + CNI), container tạo sau (CreateContainer + StartContainer).
- Container trong pod share: IP, `localhost`, network namespace, IPC namespace. Riêng: PID namespace, UTS namespace.
- Sandbox ID = pod-level. Container ID = container-level. Container thuộc sandbox (`POD ID` trong `crictl ps`).
- `crictl inspectp <sandbox-id>` — xem network namespace, IP, cgroup, DNS config.
- CNI chạy trong RunPodSandbox — CRI gọi CNI plugin để setup network (veth, IP, route).
- Container communicate via `localhost` within pod — no Service needed.
- Sandbox states: NOT_READY → READY. Container states: CREATED → RUNNING → EXITED.
- Pod cgroup = parent, container cgroup = child. QoS class determines cgroup path.
