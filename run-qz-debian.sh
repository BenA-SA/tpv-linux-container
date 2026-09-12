#!/usr/bin/env bash
# QZ DIRCON bridge, rootless podman, Debian image. Every flag is load-bearing;
# see README.md for what breaks without each one.
set -euo pipefail

IMAGE="${IMAGE:-localhost/tpv-qz:debian}"
QZHOME="${QZHOME:-$HOME/.local/share/tpv-qz}"
TRAINER="${TRAINER:-KICKR CORE AE08}"

mkdir -p "$QZHOME/.config/Roberto Viola" "$QZHOME/logs"
CONF="$QZHOME/.config/Roberto Viola/qDomyos-Zwift.conf"
[ -f "$CONF" ] || cp "$HOME/.config/Roberto Viola/qDomyos-Zwift.conf" "$CONF"

if [ "$(pgrep -c -x qdomyos-zwift || true)" -gt 0 ]; then
  echo "QZ is already running; refusing to start a second instance." >&2
  echo "Kill it with: kill -9 \$(pgrep -x qdomyos-zwift)" >&2
  exit 1
fi

podman rm -f qz >/dev/null 2>&1 || true
exec podman run --rm --name qz \
  --userns=keep-id \
  --security-opt label=disable \
  --network=host \
  -e HOME=/qzhome -w /qzhome/logs \
  -v "$QZHOME:/qzhome" \
  -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket \
  -v /var/run/avahi-daemon:/var/run/avahi-daemon \
  "$IMAGE" \
  -no-gui -no-virtual-device-bluetooth -name "$TRAINER"
