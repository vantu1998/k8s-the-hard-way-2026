# Exercise 06 — Simple Controller (Python)

> **Mục tiêu**: Viết một simple controller bằng Python (watch ConfigMap, tạo file) — hiểu reconcile loop bằng tay.
>
> **Thời gian dự kiến**: 40 phút
>
> **Yêu cầu**: Cluster K8s đang chạy (Phase 4), `python3` + `pip` installed

## Bối cảnh

Controller = watch + reconcile loop. Bài này viết Python controller watch ConfigMap, khi ConfigMap thay đổi → tạo file trên disk. Hiểu reconcile loop bằng tay.

## Prerequisites

```bash
# Install Kubernetes Python client
pip3 install kubernetes

# Verify
python3 -c "import kubernetes; print(kubernetes.__version__)"
# 29.0.0
```

## Bước 1: Tạo ConfigMap để controller watch

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: file-controller-config
  namespace: default
data:
  greeting.txt: "Hello from Kubernetes!"
  message.txt: "This file is managed by a custom controller."
EOF
```

```bash
# Verify
kubectl get cm file-controller-config
# NAME                       DATA   AGE
# file-controller-config     2      5s
```

**Kiểm tra**: ConfigMap `file-controller-config` tồn tại với 2 key.

## Bước 2: Viết controller Python

Tạo file `simple-controller.py`:

```python
#!/usr/bin/env python3
"""
Simple Controller — watch ConfigMap, sync data to files.

Reconcile loop:
  1. Watch ConfigMap "file-controller-config"
  2. For each key in ConfigMap data:
     - Create file /tmp/controller-output/<key> with value as content
  3. Delete files not in ConfigMap
  4. Repeat on every change (watch event)
"""

import os
import sys
import time
import logging
from kubernetes import client, watch

# --- Config ---
CONFIGMAP_NAME = "file-controller-config"
NAMESPACE = "default"
OUTPUT_DIR = "/tmp/controller-output"

# --- Logging ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("simple-controller")


def reconcile(cm_data: dict):
    """Reconcile: sync ConfigMap data to files."""
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # --- Create/update files from ConfigMap ---
    for key, value in cm_data.items():
        filepath = os.path.join(OUTPUT_DIR, key)
        existing = None
        if os.path.exists(filepath):
            with open(filepath, "r") as f:
                existing = f.read()

        if existing != value:
            with open(filepath, "w") as f:
                f.write(value)
            log.info(f"Created/updated file: {filepath}")
        else:
            log.debug(f"File unchanged: {filepath}")

    # --- Delete files not in ConfigMap ---
    cm_keys = set(cm_data.keys())
    if os.path.exists(OUTPUT_DIR):
        for filename in os.listdir(OUTPUT_DIR):
            if filename not in cm_keys:
                filepath = os.path.join(OUTPUT_DIR, filename)
                os.remove(filepath)
                log.info(f"Deleted stale file: {filepath}")


def get_configmap() -> dict:
    """Fetch ConfigMap data from API Server."""
    api = client.CoreV1Api()
    try:
        cm = api.read_namespaced_config_map(
            name=CONFIGMAP_NAME,
            namespace=NAMESPACE,
        )
        return cm.data or {}
    except client.ApiException as e:
        if e.status == 404:
            log.warning(f"ConfigMap {CONFIGMAP_NAME} not found")
            return {}
        raise


def initial_sync():
    """Initial reconcile — fetch current state."""
    log.info("=== Initial sync ===")
    data = get_configmap()
    reconcile(data)
    log.info(f"Synced {len(data)} file(s) from ConfigMap")


def watch_loop():
    """Watch ConfigMap changes — reconcile on every event."""
    api = client.CoreV1Api()
    w = watch.Watch()

    log.info(f"=== Watching ConfigMap {CONFIGMAP_NAME} ===")
    while True:
        try:
            for event in w.stream(
                api.list_namespaced_config_map,
                namespace=NAMESPACE,
                field_selector=f"metadata.name={CONFIGMAP_NAME}",
                timeout_seconds=0,  # infinite watch
            ):
                event_type = event["type"]
                cm = event["object"]

                if cm.metadata.name != CONFIGMAP_NAME:
                    continue

                log.info(f"Event: {event_type} — ConfigMap {cm.metadata.name}")

                if event_type == "DELETED":
                    log.info("ConfigMap deleted — clearing output")
                    reconcile({})
                else:
                    data = cm.data or {}
                    reconcile(data)

        except client.ApiException as e:
            log.error(f"API error: {e}")
            time.sleep(5)
        except Exception as e:
            log.error(f"Unexpected error: {e}")
            time.sleep(5)
        finally:
            w.stop()
            log.info("Watch disconnected — reconnecting...")


