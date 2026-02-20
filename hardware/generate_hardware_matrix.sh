#!/usr/bin/env bash
set -euo pipefail

LINUX_INPUT="${1:-}"
WINDOWS_INPUT="${2:-}"
OUTPUT_MD="${3:-out/hardware_support_matrix.md}"
TEMPLATE="${4:-docs/templates/hardware-matrix.template.md}"

pick_first_existing() {
  local pattern file
  local first_match
  for pattern in "$@"; do
    first_match=""
    while IFS= read -r file; do
      if [[ -z "${first_match}" || "${file}" < "${first_match}" ]]; then
        first_match="${file}"
      fi
    done < <(compgen -G "${pattern}" || true)
    if [[ -n "${first_match}" ]]; then
      echo "${first_match}"
      return 0
    fi
  done
  return 1
}

if [[ -z "${LINUX_INPUT}" ]]; then
  LINUX_INPUT="$(pick_first_existing \
    "out/hw_profile_ubuntu*.txt" \
    "out/hw_profile_linux_*.txt" \
    "out/hw_profile_linux.txt" || true)"
fi

if [[ -z "${WINDOWS_INPUT}" ]]; then
  WINDOWS_INPUT="$(pick_first_existing \
    "out/hw_profile_windows_*.txt" \
    "out/hw_profile_windows.txt" || true)"
fi

# Keep readable names in diagnostics/template substitution even when auto-detect fails.
LINUX_INPUT="${LINUX_INPUT:-out/hw_profile_linux.txt}"
WINDOWS_INPUT="${WINDOWS_INPUT:-out/hw_profile_windows.txt}"

mkdir -p "$(dirname "${OUTPUT_MD}")"

if [[ ! -f "${LINUX_INPUT}" && ! -f "${WINDOWS_INPUT}" ]]; then
  echo "No probe inputs found. Expected at least one of:"
  echo "  ${LINUX_INPUT}"
  echo "  ${WINDOWS_INPUT}"
  exit 1
fi

if [[ ! -f "${TEMPLATE}" ]]; then
  echo "Template not found: ${TEMPLATE}"
  exit 1
fi

escape_pipes() {
  echo "$1" | sed 's/|/\\|/g'
}

normalize_value() {
  local value="$1"
  if [[ -z "$(echo "${value}" | tr -d '[:space:]')" ]]; then
    echo "N/A"
  else
    echo "${value}"
  fi
}

section_block() {
  local file="$1"
  local header="$2"

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  awk -v h="${header}" '
    {
      line=$0
      sub(/\r$/, "", line)
    }
    line == "== " h " ==" {in_section=1; next}
    in_section && line ~ /^== .* ==$/ {exit}
    in_section {print line}
  ' "${file}"
}

last_nonempty_line() {
  local text="$1"
  echo "${text}" | awk 'NF {line=$0} END {print line}'
}

first_nonempty_line() {
  local text="$1"
  echo "${text}" | awk 'NF {print; exit}'
}

first_match() {
  local file="$1"
  local pattern="$2"

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  sed 's/\r$//' "${file}" | grep -E -m1 "${pattern}" || true
}

parse_value_after_colon() {
  local line="$1"
  echo "${line}" | sed -E 's/^[^:]+:[[:space:]]*//'
}

section_value_by_key() {
  local file="$1"
  local header="$2"
  local key="$3"
  section_block "${file}" "${header}" | awk -F ':' -v key="${key}" '
    {
      line=$0
      sub(/\r$/, "", line)
    }
    index(line, key) == 1 {
      sub(/^[^:]*:[[:space:]]*/, "", line)
      print line
      exit
    }
  '
}

first_data_row_from_table_section() {
  local file="$1"
  local header="$2"
  section_block "${file}" "${header}" | awk '
    {
      line=$0
      sub(/\r$/, "", line)
    }
    line ~ /^[[:space:]]*$/ {next}
    line ~ /^[[:space:]]*Class[[:space:]]+/ {next}
    line ~ /^[[:space:]]*-+[[:space:]]+/ {next}
    {print line; exit}
  '
}

linux_file_status="missing"
windows_file_status="missing"

if [[ -f "${LINUX_INPUT}" ]]; then
  linux_file_status="present"
fi
if [[ -f "${WINDOWS_INPUT}" ]]; then
  windows_file_status="present"
fi

