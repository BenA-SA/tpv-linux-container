#!/usr/bin/env bash
# Decide whether commit e4053143e7dc is the cause of broken LE discovery.
#
# That commit only fires when discovery.type == DISCOV_TYPE_INTERLEAVED. So an
# LE-ONLY scan should work on an affected kernel while an INTERLEAVED scan does
# not. Same kernel, same adapter, minutes apart, one variable.
#
#     sudo ./le-vs-interleaved.sh
#
# Run on the BAD kernel. On a good kernel both should find devices.
set -uo pipefail

SECS="${SECS:-25}"
OUT="le-vs-interleaved-$(uname -r)-$(date -u +%Y%m%dT%H%M%SZ)"

[ "$(id -u)" -eq 0 ] || { echo "Must run as root (btmgmt/btmon need privileges)." >&2; exit 1; }
command -v btmgmt >/dev/null || { echo "btmgmt missing (install bluez)." >&2; exit 1; }

mkdir -p "$OUT"
echo "kernel: $(uname -r)"
echo "adapter: $(bluetoothctl show 2>/dev/null | grep -m1 Manufacturer | tr -d '\t')"
echo

run_find() {
  local label="$1"; shift
  command -v btmon >/dev/null && { btmon -w "$OUT/$label.btsnoop" > "$OUT/$label.btmon" 2>&1 & BM=$!; sleep 1; }
  timeout $((SECS + 10)) btmgmt --timeout "$SECS" find "$@" > "$OUT/$label.txt" 2>&1
  [ -n "${BM:-}" ] && { kill "$BM" 2>/dev/null; wait "$BM" 2>/dev/null; BM=""; }
  grep -oE 'dev_found: [0-9A-F:]{17}' "$OUT/$label.txt" 2>/dev/null \
    | awk '{print $2}' | sort -u | tee "$OUT/$label.macs" | wc -l
}

echo "==> A: LE-only scan (btmgmt find -l) - bypasses the interleaved code path"
A=$(run_find le-only -l); echo "    devices: $A"
sleep 3
echo "==> B: interleaved scan (btmgmt find) - the path the commit touches"
B=$(run_find interleaved); echo "    devices: $B"

# The commit's own message shows this signature: scan enabled, then a premature
# Discovering-off before the scan duration elapses.
echo
echo "==> premature 'discovering off' in each trace"
for l in le-only interleaved; do
  n=$(grep -cE 'Discovering.*(off|0x00)' "$OUT/$l.btmon" 2>/dev/null || echo 0)
  printf "    %-12s discovering-off events: %s\n" "$l" "$n"
done

echo
echo "=== RESULT on $(uname -r) ==="
printf "  LE-only      : %s devices\n" "$A"
printf "  interleaved  : %s devices\n" "$B"
if [ "${A:-0}" -gt 2 ] && [ "${B:-0}" -le 1 ]; then
  echo "  CONFIRMS e4053143e7dc: LE-only works, interleaved does not."
elif [ "${A:-0}" -le 1 ] && [ "${B:-0}" -le 1 ]; then
  echo "  BOTH broken - not explained by that commit's INTERLEAVED gate."
elif [ "${A:-0}" -gt 2 ] && [ "${B:-0}" -gt 2 ]; then
  echo "  BOTH work - this kernel is not exhibiting the bug right now."
else
  echo "  AMBIGUOUS - rerun; ambient BLE traffic may be too sparse."
fi

tar czf "$OUT.tar.gz" "$OUT" 2>/dev/null
echo
echo "Artefacts: $OUT.tar.gz"