def main():
    # --- Load kubeconfig ---
    try:
        from kubernetes.config import load_kube_config
        load_kube_config()
        log.info("Loaded kubeconfig from ~/.kube/config")
    except Exception:
        try:
            from kubernetes.config import load_incluster_config
            load_incluster_config()
            log.info("Loaded in-cluster config")
        except Exception:
            log.error("Cannot load kubeconfig")
            sys.exit(1)

    # --- Initial sync (level-triggered) ---
    initial_sync()

    # --- Watch loop (edge-triggered + reconcile) ---
    watch_loop()


if __name__ == "__main__":
    main()
```

> Controller này:
> 1. **Initial sync** — fetch ConfigMap, create files (level-triggered, không phụ thuộc event)
> 2. **Watch loop** — watch ConfigMap, reconcile on change (edge-triggered)
> 3. **Reconcile** — create/update files from ConfigMap data, delete stale files
> 4. **Idempotent** — chỉ write file nếu content thay đổi, delete file nếu không còn trong ConfigMap

## Bước 3: Run controller

```bash
# Terminal 1 — run controller
python3 simple-controller.py
# 2026-01-01 00:00:00 [INFO] Loaded kubeconfig from ~/.kube/config
# 2026-01-01 00:00:00 [INFO] === Initial sync ===
# 2026-01-01 00:00:00 [INFO] Created/updated file: /tmp/controller-output/greeting.txt
# 2026-01-01 00:00:00 [INFO] Created/updated file: /tmp/controller-output/message.txt
# 2026-01-01 00:00:00 [INFO] Synced 2 file(s) from ConfigMap
# 2026-01-01 00:00:00 [INFO] === Watching ConfigMap file-controller-config ===
```

```bash
# Terminal 2 — verify files created
ls /tmp/controller-output/
# greeting.txt  message.txt

cat /tmp/controller-output/greeting.txt
# Hello from Kubernetes!

cat /tmp/controller-output/message.txt
# This file is managed by a custom controller.
```

**Kiểm tra**: 2 file tạo trong `/tmp/controller-output/`, content match ConfigMap data.

## Bước 4: Update ConfigMap — quan sát controller react

```bash
# Terminal 2 — update ConfigMap
kubectl patch cm file-controller-config --type=merge -p '{
  "data": {
    "greeting.txt": "Hello UPDATED!",
    "new-file.txt": "A new file added."
  }
}'
```

```bash
# Terminal 1 — controller log
# 2026-01-01 00:00:10 [INFO] Event: MODIFIED — ConfigMap file-controller-config
# 2026-01-01 00:00:10 [INFO] Created/updated file: /tmp/controller-output/greeting.txt
# 2026-01-01 00:00:10 [INFO] Created/updated file: /tmp/controller-output/new-file.txt
```

```bash
# Terminal 2 — verify
cat /tmp/controller-output/greeting.txt
# Hello UPDATED!

cat /tmp/controller-output/new-file.txt
# A new file added.

# message.txt bị xóa (không còn trong ConfigMap)
ls /tmp/controller-output/
# greeting.txt  new-file.txt    ← message.txt deleted
```

> Controller detect ConfigMap update → reconcile: update `greeting.txt`, create `new-file.txt`, delete `message.txt` (stale file).

**Kiểm tra**: `greeting.txt` updated, `new-file.txt` created, `message.txt` deleted (stale).

## Bước 5: Delete ConfigMap — quan sát controller clear files

```bash
# Terminal 2
kubectl delete cm file-controller-config
```

```bash
# Terminal 1 — controller log
# 2026-01-01 00:00:20 [INFO] Event: DELETED — ConfigMap file-controller-config
# 2026-01-01 00:00:20 [INFO] ConfigMap deleted — clearing output
# 2026-01-01 00:00:20 [INFO] Deleted stale file: /tmp/controller-output/greeting.txt
# 2026-01-01 00:00:20 [INFO] Deleted stale file: /tmp/controller-output/new-file.txt
```

```bash
# Terminal 2 — verify
ls /tmp/controller-output/
# (empty — all files deleted)
```

**Kiểm tra**: Tất cả file bị xóa khi ConfigMap deleted.

## Bước 6: Recreate ConfigMap — controller auto-sync

```bash
# Terminal 2 — recreate ConfigMap
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: file-controller-config
data:
  config.yaml: |
    server:
      port: 8080
      host: 0.0.0.0
  version: "v2.0"
