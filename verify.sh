#!/usr/bin/env bash
# Proves the bridge is actually working, not merely running.
QZHOME="${QZHOME:-$HOME/.local/share/tpv-qz}"
LOG=$(ls -t "$QZHOME/logs"/debug-*.log 2>/dev/null | head -1)

echo "1. backend (want BluezDBus, NOT raw socket):"
grep -Ei 'Bluetoothd:|kernel ATT|raw socket|BluezDBus' "$LOG" 2>/dev/null | head -3

echo "2. trainer connection (want ConnectedState):"
grep -Ei 'ConnectedState|Connection refused' "$LOG" 2>/dev/null | tail -2

echo "3. DIRCON listeners (want 36866 + 36867):"
ss -tlnp 2>/dev/null | grep 3686 || echo "   NOT LISTENING"

echo "4. mDNS advert (must carry a real host LAN address):"
HOSTIPS=$(ip -4 -o addr show scope global \
  | awk '$2!~/^(br-|docker|veth|tailscale)/{print $4}' | cut -d/ -f1)
ADV=$(timeout 12 avahi-browse -rpt _wahoo-fitness-tnp._tcp 2>/dev/null \
  | awk -F';' '/^=/ && $3=="IPv4" {print $8, $9}' | sort -u)
if [ -z "$ADV" ]; then
  echo "   no advert"
else
  echo "$ADV" | while read -r ip port; do
    if echo "$HOSTIPS" | grep -qx "$ip"; then
      echo "   OK   $ip:$port (matches a host LAN address)"
    else
      echo "   BAD  $ip:$port (not a host LAN address - TPV will not reach it)"
    fi
  done
fi

echo "5. ports speak DIRCON (want a frame, not just an open socket):"
IP=$(ip -4 -o addr show scope global | awk '$2!~/^(br-|docker|veth)/{print $4}' | cut -d/ -f1 | head -1)
for p in 36866 36867; do
  printf "   %s:%s -> " "$IP" "$p"
  timeout 6 python3 -c "
import socket,binascii,sys
s=socket.create_connection((sys.argv[1],int(sys.argv[2])),4)
d=s.recv(256); s.close()
print(len(d),'bytes:',binascii.hexlify(d[:16]).decode())
" "$IP" "$p" 2>&1 | tail -1
done

echo "6. TrainingPeaks Hub advert (TPV running; want at least one OK):"
HUBADV=$(timeout 12 avahi-browse -rpt _tpvirtual._tcp 2>/dev/null \
  | awk -F';' '/^=/ && $3=="IPv4" {print $8, $9, $4}' | sort -u)
if [ -z "$HUBADV" ]; then
  echo "   no advert (is TPV running?)"
else
  echo "$HUBADV" | while read -r ip port name; do
    if echo "$HOSTIPS" | grep -qx "$ip"; then
      echo "   OK   $ip:$port $name"
    else
      echo "   BAD  $ip:$port $name (unreachable; harmless if an OK entry exists)"
    fi
  done
fi
