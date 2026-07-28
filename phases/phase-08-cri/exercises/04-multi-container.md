# Exercise 04 — Multi-Container Pod

> **Mục tiêu**: Deploy pod 2 container share volume, quan sát sandbox + 2 container trong `crictl ps`. Verify container share network namespace, communicate via localhost.
>
> **Thời gian dự kiến**: 25 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 7), SSH access vào worker node, `sudo` privilege

## Bối cảnh

Pod có thể có nhiều container — tất cả share sandbox (network namespace). Bài này deploy pod 2 container (nginx + sidecar), verify share network, communicate via localhost.

## Bước 1: Deploy multi-container pod (trên master)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-container
  labels:
    app: multi-container
spec:
  volumes:
  - name: shared-data
    emptyDir: {}
  containers:
  - name: nginx
    image: nginx:1.25
    volumeMounts:
    - name: shared-data
      mountPath: /usr/share/nginx/html
    ports:
    - containerPort: 80
  - name: sidecar
    image: busybox:1.36
    volumeMounts:
    - name: shared-data
      mountPath: /var/log/shared
    command:
    - sh
    - -c
    - |
      while true; do
        echo "<h1>Hello from sidecar at $(date)</h1>" > /var/log/shared/index.html
        sleep 10
      done
EOF
```

### Giải thích

- **nginx container**: serve file từ `/usr/share/nginx/html` (shared volume)
- **sidecar container**: write `index.html` vào `/var/log/shared` (same shared volume) mỗi 10s
- **shared volume**: `emptyDir` — cả 2 container mount cùng volume

```bash
kubectl wait --for=condition=Ready pod multi-container --timeout=60s

# Verify — 2/2 containers ready
kubectl get pod multi-container
# NAME              READY   STATUS    RESTARTS   AGE
# multi-container   2/2     Running   0          15s   ← 2/2 = both containers ready
```

**Kiểm tra**: Pod `2/2` Running — cả 2 container ready.

## Bước 2: Verify shared volume

```bash
# Check nginx serving sidecar's file
kubectl exec multi-container -c nginx -- cat /usr/share/nginx/html/index.html
# <h1>Hello from sidecar at Mon Jan 1 00:00:10 UTC 2026</h1>

# Curl nginx from within pod
kubectl exec multi-container -c sidecar -- wget -qO- localhost:80
# <h1>Hello from sidecar at Mon Jan 1 00:00:10 UTC 2026</h1>
```

> Sidecar write `index.html` → shared volume → nginx serve it. Sidecar connect `localhost:80` → reach nginx (same network namespace). **localhost works within pod**.

**Kiểm tra**: Sidecar file appears in nginx volume, sidecar reaches nginx via `localhost:80`.

## Bước 3: crictl — find sandbox + 2 containers (trên worker-1)

```bash
ssh worker-1

# Find sandbox
SANDBOX_ID=$(sudo crictl pods --name multi-container -q)
echo "Sandbox ID: ${SANDBOX_ID}"

# List containers in sandbox — should be 2 + 1 pause
sudo crictl ps --pod "${SANDBOX_ID}"
# CONTAINER    IMAGE     CREATED   STATE    NAME     POD ID
# abc111       nginx     5m ago    Running  nginx    ${SANDBOX_ID}
# def222       busybox   5m ago    Running  sidecar  ${SANDBOX_ID}

# Also show pause container
sudo crictl ps -a --pod "${SANDBOX_ID}"
# CONTAINER    IMAGE                    CREATED   STATE    NAME              POD ID
# abc111       nginx                    5m ago    Running  nginx             ${SANDBOX_ID}
# def222       busybox                  5m ago    Running  sidecar           ${SANDBOX_ID}
# pause333     registry.k8s.io/pause    5m ago    Running  k8s_POD_multi...  ${SANDBOX_ID}
```

> 1 sandbox = 3 containers: nginx + sidecar + pause. Tất cả thuộc cùng sandbox (same POD ID).

**Kiểm tra**: 3 containers in sandbox — nginx, sidecar, pause. All share same POD ID.

## Bước 4: Verify network namespace sharing

```bash
# Get PIDs
NGINX_PID=$(sudo crictl inspect abc111 -o json | jq -r '.info.pid')
SIDECAR_PID=$(sudo crictl inspect def222 -o json | jq -r '.info.pid')
PAUSE_PID=$(sudo crictl inspect pause333 -o json | jq -r '.info.pid')

echo "Nginx PID: ${NGINX_PID}, Sidecar PID: ${SIDECAR_PID}, Pause PID: ${PAUSE_PID}"

# Compare network namespace inode — ALL should be SAME
echo "=== Network namespace ==="
for PID in "${PAUSE_PID}" "${NGINX_PID}" "${SIDECAR_PID}"; do
  echo -n "PID ${PID}: "
  sudo ls -la /proc/${PID}/ns/net | awk '{print $NF}'
done
# PID 123: net:[402653xxx]   ← pause
# PID 456: net:[402653xxx]   ← nginx — SAME
# PID 789: net:[402653xxx]   ← sidecar — SAME

# Compare PID namespace — ALL should be DIFFERENT
echo "=== PID namespace ==="
for PID in "${PAUSE_PID}" "${NGINX_PID}" "${SIDECAR_PID}"; do
  echo -n "PID ${PID}: "
  sudo ls -la /proc/${PID}/ns/pid | awk '{print $NF}'
