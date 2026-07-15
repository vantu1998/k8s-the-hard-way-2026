#!/bin/bash
set -euo pipefail

# Mount overlayfs bằng tay — mô phỏng container image layer
# Usage: sudo ./overlayfs-mount.sh [mount_point]
# Cleanup: sudo ./overlayfs-mount.sh --cleanup

BASE="/tmp/overlay-lab"
MOUNT="${1:-${BASE}/merged}"

if [ "${1}" = "--cleanup" ]; then
    echo "=== Cleanup overlayfs lab ==="
    umount "${BASE}/merged" 2>/dev/null || true
    rm -rf "${BASE}"
    echo "Done."
    exit 0
fi

echo "=== Setting up overlayfs lab at ${BASE} ==="

# Tạo cấu trúc thư mục
mkdir -p "${BASE}/lower" "${BASE}/upper" "${BASE}/work" "${MOUNT}"

# Tạo nội dung lower (giả lập image layer)
echo "base file from image layer" > "${BASE}/lower/base.txt"
mkdir -p "${BASE}/lower/etc"
echo "config from image" > "${BASE}/lower/etc/config.conf"
echo "readme from image" > "${BASE}/lower/README.md"

# Mount overlayfs
mount -t overlay overlay \
    -o "lowerdir=${BASE}/lower,upperdir=${BASE}/upper,workdir=${BASE}/work" \
    "${MOUNT}"

echo "=== OverlayFS mounted at ${MOUNT} ==="
echo "  lowerdir:  ${BASE}/lower (read-only, image layer)"
echo "  upperdir:  ${BASE}/upper (read-write, container write layer)"
echo "  mergeddir: ${MOUNT} (unified view)"
echo ""
echo "Contents of merged:"
ls -la "${MOUNT}"
echo ""
echo "Try:"
echo "  echo 'hello' > ${MOUNT}/new.txt        # write new file → goes to upper"
echo "  echo 'modified' > ${MOUNT}/etc/config.conf  # copy-up from lower to upper"
echo "  rm ${MOUNT}/base.txt                   # whiteout in upper"
echo "  ls -la ${BASE}/upper                    # see upper layer changes"
echo ""
echo "Cleanup: sudo $0 --cleanup"