linux_kernel="N/A"
linux_cpu_model="N/A"
linux_cpu_count="N/A"
linux_fw="N/A"
linux_secure_boot="N/A"
linux_pci="N/A"
linux_usb="N/A"
linux_interrupts="N/A"

if [[ -f "${LINUX_INPUT}" ]]; then
  linux_kernel="$(last_nonempty_line "$(section_block "${LINUX_INPUT}" "Kernel")")"

  cpu_model_line="$(first_match "${LINUX_INPUT}" '^Model name:')"
  if [[ -n "${cpu_model_line}" ]]; then
    linux_cpu_model="$(parse_value_after_colon "${cpu_model_line}")"
  fi

  cpu_count_line="$(first_match "${LINUX_INPUT}" '^CPU\(s\):')"
  if [[ -n "${cpu_count_line}" ]]; then
    linux_cpu_count="$(parse_value_after_colon "${cpu_count_line}")"
  fi

  fw_line="$(first_match "${LINUX_INPUT}" '^UEFI=')"
  if [[ -n "${fw_line}" ]]; then
    linux_fw="${fw_line#UEFI=}"
  fi

  linux_secure_boot="$(last_nonempty_line "$(section_block "${LINUX_INPUT}" "Secure Boot (mokutil)")")"
  linux_pci="$(last_nonempty_line "$(section_block "${LINUX_INPUT}" "PCI (lspci -nn)")")"
  linux_usb="$(last_nonempty_line "$(section_block "${LINUX_INPUT}" "USB (lsusb)")")"
  linux_interrupts="$(last_nonempty_line "$(section_block "${LINUX_INPUT}" "Interrupts (head)")")"
fi

linux_kernel="$(normalize_value "${linux_kernel}")"
linux_cpu_model="$(normalize_value "${linux_cpu_model}")"
linux_cpu_count="$(normalize_value "${linux_cpu_count}")"
linux_fw="$(normalize_value "${linux_fw}")"
linux_secure_boot="$(normalize_value "${linux_secure_boot}")"
linux_pci="$(normalize_value "${linux_pci}")"
linux_usb="$(normalize_value "${linux_usb}")"
linux_interrupts="$(normalize_value "${linux_interrupts}")"

windows_os="N/A"
windows_cpu="N/A"
windows_fw="N/A"
windows_secure_boot="N/A"
windows_pnp="N/A"
windows_input="N/A"
windows_interrupts="N/A"

if [[ -f "${WINDOWS_INPUT}" ]]; then
  windows_os_name="$(section_value_by_key "${WINDOWS_INPUT}" "OS" "OsName")"
  windows_os_version="$(section_value_by_key "${WINDOWS_INPUT}" "OS" "OsVersion")"
  if [[ -n "${windows_os_name}" && -n "${windows_os_version}" ]]; then
    windows_os="${windows_os_name} (${windows_os_version})"
  elif [[ -n "${windows_os_name}" ]]; then
    windows_os="${windows_os_name}"
  else
    windows_os="$(first_nonempty_line "$(section_block "${WINDOWS_INPUT}" "OS")")"
  fi

  windows_cpu_name="$(section_value_by_key "${WINDOWS_INPUT}" "CPU" "Name")"
  windows_cpu_threads="$(section_value_by_key "${WINDOWS_INPUT}" "CPU" "NumberOfLogicalProcessors")"
  if [[ -n "${windows_cpu_name}" && -n "${windows_cpu_threads}" ]]; then
    windows_cpu="${windows_cpu_name} (logical: ${windows_cpu_threads})"
  elif [[ -n "${windows_cpu_name}" ]]; then
    windows_cpu="${windows_cpu_name}"
  else
    windows_cpu="$(first_nonempty_line "$(section_block "${WINDOWS_INPUT}" "CPU")")"
  fi

  windows_fw="$(section_value_by_key "${WINDOWS_INPUT}" "Firmware / BIOS / Board" "FirmwareType")"
  secure_boot_line="$(section_value_by_key "${WINDOWS_INPUT}" "Firmware / BIOS / Board" "SecureBoot")"
  if echo "${secure_boot_line}" | grep -qi 'enabled'; then
    windows_secure_boot="enabled"
  elif echo "${secure_boot_line}" | grep -qi 'disabled'; then
    windows_secure_boot="disabled"
  elif [[ -n "${secure_boot_line}" ]]; then
    windows_secure_boot="${secure_boot_line}"
  fi

  windows_pnp="$(first_data_row_from_table_section "${WINDOWS_INPUT}" "PCI / Display / USB / Input PnP Snapshot")"
  windows_input="$(first_data_row_from_table_section "${WINDOWS_INPUT}" "Keyboard / Mouse devices")"
  windows_interrupts="$(first_nonempty_line "$(section_block "${WINDOWS_INPUT}" "Interrupt Assignment (PnP allocated resources)")")"
