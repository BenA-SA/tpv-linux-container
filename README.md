# TrainingPeaks Virtual on Linux, in a container

TrainingPeaks Virtual (TPV) has no Linux build. This repository builds it — plus
the bridge that gets your trainer into it — as a single rootless **podman** image.

**Verified working end to end on 2026-09-12**: a Wahoo KICKR CORE over BLE, into
[qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift) (QZ), re-presented as a
Wahoo Direct Connect device over TCP, consumed by TPV running under Wine — with
resistance commands flowing back down to the trainer.

```
KICKR CORE ──BLE──► QZ ──DIRCON (TCP 36866/36867 + mDNS)──► TPV under Wine
     ▲                                                          │
     └────────────── FTMS resistance / gradient ────────────────┘
```

## Why a bridge at all

Wine cannot do Bluetooth Low Energy. Its WinRT `BluetoothLEAdvertisementWatcher`
is a stub, so a Windows app under Wine cannot talk to a BLE trainer. This is what
blocks Zwift on Linux.

TPV is a much easier target because it supports **Direct Connect (DIRCON)**
natively — trainer data over plain TCP, discovered by mDNS. Both are ordinary
networking that Wine passes straight through to the host. QZ holds the trainer
over BLE on the Linux side and re-presents it as a Wahoo DIRCON device, so TPV
never needs Bluetooth at all.

TPV also ships keyboard virtual shifting (`+` / `-`), so a Zwift Click or similar
proprietary controller is not required either.

## Requirements

