#!/usr/bin/env bash
# Modes: both (default) | qz | tpv | shell
set -euo pipefail
. /opt/scripts/xvfb-lib.sh

MODE="${1:-both}"
STATE="${TPV_HOME:-/state}"
export WINEPREFIX="$STATE/wineprefix"
export WINEARCH=win64 WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
# The Inno installer delivers the LAUNCHER; the launcher then downloads the
# game into InstallData-Win on first run and self-updates thereafter.
TPV_LAUNCHER="drive_c/users/tpv/AppData/Local/TPVirtual/TPVirtual-Launcher.exe"
TPV_GAME="drive_c/users/tpv/AppData/Local/TPVirtual/InstallData-Win/TPVirtual.exe"

seed_prefix() {
  [ -d "$WINEPREFIX" ] && return 0
  echo "==> first run: seeding prefix from image template into $STATE"
  mkdir -p "$STATE"
  cp -r /opt/tpv/wine-template "$WINEPREFIX"
}

ensure_tpv() {
  [ -f "$WINEPREFIX/$TPV_LAUNCHER" ] && return 0
  echo "==> TPV launcher missing; installing into the prefix"
  curl -fsSL "${TPV_INSTALLER_URL:-https://virtual.trainingpeaks.com/TPVirtual-Installer_v6.exe}" \
    -o /tmp/tpv-installer.exe
  start_xvfb :99
  timeout 900 wine /tmp/tpv-installer.exe \
    /VERYSILENT /SUPPRESSMSGBOXES /NORESTART '/LOG=C:\tpv-install.log' || true
  stop_xvfb
  wineserver -w
  rm -f /tmp/tpv-installer.exe
  if [ ! -f "$WINEPREFIX/$TPV_LAUNCHER" ]; then
    echo "!! TPV launcher still absent. Install log:" >&2
    find "$WINEPREFIX/drive_c" -maxdepth 2 -name 'tpv-install.log' \
      -exec tail -30 {} \; >&2 2>/dev/null
    return 1
  fi
}

start_qz() {
  mkdir -p "$STATE/qz-logs" "$STATE/.config/Roberto Viola"
  CONF="$STATE/.config/Roberto Viola/qDomyos-Zwift.conf"
  if [ ! -f "$CONF" ]; then
    printf '[General]\ndircon_yes=true\nfilter_device=Disabled\n' > "$CONF"
  fi
  # Without a belt name QZ binds no HR sensor, and TPV then takes heart rate
  # from the FTMS Indoor Bike Data field (0x2AD2) and shows it against the
  # trainer instead of the strap.
  if [ -n "${QZ_HR_BELT:-}" ] && ! grep -q '^heart_rate_belt_name=' "$CONF"; then
    sed -i "/^\[General\]/a heart_rate_belt_name=${QZ_HR_BELT}" "$CONF"
    echo "==> configured HR belt: ${QZ_HR_BELT}"
  fi
  echo "==> starting QZ (DIRCON bridge)"
  ( cd "$STATE/qz-logs" && HOME="$STATE" /opt/qz/qdomyos-zwift \
      -no-gui -no-virtual-device-bluetooth ${QZ_TRAINER:+-name "$QZ_TRAINER"} & )
}

wait_for_dircon() {
  echo "==> waiting for DIRCON ports (36866/36867)"
  for _ in $(seq 1 60); do
    if ss -tln 2>/dev/null | grep -q ':36866'; then
      echo "    DIRCON up"; return 0
    fi
    sleep 1
  done
  echo "    WARNING: DIRCON never came up; TPV will find no trainer." >&2
}

sync_timezone() {
  # Wine rewrites TimeZoneKeyName only on a prefix update, so a UTC-era prefix needs wineboot -u.
  local marker="$WINEPREFIX/.tpv-timezone"
  local current
  current="${TZ:-}:$(cksum < /etc/localtime 2>/dev/null || true)"
  [ -f "$marker" ] && [ "$(cat "$marker")" = "$current" ] && return 0
  echo "==> timezone changed (${TZ:-/etc/localtime}); updating the Wine prefix"
  wineboot -u >/dev/null 2>&1 || true
  wineserver -w
  printf '%s' "$current" > "$marker"
}

run_tpv() {
  seed_prefix
  ensure_tpv
  sync_timezone
  # TPV refuses a direct launch of the game exe ("must be launched using the
  # TPVirtual-Launcher"), so the launcher is the only supported path. Do not
  # exec it: it hands off to the game and exits, which would take the
  # container down with it. Wait on wineserver so the game survives.
  if [ "${TPV_DIRECT:-0}" = "1" ] && [ -f "$WINEPREFIX/$TPV_GAME" ]; then
    echo "==> WARNING: TPV_DIRECT=1 is rejected by TPV itself; using the launcher" >&2
  fi
  echo "==> launching TPV launcher"
  wine "$WINEPREFIX/$TPV_LAUNCHER" || true
  echo "==> launcher exited; waiting on any TPV process it started"
  wineserver -w
  echo "==> all wine processes finished"
}

case "$MODE" in
  qz)    start_qz; wait_for_dircon; echo "==> QZ only; Ctrl-C to stop"; wait ;;
  tpv)   run_tpv ;;
  both)  start_qz; wait_for_dircon; run_tpv ;;
  shell) shift || true; [ $# -gt 0 ] && exec /bin/bash "$@"; exec /bin/bash ;;
  *)     echo "usage: {both|qz|tpv|shell}" >&2; exit 2 ;;
esac
