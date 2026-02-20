#!/usr/bin/env bash
set -euo pipefail

# Collect a portable hardware profile for MEGOS bare-metal test triage.
# Default output path is ignored by git and can be attached to issue reports.

OUT_PATH="${1:-out/hw_profile.txt}"
declare -a MISSING_COMMANDS=()

register_missing_command() {
    local cmd="$1"
    local seen
    for seen in "${MISSING_COMMANDS[@]}"; do
        if [[ "${seen}" == "${cmd}" ]]; then
            return 0
        fi
    done
    MISSING_COMMANDS+=("${cmd}")
}

command_to_package() {
    case "$1" in
        mokutil) echo "mokutil" ;;
        lspci) echo "pciutils" ;;
        lsusb) echo "usbutils" ;;
        lscpu|lsblk) echo "util-linux" ;;
        *) echo "" ;;
    esac
}

emit_probe_notes() {
    echo "== Probe Notes =="
    if [[ -n "${WSL_INTEROP:-}" ]] || grep -qi "microsoft" /proc/version 2>/dev/null; then
        echo "WSL2 detected: PCI/USB/firmware visibility is virtualized and may be incomplete."
        echo "Use scripts/hardware/hw_probe_windows.ps1 on Windows for host-accurate hardware details."
    fi

    if [[ "${#MISSING_COMMANDS[@]}" -gt 0 ]]; then
        local cmd pkg
        local -a packages=()
        echo "Missing tools:"
        for cmd in "${MISSING_COMMANDS[@]}"; do
            echo "- ${cmd}"
            pkg="$(command_to_package "${cmd}")"
            if [[ -n "${pkg}" ]]; then
                packages+=("${pkg}")
            fi
        done

        if [[ "${#packages[@]}" -gt 0 ]]; then
            local unique_packages
            unique_packages="$(printf '%s\n' "${packages[@]}" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
            echo "Install hint: sudo apt install -y ${unique_packages}"
        fi
    else
        echo "No missing command-line probe tools detected."
    fi
    echo
}

mkdir -p "$(dirname "$OUT_PATH")"

run_or_na() {
    local title="$1"
    shift
    echo "== $title =="
    if command -v "$1" >/dev/null 2>&1; then
        "$@" || true
    else
        echo "N/A (missing command: $1)"
        register_missing_command "$1"
    fi
    echo
}

{
    echo "MEGOS Hardware Probe (Linux)"
    echo "Timestamp: $(date -Iseconds)"
    echo

    run_or_na "Kernel" uname -a

    echo "== OS Release =="
    if [[ -f /etc/os-release ]]; then
        cat /etc/os-release
    else
        echo "N/A (/etc/os-release missing)"
    fi
    echo

    run_or_na "CPU (lscpu)" lscpu
    run_or_na "Block Devices (lsblk)" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL

    echo "== Firmware =="
    if [[ -d /sys/firmware/efi ]]; then
        echo "UEFI=yes"
    else
        echo "UEFI=no"
    fi
    echo

    echo "== DMI =="
    for f in sys_vendor product_name product_version bios_vendor bios_version; do
        local_path="/sys/devices/virtual/dmi/id/$f"
        if [[ -r "$local_path" ]]; then
            printf "%s: " "$f"
            cat "$local_path"
        fi
    done
    echo

    run_or_na "Secure Boot (mokutil)" mokutil --sb-state
    run_or_na "PCI (lspci -nn)" lspci -nn
    run_or_na "USB (lsusb)" lsusb

    echo "== PCI Highlights =="
    if command -v lspci >/dev/null 2>&1; then
        if command -v rg >/dev/null 2>&1; then
            lspci -nn | rg -i "(ISA bridge|LPC|USB|xHCI|VGA|Display|Audio|SMBus|Serial bus controller|I2C|SPI)" || true
        else
            lspci -nn | grep -Ei "(ISA bridge|LPC|USB|xHCI|VGA|Display|Audio|SMBus|Serial bus controller|I2C|SPI)" || true
        fi
    else
        echo "N/A (missing command: lspci)"
        register_missing_command "lspci"
    fi
    echo

    echo "== Interrupts (head) =="
    if [[ -r /proc/interrupts ]]; then
        head -n 120 /proc/interrupts
    else
        echo "N/A (/proc/interrupts unreadable)"
    fi
    echo

    emit_probe_notes
} >"$OUT_PATH"

echo "Wrote hardware profile: $OUT_PATH"
