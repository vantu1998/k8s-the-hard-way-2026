#!/bin/bash
set -euo pipefail

# crictl operations — debug CRI runtime (containerd)
#
# Usage: ./crictl-ops.sh {pods|ps|images|inspect-sandbox|inspect-container|pull|rmi|stats|info|logs|exec|version}
#        ./crictl-ops.sh inspect-sandbox <pod-name>
#        ./crictl-ops.sh inspect-container <container-name>
#        ./crictl-ops.sh pull <image>
#        ./crictl-ops.sh rmi <image>
#        ./crictl-ops.sh logs <container-id>
#        ./crictl-ops.sh exec <container-id>

SOCKET="${CRI_SOCKET:-unix:///run/containerd/containerd.sock}"
CRICTL="sudo crictl --runtime-endpoint=${SOCKET}"

ACTION="${1:-info}"
shift || true

case "${ACTION}" in
  pods)
    echo "=== Pod Sandboxes ==="
    ${CRICTL} pods "$@"
    ;;

  ps|containers)
    echo "=== Containers ==="
    ${CRICTL} ps -a "$@"
    ;;

  images)
    echo "=== Images ==="
    ${CRICTL} images "$@"
    ;;

  inspect-sandbox|inspectp)
    POD_NAME="${1:?Usage: $0 inspect-sandbox <pod-name-or-id>}"
    echo "=== Inspect Sandbox: ${POD_NAME} ==="
    if [[ "${POD_NAME}" =~ ^[a-f0-9]{20,}$ ]]; then
      ${CRICTL} inspectp "${POD_NAME}"
    else
      SANDBOX_ID=$(${CRICTL} pods --name "${POD_NAME}" -q | head -1)
      if [ -z "${SANDBOX_ID}" ]; then
        echo "ERROR: Sandbox not found: ${POD_NAME}"
        exit 1
      fi
      ${CRICTL} inspectp "${SANDBOX_ID}"
    fi
    ;;

  inspect-container|inspect)
    CONTAINER_ID="${1:?Usage: $0 inspect-container <container-id>}"
    echo "=== Inspect Container: ${CONTAINER_ID} ==="
    ${CRICTL} inspect "${CONTAINER_ID}"
    ;;

  pull)
    IMAGE="${1:?Usage: $0 pull <image>}"
    echo "=== Pull Image: ${IMAGE} ==="
    ${CRICTL} pull "${IMAGE}"
    ;;

  rmi)
    IMAGE="${1:?Usage: $0 rmi <image>}"
    echo "=== Remove Image: ${IMAGE} ==="
    ${CRICTL} rmi "${IMAGE}"
    ;;

  stats)
    echo "=== Container Stats ==="
    ${CRICTL} stats "$@"
    ;;

  statsp)
    echo "=== Sandbox Stats ==="
    ${CRICTL} statsp "$@"
    ;;

  info)
    echo "=== CRI Info ==="
    ${CRICTL} info | jq . 2>/dev/null || ${CRICTL} info
    ;;

  version)
    echo "=== CRI Version ==="
    ${CRICTL} version
    ;;

  logs)
    CONTAINER_ID="${1:?Usage: $0 logs <container-id>}"
    echo "=== Logs: ${CONTAINER_ID} ==="
    ${CRICTL} logs "${CONTAINER_ID}"
    ;;

  exec)
    CONTAINER_ID="${1:?Usage: $0 exec <container-id> [command...]}"
    shift
    ${CRICTL} exec -it "${CONTAINER_ID}" "$@"
    ;;

  stop)
    CONTAINER_ID="${1:?Usage: $0 stop <container-id>}"
    echo "=== Stop Container: ${CONTAINER_ID} ==="
    ${CRICTL} stop "${CONTAINER_ID}"
    ;;

  stopp)
    SANDBOX_ID="${1:?Usage: $0 stopp <sandbox-id>}"
    echo "=== Stop Sandbox: ${SANDBOX_ID} ==="
    ${CRICTL} stopp "${SANDBOX_ID}"
    ;;

  imagefs)
    echo "=== Image Filesystem Info ==="
    ${CRICTL} imagefsinfo | jq . 2>/dev/null || ${CRICTL} imagefsinfo
    ;;

  netns)
    POD_NAME="${1:?Usage: $0 netns <pod-name>}"
    echo "=== Network Namespace for: ${POD_NAME} ==="
    SANDBOX_ID=$(${CRICTL} pods --name "${POD_NAME}" -q | head -1)
    if [ -z "${SANDBOX_ID}" ]; then
      echo "ERROR: Sandbox not found: ${POD_NAME}"
      exit 1
    fi
    PAUSE_PID=$(${CRICTL} inspectp "${SANDBOX_ID}" -o json | jq -r '.info.pid')
    echo "Pause PID: ${PAUSE_PID}"
    echo "Network namespace:"
    sudo ls -la /proc/${PAUSE_PID}/ns/net
    echo ""
    echo "Interfaces:"
    sudo nsenter -n -t "${PAUSE_PID}" ip addr
    echo ""
    echo "Routes:"
    sudo nsenter -n -t "${PAUSE_PID}" ip route
    ;;

  cgroup)
    POD_NAME="${1:?Usage: $0 cgroup <pod-name>}"
    echo "=== Cgroup for: ${POD_NAME} ==="
    SANDBOX_ID=$(${CRICTL} pods --name "${POD_NAME}" -q | head -1)
    if [ -z "${SANDBOX_ID}" ]; then
      echo "ERROR: Sandbox not found: ${POD_NAME}"
      exit 1
    fi
    CGROUP=$(${CRICTL} inspectp "${SANDBOX_ID}" -o json | jq -r '.status.linux.cgroupParent')
    echo "Cgroup parent: ${CGROUP}"
    if [ -d "/sys/fs/cgroup${CGROUP}" ]; then
      echo ""
      echo "CPU limit:"
      sudo cat "/sys/fs/cgroup${CGROUP}/cpu.max" 2>/dev/null || echo "N/A"
      echo ""
      echo "Memory limit:"
      sudo cat "/sys/fs/cgroup${CGROUP}/memory.max" 2>/dev/null || echo "N/A"
    fi
    ;;

  *)
    echo "Usage: $0 {pods|ps|images|inspect-sandbox|inspect-container|pull|rmi|stats|statsp|info|version|logs|exec|stop|stopp|imagefs|netns|cgroup}"
    echo ""
    echo "Examples:"
    echo "  $0 pods                                    # List all sandboxes"
    echo "  $0 ps                                      # List all containers"
    echo "  $0 images                                  # List all images"
    echo "  $0 inspect-sandbox web                     # Inspect sandbox by pod name"
    echo "  $0 inspect-container abc123                # Inspect container by ID"
    echo "  $0 pull nginx:1.25                         # Pull image"
    echo "  $0 rmi nginx:1.25                          # Remove image"
    echo "  $0 stats                                   # Container resource stats"
    echo "  $0 info                                    # CRI runtime info"
    echo "  $0 logs abc123                             # Container logs"
    echo "  $0 exec abc123 /bin/sh                     # Exec in container"
    echo "  $0 netns web                               # Enter network namespace"
    echo "  $0 cgroup web                              # Show cgroup limits"
    exit 1
    ;;
esac
