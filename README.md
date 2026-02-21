# Next Boot

A KDE Plasma 6 panel widget for selecting an EFI boot entry and rebooting into it with one click.

![Plasma 6](https://img.shields.io/badge/Plasma-6.0+-blue) ![License](https://img.shields.io/badge/License-GPL--3.0-green)

## Features

- Lists all EFI boot entries from `efibootmgr`
- One-click reboot into any entry (sets `BootNext` then reboots)
- **USB boot detection** — scans plugged-in USB drives for EFI bootloader files and shows them in a dedicated section
  - Reuses existing firmware boot entries when available (no extra NVRAM writes)
  - Creates temporary one-shot entries when needed (cleaned up automatically)
  - Hotplug-aware — refreshes on USB plug/unplug events
- Hides stale USB boot entries when the drive is unplugged
- Currently booted entry pinned to the top
- Custom entry names, reordering, and hiding via settings
- Optional confirmation dialog before rebooting
- Auto-hides UEFI OS duplicate entries
- Dynamic popup sizing that fits the content

## Dependencies

- KDE Plasma 6.0+
- `efibootmgr`
- `python3`
- `udisks2` (for `udisksctl` — USB partition mounting without root)
- EFI variables accessible (booted in UEFI mode)

## Install

```bash
git clone https://github.com/mignat/plasma-next-boot.git
cd plasma-next-boot
bash install.sh
```

Then add **Next Boot** to your panel via the Plasma widget selector.

## Uninstall

```bash
kpackagetool6 -t Plasma/Applet -r org.kde.plasma.nextboot
```

## How it works

### EFI boot entries

The widget runs `efibootmgr` to list NVRAM boot entries. When you click an entry, it runs `pkexec efibootmgr -n <bootnum>` to set `BootNext`, then `systemctl reboot`. The system boots into the selected entry once, then reverts to the normal boot order.

### USB boot detection

On panel open (and on hotplug events), a scan script:

1. Uses `lsblk` to find removable USB devices with EFI System Partitions
2. Mounts them temporarily via `udisksctl` if needed
3. Scans for EFI bootloader files (`/EFI/BOOT/BOOTX64.EFI` and distro-specific loaders)
4. Checks `efibootmgr -v` for existing firmware entries matching the USB

If the firmware already created a boot entry for the USB, clicking the device reuses it. Otherwise, a temporary `NB-USB:` entry is created, used for one boot, and cleaned up on the next invocation. The entry is excluded from `BootOrder` so the system never gets stuck booting from USB.

## Configuration

Right-click the widget and select **Configure...** to:

- Rename boot entries with custom display names
- Reorder entries with drag arrows
- Hide entries you don't want to see
- Toggle the confirmation dialog
- Toggle UEFI OS duplicate hiding

## License

GPL-3.0-or-later
