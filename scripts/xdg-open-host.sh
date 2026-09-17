#!/usr/bin/env bash
# xdg-open for the container: hands links to the host desktop's browser through
# the OpenURI portal on the host session bus (mounted by run-tpv.sh).
set -uo pipefail

URL="${1:-}"
if [ -z "$URL" ]; then
  echo "usage: xdg-open <url>" >&2
  exit 1
fi

case "$URL" in
  http://*|https://*|mailto:*) ;;
  *) echo "==> xdg-open: not forwarding unsupported link: $URL" >&2; exit 1 ;;
esac

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  echo "!! xdg-open: no host session bus; open this link manually: $URL" >&2
  exit 1
fi

if ! ERR=$(gdbus call --session \
      --dest org.freedesktop.portal.Desktop \
      --object-path /org/freedesktop/portal/desktop \
      --method org.freedesktop.portal.OpenURI.OpenURI \
      "" "$URL" "{}" 2>&1 >/dev/null); then
  echo "!! xdg-open: host portal refused ($ERR); open this link manually: $URL" >&2
  exit 1
fi
echo "==> opened in host browser: ${URL%%\?*}" >&2