EOF
```

```bash
# Terminal 1 — controller auto-sync (watch detect new ConfigMap)
# 2026-01-01 00:00:30 [INFO] Event: ADDED — ConfigMap file-controller-config
# 2026-01-01 00:00:30 [INFO] Created/updated file: /tmp/controller-output/config.yaml
# 2026-01-01 00:00:30 [INFO] Created/updated file: /tmp/controller-output/version
```

```bash
# Verify
cat /tmp/controller-output/config.yaml
# server:
#   port: 8080
#   host: 0.0.0.0

cat /tmp/controller-output/version
# v2.0
```

> Controller watch detect ConfigMap created → reconcile → create files. **Không cần restart controller**.

## Bước 7: Stop controller — verify level-triggered

```bash
# Terminal 1 — Ctrl+C to stop controller

# Terminal 2 — update ConfigMap while controller down
kubectl patch cm file-controller-config --type=merge -p '{"data":{"version":"v3.0"}}'

# File NOT updated (controller down)
cat /tmp/controller-output/version
# v2.0   ← still old

# Restart controller
python3 simple-controller.py
# 2026-01-01 00:01:00 [INFO] === Initial sync ===
# 2026-01-01 00:01:00 [INFO] Created/updated file: /tmp/controller-output/version
# 2026-01-01 00:01:00 [INFO] Synced 2 file(s) from ConfigMap

# File updated — initial sync catches up
cat /tmp/controller-output/version
# v3.0
```

> Controller restart → **initial sync** (level-triggered) catches up missed changes. Không miss event — kiểm tra state hiện tại, không phụ thuộc event đã nhận.

**Kiểm tra**: Controller restart → initial sync update file với ConfigMap mới nhất (level-triggered).

## Cleanup

```bash
# Stop controller (Ctrl+C)
kubectl delete cm file-controller-config
rm -rf /tmp/controller-output
```

## Câu hỏi tự kiểm tra

1. Controller dùng `initial_sync` + `watch_loop` — tại sao cần cả hai?
2. Reconcile function có idempotent không? Chạy 2 lần cho cùng ConfigMap → kết quả?
3. Controller miss event (stop trong lúc ConfigMap update) — restart có catch up không?
4. `watch.Watch()` disconnect (network glitch) — controller xử lý thế nào?
5. So sánh controller này với built-in Kubernetes controller (ReplicaSet, Deployment)?

## Đáp án tham khảo

1. `initial_sync` = **level-triggered** — fetch state hiện tại, không phụ thuộc event. Đảm bảo controller sync đúng state khi start/restart. `watch_loop` = **edge-triggered** — react khi ConfigMap thay đổi. Cả hai: initial sync catch up missed state, watch loop react realtime.
2. **Idempotent** — chỉ write file nếu content thay đổi (`existing != value`), delete file nếu không còn trong ConfigMap. Chạy 2 lần: lần 1 = create/update, lần 2 = "File unchanged" (no-op). Idempotent = an toàn khi retry.
3. **Có catch up** — initial sync fetch ConfigMap hiện tại, compare với files, update nếu khác. Không miss event vì level-triggered — kiểm tra state, không phụ thuộc event đã nhận. Đây là lý do Kubernetes controller dùng level-triggered.
4. `watch.Watch()` disconnect → exception → `finally: w.stop()` → log "reconnecting" → while loop restart watch. Controller reconnect với `resourceVersion` mới nhất — không miss event. Nếu miss, initial sync (level-triggered) catch up.
5. Built-in controller phức tạp hơn: Informer (cache + watch), WorkQueue (rate limited, retry), SharedInformer (share giữa controller), leader election (HA), RBAC. Controller này đơn giản: watch trực tiếp, no cache, no queue. Nhưng **reconcile pattern** giống: watch + compare + act + idempotent.
