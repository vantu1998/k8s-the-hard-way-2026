#!/bin/bash
set -euo pipefail

# Tạo OCI bundle tối thiểu — rootfs từ busybox + config.json
# Usage: sudo ./create-oci-bundle.sh [bundle_dir] [container_name]
# Example: sudo ./create-oci-bundle.sh /tmp/mycontainer mycontainer

BUNDLE_DIR="${1:-/tmp/mycontainer}"
CONTAINER_NAME="${2:-mycontainer}"
BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Creating OCI bundle at ${BUNDLE_DIR} ==="

# Tạo cấu trúc thư mục
mkdir -p "${BUNDLE_DIR}/rootfs/bin"
mkdir -p "${BUNDLE_DIR}/rootfs/proc" "${BUNDLE_DIR}/rootfs/sys"
mkdir -p "${BUNDLE_DIR}/rootfs/dev" "${BUNDLE_DIR}/rootfs/tmp"
mkdir -p "${BUNDLE_DIR}/rootfs/etc"

# Download busybox
echo "Downloading busybox..."
curl -fsSL "${BUSYBOX_URL}" -o "${BUNDLE_DIR}/rootfs/bin/busybox"
chmod +x "${BUNDLE_DIR}/rootfs/bin/busybox"

# Tạo symlink cho các lệnh phổ biến
cd "${BUNDLE_DIR}/rootfs/bin"
for cmd in sh ls cat echo ps hostname mkdir sleep mount umount env true false pwd id whoami; do
    ln -sf busybox "${cmd}"
done
cd "${SCRIPT_DIR}"

# Tạo /etc/passwd + /etc/group
echo "root:x:0:0:root:/root:/bin/sh" > "${BUNDLE_DIR}/rootfs/etc/passwd"
echo "root:x:0:" > "${BUNDLE_DIR}/rootfs/etc/group"

# Copy config.json template
cp "${SCRIPT_DIR}/minimal-config.json" "${BUNDLE_DIR}/config.json"

# Sửa hostname trong config
if command -v jq &> /dev/null; then
    jq --arg name "${CONTAINER_NAME}" '.hostname = $name' \
       "${BUNDLE_DIR}/config.json" > "${BUNDLE_DIR}/config.json.tmp"
    mv "${BUNDLE_DIR}/config.json.tmp" "${BUNDLE_DIR}/config.json"
fi

echo "=== Bundle created ==="
echo "  Bundle dir: ${BUNDLE_DIR}"
echo "  Container name: ${CONTAINER_NAME}"
echo ""
echo "Run:"
echo "  cd ${BUNDLE_DIR} && sudo runc run ${CONTAINER_NAME}"
echo ""
echo "Or with create + start:"
echo "  cd ${BUNDLE_DIR} && sudo runc create ${CONTAINER_NAME}"
echo "  sudo runc start ${CONTAINER_NAME}"
echo ""
echo "Cleanup:"
echo "  sudo runc delete ${CONTAINER_NAME} 2>/dev/null; rm -rf ${BUNDLE_DIR}"
