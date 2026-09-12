# Kernel test VM — bisect a Bluetooth regression without rebooting your host

Passes the real Bluetooth adapter through to a QEMU guest, so you can boot any
kernel against your actual hardware while your host stays up. Guest reboots are
seconds and cost you nothing.

Built for bisecting
[the AX211 LE-scan regression](https://github.com/BenA-SA/tpv-linux-container/issues/1),
but it works for any USB Bluetooth adapter and any Fedora kernel.

## One-time host setup

QEMU needs access to the adapter's USB node, which is root-owned by default.
This is the only step needing root:

```bash
sudo ./host-setup.sh
```

It installs a udev rule granting your login session access to the adapter
(`uaccess`), then re-triggers it. No reboot. Reversible by deleting
`/etc/udev/rules.d/70-bluetooth-vm-passthrough.rules`.

## Build the guest (once)

```bash
./build-guest.sh
```

Downloads the Fedora Cloud base image, grows it, and seeds cloud-init with an
SSH key plus `bluez` and the capture tooling.

## Choosing a test target

The scan needs something that is definitely advertising, because on a broken
kernel "not seen" and "not in range" look identical. Pick a **small BLE device
you can keep next to the adapter**, not the trainer:

```bash
TARGET="Zwift Click" ./test-kernel.sh 7.1.5-201.fc44
```

A Zwift Click, a heart-rate strap or any BLE sensor works, and beats a trainer
for this: it is portable, so you can test indoors, and it wakes on a button press
rather than needing the flywheel spun every 15 minutes.

Verify your chosen target is visible on a **known-good kernel first**. Its
absence proves nothing otherwise.

The harness also reports the **total distinct device count**, which is the more
robust signal — a working scan in a normal house sees several devices, a broken
one sees near-zero regardless of what you were aiming at.

## Test a kernel

```bash
./test-kernel.sh 7.1.4-200.fc44      # known good
./test-kernel.sh 7.1.8-200.fc44      # known bad
./test-kernel.sh 7.1.5-201.fc44      # the one that narrows it
```

Each run boots the guest, installs that kernel from Koji, reboots the *guest*
into it, passes the adapter through, runs `ble-scan-repro.sh`, and copies the
tarball back to `results/`.

## Caveats

- **While the guest holds the adapter, your host has no Bluetooth.** Mouse,
  keyboard and headphones on Bluetooth will drop. Use wired ones for this.
- The guest needs the trainer (or whatever you are scanning for) in range, so
  run this near the device.
- `usb-host` passthrough is faithful for HCI-over-USB, which is what the
  Bluetooth stack drives — but it is still a VM. If a result looks impossible,
  confirm it with one real boot before reporting it upstream.

## Verified

The Koji URL pattern this uses was checked against 7.1.4-200.fc44,
7.1.5-201.fc44 and 7.1.8-200.fc44 (all `kernel`, `kernel-core`,
`kernel-modules` and `kernel-modules-core` RPMs returned HTTP 200), and the
Fedora Cloud base image `Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2` is
present on the mirrors.

The harness itself has **not** yet been run end to end — the VM boot, kernel
install and passthrough path are untested. Treat a surprising result with
suspicion and confirm it with one real boot before reporting it upstream.