fi

windows_os="$(normalize_value "${windows_os}")"
windows_cpu="$(normalize_value "${windows_cpu}")"
windows_fw="$(normalize_value "${windows_fw}")"
windows_secure_boot="$(normalize_value "${windows_secure_boot}")"
windows_pnp="$(normalize_value "${windows_pnp}")"
windows_input="$(normalize_value "${windows_input}")"
windows_interrupts="$(normalize_value "${windows_interrupts}")"

generated_at="$(date -Iseconds)"

matrix_rows=$(cat <<MATRIX
| Probe file status | ${linux_file_status} | ${windows_file_status} | Use both probes for best coverage on WSL2 workflows. |
| Firmware mode | ${linux_fw} | ${windows_fw} | Linux under WSL2 may not expose full host firmware state. |
| Secure Boot | $(escape_pipes "${linux_secure_boot}") | $(escape_pipes "${windows_secure_boot}") | Prefer Windows result for host secure-boot truth. |
| CPU summary | $(escape_pipes "${linux_cpu_model} (CPUs: ${linux_cpu_count})") | $(escape_pipes "${windows_cpu}") | Linux view may reflect virtualized topology in WSL2. |
| PCI visibility | $(escape_pipes "${linux_pci}") | $(escape_pipes "${windows_pnp}") | Windows probe usually has richer PCI/PnP coverage on laptops/desktops. |
| USB/Input visibility | $(escape_pipes "${linux_usb}") | $(escape_pipes "${windows_input}") | Input device classes are typically clearer in Windows PnP output. |
| Interrupt visibility | $(escape_pipes "${linux_interrupts}") | $(escape_pipes "${windows_interrupts}") | Linux gives proc interrupts view; Windows gives allocated IRQ mappings. |
MATRIX
)

linux_highlights=$(cat <<LINUX
- Kernel: $(escape_pipes "${linux_kernel}")
- CPU: $(escape_pipes "${linux_cpu_model}")
- Firmware (WSL2-visible): $(escape_pipes "${linux_fw}")
- Secure Boot section: $(escape_pipes "${linux_secure_boot}")
LINUX
)

windows_highlights=$(cat <<WINDOWS
- OS row: $(escape_pipes "${windows_os}")
- CPU row: $(escape_pipes "${windows_cpu}")
- Firmware type: $(escape_pipes "${windows_fw}")
- Secure Boot: $(escape_pipes "${windows_secure_boot}")
WINDOWS
)

next_actions=$(cat <<ACTIONS
1. Attach this matrix to the PR/issue for hardware validation context.
2. Add one row per tested physical machine in your long-term support matrix doc.
3. For regressions, rerun probes after BIOS/firmware or driver updates and diff reports.
ACTIONS
)

while IFS= read -r line; do
  case "${line}" in
    *__GENERATED_AT__*)
      echo "${line/__GENERATED_AT__/${generated_at}}"
      ;;
    *__LINUX_INPUT__*)
      echo "${line/__LINUX_INPUT__/${LINUX_INPUT}}"
      ;;
    *__WINDOWS_INPUT__*)
      echo "${line/__WINDOWS_INPUT__/${WINDOWS_INPUT}}"
      ;;
    *__MATRIX_ROWS__*)
      printf '%s\n' "${matrix_rows}"
      ;;
    *__LINUX_HIGHLIGHTS__*)
      printf '%s\n' "${linux_highlights}"
      ;;
    *__WINDOWS_HIGHLIGHTS__*)
      printf '%s\n' "${windows_highlights}"
      ;;
    *__NEXT_ACTIONS__*)
      printf '%s\n' "${next_actions}"
      ;;
    *)
      echo "${line}"
      ;;
  esac
done < "${TEMPLATE}" > "${OUTPUT_MD}"

echo "Wrote hardware matrix: ${OUTPUT_MD}"
