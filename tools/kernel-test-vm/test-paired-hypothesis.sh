#!/usr/bin/env bash
# Test whether an active BLE connection breaks LE discovery on a given kernel.
#
# Scans with nothing connected, connects one device, then scans again — both in
# a single guest boot, so the connection is the only variable.
#
#   ./test-paired-hypothesis.sh F4:C4:59:F1:A4:33      # e.g. a Zwift Click
set -euo pipefail
cd "$(dirname "$0")"

PEER="${1:?usage: test-paired-hypothesis.sh <BLE MAC to connect>}"
BT_VID="${BT_VID:-8087}"; BT_PID="${BT_PID:-0033}"
SSH_PORT="${SSH_PORT:-2222}"; MEM="${MEM:-4096}"; CPUS="${CPUS:-4}"
SCAN="${SCAN:-30}"

[ -f guest.qcow2 ] || { echo "Run ./build-guest.sh first." >&2; exit 1; }
NODE=$(lsusb -d "${BT_VID}:${BT_PID}" 2>/dev/null \
       | sed -E 's|Bus ([0-9]+) Device ([0-9]+).*|/dev/bus/usb/\1/\2|')
[ -w "${NODE:-/nonexistent}" ] || { echo "Adapter not present/writable - run sudo ./host-setup.sh" >&2; exit 1; }

SSH="ssh -i id_guest -p $SSH_PORT -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tester@127.0.0.1"

QEMU=$(command -v qemu-kvm || command -v qemu-system-x86_64)
$QEMU -enable-kvm -m "$MEM" -smp "$CPUS" -machine q35 \
  -drive file=guest.qcow2,if=virtio,format=qcow2 \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
  -device virtio-net-pci,netdev=n0 \
  -device qemu-xhci,id=xhci \
  -device usb-host,bus=xhci.0,vendorid=0x${BT_VID},productid=0x${BT_PID} \
  -display none -serial file:serial-hypothesis.log -daemonize -pidfile qemu.pid
trap 'kill "$(cat qemu.pid 2>/dev/null)" 2>/dev/null || true' EXIT

echo "==> waiting for guest ssh"
for _ in $(seq 1 90); do $SSH true 2>/dev/null && break; sleep 5; done
$SSH true 2>/dev/null || { echo "guest did not come up; see serial-hypothesis.log" >&2; exit 1; }
echo "==> guest kernel: $($SSH 'uname -r' 2>/dev/null)"

count_scan() {
  $SSH "sudo timeout $((SCAN + 8)) bluetoothctl --timeout $SCAN scan on 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '[0-9A-F]{2}(:[0-9A-F]{2}){5}' \
        | sort -u | wc -l" 2>/dev/null
}

$SSH 'sudo bluetoothctl power on' >/dev/null 2>&1; sleep 2

echo "==> A: scanning with NOTHING connected"
A=$(count_scan); echo "    devices seen: $A"

echo "==> connecting $PEER"
$SSH "sudo bluetoothctl --timeout 20 scan on >/dev/null 2>&1; \
      sudo bluetoothctl connect $PEER 2>&1 | tail -3" 2>/dev/null | sed 's/^/    /'
CONNECTED=$($SSH "sudo bluetoothctl info $PEER 2>/dev/null | grep -c 'Connected: yes'" 2>/dev/null)
echo "    connected: $CONNECTED (1 = yes)"

echo "==> B: scanning WITH that device connected"
B=$(count_scan); echo "    devices seen: $B"

echo
echo "=== RESULT on $($SSH 'uname -r' 2>/dev/null) ==="
echo "  nothing connected : $A devices"
echo "  one peer connected: $B devices"
if [ "$CONNECTED" != "1" ]; then
  echo "  INCONCLUSIVE - the peer never connected, so B is not a real test."
  echo "  Wake the device (press a button) and retry, or try another MAC."
elif [ "${B:-0}" -lt "${A:-0}" ] && [ "${A:-0}" -gt 2 ]; then
  echo "  SUPPORTS the hypothesis: discovery degraded once a peer was connected."
else
  echo "  DOES NOT support the hypothesis: discovery held up with a peer connected."
fi

$SSH 'sudo poweroff' >/dev/null 2>&1 || true; sleep 5
echo "==> adapter released to the host"
