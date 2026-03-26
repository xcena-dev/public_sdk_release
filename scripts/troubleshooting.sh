#!/bin/bash
# troubleshooting.sh — XCENA debugging information collector
#
# Collects detailed diagnostic data for troubleshooting XCENA host issues.
# Output is saved to troubleshooting_report_YYYY-MM-DD.log (KST timezone).
#
# Usage:
#   sudo bash troubleshooting.sh
#
# Note: Most commands require root privileges for full output.

set -u

# ---------------------------------------------------------------------------
# Output setup (KST timezone)
# ---------------------------------------------------------------------------
KST_DATETIME="$(TZ='Asia/Seoul' date '+%Y-%m-%d-%H-%M')"
KST_TIME="$(TZ='Asia/Seoul' date '+%Y-%m-%d %H:%M:%S %Z')"
REPORT_FILE="troubleshooting_report_${KST_DATETIME}.log"

# ---------------------------------------------------------------------------
# Color setup (terminal only — not written to log)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_BOLD='\033[1m'
    C_GREEN='\033[32m'
    C_RED='\033[31m'
    C_YELLOW='\033[33m'
    C_CYAN='\033[36m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_BOLD='' C_GREEN='' C_RED='' C_YELLOW='' C_CYAN='' C_DIM='' C_RESET=''
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log() {
    echo "$*" >> "$REPORT_FILE"
}

section() {
    local title="$1"
    local divider
    divider="$(printf '%0.s=' $(seq 1 70))"
    log ""
    log "$divider"
    log "  $title"
    log "$divider"
    printf "${C_BOLD}${C_CYAN}[collect]${C_RESET} %s\n" "$title"
}

subsection() {
    local title="$1"
    local divider
    divider="$(printf '%0.s-' $(seq 1 70))"
    log ""
    log "$divider"
    log ">>> $title"
    log "$divider"
}

run_cmd() {
    local label="$1"
    shift
    subsection "$label ($*)"
    printf "  ${C_DIM}  -> %-45s${C_RESET}" "$label"
    if output="$("$@" 2>&1)"; then
        log "$output"
        printf "${C_GREEN}[OK]${C_RESET}\n"
    else
        log "(command failed with exit code $?)"
        [ -n "${output:-}" ] && log "$output"
        printf "${C_RED}[FAIL]${C_RESET}\n"
    fi
}

# ---------------------------------------------------------------------------
# Initialize report
# ---------------------------------------------------------------------------
: > "$REPORT_FILE"
log "XCENA Troubleshooting Report"
log "Generated: $KST_TIME"
log "Host: $(hostname 2>/dev/null || echo 'unknown')"
log "User: $(whoami 2>/dev/null || echo 'unknown')"

printf "\n${C_BOLD}  XCENA Troubleshooting Report${C_RESET}\n"
printf "  %s\n" "$KST_TIME"
printf "  Output: ${C_CYAN}%s${C_RESET}\n\n" "$REPORT_FILE"

# ===========================================================================
# 0. Host Validation
# ===========================================================================
collect_host_validation() {
    section "0. Host Validation"

    local validate_script="validate_host.sh"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -f "$script_dir/$validate_script" ]; then
        subsection "validate_host.sh (local)"
        printf "  ${C_DIM}  -> %-45s${C_RESET}" "Running validate_host.sh (local)"
        local output
        output="$(bash "$script_dir/$validate_script" 2>&1)" || true
        log "$output"
        printf "${C_GREEN}[OK]${C_RESET}\n"
    else
        subsection "validate_host.sh (download)"
        printf "  ${C_DIM}  -> %-45s${C_RESET}" "Running validate_host.sh (download)"
        local tmp_script
        tmp_script="$(mktemp /tmp/validate_host_XXXXXX.sh)"
        if command -v wget >/dev/null 2>&1; then
            wget -q -O "$tmp_script" \
                "https://raw.githubusercontent.com/metisx-dev/public_sdk_release/refs/heads/main/scripts/validate_host.sh" 2>/dev/null || true
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL -o "$tmp_script" \
                "https://raw.githubusercontent.com/metisx-dev/public_sdk_release/refs/heads/main/scripts/validate_host.sh" 2>/dev/null || true
        fi

        if [ -s "$tmp_script" ]; then
            local output
            output="$(bash "$tmp_script" 2>&1)" || true
            log "$output"
            printf "${C_GREEN}[OK]${C_RESET}\n"
        else
            log "(failed to download validate_host.sh)"
            printf "${C_RED}[FAIL]${C_RESET}\n"
        fi
        rm -f "$tmp_script"
    fi
}

