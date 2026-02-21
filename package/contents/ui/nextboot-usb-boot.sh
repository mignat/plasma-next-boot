#!/bin/bash
# nextboot-usb-boot.sh
# Creates a temporary EFI boot entry for a USB device and sets it as BootNext.
# Must be run as root (via pkexec).
# Usage: nextboot-usb-boot.sh <disk_path> <part_num> <efi_path> <label>
# Outputs "OK:<bootnum>" on success.
set -euo pipefail

DISK_PATH="$1"
PART_NUM="$2"
EFI_PATH="$3"
LABEL="$4"

PREFIX="NB-USB:"

# Validate inputs
if [[ ! -b "$DISK_PATH" ]]; then
    echo "ERROR: $DISK_PATH is not a block device" >&2
    exit 1
fi

if ! [[ "$PART_NUM" =~ ^[0-9]+$ ]]; then
    echo "ERROR: partition number must be numeric" >&2
    exit 1
fi

# Clean up stale NB-USB: entries from previous runs
STALE=$(efibootmgr | grep -oP "^Boot\K[0-9A-Fa-f]{4}(?=\*?\s+${PREFIX})" || true)
for BOOT_NUM in $STALE; do
    efibootmgr -q -b "$BOOT_NUM" -B 2>/dev/null || true
done

# Save current BootOrder before creating (efibootmgr -c prepends to BootOrder)
ORIG_ORDER=$(efibootmgr | grep -oP "^BootOrder:\s*\K.*" || true)

# Create new boot entry
FULL_LABEL="${PREFIX} ${LABEL}"
OUTPUT=$(efibootmgr -c -d "$DISK_PATH" -p "$PART_NUM" -l "$EFI_PATH" -L "$FULL_LABEL" 2>&1)

# Extract the boot number of our new entry
NEW_BOOT_NUM=$(echo "$OUTPUT" | grep -oP "^Boot\K[0-9A-Fa-f]{4}(?=\*?\s+${PREFIX})" | head -1)

if [[ -z "$NEW_BOOT_NUM" ]]; then
    echo "ERROR: could not determine new boot entry number" >&2
    echo "$OUTPUT" >&2
    exit 1
fi

# Set BootNext (one-shot boot into USB)
efibootmgr -n "$NEW_BOOT_NUM"

# Restore original BootOrder so the USB entry is NOT in the regular boot sequence.
# This ensures BootNext is consumed once, then the system falls back to normal order.
if [[ -n "$ORIG_ORDER" ]]; then
    efibootmgr -q -o "$ORIG_ORDER"
fi

echo "OK:$NEW_BOOT_NUM"
