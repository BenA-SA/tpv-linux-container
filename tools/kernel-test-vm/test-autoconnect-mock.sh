#!/usr/bin/env bash
# Does having auto-connect/background-scan entries break LE discovery?
#
# Mocks the state that paired devices create, WITHOUT any real peer: btmgmt
# add-device puts addresses on the kernel accept list with an auto-connect
# action, which is what makes BlueZ keep passive background scanning alive.
# That is the suspected conflict with active discovery.
#
# Addresses are invented and never present, so nothing can actually connect --
# only the kernel-side machinery is exercised. Fully reversible via del-device.
#
#   ./test-autoconnect-mock.sh              # uses the guest's current kernel
set -euo pipefail
cd "$(dirname "$0")"

BT_VID="${BT_VID:-8087}"; BT_PID="${BT_PID:-0033}"
SSH_PORT="${SSH_PORT:-2222}"; MEM="${MEM:-4096}"; CPUS="${CPUS:-4}"
SCAN="${SCAN:-30}"
MOCKS="${MOCKS:-4}"          # the laptop had 4 paired devices

[ -f guest.qcow2 ] || { echo "Run ./build-guest.sh first." >&2; exit 1; }
NODE=$(lsusb -d "${BT_VID}:${BT_PID}" 2>/dev/null \
       | sed -E 's|Bus ([0-9]+) Device ([0-9]+).*|/dev/bus/usb/\1/\2|')
[ -w "${NODE:-/nonexistent}" ] || { echo "Adapter missing/not writable - sudo ./host-setup.sh" >&2; exit 1; }

SSH="ssh -i id_guest -p $SSH_PORT -o StrictHostKeyChecking=no \
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tester@127.0.0.1"

QEMU=$(command -v qemu-kvm || command -v qemu-system-x86_64)
$QEMU -enable-kvm -m "$MEM" -smp "$CPUS" -machine q35 \
  -drive file=guest.qcow2,if=virtio,format=qcow2 \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
  -device virtio-net-pci,netdev=n0 -device qemu-xhci,id=xhci \
  -device usb-host,bus=xhci.0,vendorid=0x${BT_VID},productid=0x${BT_PID} \
  -display none -serial file:serial-mock.log -daemonize -pidfile qemu.pid
trap 'kill "$(cat qemu.pid 2>/dev/null)" 2>/dev/null || true' EXIT

echo "==> waiting for guest ssh"
for i in $(seq 1 90); do $SSH true 2>/dev/null && break; sleep 5; done
$SSH true 2>/dev/null || { echo "guest did not come up; see serial-mock.log" >&2; exit 1; }
KREL=$($SSH 'uname -r' 2>/dev/null)
echo "==> guest kernel: $KREL"

count_scan() {
  $SSH "sudo timeout $((SCAN + 8)) bluetoothctl --timeout $SCAN scan on 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' | grep -oE '[0-9A-F]{2}(:[0-9A-F]{2}){5}' \
        | sort -u | wc -l" 2>/dev/null
}

$SSH 'sudo bluetoothctl power on' >/dev/null 2>&1; sleep 2

echo "==> A: baseline, no accept-list entries"
A=$(count_scan); echo "    devices seen: $A"

echo "==> adding $MOCKS mock auto-connect entries"
# btmgmt needs --timeout to wait for the reply in non-interactive mode, and
# prints a controller banner regardless, so detect FAILURE rather than success.
ADDED=0
for i in $(seq 1 "$MOCKS"); do
  MAC=$(printf 'DE:AD:BE:EF:00:%02X' "$i")
  OUT=$($SSH "sudo btmgmt --timeout 6 add-device -a 2 -t 1 $MAC 2>&1" 2>/dev/null)
  echo "    $MAC:"; echo "$OUT" | sed 's/^/      /'
  if echo "$OUT" | grep -qiE 'fail|invalid|error|not supported|rejected|busy'; then
    :
  else
    ADDED=$((ADDED+1))
  fi
done
echo "    entries that did not error: $ADDED/$MOCKS"

echo "==> verifying the kernel actually holds them"
VERIFY=$($SSH "sudo cat /sys/kernel/debug/bluetooth/hci0/le_accept_list 2>/dev/null \
               || sudo cat /sys/kernel/debug/bluetooth/hci0/white_list 2>/dev/null \
               || echo NO_DEBUGFS_FILE" 2>/dev/null)
echo "$VERIFY" | sed 's/^/      /'
IN_KERNEL=$(echo "$VERIFY" | grep -ci 'de:ad:be:ef' || true)
echo "    mock addresses visible in the kernel accept list: $IN_KERNEL"

echo "==> B: scanning with mock auto-connect entries present"
B=$(count_scan); echo "    devices seen: $B"

echo "==> removing the mocks"
for i in $(seq 1 "$MOCKS"); do
  MAC=$(printf 'DE:AD:BE:EF:00:%02X' "$i")
  $SSH "sudo btmgmt del-device -t 1 $MAC >/dev/null 2>&1 \
        || sudo btmgmt del-device $MAC >/dev/null 2>&1" 2>/dev/null || true
done

echo "==> C: scanning again after removal (should return to baseline)"
C=$(count_scan); echo "    devices seen: $C"

echo
echo "=== RESULT on $KREL ==="
printf "  A baseline            : %s devices\n" "$A"
printf "  B with mock entries   : %s devices\n" "$B"
printf "  C after removal       : %s devices\n" "$C"
printf "  mocks accepted        : %s/%s (kernel accept list shows %s)\n" "$ADDED" "$MOCKS" "$IN_KERNEL"
if [ "$ADDED" -eq 0 ]; then
  echo "  INCONCLUSIVE - every add-device call errored; the mock never applied."
elif [ "${A:-0}" -le 2 ]; then
  echo "  INCONCLUSIVE - baseline discovery was already near-zero."
elif [ "${B:-0}" -lt "${A:-0}" ] && [ "${C:-0}" -ge "${A:-0}" ]; then
  echo "  SUPPORTS the hypothesis: discovery dropped with the entries and recovered."
elif [ "${B:-0}" -lt "${A:-0}" ]; then
  echo "  PARTIAL: discovery dropped, but did not recover after removal."
else
  echo "  DOES NOT support it: discovery held up with auto-connect entries present."
fi

$SSH 'sudo poweroff' >/dev/null 2>&1 || true; sleep 5
echo "==> adapter released to the host"
