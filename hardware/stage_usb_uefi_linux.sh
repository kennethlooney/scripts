#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

usage() {
  cat <<'USAGE'
Usage:
  scripts/hardware/stage_usb_uefi_linux.sh --list-drives
  scripts/hardware/stage_usb_uefi_linux.sh --device /dev/sdX1 [--arch x86_64|aarch64] [--force]

Examples:
  scripts/hardware/stage_usb_uefi_linux.sh --list-drives
  scripts/hardware/stage_usb_uefi_linux.sh --device /dev/sdb1 --arch x86_64 --force
USAGE
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

list_drives() {
  require_cmd lsblk
  echo "Candidate removable/USB partitions:"
  lsblk -fp -o PATH,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,RM,TRAN | \
    awk 'NR==1 || ($3=="part" && ($7=="1" || $8=="usb"))'
}

LIST_DRIVES=0
ARCH="x86_64"
DEVICE=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list-drives)
      LIST_DRIVES=1
      shift
      ;;
    --device|-d)
      DEVICE="${2:-}"
      shift 2
      ;;
    --arch)
      ARCH="${2:-}"
      shift 2
      ;;
    --force|-f)
      FORCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${ARCH}" != "x86_64" && "${ARCH}" != "aarch64" ]]; then
  echo "Invalid --arch: ${ARCH} (expected x86_64 or aarch64)" >&2
  exit 1
fi

if [[ "${LIST_DRIVES}" -eq 1 ]]; then
  list_drives
  exit 0
fi

if [[ -z "${DEVICE}" ]]; then
  echo "--device is required unless --list-drives is used." >&2
  usage
  exit 1
fi

if [[ ! -b "${DEVICE}" ]]; then
  echo "Device is not a block device: ${DEVICE}" >&2
  exit 1
fi

require_cmd lsblk
require_cmd sudo
require_cmd mount
require_cmd umount
require_cmd install
require_cmd sync
require_cmd stat

EFI_NAME="BOOTX64.EFI"
if [[ "${ARCH}" == "aarch64" ]]; then
  EFI_NAME="BOOTAA64.EFI"
fi

EFI_SOURCE="${ROOT_DIR}/out/${ARCH}/efi/${EFI_NAME}"
KERNEL_SOURCE="${ROOT_DIR}/out/${ARCH}/megos-kernel.elf"

if [[ ! -f "${EFI_SOURCE}" ]]; then
  echo "Missing EFI artifact: ${EFI_SOURCE}" >&2
  exit 1
fi

if [[ ! -f "${KERNEL_SOURCE}" ]]; then
  echo "Missing kernel artifact: ${KERNEL_SOURCE}" >&2
  exit 1
fi

FS_TYPE="$(lsblk -no FSTYPE "${DEVICE}" | head -n 1 | tr -d '[:space:]')"
if [[ "${FS_TYPE}" != vfat && "${FS_TYPE}" != fat && "${FS_TYPE}" != fat32 ]]; then
  if [[ "${FORCE}" -ne 1 ]]; then
    echo "Device ${DEVICE} filesystem is '${FS_TYPE:-unknown}'. UEFI removable media is most reliable with FAT32/vfat." >&2
    echo "Re-run with --force to continue anyway." >&2
    exit 1
  fi
  echo "Warning: staging to non-FAT filesystem '${FS_TYPE:-unknown}' due to --force." >&2
fi

TARGET_ROOT="$(lsblk -no MOUNTPOINT "${DEVICE}" | sed -n '1p' | xargs)"
MOUNTED_HERE=0

cleanup() {
  if [[ "${MOUNTED_HERE}" -eq 1 ]]; then
    sudo umount "${TARGET_ROOT}"
    rmdir "${TARGET_ROOT}"
  fi
}
trap cleanup EXIT

if [[ -z "${TARGET_ROOT}" ]]; then
  TARGET_ROOT="$(mktemp -d /tmp/megos-usb.XXXXXX)"
  sudo mount "${DEVICE}" "${TARGET_ROOT}"
  MOUNTED_HERE=1
fi

TARGET_EFI_DIR="${TARGET_ROOT}/EFI/BOOT"
TARGET_EFI_PATH="${TARGET_EFI_DIR}/${EFI_NAME}"
TARGET_KERNEL_PATH="${TARGET_ROOT}/megos-kernel.elf"

sudo mkdir -p "${TARGET_EFI_DIR}"
sudo install -m 0644 "${EFI_SOURCE}" "${TARGET_EFI_PATH}"
sudo install -m 0644 "${KERNEL_SOURCE}" "${TARGET_KERNEL_PATH}"
sync

EFI_SIZE="$(sudo stat -c%s "${TARGET_EFI_PATH}")"
KERNEL_SIZE="$(sudo stat -c%s "${TARGET_KERNEL_PATH}")"

echo "Staged MEGOS artifacts to ${DEVICE}"
echo "  ${TARGET_EFI_PATH} (${EFI_SIZE} bytes)"
echo "  ${TARGET_KERNEL_PATH} (${KERNEL_SIZE} bytes)"
echo
echo "Bootable layout:"
echo "  EFI/BOOT/${EFI_NAME}"
echo "  megos-kernel.elf"
