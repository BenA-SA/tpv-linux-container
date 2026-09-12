#!/usr/bin/env bash
# Minimal headless X for Inno Setup, which needs a display even with
# /VERYSILENT. Avoids xvfb-run, which additionally requires xauth.

XVFB_PID=""

start_xvfb() {
  local display="${1:-:99}"
  Xvfb "$display" -screen 0 1280x1024x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
  XVFB_PID=$!
  export DISPLAY="$display"
  for _ in $(seq 1 50); do
    [ -S "/tmp/.X11-unix/X${display#:}" ] && return 0
    kill -0 "$XVFB_PID" 2>/dev/null || { echo "Xvfb died:" >&2; cat /tmp/xvfb.log >&2; return 1; }
    sleep 0.2
  done
  echo "Xvfb did not come up on $display" >&2
  return 1
}

stop_xvfb() {
  [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null || true
  XVFB_PID=""
}