# ===========================================================================
# 1. Kernel
# ===========================================================================
collect_kernel() {
    section "1. Kernel"

    run_cmd "1-1. dmesg" dmesg
    run_cmd "1-2. Kernel version" uname -r
    run_cmd "1-3. Boot parameters" cat /proc/cmdline
}

# ===========================================================================
# 2. PXL
# ===========================================================================
collect_pxl() {
    section "2. PXL"

    run_cmd "2-1. pxl_resourced journal" journalctl -u pxl_resourced.service --no-pager -n 500

    # PXL daemon history log
    local pxl_history="/tmp/pxl/history.log"
    subsection "2-2. pxl_resourced history.log ($pxl_history)"
    printf "  ${C_DIM}  -> %-45s${C_RESET}" "2-2. pxl history.log"
    if [ -f "$pxl_history" ]; then
        log "$(tail -n 500 "$pxl_history")"
        printf "${C_GREEN}[OK]${C_RESET}\n"
    else
        log "(history.log not found — skipped)"
        printf "${C_YELLOW}[SKIP]${C_RESET}\n"
    fi
}

# ===========================================================================
# 3. iomem
# ===========================================================================
collect_iomem() {
    section "3. iomem"

    run_cmd "3-1. /proc/iomem" cat /proc/iomem
}

# ===========================================================================
# 4. Detailed CXL Environment
# ===========================================================================
collect_cxl() {
    section "4. Detailed CXL Environment"

    run_cmd "4-1. cxl list" cxl list -RDMu
    run_cmd "4-2. sysfs CXL devices" find /sys/bus/cxl/devices/ -maxdepth 5 -ls
    run_cmd "4-3. daxctl list" daxctl list -Mu
    run_cmd "4-4. DAX devices" ls -al /dev/dax*

    # CEDT ACPI table (parsed via acpidump + iasl)
    subsection "4-5. CEDT ACPI table"
    printf "  ${C_DIM}  -> %-45s${C_RESET}" "4-5. CEDT ACPI table"
    if [ ! -f /sys/firmware/acpi/tables/CEDT ]; then
        log "(CEDT ACPI table not found — skipped)"
        printf "${C_YELLOW}[SKIP]${C_RESET}\n"
    elif command -v acpidump >/dev/null 2>&1 && command -v iasl >/dev/null 2>&1; then
        local tmpdir
        tmpdir="$(mktemp -d /tmp/cedt_dump_XXXXXX)"
        (
            cd "$tmpdir"
            acpidump -n CEDT > cedt.out 2>/dev/null
            acpixtract -a cedt.out >/dev/null 2>&1 || true
            local dat_file
            dat_file="$(ls *.dat 2>/dev/null | head -1)"
            if [ -n "$dat_file" ]; then
                iasl -d "$dat_file" >/dev/null 2>&1 || true
                local dsl_file="${dat_file%.dat}.dsl"
                if [ -f "$dsl_file" ]; then
                    cat "$dsl_file"
                else
                    echo "(iasl decompile failed)"
                fi
            else
                echo "(acpixtract produced no .dat file)"
            fi
        ) >> "$REPORT_FILE" 2>&1
        rm -rf "$tmpdir"
        printf "${C_GREEN}[OK]${C_RESET}\n"
    else
        log "(acpidump/iasl not found — CEDT parsing skipped)"
        printf "${C_YELLOW}[SKIP]${C_RESET}\n"
    fi

    # NUMA topology (parsed)
    subsection "4-6. NUMA topology"
    printf "  ${C_DIM}  -> %-45s${C_RESET}" "4-6. NUMA topology"
    {
        log ""
        log "[Node summary]"
        if command -v numactl >/dev/null 2>&1; then
            local numa_hw
            numa_hw="$(numactl --hardware 2>&1)" || true
            log "$numa_hw"
        else
            log "(numactl not found — skipped)"
        fi

        log ""
        log "[Node distances]"
        if [ -d /sys/devices/system/node ]; then
            for node_dir in /sys/devices/system/node/node*; do
                [ -d "$node_dir" ] || continue
                local node_name
                node_name="$(basename "$node_dir")"
                local dist=""
                [ -f "$node_dir/distance" ] && dist="$(cat "$node_dir/distance" 2>/dev/null)" || true
                local meminfo_total=""
                if [ -f "$node_dir/meminfo" ]; then
                    meminfo_total="$(grep 'MemTotal' "$node_dir/meminfo" 2>/dev/null | awk '{print $4, $5}')" || true
                fi
                log "  $node_name: distance=[$dist]  MemTotal=${meminfo_total:-N/A}"
            done
        else
            log "(/sys/devices/system/node not found)"
        fi

        log ""
        log "[Memory overview]"
        if command -v lsmem >/dev/null 2>&1; then
            local lsmem_out
            lsmem_out="$(lsmem -o RANGE,SIZE,STATE,REMOVABLE,NODE 2>&1)" || true
            log "$lsmem_out"
        else
            log "(lsmem not found — skipped)"
        fi
    }
    printf "${C_GREEN}[OK]${C_RESET}\n"
}

