#!/usr/bin/env bash
# Creates the template WINEPREFIX: win64, Windows 10, DXVK + VKD3D-Proton, and
# the TPV launcher. Runs at image build time as uid 1000.
set -euo pipefail
. /opt/scripts/xvfb-lib.sh

echo "==> wineboot (initialising ${WINEPREFIX})"
wineboot --init
wineserver -w

echo "==> Windows 10 mode"
wine reg add 'HKEY_CURRENT_USER\Software\Wine' /v Version /t REG_SZ /d win10 /f
wineserver -w

echo "==> DXVK"
/opt/dxvk-*/setup_dxvk.sh install --symlink 2>/dev/null \
  || for d in /opt/dxvk-*/x64/*.dll; do
       cp -f "$d" "${WINEPREFIX}/drive_c/windows/system32/"
     done
for d in /opt/dxvk-*/x32/*.dll; do
  cp -f "$d" "${WINEPREFIX}/drive_c/windows/syswow64/" 2>/dev/null || true
done

echo "==> VKD3D-Proton"
/opt/vkd3d-proton-*/setup_vkd3d_proton.sh install --symlink 2>/dev/null \
  || for d in /opt/vkd3d-proton-*/x64/*.dll; do
       cp -f "$d" "${WINEPREFIX}/drive_c/windows/system32/"
     done
wineserver -w

# Native overrides so Wine loads the translation-layer DLLs, not its own.
for dll in d3d11 d3d10core dxgi d3d12 d3d12core d3d9; do
  wine reg add 'HKEY_CURRENT_USER\Software\Wine\DllOverrides' \
    /v "$dll" /t REG_SZ /d native /f >/dev/null 2>&1 || true
done
wineserver -w

echo "==> TPV launcher (Inno Setup; /VERYSILENT - WiX flags are ignored)"
curl -fsSL "${TPV_INSTALLER_URL:-https://virtual.trainingpeaks.com/TPVirtual-Installer_v6.exe}" \
  -o /tmp/TPVirtual-Installer.exe
# Inno needs a display even when silent, and can hang rather than error; a
# timeout keeps the build bounded and the entrypoint retries if this misses.
start_xvfb :99
timeout 900 wine /tmp/TPVirtual-Installer.exe \
  /VERYSILENT /SUPPRESSMSGBOXES /NORESTART '/LOG=C:\tpv-install.log' || true
stop_xvfb
wineserver -w
rm -f /tmp/TPVirtual-Installer.exe

TPV_LAUNCHER="${WINEPREFIX}/drive_c/users/tpv/AppData/Local/TPVirtual/TPVirtual-Launcher.exe"
if [ -f "$TPV_LAUNCHER" ]; then
  echo "==> TPV launcher installed into the image: $(basename "$TPV_LAUNCHER")"
else
  echo "==> WARNING: launcher not present after silent install."
  echo "    Entrypoint will install it on first run. Install log follows:"
  find "${WINEPREFIX}/drive_c" -maxdepth 2 -name 'tpv-install.log' \
    -exec tail -25 {} \; 2>/dev/null || echo "    (no install log written)"
fi
