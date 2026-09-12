#!/usr/bin/env bash
# Grant the logged-in user access to the Bluetooth adapter's USB node so QEMU
# can pass it through without root. The only step in this harness needing sudo.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

RULE=/etc/udev/rules.d/70-bluetooth-vm-passthrough.rules
cat > "$RULE" <<'RULE_EOF'
# Let the active local session open USB Bluetooth adapters, so a QEMU guest can
# claim one for kernel testing. Intel (8087), Realtek (0bda), Qualcomm (0cf3).
SUBSYSTEM=="usb", ATTR{idVendor}=="8087", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="0cf3", TAG+="uaccess"
RULE_EOF

udevadm control --reload
udevadm trigger --subsystem-match=usb --action=change

echo "Installed $RULE"
echo
for d in /sys/bus/usb/devices/*/; do
  [ -f "$d/idVendor" ] || continue
  case "$(cat "$d/idVendor")" in
    8087|0bda|0cf3)
      b=$(cat "$d/busnum" 2>/dev/null); dv=$(cat "$d/devnum" 2>/dev/null)
      n=$(printf '/dev/bus/usb/%03d/%03d' "$b" "$dv")
      echo "  $n  $(stat -c '%A %U:%G' "$n" 2>/dev/null)" ;;
  esac
done
echo
echo "If the node is still not user-accessible, unplug/replug the adapter"
echo "(internal adapters: the change action above should be enough)."
