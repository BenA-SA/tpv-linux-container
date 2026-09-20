#!/usr/bin/env bash
# Boot the guest on a given Fedora kernel NVR, with the real Bluetooth adapter
# passed through, and capture a BLE scan report. No host reboot.
#
#   ./test-kernel.sh 7.1.8-200.fc44
set -euo pipefail
cd "$(dirname "$0")"

NVR="${1:?usage: test-kernel.sh <kernel-nvr, e.g. 7.1.8-200.fc44>}"
BT_VID="${BT_VID:-8087}"
BT_PID="${BT_PID:-0033}"
TARGET="${TARGET:-KICKR}"
SSH_PORT="${SSH_PORT:-2222}"
MEM="${MEM:-4096}"
CPUS="${CPUS:-4}"

[ -f guest.qcow2 ] || { echo "Run ./build-guest.sh first." >&2; exit 1; }

NODE=$(lsusb -d "${BT_VID}:${BT_PID}" 2>/dev/null \
       | sed -E 's|Bus ([0-9]+) Device ([0-9]+).*|/dev/bus/usb/\1/\2|')
[ -n "$NODE" ] || { echo "Adapter ${BT_VID}:${BT_PID} not found on the host." >&2; exit 1; }
if [ ! -w "$NODE" ]; then
  echo "$NODE is not writable by you - run 'sudo ./host-setup.sh' first." >&2
  exit 1
fi

SSH="ssh -i id_guest -p $SSH_PORT -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tester@127.0.0.1"

echo "==> your host is about to lose this Bluetooth adapter to the guest"
QEMU=$(command -v qemu-kvm || command -v qemu-system-x86_64)
$QEMU \
  -enable-kvm -m "$MEM" -smp "$CPUS" -machine q35 \
  -drive file=guest.qcow2,if=virtio,format=qcow2 \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
  -device virtio-net-pci,netdev=n0 \
  -device qemu-xhci,id=xhci \
  -device usb-host,bus=xhci.0,vendorid=0x${BT_VID},productid=0x${BT_PID} \
  -display none -serial file:serial-$NVR.log -daemonize \
  -pidfile qemu.pid
QPID=$(cat qemu.pid)
trap 'kill '"$QPID"' 2>/dev/null || true' EXIT

echo "==> waiting for the guest to accept ssh"
for _ in $(seq 1 90); do $SSH true 2>/dev/null && break; sleep 5; done
$SSH true 2>/dev/null || { echo "guest never came up; see serial-$NVR.log" >&2; exit 1; }

echo "==> waiting for cloud-init"
$SSH 'until [ -f /var/lib/cloud-init-finished ]; do sleep 5; done' 2>/dev/null || true

RUNNING=$($SSH 'uname -r' 2>/dev/null)
if [ "$RUNNING" != "${NVR}.x86_64" ]; then
  echo "==> installing kernel-$NVR from Koji (guest is on $RUNNING)"
  $SSH "sudo dnf install -y --nogpgcheck \
    https://kojipkgs.fedoraproject.org/packages/kernel/${NVR%%-*}/${NVR#*-}/x86_64/kernel-core-${NVR}.x86_64.rpm \
    https://kojipkgs.fedoraproject.org/packages/kernel/${NVR%%-*}/${NVR#*-}/x86_64/kernel-modules-core-${NVR}.x86_64.rpm \
    https://kojipkgs.fedoraproject.org/packages/kernel/${NVR%%-*}/${NVR#*-}/x86_64/kernel-modules-${NVR}.x86_64.rpm \
    https://kojipkgs.fedoraproject.org/packages/kernel/${NVR%%-*}/${NVR#*-}/x86_64/kernel-${NVR}.x86_64.rpm" \
    || { echo "kernel install failed - check the NVR exists in Koji" >&2; exit 1; }
  $SSH "sudo grubby --set-default /boot/vmlinuz-${NVR}.x86_64 && sudo reboot" 2>/dev/null || true
  echo "==> guest rebooting into $NVR"
  sleep 20
  for _ in $(seq 1 90); do $SSH true 2>/dev/null && break; sleep 5; done
  RUNNING=$($SSH 'uname -r' 2>/dev/null)
fi

echo "==> guest kernel: $RUNNING"
[ "$RUNNING" = "${NVR}.x86_64" ] || echo "    WARNING: wanted ${NVR}.x86_64"

echo "==> running the capture (adapter must be in range of $TARGET)"
scp -q -i id_guest -P "$SSH_PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null ../ble-scan-repro.sh tester@127.0.0.1:/tmp/ 2>/dev/null
$SSH "chmod +x /tmp/ble-scan-repro.sh && cd /tmp && sudo TARGET='$TARGET' ./ble-scan-repro.sh" 2>&1 \
  | sed 's/^/    /'

mkdir -p results
scp -q -i id_guest -P "$SSH_PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null 'tester@127.0.0.1:/tmp/ble-repro-*.tar.gz' results/ 2>/dev/null || true

$SSH 'sudo poweroff' 2>/dev/null || true
sleep 5

echo
echo "==> results in results/ :"
ls -1 results/ | sed 's/^/    /'
echo "==> your host's Bluetooth adapter is released"
