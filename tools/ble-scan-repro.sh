#!/usr/bin/env bash
# Capture a self-contained BLE-scan regression report for one kernel.
#
# Run once per kernel you want to compare, as root:
#     sudo ./ble-scan-repro.sh
#
# Produces a timestamped directory plus a tarball containing the environment,
# an HCI trace of a fixed-length LE scan, and the devices actually discovered.
# Attach the tarballs from a good and a bad kernel to the bug report.
set -uo pipefail

SCAN_SECONDS="${SCAN_SECONDS:-30}"
TARGET="${TARGET:-}"          # optional BLE name/MAC you expect to see
OUT="ble-repro-$(uname -r)-$(date -u +%Y%m%dT%H%M%SZ)"

[ "$(id -u)" -eq 0 ] || { echo "Must run as root (btmon needs privileges)." >&2; exit 1; }
command -v btmon >/dev/null || { echo "btmon missing: install bluez (Fedora: bluez)." >&2; exit 1; }

mkdir -p "$OUT"
exec > >(tee "$OUT/console.log") 2>&1

echo "=== BLE scan regression capture ==="
echo "kernel:        $(uname -r)"
echo "scan duration: ${SCAN_SECONDS}s"
[ -n "$TARGET" ] && echo "expected:      $TARGET"
echo

{
  echo "## kernel"
  uname -a
  echo; echo "## cmdline"; cat /proc/cmdline
  echo; echo "## distro"; cat /etc/os-release 2>/dev/null
  echo; echo "## bluez"; bluetoothctl --version 2>/dev/null
  echo; echo "## firmware package"
  (rpm -q linux-firmware || dpkg -l linux-firmware 2>/dev/null) 2>/dev/null
  echo; echo "## adapter (usb)"; lsusb -d 8087: 2>/dev/null; lsusb 2>/dev/null | grep -i bluetooth
  echo; echo "## adapter (sysfs)"
  for h in /sys/class/bluetooth/hci*; do
    [ -e "$h" ] && echo "$(basename "$h") -> $(readlink -f "$h" | sed 's|/sys/devices/||')"
  done
  echo; echo "## modules"; lsmod | grep -E '^(bluetooth|btusb|btintel|btrtl|btmtk) '
  echo; echo "## usb autosuspend for the adapter"
  for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    case "$(cat "$d/idVendor")" in
      8087|0bda|0cf3)
        echo "$(basename "$d") vid=$(cat "$d/idVendor") pid=$(cat "$d/idProduct" 2>/dev/null)" \
             "control=$(cat "$d/power/control" 2>/dev/null)" \
             "status=$(cat "$d/power/runtime_status" 2>/dev/null)" ;;
    esac
  done
  echo; echo "## controller state before scan"; bluetoothctl show 2>/dev/null
  echo; echo "## kernel bluetooth messages this boot"
  journalctl -k -b --no-pager 2>/dev/null | grep -iE 'bluetooth|hci[0-9]|btusb|btintel' | tail -60
} > "$OUT/environment.txt" 2>&1
echo "wrote $OUT/environment.txt"

# The HCI trace is the artefact maintainers need: it shows whether the LE scan
# commands are even issued, what the controller returns, and whether any
# advertising reports come back.
btmon -w "$OUT/btmon.btsnoop" > "$OUT/btmon.txt" 2>&1 &
BTMON_PID=$!
sleep 1

echo "scanning for ${SCAN_SECONDS}s ..."
timeout $((SCAN_SECONDS + 8)) bluetoothctl --timeout "$SCAN_SECONDS" scan on \
  > "$OUT/scan-raw.txt" 2>&1
kill "$BTMON_PID" 2>/dev/null; wait "$BTMON_PID" 2>/dev/null

sed -i 's/\x1b\[[0-9;]*m//g' "$OUT/scan-raw.txt" 2>/dev/null
grep -oE '[0-9A-F]{2}(:[0-9A-F]{2}){5}' "$OUT/scan-raw.txt" | sort -u > "$OUT/devices-seen.txt"
COUNT=$(wc -l < "$OUT/devices-seen.txt")

{
  echo "## distinct devices discovered: $COUNT"
  echo
  echo "## LE advertising reports in the HCI trace"
  grep -cE 'LE Advertising Report|LE Extended Advertising Report' "$OUT/btmon.txt" 2>/dev/null
  echo
  echo "## LE scan commands issued"
  grep -E 'LE Set (Extended )?Scan (Parameters|Enable)' "$OUT/btmon.txt" 2>/dev/null | head -10
  echo
  echo "## command failures / errors in the trace"
  grep -iE 'Status: (?!Success)|error|timeout|unsupported' "$OUT/btmon.txt" 2>/dev/null -P | head -20
} > "$OUT/summary.txt" 2>&1

echo
echo "=== RESULT ==="
echo "distinct devices in ${SCAN_SECONDS}s: $COUNT"
echo "   (this count is the robust metric - a broken scan sees near-zero)"
if [ -n "$TARGET" ]; then
  if grep -qi "$TARGET" "$OUT/scan-raw.txt"; then
    RSSI=$(grep -i -A0 "$TARGET" "$OUT/scan-raw.txt" | grep -oE 'RSSI: .*' | tail -1)
    echo "expected device '$TARGET': SEEN ${RSSI:+($RSSI)}"
  else
    echo "expected device '$TARGET': NOT SEEN"
    echo
    echo "   Absence only means something if this device is KNOWN to be in range."
    echo "   Verify it on a good kernel first, and keep it next to the adapter."
    echo "   A device that is merely asleep or out of range gives the same answer"
    echo "   for the wrong reason."
  fi
fi

tar czf "$OUT.tar.gz" "$OUT"
echo
echo "Attach this to the bug report: $OUT.tar.gz"
echo "Run the same script on a known-good kernel and attach both."