- Linux with podman (rootless), an x86_64 host
- A working BLE adapter — **see [Known issues](#known-issues)**, this bit bites
- A GPU that can present a Vulkan swapchain (see the GPU note below)
- An active graphical session. Wine needs a compositor; without one TPV dies with
  `nodrv_CreateWindow ... The explorer process failed to start`
- A DIRCON-capable trainer, or any BLE trainer QZ supports

## Build

```bash
git clone https://github.com/BenA-SA/tpv-linux-container.git
cd tpv-linux-container
podman build -f Containerfile.full -t localhost/tpv-full:debian .
```

Nothing needs to be prebuilt on the host: both Containerfiles compile QZ
themselves from a pinned upstream commit, so a fresh clone is all you need.

Roughly 6.6 GB and 20–40 minutes. It compiles QZ from a pinned commit, installs
Wine 11.0 with DXVK and VKD3D-Proton, and runs the TPV installer silently under a
headless X server.

## Run

```bash
./run-tpv.sh            # QZ, wait for DIRCON, then TPV
./run-tpv.sh qz         # bridge only (headless, no display needed)
./run-tpv.sh tpv        # TPV only
./run-tpv.sh shell      # poke around inside
./verify.sh             # prove the bridge actually works
```

Configure via environment:

| Variable | Default | Purpose |
|---|---|---|
| `QZ_TRAINER` | `KICKR CORE AE08` | BLE name of your trainer |
| `QZ_HR_BELT` | `TRACKR HR 7DC2` | BLE name of your HR strap |
| `TPV_GPU` | `auto` | `intel`, `nvidia`, `none` |
| `STATE` | `~/.local/share/tpv-full` | Where the Wine prefix and game data live |
| `TZ` | host zone (`timedatectl`) | Time zone for TPV's HUD clock; set to override |
| `TPV_NETWORK` | `pasta` | `host` uses host networking (needed for trainers that advertise themselves on the LAN, #13) |
| `TPV_LAN_IF` | default-route interface | The only interface TPV sees under `pasta` |
| `TPV_HUB_ADVERT` | `1` | `0` skips the TrainingPeaks Hub re-advert (see below) |
| `TPV_HUB_ADDR` | default-route IPv4 | Address the Hub app should connect to |
| `TPV_HUB_NAME` | `<hostname> (LAN)` | Name of the re-advertised TPV instance |

`verify.sh` checks the five bridge things that actually matter: the Bluetooth backend
chosen, the trainer connection, the DIRCON listeners, whether the mDNS advert
carries a reachable host address, and whether the ports emit real DIRCON frames
rather than merely accepting sockets.

## State and updates

The image carries a **template** Wine prefix. First run copies it to
`$STATE/wineprefix`, so your TPV login, settings and the ~1.1 GB of downloaded
game data survive rebuilding the image.

Game data is deliberately not baked in: TPV's launcher owns it and self-updates,
and TPV is proprietary. **Do not publish a built image** — see `LICENSE`.

## Known issues

### BLE scanning can stop finding anything — intermittently

This cost hours, and the cause is **still not pinned down**. On an Intel AX211,
BLE discovery can silently return almost nothing while Bluetooth **Classic**
keeps working perfectly. Mouse, keyboard and headphones behave, so the adapter
looks healthy — but no trainer will ever be found.

Symptom check:

```bash
bluetoothctl --timeout 30 scan on | grep -c Device   # near-zero is the symptom
```

What we know: it is **intermittent and state-dependent**, not a property of any
one kernel. A machine that failed repeatedly on 7.1.8-200.fc44 later scanned
fine on that same kernel after a clean reboot. Suspect triggers, none confirmed:
long uptime, connection churn, suspend/resume, or power-cycling the adapter.

Things worth trying, cheapest first:

1. Disable USB autosuspend on the adapter (see below) — a real and separate bug.
2. Reboot. A clean boot has restored it in our testing.
3. Try an older kernel. This helped once, but a single observation either way
   proves little given the intermittency.

[Issue #1](https://github.com/BenA-SA/tpv-linux-container/issues/1) carries the
full investigation, including a code-level suspect
(`e4053143e7dc`, a discovery-state race that would present intermittently) and
the tooling to capture evidence if you hit it.

### USB autosuspend powers the radio down

Intel Bluetooth is a USB device and autosuspend may suspend it after 2 seconds,
which makes scanning unreliable and can leave the adapter reporting
`Powered: no` or scans failing with `org.bluez.Error.NotReady`:

```bash
echo on | sudo tee /sys/bus/usb/devices/<n-n>/power/control
```

Find `<n-n>` by matching `idVendor` `8087` under `/sys/bus/usb/devices/`.

### Discrete GPUs may not be able to present

On a hybrid laptop the dGPU often has no display outputs, so Vulkan swapchain
creation fails with `Failed to query present modes: -13` (`VK_ERROR_UNKNOWN`)
even though the GPU renders fine. Passing `/dev/dri` alongside it is **not**
enough. Use the integrated GPU: `TPV_GPU=intel` (the default).

### TPV refuses to launch its own game binary

Running `InstallData-Win/TPVirtual.exe` directly produces *"must be launched using
the TPVirtual-Launcher"*. The launcher is the only supported entry point, and it
**exits after handing off to the game** — so the entrypoint waits on
`wineserver -w` rather than exec'ing the launcher, otherwise the container would
take the game down with it.

### Stopping QZ does not release the trainer

BlueZ keeps the connection (`Connected: yes`, `Paired: no`) after QZ exits, and a
connected BLE device stops advertising — so another machine cannot see it:

```bash
bluetoothctl disconnect <trainer-mac>
```

### Custom GPX routes show a road at head height

Not a container bug: TPV mis-renders custom routes where two legs run within
~10 m of each other, which covers most out-and-back race courses. See
[docs/custom-route-overlap.md](docs/custom-route-overlap.md) for the cause, a
script that shifts a course a few metres to fix it
(`tools/gpx-separate-legs.py`), and an AI prompt that does the same.

### TrainingPeaks Hub app cannot find TPV

The [Hub companion app](https://help.trainingpeaks.com/hc/en-us/articles/34618989898765-TrainingPeaks-Virtual-Hub-App)
(chat, live stats, and a remote with gear and workout-difficulty buttons) finds
TPV over mDNS (`_tpvirtual._tcp`) and connects in on **TCP 7779**. TPV
advertises an address for **every** interface it can see, and Hub only tries the
first one. If that's a Docker bridge (`172.17.0.1`) or a VPN address the phone
can't reach, Hub shows "start a ride" for the ~127 s TCP connect timeout before
it moves on.

So `run-tpv.sh` runs the container on **pasta networking bound to the LAN
interface** (`TPV_LAN_IF`, by default the one carrying the default route). TPV
then sees only that interface, and `-p 7779:7779` forwards Hub's connection in.
Under pasta, TPV's own advert doesn't reach the phone, so the entrypoint
publishes one through the host's avahi-daemon, pointing at the LAN address.
Measured on cold starts of Hub: ~132 s on host networking with Docker running,
3–4 s under pasta.

Check with `./verify.sh` (check 6) during a ride. Override the address with
`TPV_HUB_ADDR` if the default route is not the network your phone is on.
`TPV_NETWORK=host` restores host networking (for trainers that advertise
themselves on the LAN, see #13). The phone must be on the same subnet, and the host
firewall must allow TCP 7779 and UDP 5353 (Fedora Workstation's default zone
already does).

### Heart rate appears to come from the trainer

If `heart_rate_belt_name` is unset, QZ binds no HR sensor and TPV falls back to
the optional heart-rate field inside FTMS Indoor Bike Data (`0x2AD2`), attributing
it to the trainer. Set `QZ_HR_BELT` and pair `Wahoo HRM` in TPV explicitly.

## Files

| Path | Purpose |
|---|---|
| `Containerfile.full` | TPV + QZ in one image — the one you want |
| `Containerfile.debian` | QZ only, built from source (bridge on a separate host) |
| `patches/` | The QZ root-guard patch, published as GPL requires |
| `scripts/entrypoint.sh` | Mode dispatch, prefix seeding, QZ + TPV startup |
| `scripts/xdg-open-host.sh` | Opens links from TPV in the host browser |
| `scripts/build-prefix.sh` | Builds the template Wine prefix at image build time |
| `run-tpv.sh` | GPU, display and audio wiring for the combined image |
| `run-qz-debian.sh` | Runs the QZ-only image |
| `verify.sh` | End-to-end proof the bridge works |
| `tools/gpx-separate-legs.py` | Finds and fixes overlapping legs in custom GPX routes |
| `docs/` | Longer write-ups of known issues, and decision records |

## Why each podman flag is load-bearing

| Flag | Without it |
|---|---|
| `--userns=keep-id` | Container uid is 0 in its userns, so libdbus `EXTERNAL` auth claims uid 0 while the bus sees the real peer uid via `SO_PEERCRED`. Auth hangs: `Did not receive a reply` |
| `--security-opt label=disable` | SELinux blocks the host D-Bus socket: `Permission denied`. `:z` cannot work — relabelling the host socket is `operation not permitted` |
| `--network=pasta:-i,<LAN if>` | TPV advertises Docker/VPN addresses too, and Hub waits ~127 s on an unreachable one. pasta copies the host's LAN address into the container, so QZ's DIRCON advert still carries a reachable address (the old `--network=host` requirement was about private container addresses) |
| `-p 7779:7779` | Hub can't connect in to TPV under pasta |
| `--hostname` | TPV takes its name from the container ID (e.g. `E04007E15893`) instead of the host |
| writable `HOME` and workdir | QZ spins on failed debug-log writes and never gets past discovery. Looks like a hang |
| D-Bus socket mount | No BlueZ at all: `Cannot find a running Bluez`. Also how the Hub re-advert reaches avahi-daemon |
| Avahi socket mount | No mDNS advert, so TPV never discovers the bridge |
| Session bus mount | Connect Garmin / Strava / TrainingPeaks buttons do nothing: Wine's `xdg-open` has no browser to reach. The image's `xdg-open` forwards links to the host browser through the OpenURI portal |
| `BLUETOOTH_FORCE_DBUS_LE_VERSION` | Qt probes bluetoothd's version by executing its path *inside* the container, where it is absent; the `"4.0"` fallback selects a legacy raw-L2CAP backend that cannot connect |

QZ needs **no root**. Its upstream `getuid()` guard predates QZ reaching BlueZ
over D-Bus; `patches/` removes it. Capabilities cannot satisfy a `getuid()`
check, which is why a patch rather than `--cap-add` is required.

## Scope

This is packaging, not sandboxing. Host networking, host D-Bus (system and session) and host Avahi mean
the container is tightly coupled to the host. What it removes is installing a Qt5
build environment, compiling QZ, and assembling a working Wine prefix by hand.

## Credits

[qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift) by Roberto Viola does
the actual work of speaking to trainers. The container approach follows the
pattern set by [netbrain/zwift](https://github.com/netbrain/zwift).