done
# PID 123: pid:[402653aaa]   ← pause
# PID 456: pid:[402653bbb]   ← nginx — DIFFERENT
# PID 789: pid:[402653ccc]   ← sidecar — DIFFERENT
```

> Network namespace: ALL same inode = share network. PID namespace: ALL different = separate PID. Container share network (localhost), riêng PID (isolation).

**Kiểm tra**: Network namespace inode same for all 3. PID namespace inode different for each.

## Bước 5: Verify localhost communication

```bash
# Nginx listens on port 80 (in shared network namespace)
sudo nsenter -n -t "${NGINX_PID}" ss -tlnp
# State  Recv-Q  Send-Q  Local Address:Port  Peer Address:Port
# LISTEN 0       511     0.0.0.0:80          0.0.0.0:*   ← nginx listening

# Sidecar can reach nginx via localhost (same network namespace)
sudo nsenter -n -t "${SIDECAR_PID}" curl -s http://localhost:80
# <h1>Hello from sidecar at Mon Jan 1 00:00:10 UTC 2026</h1>

# Check from pause container's network namespace — same view
sudo nsenter -n -t "${PAUSE_PID}" ss -tlnp
# LISTEN 0  511  0.0.0.0:80  0.0.0.0:*   ← nginx port visible from pause too
```

> Tất cả container share network namespace → same `ss` output, same `localhost`. Nginx listen port 80 → sidecar + pause see port 80. `curl localhost:80` from sidecar → reach nginx.

**Kiểm tra**: `curl localhost:80` from sidecar network namespace → nginx response.

## Bước 6: Verify shared volume — same emptyDir

```bash
# Check mount in nginx container
sudo crictl inspect abc111 -o json | jq '.info.runtimeSpec.mounts[] | select(.destination == "/usr/share/nginx/html")'
# {
#   "destination": "/usr/share/nginx/html",
#   "source": "/var/lib/kubelet/pods/xxx/volumes/kubernetes.io~empty-dir/shared-data",
#   "type": "bind"
# }

# Check mount in sidecar container
sudo crictl inspect def222 -o json | jq '.info.runtimeSpec.mounts[] | select(.destination == "/var/log/shared")'
# {
#   "destination": "/var/log/shared",
#   "source": "/var/lib/kubelet/pods/xxx/volumes/kubernetes.io~empty-dir/shared-data",
#   "type": "bind"
# }

# Same source path — both mount same emptyDir
```

> Both containers mount **same source** (`/var/lib/kubelet/pods/xxx/volumes/.../shared-data`) — different mount path inside container. File written by sidecar → visible to nginx (same underlying directory).

**Kiểm tra**: Both containers mount same emptyDir source (different path inside container).

## Bước 7: Kill one container — verify sandbox alive

```bash
# Kill nginx container (simulate crash)
sudo crictl stop abc111
# Stopped abc111

# Check — sandbox still alive (pause running)
sudo crictl pods --name multi-container
# POD ID       STATE
# ${SANDBOX_ID}  Ready   ← sandbox still Ready!

# Kubelet will restart nginx (restartPolicy: Always default)
sleep 5
sudo crictl ps --pod "${SANDBOX_ID}"
# CONTAINER    IMAGE     STATE    NAME     ATTEMPT
# abc111-new   nginx     Running  nginx    2   ← restarted (attempt=2)
# def222       busybox   Running  sidecar  1
# pause333     pause     Running  k8s_POD  0

# Verify — sidecar still reaches restarted nginx
kubectl exec multi-container -c sidecar -- wget -qO- localhost:80
# <h1>Hello from sidecar at ...</h1>
```

> Nginx crash → kubelet restart. Sandbox (pause) still alive → network namespace intact → nginx restart rejoin same network → same IP, same localhost. **No network disruption**.

**Kiểm tra**: Nginx restarted, sandbox still Ready, sidecar reaches nginx via localhost.

## Cleanup

```bash
kubectl delete pod multi-container
```

## Câu hỏi tự kiểm tra

1. Pod 2 container — bao nhiêu sandbox? Bao nhiêu container trong `crictl ps`?
2. Network namespace của nginx và sidecar — same hay different? Tại sao?
3. Sidecar connect `localhost:80` → reach ai? Tại sao không cần Service?
4. Nginx container crash → sandbox có bị destroy không? Sidecar có mất network không?
5. Shared volume (emptyDir) — 2 container mount same source hay different source?

## Đáp án tham khảo

1. **1 sandbox** (pod = 1 sandbox). **3 containers** trong `crictl ps`: nginx + sidecar + pause. Pause = sandbox container (giữ network namespace). Mỗi pod = 1 sandbox, N container + 1 pause.
2. **Same** network namespace — tất cả container trong pod share sandbox network. Inode match. Container share IP, `localhost`, `eth0`. Tại sao: pod = 1 network namespace (sandbox), container join sandbox.
3. Reach **nginx** — sidecar connect `localhost:80`, nginx listen port 80 (same network namespace). Không cần Service vì **localhost works within pod** — same network namespace = same loopback. Service cho cross-pod communication.
4. **Sandbox không bị destroy** — pause container vẫn chạy → network namespace alive. Sidecar không mất network. Nginx restart → rejoin same sandbox → same IP, same localhost. **No network disruption**. Đây là lý do pause container tồn tại.
5. **Same source** — cả 2 container mount cùng emptyDir directory (`/var/lib/kubelet/pods/xxx/volumes/.../shared-data`). Different mount path **inside container** (`/usr/share/nginx/html` vs `/var/log/shared`) nhưng same underlying directory. File written by sidecar → visible to nginx.
