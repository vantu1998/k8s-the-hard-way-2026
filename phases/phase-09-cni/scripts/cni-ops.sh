#!/bin/bash
set -euo pipefail

# CNI operations — inspect and debug CNI networking
#
# Usage: ./cni-ops.sh {config|plugins|bridge|veth|ipam|netns|route|arp|policy|test|trace}
#        ./cni-ops.sh veth <pod-name>
#        ./cni-ops.sh netns <pod-name>
#        ./cni-ops.sh route <pod-name>
#        ./cni-ops.sh policy [namespace]
#        ./cni-ops.sh test <source-pod> <dest-ip> [port]
#        ./cni-ops.sh trace <pod-name> <dest-ip>

CNI_DIR="/opt/cni/bin"
CNI_CONFIG_DIR="/etc/cni/net.d"
IPAM_DIR="/var/lib/cni/networks"

ACTION="${1:-info}"
shift || true

case "${ACTION}" in
  config)
    echo "=== CNI Config ==="
    echo "Config dir: ${CNI_CONFIG_DIR}"
    ls -la "${CNI_CONFIG_DIR}/"
    echo ""
    for f in "${CNI_CONFIG_DIR}"/*.conflist "${CNI_CONFIG_DIR}"/*.conf; do
      [ -f "$f" ] || continue
      echo "--- $(basename "$f") ---"
      cat "$f" | jq . 2>/dev/null || cat "$f"
      echo ""
    done
    ;;

  plugins)
    echo "=== CNI Plugins ==="
    echo "Plugin dir: ${CNI_DIR}"
    ls -la "${CNI_DIR}/"
    echo ""
    echo "=== Plugin versions ==="
    for plugin in "${CNI_DIR}"/*; do
      [ -x "$plugin" ] || continue
      echo -n "$(basename "$plugin"): "
      CNI_COMMAND=VERSION CNI_PATH="${CNI_DIR}" "$plugin" 2>/dev/null | jq -r '.cniVersion' 2>/dev/null || echo "N/A"
    done
    ;;

  bridge)
    echo "=== Bridge Interfaces ==="
    ip link show type bridge
    echo ""
    echo "=== Bridge Details ==="
    for br in $(ip -o link show type bridge | awk -F': ' '{print $2}'); do
      echo "--- ${br} ---"
      ip addr show "${br}"
      echo ""
      echo "  Attached veth:"
      bridge link | grep "${br}" | sed 's/^/    /'
      echo ""
      echo "  FDB (MAC table):"
      bridge fdb show br "${br}" | head -10 | sed 's/^/    /'
      echo ""
    done
    ;;

  veth)
    POD_NAME="${1:?Usage: $0 veth <pod-name>}"
    echo "=== Veth for pod: ${POD_NAME} ==="
    SANDBOX_ID=$(sudo crictl pods --name "${POD_NAME}" -q 2>/dev/null | head -1)
    if [ -z "${SANDBOX_ID}" ]; then
      echo "ERROR: Pod not found: ${POD_NAME}"
      exit 1
    fi
    PAUSE_PID=$(sudo crictl inspectp "${SANDBOX_ID}" -o json | jq -r '.info.pid')
    echo "Pause PID: ${PAUSE_PID}"
    echo ""
    echo "Pod eth0:"
    sudo nsenter -n -t "${PAUSE_PID}" ip link show eth0 2>/dev/null
    echo ""
    POD_MAC=$(sudo nsenter -n -t "${PAUSE_PID}" ip link show eth0 2>/dev/null | grep -oP 'link/\K[^ ]+')
    echo "Pod MAC: ${POD_MAC}"
    echo ""
    echo "Host veth (matching MAC):"
    HOST_VETH=$(ip -o link show | grep -B1 "${POD_MAC}" | awk -F': ' '{print $2}' | head -1)
    if [ -n "${HOST_VETH}" ]; then
      ip link show "${HOST_VETH}"
      echo ""
      echo "  Attached to bridge:"
      bridge link | grep "${HOST_VETH}" | sed 's/^/    /'
    else
      echo "  (not found by MAC, listing all veth)"
      ip -o link show type veth | awk -F': ' '{print "    " $2}'
    fi
    ;;

  ipam)
    echo "=== IPAM State ==="
    echo "IPAM dir: ${IPAM_DIR}"
    echo ""
    for net_dir in "${IPAM_DIR}"/*/; do
      [ -d "$net_dir" ] || continue
      echo "--- $(basename "$net_dir") ---"
      echo "  Allocated IPs:"
      ls "$net_dir" | grep -v "last_reserved_ip\|lock" | sed 's/^/    /'
      echo ""
      echo "  Last reserved: $(cat "${net_dir}last_reserved_ip" 2>/dev/null || echo N/A)"
      echo "  Count: $(ls "$net_dir" | grep -v "last_reserved_ip\|lock" | wc -l) IPs allocated"
      echo ""
    done
    echo "=== Node podCIDR ==="
    kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}' 2>/dev/null || echo "kubectl not available"
    ;;

  netns)
    POD_NAME="${1:?Usage: $0 netns <pod-name>}"
    echo "=== Network namespace for: ${POD_NAME} ==="
    SANDBOX_ID=$(sudo crictl pods --name "${POD_NAME}" -q 2>/dev/null | head -1)
    if [ -z "${SANDBOX_ID}" ]; then
      echo "ERROR: Pod not found: ${POD_NAME}"
      exit 1
    fi
    PAUSE_PID=$(sudo crictl inspectp "${SANDBOX_ID}" -o json | jq -r '.info.pid')
    echo "Pause PID: ${PAUSE_PID}"
    echo ""
    echo "=== Interfaces ==="
    sudo nsenter -n -t "${PAUSE_PID}" ip addr
    echo ""
    echo "=== Routes ==="
    sudo nsenter -n -t "${PAUSE_PID}" ip route
    echo ""
    echo "=== ARP ==="
    sudo nsenter -n -t "${PAUSE_PID}" ip neigh
    echo ""
    echo "=== DNS ==="
    sudo nsenter -n -t "${PAUSE_PID}" cat /etc/resolv.conf 2>/dev/null || echo "N/A"
    ;;

  route)
    POD_NAME="${1:?Usage: $0 route <pod-name>}"
    echo "=== Routing for pod: ${POD_NAME} ==="
    SANDBOX_ID=$(sudo crictl pods --name "${POD_NAME}" -q 2>/dev/null | head -1)
    if [ -z "${SANDBOX_ID}" ]; then
      echo "ERROR: Pod not found: ${POD_NAME}"
      exit 1
    fi
    PAUSE_PID=$(sudo crictl inspectp "${SANDBOX_ID}" -o json | jq -r '.info.pid')
    echo "Pod routes:"
    sudo nsenter -n -t "${PAUSE_PID}" ip route
    echo ""
    echo "Node routes:"
    ip route
    echo ""
    echo "Pod IP:"
    sudo crictl inspectp "${SANDBOX_ID}" -o json | jq -r '.status.network.ip'
    ;;

  arp)
    echo "=== Node ARP table ==="
    ip neigh show
    echo ""
    echo "=== Bridge FDB ==="
    for br in $(ip -o link show type bridge | awk -F': ' '{print $2}'); do
      echo "--- ${br} ---"
      bridge fdb show br "${br}" | head -20
    done
    ;;

  policy)
    NAMESPACE="${1:-default}"
    echo "=== NetworkPolicies in namespace: ${NAMESPACE} ==="
    kubectl get networkpolicy -n "${NAMESPACE}" 2>/dev/null || echo "kubectl not available"
    echo ""
    kubectl describe networkpolicy -n "${NAMESPACE}" 2>/dev/null || true
    ;;

  test)
    SRC_POD="${1:?Usage: $0 test <source-pod> <dest-ip> [port]}"
    DEST_IP="${2:?Usage: $0 test <source-pod> <dest-ip> [port]}"
    PORT="${3:-80}"
    echo "=== Test connectivity: ${SRC_POD} → ${DEST_IP}:${PORT} ==="
    echo ""
    echo "--- Ping (ICMP) ---"
    kubectl exec "${SRC_POD}" -- ping -c 3 -W 2 "${DEST_IP}" 2>&1 || echo "Ping failed"
    echo ""
    echo "--- TCP connect (port ${PORT}) ---"
    kubectl exec "${SRC_POD}" -- wget -qO- --timeout=3 "http://${DEST_IP}:${PORT}" 2>&1 | head -5 || echo "TCP connect failed"
    ;;

  trace)
    POD_NAME="${1:?Usage: $0 trace <pod-name> <dest-ip>}"
    DEST_IP="${2:?Usage: $0 trace <pod-name> <dest-ip>}"
    echo "=== Traceroute from ${POD_NAME} to ${DEST_IP} ==="
    kubectl exec "${POD_NAME}" -- traceroute -m 10 -w 2 "${DEST_IP}" 2>&1 || echo "Traceroute failed"
    ;;

  vxlan)
    echo "=== VXLAN interfaces ==="
    ip link show type vxlan 2>/dev/null || echo "No VXLAN interfaces"
    echo ""
    echo "=== VXLAN peers ==="
    for vx in $(ip -o link show type vxlan | awk -F': ' '{print $2}'); do
      echo "--- ${vx} ---"
      bridge fdb show dev "${vx}" 2>/dev/null | head -10
    done
    ;;

  tcpdump)
    POD_NAME="${1:?Usage: $0 tcpdump <pod-name> [filter]}"
    FILTER="${2:-}"
    echo "=== tcpdump for pod: ${POD_NAME} ==="
    SANDBOX_ID=$(sudo crictl pods --name "${POD_NAME}" -q 2>/dev/null | head -1)
    if [ -z "${SANDBOX_ID}" ]; then
      echo "ERROR: Pod not found: ${POD_NAME}"
      exit 1
    fi
    PAUSE_PID=$(sudo crictl inspectp "${SANDBOX_ID}" -o json | jq -r '.info.pid')
    POD_MAC=$(sudo nsenter -n -t "${PAUSE_PID}" ip link show eth0 2>/dev/null | grep -oP 'link/\K[^ ]+')
    HOST_VETH=$(ip -o link show | grep -B1 "${POD_MAC}" | awk -F': ' '{print $2}' | head -1)
    if [ -z "${HOST_VETH}" ]; then
      echo "ERROR: Cannot find host veth for pod ${POD_NAME}"
      exit 1
    fi
    echo "Host veth: ${HOST_VETH}"
    echo "Filter: ${FILTER:-none}"
    echo ""
    if [ -n "${FILTER}" ]; then
      sudo tcpdump -i "${HOST_VETH}" -n "${FILTER}"
    else
      sudo tcpdump -i "${HOST_VETH}" -n
    fi
    ;;

  *)
    echo "Usage: $0 {config|plugins|bridge|veth|ipam|netns|route|arp|policy|test|trace|vxlan|tcpdump}"
    echo ""
    echo "Examples:"
    echo "  $0 config                                 # Show CNI config"
    echo "  $0 plugins                                 # List CNI plugins"
    echo "  $0 bridge                                  # Show bridge interfaces"
    echo "  $0 veth web                                # Find veth for pod 'web'"
    echo "  $0 ipam                                    # Show IPAM allocated IPs"
    echo "  $0 netns web                               # Enter pod network namespace"
    echo "  $0 route web                               # Show pod + node routes"
    echo "  $0 arp                                     # Show ARP + FDB tables"
    echo "  $0 policy default                          # List NetworkPolicies"
    echo "  $0 test client 10.244.1.5 80               # Test connectivity"
    echo "  $0 trace web 10.244.2.3                    # Traceroute from pod"
    echo "  $0 vxlan                                   # Show VXLAN interfaces"
    echo "  $0 tcpdump web 'port 80'                   # tcpdump pod traffic"
    exit 1
    ;;
esac
