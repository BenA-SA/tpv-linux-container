#!/usr/bin/env bash
# TPV + QZ in one container. Needs a graphical session on the host.
set -euo pipefail

IMAGE="${IMAGE:-localhost/tpv-full:debian}"
STATE="${STATE:-$HOME/.local/share/tpv-full}"
MODE="${1:-both}"
TRAINER="${QZ_TRAINER:-KICKR CORE AE08}"
HR_BELT="${QZ_HR_BELT:-TRACKR HR 7DC2}"

mkdir -p "$STATE"

if [ "$(pgrep -c -x qdomyos-zwift || true)" -gt 0 ]; then
  echo "QZ already running on the host; refusing to start a second instance." >&2
  echo "Kill it with: kill -9 \$(pgrep -x qdomyos-zwift)" >&2
  exit 1
fi

GPU=()
case "${TPV_GPU:-auto}" in
  nvidia) GPU=(--device nvidia.com/gpu=all --device /dev/dri)
          echo "==> GPU: NVIDIA (forced) - known broken on this laptop:" >&2
          echo "    the Max-Q dGPU has no display outputs, so the swapchain" >&2
          echo "    fails with 'Failed to query present modes: -13'." >&2 ;;
  intel)  GPU=(--device /dev/dri);           echo "==> GPU: Intel (forced)" ;;
  none)   echo "==> GPU: none (llvmpipe; expect it to be unusably slow)" ;;
  auto)
    GPU=(--device /dev/dri)
    echo "==> GPU: /dev/dri (integrated; verified working 2026-09-12)" ;;
esac

AUDIO=()
[ -d /dev/snd ] && AUDIO+=(--device /dev/snd)
[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0" ] \
  && AUDIO+=(-v "${XDG_RUNTIME_DIR}/pipewire-0:${XDG_RUNTIME_DIR}/pipewire-0")

DISPLAY_ARGS=()
if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
  DISPLAY_ARGS=(
    -e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
    -e "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
    -v "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}:${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}"
  )
  echo "==> display: Wayland (${WAYLAND_DISPLAY})"
fi
if [ -n "${DISPLAY:-}" ] && [ -S "/tmp/.X11-unix/X${DISPLAY#*:}" ]; then
  DISPLAY_ARGS+=(-e "DISPLAY=${DISPLAY}" -v /tmp/.X11-unix:/tmp/.X11-unix)
  XAUTH="${XAUTHORITY:-}"
  [ -n "$XAUTH" ] && [ -r "$XAUTH" ] || XAUTH="$HOME/.Xauthority"
  [ -r "$XAUTH" ] || XAUTH=$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
  if [ -n "${XAUTH:-}" ] && [ -r "$XAUTH" ]; then
    DISPLAY_ARGS+=(-e "XAUTHORITY=$XAUTH" -v "$XAUTH:$XAUTH:ro")
    echo "==> display: X11/XWayland (${DISPLAY}), cookie $(basename "$XAUTH")"
  else
    echo "==> WARNING: X socket found but no readable auth cookie." >&2
    echo "    Expect 'Authorization required, but no authorization protocol specified'" >&2
  fi
fi
if [ ${#DISPLAY_ARGS[@]} -eq 0 ]; then
  echo "No Wayland or X socket found. TPV needs a graphical session:" >&2
  echo "Wine dies with 'explorer process failed to start' without one." >&2
  exit 1
fi

TIMEZONE=()
HOST_TZ="${TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || true)}"
[ -n "$HOST_TZ" ] && TIMEZONE+=(-e "TZ=${HOST_TZ}")
[ -e /etc/localtime ] && TIMEZONE+=(-v /etc/localtime:/etc/localtime:ro)
echo "==> timezone: ${HOST_TZ:-host /etc/localtime}"

HOST_LINKS=()
SESSION_BUS="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus"
if [ -S "$SESSION_BUS" ]; then
  HOST_LINKS=(-v "$SESSION_BUS:/run/host-session-bus"
              -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/host-session-bus)
else
  echo "==> WARNING: no session bus; account-linking buttons cannot open a browser" >&2
fi

INHIBIT=()
if [ "$MODE" != qz ] && command -v gnome-session-inhibit >/dev/null; then
  INHIBIT=(gnome-session-inhibit --inhibit idle:suspend
           --reason "TrainingPeaks Virtual running" --app-id tpv)
  echo "==> screen blank/suspend inhibited while the container runs"
fi

podman rm -f tpv >/dev/null 2>&1 || true
exec "${INHIBIT[@]}" podman run --rm --name tpv \
  --userns=keep-id \
  --security-opt label=disable \
  --network=host \
  "${GPU[@]}" "${AUDIO[@]}" \
  "${DISPLAY_ARGS[@]}" \
  "${TIMEZONE[@]}" \
  "${HOST_LINKS[@]}" \
  -e "QZ_TRAINER=${TRAINER}" \
  -e "QZ_HR_BELT=${HR_BELT}" \
  -e "TPV_DIRECT=${TPV_DIRECT:-0}" \
  -v "$STATE:/state" \
  -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket \
  -v /var/run/avahi-daemon:/var/run/avahi-daemon \
  "$IMAGE" "$MODE"
