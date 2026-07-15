#!/bin/bash
set -euo pipefail

# Setup 2 network namespace nối bằng veth pair
# Usage: sudo ./setup-netns.sh [ns1_name] [ns2_name] [ns1_ip] [ns2_ip] [prefix]

NS1="${1:-ns1}"
NS2="${2:-ns2}"
IP1="${3:-10.0.0.1}"
IP2="${4:-10.0.0.2}"
PREFIX="${5:-24}"

VETH1="veth-${NS1}"
VETH2="veth-${NS2}"

echo "=== Creating network namespaces: ${NS1}, ${NS2} ==="

# Cleanup nếu đã tồn tại
ip netns del "${NS1}" 2>/dev/null || true
ip netns del "${NS2}" 2>/dev/null || true

# Tạo netns
ip netns add "${NS1}"
ip netns add "${NS2}"

# Tạo veth pair
ip link add "${VETH1}" type veth peer name "${VETH2}"

# Chuyển veth vào netns
ip link set "${VETH1}" netns "${NS1}"
ip link set "${VETH2}" netns "${NS2}"

# Up loopback
ip netns exec "${NS1}" ip link set lo up
ip netns exec "${NS2}" ip link set lo up

# Up veth
ip netns exec "${NS1}" ip link set "${VETH1}" up
ip netns exec "${NS2}" ip link set "${VETH2}" up

# Gán IP
ip netns exec "${NS1}" ip addr add "${IP1}/${PREFIX}" dev "${VETH1}"
ip netns exec "${NS2}" ip addr add "${IP2}/${PREFIX}" dev "${VETH2}"

echo "=== Done ==="
echo "  ${NS1}: ${IP1}/${PREFIX}"
echo "  ${NS2}: ${IP2}/${PREFIX}"
echo ""
echo "Test: sudo ip netns exec ${NS1} ping ${IP2}"
echo "Cleanup: sudo ip netns del ${NS1} && sudo ip netns del ${NS2}"
