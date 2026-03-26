#!/bin/bash
# validate_host.sh — XCENA host environment validation
#
# Non-destructive, read-only diagnostic script for real hardware (mx1p) hosts.
# Collects system info and checks component status without modifying anything.
#
# Usage:
#   bash validate_host.sh
#   bash validate_host.sh 2>&1 | tee validate.log

# ---------------------------------------------------------------------------
# Color setup (auto-disable when piped)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_GREEN='\033[32m'
    C_RED='\033[31m'
    C_YELLOW='\033[33m'
    C_CYAN='\033[36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_GREEN='' C_RED='' C_YELLOW='' C_CYAN='' C_BOLD='' C_DIM='' C_RESET=''
fi

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
ok_count=0
warn_count=0
fail_count=0
info_count=0

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------
ok()   { printf "  ${C_GREEN}%-8s${C_RESET} %s\n" "[  OK  ]" "$*"; ((ok_count++)); }
warn() { printf "  ${C_YELLOW}%-8s${C_RESET} %s\n" "[ WARN ]" "$*"; ((warn_count++)); }
fail() { printf "  ${C_RED}%-8s${C_RESET} %s\n" "[ FAIL ]" "$*"; ((fail_count++)); }
info() { printf "  ${C_DIM}%-8s${C_RESET} %s\n" "[ INFO ]" "$*"; ((info_count++)); }
detail() { printf "           ${C_DIM}%s${C_RESET}\n" "$*"; }

section() {
    printf "\n${C_BOLD}--- %s ${C_RESET}${C_DIM}%s${C_RESET}\n" "$1" "$(printf '%0.s-' $(seq 1 $((40 - ${#1}))))"
}

check_cmd() { command -v "$1" >/dev/null 2>&1; }

human_size() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -le 0 ] 2>/dev/null; then
        echo "0B"
        return
    fi
    if [ "$bytes" -ge 1073741824 ]; then
        local gb=$((bytes / 1073741824))
        local rem=$(( (bytes % 1073741824) * 10 / 1073741824 ))
        printf "%d.%d GB" "$gb" "$rem"
    elif [ "$bytes" -ge 1048576 ]; then
        local mb=$((bytes / 1048576))
        local rem=$(( (bytes % 1048576) * 10 / 1048576 ))
        printf "%d.%d MB" "$mb" "$rem"
    elif [ "$bytes" -ge 1024 ]; then
        local kb=$((bytes / 1024))
        local rem=$(( (bytes % 1024) * 10 / 1024 ))
        printf "%d.%d KB" "$kb" "$rem"
    else
        printf "%d B" "$bytes"
    fi
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
printf "\n${C_BOLD}  XCENA Host Environment Validation${C_RESET}\n"
printf "  %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"

# ===========================================================================
# 1. System Environment
# ===========================================================================
check_system() {
    section "System Environment"

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        info "OS            ${PRETTY_NAME:-unknown}"
    elif check_cmd lsb_release; then
        info "OS            $(lsb_release -ds 2>/dev/null)"
    else
        info "OS            unknown"
    fi

    info "Kernel        $(uname -r)"

    if [ "${IN_DOCKER:-0}" -eq 1 ] 2>/dev/null || [ -f /.dockerenv ]; then
        info "Environment   Docker"
    else
        info "Environment   Native"
    fi
}

# ===========================================================================
# 2. PCI / Hardware Detection
# ===========================================================================
check_pci() {
    section "PCI / Hardware"

    local pcie_vendor_id="20a6"

    if ! check_cmd lspci; then
        warn "lspci not found (install pciutils)"
        return
    fi

    local pci_lines
    pci_lines="$(lspci -nn -d "${pcie_vendor_id}:" 2>/dev/null)" || true

    if [ -z "$pci_lines" ]; then
        fail "No XCENA PCI device detected (vendor ${pcie_vendor_id})"
        return
    fi

    local device_count
    device_count="$(echo "$pci_lines" | wc -l)"
    ok "XCENA PCI device detected"

    while IFS= read -r line; do
        detail "$line"
    done <<< "$pci_lines"
}

