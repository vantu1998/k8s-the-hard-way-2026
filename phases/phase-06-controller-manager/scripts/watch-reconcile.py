#!/usr/bin/env python3
"""
Simple Kubernetes Controller — Watch + Reconcile Loop

Watches a ConfigMap and syncs its data to files on disk.
Demonstrates the core controller pattern used by all Kubernetes controllers.

Usage:
  python3 watch-reconcile.py [configmap_name] [namespace] [output_dir]

Examples:
  python3 watch-reconcile.py
  python3 watch-reconcile.py file-controller-config default /tmp/controller-output

Requirements:
  pip3 install kubernetes
"""

import os
import sys
import time
import logging
from kubernetes import client, watch
from kubernetes.config import load_kube_config, load_incluster_config

# --- Config ---
CONFIGMAP_NAME = sys.argv[1] if len(sys.argv) > 1 else "file-controller-config"
NAMESPACE = sys.argv[2] if len(sys.argv) > 2 else "default"
OUTPUT_DIR = sys.argv[3] if len(sys.argv) > 3 else "/tmp/controller-output"

# --- Logging ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("controller")


def reconcile(cm_data: dict) -> None:
    """
    Reconcile loop — sync ConfigMap data to files.

    Idempotent: running multiple times with same data produces same result.
    Level-triggered: checks current state, not events.
    """
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Create/update files from ConfigMap
    for key, value in cm_data.items():
        filepath = os.path.join(OUTPUT_DIR, key)
        existing = None
        if os.path.exists(filepath):
            with open(filepath, "r") as f:
                existing = f.read()

        if existing != value:
            with open(filepath, "w") as f:
                f.write(value)
            log.info(f"Created/updated: {filepath}")
        else:
            log.debug(f"Unchanged: {filepath}")

    # Delete stale files (not in ConfigMap)
    cm_keys = set(cm_data.keys())
    if os.path.exists(OUTPUT_DIR):
        for filename in os.listdir(OUTPUT_DIR):
            if filename not in cm_keys:
                filepath = os.path.join(OUTPUT_DIR, filename)
                os.remove(filepath)
                log.info(f"Deleted stale: {filepath}")


def fetch_configmap() -> dict:
    """Fetch ConfigMap from API Server (level-triggered read)."""
    api = client.CoreV1Api()
    try:
        cm = api.read_namespaced_config_map(
            name=CONFIGMAP_NAME,
            namespace=NAMESPACE,
        )
        return cm.data or {}
    except client.ApiException as e:
        if e.status == 404:
            log.warning(f"ConfigMap {CONFIGMAP_NAME} not found in {NAMESPACE}")
            return {}
        raise


def initial_sync() -> None:
    """Initial reconcile — fetch current state (level-triggered)."""
    log.info("=== Initial sync ===")
    data = fetch_configmap()
    reconcile(data)
    log.info(f"Synced {len(data)} file(s)")


def watch_loop() -> None:
    """Watch ConfigMap changes — reconcile on every event (edge-triggered)."""
    api = client.CoreV1Api()
    w = watch.Watch()

    log.info(f"=== Watching ConfigMap {NAMESPACE}/{CONFIGMAP_NAME} ===")
    while True:
        try:
            for event in w.stream(
                api.list_namespaced_config_map,
                namespace=NAMESPACE,
                field_selector=f"metadata.name={CONFIGMAP_NAME}",
                timeout_seconds=0,
            ):
                event_type = event["type"]
                cm = event["object"]

                if cm.metadata.name != CONFIGMAP_NAME:
                    continue

                log.info(f"Event: {event_type}")

                if event_type == "DELETED":
                    log.info("ConfigMap deleted — clearing output")
                    reconcile({})
                else:
                    data = cm.data or {}
                    reconcile(data)

        except client.ApiException as e:
            log.error(f"API error: {e}")
            time.sleep(5)
        except KeyboardInterrupt:
            log.info("Shutting down...")
            w.stop()
            sys.exit(0)
        except Exception as e:
            log.error(f"Unexpected error: {e}")
            time.sleep(5)
        finally:
            w.stop()
            log.info("Watch disconnected — reconnecting...")


def load_config() -> None:
    """Load kubeconfig — try local first, then in-cluster."""
    try:
        load_kube_config()
        log.info("Loaded kubeconfig from ~/.kube/config")
    except Exception:
        try:
            load_incluster_config()
            log.info("Loaded in-cluster config")
        except Exception:
            log.error("Cannot load kubeconfig")
            sys.exit(1)


def main() -> None:
    load_config()
    initial_sync()
    watch_loop()


if __name__ == "__main__":
    main()
