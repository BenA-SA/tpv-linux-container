#!/usr/bin/env bash
# Build the Fedora guest used to test kernels. Run once. No root needed.
set -euo pipefail
cd "$(dirname "$0")"

IMG_VER="${IMG_VER:-44-1.7}"
IMG_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/${IMG_VER%%-*}/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-${IMG_VER}.x86_64.qcow2"
BASE="base-${IMG_VER}.qcow2"
DISK="guest.qcow2"
DISK_SIZE="${DISK_SIZE:-20G}"

mkdir -p results

if [ ! -f "$BASE" ]; then
  echo "==> downloading Fedora Cloud base (~500MB)"
  curl -fL --progress-bar "$IMG_URL" -o "$BASE.part"
  mv "$BASE.part" "$BASE"
fi

if [ ! -f id_guest ]; then
  echo "==> generating an SSH key for the guest"
  ssh-keygen -q -t ed25519 -N '' -f id_guest -C kernel-test-vm
fi

echo "==> creating $DISK ($DISK_SIZE) from the base image"
rm -f "$DISK"
qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$DISK" "$DISK_SIZE" >/dev/null

# cloud-init: enable SSH, install the tools the capture needs. Kernels are
# installed per-test by test-kernel.sh, not here.
mkdir -p seed
cat > seed/meta-data <<META
instance-id: kernel-test-vm
local-hostname: kernel-test-vm
META
cat > seed/user-data <<USERDATA
#cloud-config
users:
  - name: tester
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat id_guest.pub)
packages:
  - bluez
  - bluez-tools
  - usbutils
package_update: false
runcmd:
  - [ systemctl, enable, --now, bluetooth ]
  - [ touch, /var/lib/cloud-init-finished ]
USERDATA

if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds seed.iso seed/user-data seed/meta-data
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -output seed.iso -volid cidata -joliet -rock seed/user-data seed/meta-data >/dev/null 2>&1
elif command -v xorrisofs >/dev/null 2>&1; then
  xorrisofs -output seed.iso -volid cidata -joliet -rock seed/user-data seed/meta-data >/dev/null 2>&1
else
  echo "Need cloud-localds, genisoimage or xorrisofs to build the cloud-init seed." >&2
  echo "Fedora: sudo dnf install cloud-utils or xorriso" >&2
  exit 1
fi

echo "==> guest built: $DISK"
echo "    first boot will run cloud-init; test-kernel.sh waits for it"