# ===========================================================================
# 5. Firmware Info
# ===========================================================================
collect_fw_info() {
    section "5. Firmware Info"

    if ! command -v xcena_cli >/dev/null 2>&1; then
        subsection "5-1. xcena_cli fw-info"
        printf "  ${C_DIM}  -> %-45s${C_RESET}" "5-1. xcena_cli fw-info"
        log "(xcena_cli not found — skipped)"
        printf "${C_YELLOW}[SKIP]${C_RESET}\n"
        return
    fi

    local num_out num_devices=0
    num_out="$(xcena_cli num-device 2>/dev/null)" || true
    if [ -n "$num_out" ]; then
        num_devices="$(echo "$num_out" | grep -oP 'Number of devices\s*:\s*\K[0-9]+' | head -1)" || true
        if [ -z "$num_devices" ] && [[ "$num_out" =~ ^[0-9]+$ ]]; then
            num_devices="$num_out"
        fi
        num_devices="${num_devices:-0}"
    fi

    if [ "$num_devices" -le 0 ] 2>/dev/null; then
        subsection "5-1. xcena_cli fw-info"
        printf "  ${C_DIM}  -> %-45s${C_RESET}" "5-1. xcena_cli fw-info"
        log "(no devices detected — skipped)"
        printf "${C_YELLOW}[SKIP]${C_RESET}\n"
        return
    fi

    local i=0
    while [ "$i" -lt "$num_devices" ]; do
        run_cmd "5-$((i+1)). xcena_cli fw-info (device $i)" xcena_cli fw-info "$i"
        ((i++))
    done
}

# ===========================================================================
# 6. CXL Device Verbose Information
# ===========================================================================
collect_cxl_verbose() {
    section "6. CXL Device Verbose Information"

    local cxl_bdfs
    cxl_bdfs="$(lspci 2>/dev/null | grep -i 'CXL' | awk '{print $1}')" || true

    if [ -z "$cxl_bdfs" ]; then
        subsection "6-1. lspci verbose for CXL devices"
        printf "  ${C_DIM}  -> %-45s${C_RESET}" "6-1. lspci verbose for CXL devices"
        log "(no CXL devices found via lspci)"
        printf "${C_YELLOW}[SKIP]${C_RESET}\n"
    else
        local idx=1
        while IFS= read -r bdf; do
            run_cmd "6-${idx}. lspci -vvs $bdf" lspci -vvs "$bdf"
            ((idx++))
        done <<< "$cxl_bdfs"
    fi
}

# ===========================================================================
# Main
# ===========================================================================
collect_host_validation
collect_kernel
collect_pxl
collect_iomem
collect_cxl
collect_fw_info
collect_cxl_verbose

printf "\n${C_BOLD}  Done.${C_RESET} Report saved to: ${C_CYAN}%s${C_RESET}\n\n" "$REPORT_FILE"
