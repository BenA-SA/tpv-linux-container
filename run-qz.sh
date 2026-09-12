#!/usr/bin/env bash
# QZ (DIRCON bridge) in a rootless podman container. Verified 2026-09-12.
# Every flag below is load-bearing; see README.md for why.
set -euo pipefail

QZHOME="${QZHOME:-$HOME/.local/share/tpv-qz}"
mkdir -p "$QZHOME/.config/Roberto Viola" "$QZHOME/logs"
[ -f "$QZHOME/.config/Roberto Viola/qDomyos-Zwift.conf" ] \
  || cp "$HOME/.config/Roberto Viola/qDomyos-Zwift.conf" \
        "$QZHOME/.config/Roberto Viola/" 2>/dev/null || true

podman rm -f qz >/dev/null 2>&1 || true
exec podman run --rm --name qz \
  --userns=keep-id \
  --security-opt label=disable \
  --network=host \
  --pid=host \
  -e HOME=/qzhome -w /qzhome/logs \
  -v "$QZHOME:/qzhome" \
  -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket \
  -v /var/run/avahi-daemon:/var/run/avahi-daemon \
  localhost/tpv-qz:test \
  -no-gui -no-virtual-device-bluetooth -name "KICKR CORE AE08"