# ===========================================================================
# 3. Driver
# ===========================================================================
check_driver() {
    section "Driver"

    local mod_line
    mod_line="$(lsmod 2>/dev/null | grep '^mx_dma ')" || true

    if [ -z "$mod_line" ]; then
        fail "mx_dma module not loaded"
    else
        ok "mx_dma module loaded"
    fi

    if [ ! -d /dev/mx_dma ]; then
        fail "/dev/mx_dma/ directory not found"
    else
        local dev_count=0
        dev_count="$(ls /dev/mx_dma/ 2>/dev/null | wc -l)" || true

        if [ "$dev_count" -eq 0 ]; then
            fail "/dev/mx_dma/ is empty"
        else
            ok "/dev/mx_dma/ devices found"
        fi
    fi

    local bad_perms=0
    for devf in /dev/mx_dma/mx_dma*; do
        [ -e "$devf" ] || continue
        if [ ! -r "$devf" ]; then
            bad_perms=1
            break
        fi
    done
    if [ "$bad_perms" -eq 1 ]; then
        warn "Some /dev/mx_dma/ files are not readable by current user"
    elif ls /dev/mx_dma/mx_dma* >/dev/null 2>&1; then
        ok "/dev/mx_dma/ device permissions OK"
    fi
}

# ===========================================================================
# 4. CXL / DAX
# ===========================================================================
check_cxl_dax() {
    section "CXL / DAX"

    if check_cmd cxl; then
        ok "cxl command found"
    else
        warn "cxl command not found (install ndctl/cxl-cli)"
    fi

    if check_cmd daxctl; then
        ok "daxctl command found"
    else
        warn "daxctl command not found (install daxctl)"
    fi

    if [ -f /sys/firmware/acpi/tables/CEDT ]; then
        ok "CEDT ACPI table present"
    else
        info "CEDT ACPI table not found"
    fi

    local cxl_mods
    cxl_mods="$(lsmod 2>/dev/null | grep '^cxl' | awk '{print $1}' | sort)" || true
    if [ -z "$cxl_mods" ]; then
        warn "No CXL kernel modules loaded"
    else
        local cxl_mod_count
        cxl_mod_count="$(echo "$cxl_mods" | wc -l)"
        ok "CXL kernel modules loaded"
    fi

    if check_cmd cxl; then
        local cxl_regions
        cxl_regions="$(cxl list -R 2>/dev/null)" || true
        if [ -z "$cxl_regions" ] || [ "$cxl_regions" = "[]" ]; then
            fail "No CXL regions found (cxl list -R)"
        else
            ok "CXL region detected"
            if check_cmd jq; then
                echo "$cxl_regions" | jq -c '.[]' 2>/dev/null | while IFS= read -r r; do
                    local rname rsize rtype rstate
                    rname="$(echo "$r" | jq -r '.region' 2>/dev/null)"
                    rsize="$(echo "$r" | jq -r '.size' 2>/dev/null)"
                    rtype="$(echo "$r" | jq -r '.type' 2>/dev/null)"
                    rstate="$(echo "$r" | jq -r '.decode_state' 2>/dev/null)"
                    detail "$rname  size=$(human_size "$rsize")  type=$rtype  state=$rstate"
                done
            fi
        fi
    fi

    local dax_devs
    dax_devs="$(ls /dev/dax* 2>/dev/null)" || true
    if [ -z "$dax_devs" ]; then
        fail "No DAX device found (/dev/dax*)"
    else
        local dax_count
        dax_count="$(echo "$dax_devs" | wc -l)"
        ok "DAX device found"

        # Collect daxctl info into associative array for merging
        local daxctl_out=""
        if check_cmd daxctl; then
            daxctl_out="$(daxctl list 2>/dev/null)" || true
        fi

        local has_non_devdax=0
        while IFS= read -r dax_dev; do
            [ -e "$dax_dev" ] || continue
            local dax_name perm dsize dmode
            dax_name="$(basename "$dax_dev")"
            perm="$(stat -c '%a' "$dax_dev" 2>/dev/null)" || true
            dsize="" dmode=""
            if [ -n "$daxctl_out" ] && check_cmd jq; then
                dsize="$(echo "$daxctl_out" | jq -r ".[] | select(.chardev==\"$dax_name\") | .size" 2>/dev/null)" || true
                dmode="$(echo "$daxctl_out" | jq -r ".[] | select(.chardev==\"$dax_name\") | .mode" 2>/dev/null)" || true
            fi
            local line="$dax_name  perm=$perm"
            [ -n "$dsize" ] && line="$line  size=$(human_size "$dsize")"
            [ -n "$dmode" ] && line="$line  mode=$dmode"
            detail "$line"
            if [ -n "$dmode" ] && [ "$dmode" != "devdax" ]; then
                has_non_devdax=1
            fi
        done <<< "$dax_devs"

        if [ "$has_non_devdax" -eq 1 ]; then
            warn "CXL device is not in devdax mode. devdax mode is required for computing."
            detail "To fix: sudo daxctl reconfigure-device --mode=devdax <dax_device>"
            detail "Then:   sudo systemctl restart pxl_resourced"
        fi
    fi
}

