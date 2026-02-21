#!/bin/bash
# nextboot-usb-scan.sh
# Scans removable USB devices for EFI boot files.
# Outputs JSON array to stdout. Requires no root privileges.
# Uses udisksctl for mounting unmounted partitions.
set -euo pipefail

exec python3 << 'PYEOF'
import json, subprocess, sys, os, re

EFI_GPT_TYPE = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
EFI_MBR_TYPE = "0xef"

try:
    lsblk_raw = subprocess.check_output(
        ["lsblk", "-J", "-o",
         "NAME,PATH,TYPE,PARTN,RM,HOTPLUG,TRAN,FSTYPE,MOUNTPOINT,LABEL,PARTTYPE,VENDOR,MODEL"],
        text=True, stderr=subprocess.DEVNULL
    )
    lsblk = json.loads(lsblk_raw)
except Exception:
    print('{"devices":[],"usbBootNums":[]}')
    sys.exit(0)

# Collect existing efibootmgr entries and detect USB-related ones
existing_entries = []   # non-verbose: boot number + name
usb_boot_nums = []      # boot numbers with USB device paths (always hidden from main list)
try:
    # Verbose output to detect USB device paths
    efi_out = subprocess.check_output(
        ["efibootmgr", "-v"], text=True, stderr=subprocess.DEVNULL
    )
    for line in efi_out.splitlines():
        m = re.match(r'^Boot([0-9A-Fa-f]{4})\*?\s+(.+)', line)
        if m:
            boot_num = m.group(1)
            full_text = m.group(2)
            # Extract just the name (before the device path)
            name = full_text.split("\t")[0].strip() if "\t" in full_text else full_text.strip()
            existing_entries.append({"bootNum": boot_num, "name": name})
            # Check if device path contains USB transport
            if "USB(" in full_text or "UsbClass(" in full_text:
                usb_boot_nums.append(boot_num)
            # Also catch our own temporary entries
            if name.lower().startswith("nb-usb:"):
                usb_boot_nums.append(boot_num)
except Exception:
    pass

def find_existing_boot_num(device_name, label):
    """Find a firmware boot entry matching this USB device by name."""
    words = [w.lower() for w in device_name.split() if len(w) >= 3]
    for entry in existing_entries:
        name_lower = entry["name"].lower()
        if name_lower.startswith("nb-usb:"):
            continue
        if words and all(w in name_lower for w in words):
            return entry["bootNum"]
    return ""

results = []

for disk in lsblk.get("blockdevices", []):
    if disk.get("type") != "disk":
        continue
    if not disk.get("rm") and not disk.get("hotplug"):
        continue
    if disk.get("tran") != "usb":
        continue

    vendor = (disk.get("vendor") or "").strip()
    model = (disk.get("model") or "").strip()
    disk_path = disk.get("path", "")

    for part in disk.get("children", []):
        if part.get("type") != "part":
            continue

        parttype = (part.get("parttype") or "").lower()
        if parttype != EFI_GPT_TYPE and parttype != EFI_MBR_TYPE:
            continue

        part_path = part.get("path", "")
        part_num = part.get("partn")
        label = part.get("label") or ""
        mountpoint = part.get("mountpoint")
        we_mounted = False

        # Mount if not already mounted
        if not mountpoint:
            try:
                out = subprocess.check_output(
                    ["udisksctl", "mount", "-b", part_path, "--no-user-interaction"],
                    text=True, stderr=subprocess.STDOUT
                )
                # Parse: "Mounted /dev/sda2 at /run/media/user/LABEL."
                if " at " in out:
                    mountpoint = out.strip().split(" at ")[-1].rstrip(".")
                we_mounted = True
            except (subprocess.CalledProcessError, FileNotFoundError):
                continue

        if not mountpoint or not os.path.isdir(mountpoint):
            continue

        # Scan for EFI boot files
        efi_files = []
        efi_dir = os.path.join(mountpoint, "EFI")

        # Case-insensitive search for EFI directory (FAT32 mounted on Linux)
        if not os.path.isdir(efi_dir):
            for entry in os.listdir(mountpoint):
                if entry.upper() == "EFI" and os.path.isdir(os.path.join(mountpoint, entry)):
                    efi_dir = os.path.join(mountpoint, entry)
                    break

        if os.path.isdir(efi_dir):
            # Check standard removable media fallback path first
            boot_dir = None
            for entry in os.listdir(efi_dir):
                if entry.upper() == "BOOT" and os.path.isdir(os.path.join(efi_dir, entry)):
                    boot_dir = os.path.join(efi_dir, entry)
                    break

            if boot_dir:
                for bootfile in ["BOOTX64.EFI", "BOOTIA32.EFI", "BOOTAA64.EFI"]:
                    for f in os.listdir(boot_dir):
                        if f.upper() == bootfile and os.path.isfile(os.path.join(boot_dir, f)):
                            rel = os.path.relpath(os.path.join(boot_dir, f), mountpoint)
                            efi_path = "\\" + rel.replace("/", "\\")
                            efi_files.append({"path": efi_path, "name": bootfile})
                            break

            # Check for distro-specific loaders under /EFI/*/
            for subdir in sorted(os.listdir(efi_dir)):
                if subdir.upper() == "BOOT":
                    continue
                subdir_full = os.path.join(efi_dir, subdir)
                if not os.path.isdir(subdir_full):
                    continue
                for f in sorted(os.listdir(subdir_full)):
                    if f.lower().endswith(".efi") and os.path.isfile(os.path.join(subdir_full, f)):
                        rel = os.path.relpath(os.path.join(subdir_full, f), mountpoint)
                        efi_path = "\\" + rel.replace("/", "\\")
                        efi_files.append({"path": efi_path, "name": f"{subdir}/{f}"})

        # Unmount if we mounted it
        if we_mounted:
            try:
                subprocess.check_call(
                    ["udisksctl", "unmount", "-b", part_path, "--no-user-interaction"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )
            except (subprocess.CalledProcessError, FileNotFoundError):
                pass

        if efi_files:
            device_name = ""
            if vendor and model:
                device_name = f"{vendor} {model}"
            elif model:
                device_name = model
            elif vendor:
                device_name = vendor
            elif label:
                device_name = label
            else:
                device_name = os.path.basename(disk_path)

            results.append({
                "deviceName": device_name,
                "diskPath": disk_path,
                "partPath": part_path,
                "partNum": part_num,
                "label": label,
                "efiFiles": efi_files,
                "existingBootNum": find_existing_boot_num(device_name, label)
            })

print(json.dumps({"devices": results, "usbBootNums": usb_boot_nums}))
PYEOF
