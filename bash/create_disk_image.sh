#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./make-uefi-image-mtools.sh myos.img path/to/BOOTX64.EFI
img="${1:-myos.img}"
if [[ $# -lt 2 ]]; then
  echo "ERROR: missing BOOTX64.EFI path"
  echo "Usage: $0 [image-file] path/to/BOOTX64.EFI"
  exit 1
fi

bootx64="$2"

if [[ ! -f "$bootx64" ]]; then
  echo "ERROR: BOOTX64.EFI not found at: $bootx64"
  echo "Pass it explicitly as the second argument, e.g.:"
  echo "  $0 myos.img path/to/BOOTX64.EFI"
  exit 1
fi

# Sizes (MiB)
disk_size_mib="${DISK_MIB:-1024}"   # total image size
esp_size_mib="${ESP_MIB:-256}"      # ESP size

# GPT alignment + offset assumptions
sector_size=512
esp_start_lba=2048                  # matches the pattern in [megos.tar](https://onedrive.live.com/?id=1850d8b0-9f62-445c-a6bd-145de21c9855&cid=b4002edbb4bc0f90&web=1&EntityRepresentationId=9d62b0ee-75e3-451f-89ae-daa093c20324) [6](https://onedrive.live.com/?id=1850d8b0-9f62-445c-a6bd-145de21c9855&cid=b4002edbb4bc0f90&web=1)
esp_offset_bytes=$((esp_start_lba * sector_size))

# On Windows (Git Bash/MSYS/Cygwin), use sgdisk64. Keep Linux on sgdisk.
sgdisk_cmd="sgdisk"
uname_s="$(uname -s | tr -d '\r')"
echo "${uname_s}" | grep -Eq '^(MINGW|MSYS|CYGWIN)' && sgdisk_cmd="sgdisk64"

# 1) Create sparse image file
truncate -s "${disk_size_mib}M" "$img"

# 2) Partition with GPT: ESP (EF00) + data (8300)
"${sgdisk_cmd}" --zap-all "$img" >/dev/null
"${sgdisk_cmd}" --clear \
  --new=1:${esp_start_lba}:+${esp_size_mib}M --typecode=1:EF00 --change-name=1:"EFI System Partition" \
  --new=2:0:0                               --typecode=2:8300 --change-name=2:"MyOS Data" \
  "$img" >/dev/null

# Optional: print partition table
"${sgdisk_cmd}" --print "$img"

# 3) Format the ESP using mtools at an offset into the image.
# mtools supports "-i image@@offset" to access an image starting at a given offset. [1](https://www.gnu.org/software/mtools/manual/html_node/drive-letters.html)
#
# mformat creates an MS-DOS filesystem (FAT). [4](https://www.gnu.org/software/mtools/manual/html_node/mformat.html)[5](https://manpages.ubuntu.com/manpages/bionic/man1/mformat.1.html)
# NOTE: The exact FAT type (FAT16 vs FAT32) can depend on image geometry/options.
# For an ESP, FAT32 is commonly used; tune mformat options if you need strict FAT32.
mformat -i "${img}@@${esp_offset_bytes}" -v ESP ::

# 4) Create the standard UEFI boot directory structure and copy BOOTX64.EFI
mmd   -i "${img}@@${esp_offset_bytes}" ::/EFI
mmd   -i "${img}@@${esp_offset_bytes}" ::/EFI/BOOT

# mcopy copies files to/from an MS-DOS filesystem. [2](https://www.gnu.org/software/mtools/manual/html_node/mcopy.html)[3](https://man.archlinux.org/man/extra/mtools/mcopy.1.en)
mcopy -i "${img}@@${esp_offset_bytes}" -o "${bootx64}" ::/EFI/BOOT/BOOTX64.EFI

echo "OK: wrote ${bootx64} to ${img} ESP at /EFI/BOOT/BOOTX64.EFI"