# ===========================================================================
# 5. PXL Library
# ===========================================================================
check_pxl() {
    section "PXL Library"

    local pxl_installed
    pxl_installed="$(dpkg -l 2>/dev/null | grep 'libpxl')" || true
    if [ -z "$pxl_installed" ]; then
        fail "libpxl package not installed"
    else
        local pxl_ver
        pxl_ver="$(dpkg-query -W -f='${Version}' libpxl 2>/dev/null)" || true
        ok "libpxl installed (v${pxl_ver:-unknown})"
    fi

    if check_cmd systemctl; then
        local svc_active
        svc_active="$(systemctl is-active pxl_resourced 2>/dev/null)" || true
        if [ "$svc_active" = "active" ]; then
            ok "pxl_resourced service active"
        else
            fail "pxl_resourced service not active (${svc_active:-unknown})"
        fi

        local svc_enabled
        svc_enabled="$(systemctl is-enabled pxl_resourced 2>/dev/null)" || true
        if [ "$svc_enabled" = "enabled" ]; then
            ok "pxl_resourced service enabled"
        else
            warn "pxl_resourced service not enabled (${svc_enabled:-unknown})"
        fi
    else
        info "systemctl not available, skipping service checks"
    fi
}

# ===========================================================================
# 6. CLI & Tools
# ===========================================================================
check_cli_tools() {
    section "CLI & Tools"

    if ! check_cmd xcena_cli; then
        fail "xcena_cli not found in PATH"
    else
        ok "xcena_cli found"

        local num_out
        num_out="$(xcena_cli num-device 2>/dev/null)" || true
        local num_devices=0

        if [ -n "$num_out" ]; then
            num_devices="$(echo "$num_out" | grep -oP 'Number of devices\s*:\s*\K[0-9]+' | head -1)" || true
            if [ -z "$num_devices" ] && [[ "$num_out" =~ ^[0-9]+$ ]]; then
                num_devices="$num_out"
            fi
            num_devices="${num_devices:-0}"
        fi

        if [ "$num_devices" -gt 0 ] 2>/dev/null; then
            ok "Number of devices : $num_devices"
            local i=0
            while [ "$i" -lt "$num_devices" ]; do
                local dev_info
                dev_info="$(xcena_cli device-info "$i" 2>/dev/null)" || true
                if [ -n "$dev_info" ]; then
                    local target bdf computable
                    target="$(echo "$dev_info" | grep 'Target' | awk -F': ' '{print $2}' | xargs)" || true
                    bdf="$(echo "$dev_info" | grep 'BDF' | awk -F': ' '{print $2}' | xargs)" || true
                    computable="$(echo "$dev_info" | grep 'Computable' | awk -F': ' '{print $2}' | xargs)" || true
                    detail "[$i] $target  BDF=$bdf  computable=$computable"
                else
                    warn "Device $i: failed to get device-info"
                fi
                ((i++))
            done
        else
            info "No devices detected"
        fi
    fi

    if check_cmd xtop; then
        ok "xtop found"
    else
        warn "xtop not found in PATH"
    fi
}

# ===========================================================================
# 7. MU Toolchain
# ===========================================================================
check_mu_toolchain() {
    section "MU Toolchain"

    local mu_lib_path="/usr/local/mu_library/mu"

    if [ -d "$mu_lib_path" ]; then
        ok "MU library installed"
    else
        warn "MU library not found ($mu_lib_path)"
        return
    fi

    local env_script="$mu_lib_path/script/min_llvm_version_env.sh"
    if [ -f "$env_script" ]; then
        local XCENA_LLVM_VERSION=""
        local MU_REVISION=""
        # shellcheck disable=SC1090
        source "$env_script"

        if [ -n "$XCENA_LLVM_VERSION" ] && [ -n "$MU_REVISION" ]; then
            local llvm_dir="/usr/local/mu_library/mu_llvm/${XCENA_LLVM_VERSION}/${MU_REVISION}"
            if [ -d "$llvm_dir" ]; then
                ok "MU LLVM installed (${XCENA_LLVM_VERSION}/${MU_REVISION})"
            else
                warn "MU LLVM directory not found: $llvm_dir"
            fi
        else
            warn "XCENA_LLVM_VERSION or MU_REVISION not set"
        fi
    else
        warn "MU LLVM env script not found"
    fi
}

# ===========================================================================
# Main
# ===========================================================================
check_system
check_pci
check_cxl_dax
check_driver
check_pxl
check_cli_tools
check_mu_toolchain
printf "\n"

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
