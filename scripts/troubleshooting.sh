#!/bin/bash
# troubleshooting.sh — XCENA debugging information collector
#
# Collects detailed diagnostic data for troubleshooting XCENA host issues.
# Output is saved to troubleshooting_report_YYYY-MM-DD-HH-MM-SS.log (KST timezone).
#
# Usage:
#   sudo bash troubleshooting.sh          # recommended
#   bash troubleshooting.sh               # auto re-executes itself via sudo
#
# The script requires root privileges: dmesg, dmidecode, lspci -vv, acpidump
# and journalctl all return incomplete data otherwise. When not run as root it
# re-executes itself under sudo. If that is impossible (piped from curl, or no
# sudo rights) it continues in a reduced mode and marks the report as
# INCOMPLETE so the recipient can tell immediately.
#
# NOTE: the report contains host-identifying data (hostname, machine-id,
#       hardware/DIMM serial numbers, PCI topology). Review before sharing.

set -u

# ---------------------------------------------------------------------------
# Pinned revision of validate_host.sh
# ---------------------------------------------------------------------------
# Used only when validate_host.sh is not sitting next to this script. It is a
# commit SHA, not a branch: this collector re-executes itself as root, so
# whatever it fetches runs as root on the customer's machine. Pointing at
# refs/heads/main would mean that code is "whatever is on main at the moment
# the customer runs it" — including a change nobody has released or reviewed
# against this version of the collector. A SHA cannot be moved, unlike a tag.
#
# BUMP THIS whenever scripts/validate_host.sh changes, in the same PR.
VALIDATE_HOST_REV="6f8a84234850aa4518f0673332aea36e1fe019b7"

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
# Default mode summarises a handful of sources that are enormous but mostly
# noise (SRAT's per-CPU affinity records, per-CPU pageset statistics, per-DIMM
# serial numbers, per-CPU interrupt columns). --full turns every one of those
# back into a raw dump, for the rare case where a summary hid the answer.
#
# Parsed ahead of the privilege block below, so that --help and an invalid
# option answer immediately instead of first prompting for a sudo password
# (and so an invalid option exits non-zero instead of being swallowed by
# the re-exec fallback).
FULL_MODE=0

# Host-identifying fields are always masked. There is no opt-out, because none
# of them answers a CXL question: hostname, machine-id, chassis and board
# serials, account names, MAC and IP addresses. The unit under diagnosis is
# identified by the CXL device's own serial, which is kept, as are the BIOS
# version, board model and slot labels a diagnosis actually turns on. Without a
# flag there is no path by which an unmasked report reaches us by accident.

usage() {
    cat <<'USAGE'
Usage: sudo bash troubleshooting.sh [--full]

  --full     Collect everything unsummarised. Default mode summarises a few
             very large, low-signal sources; this disables that. The report
             grows several times larger.
  -h, --help Show this message.

The script re-executes itself under sudo when not run as root: dmesg,
dmidecode, lspci -vv, acpidump, journalctl and most of the CXL sysfs tree
return nothing useful otherwise.
USAGE
}

# Keep the original argument list: the parse loop below consumes "$@" with
# shift, so the sudo re-exec cannot forward it afterwards.
ORIG_ARGS=("$@")

while [ $# -gt 0 ]; do
    case "$1" in
        --full)    FULL_MODE=1 ;;
        -h|--help) usage; exit 0 ;;
        *)         printf "unknown option: %s\n\n" "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Privilege escalation — re-exec as root
# ---------------------------------------------------------------------------
PRIV_LEVEL="root"
if [ "$(id -u)" -ne 0 ]; then
    if [ "${XCENA_TS_REEXEC:-0}" -ne 1 ] \
       && [ -f "${BASH_SOURCE[0]:-}" ] \
       && command -v sudo >/dev/null 2>&1; then

        # Decide whether sudo can succeed at all before trying.
        #   - `sudo -n true` covers passwordless sudo and cached credentials.
        #   - Otherwise sudo needs a terminal to prompt on. Note that `sudo -v`
        #     is NOT a usable probe here: it validates for all commands and can
        #     demand a password even where NOPASSWD applies.
        _can_sudo=0
        if sudo -n true 2>/dev/null; then
            _can_sudo=1
        elif [ -t 0 ] && [ -t 1 ]; then
            _can_sudo=1
        fi

        if [ "$_can_sudo" -eq 1 ]; then
            printf "\n  [INFO] root privileges are required. Re-executing via sudo...\n\n" >&2
            # Run as a child rather than exec'ing, so that a cancelled or
            # mistyped password still leaves the user with a partial report
            # instead of nothing at all. Preserve PATH so xcena_cli / xtop /
            # cxl stay reachable under sudo's secure_path.
            sudo -E env "PATH=$PATH" XCENA_TS_REEXEC=1 \
                bash "${BASH_SOURCE[0]}" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
            _child_rc=$?
            # Distinguish "sudo could not run us" from "we ran and reported a
            # problem". Only sudo's own failures (auth denied, cannot execute)
            # fall through to the degraded run; anything else is the child's own
            # exit status and must be propagated, or a child that exits non-zero
            # makes the parent collect the whole report a second time as non-root.
            case "$_child_rc" in
                1|126|127)
                    printf "\n  [WARN] sudo re-execution failed; continuing without root.\n" >&2
                    ;;
                *)
                    exit "$_child_rc"
                    ;;
            esac
        fi
    fi

    PRIV_LEVEL="NON-ROOT (REPORT IS INCOMPLETE)"
    cat >&2 <<'PRIV_WARN'

  ****************************************************************
  *  WARNING: running without root privileges.                   *
  *                                                              *
  *  dmesg, dmidecode, lspci -vv, acpidump, journalctl and most  *
  *  of the CXL sysfs tree will be missing or truncated.         *
  *                                                              *
  *  Please re-run as:                                           *
  *      sudo bash troubleshooting.sh                            *
  *                                                              *
  *  (If you piped this script from curl, save it to a file      *
  *   first:  curl -fsSL <URL> -o ts.sh && sudo bash ts.sh)      *
  ****************************************************************

PRIV_WARN
fi

# ---------------------------------------------------------------------------
# Output setup (KST timezone)
# ---------------------------------------------------------------------------
# Seconds included: two runs in the same minute would otherwise truncate the
# first report and overwrite its archive.
KST_DATETIME="$(TZ='Asia/Seoul' date '+%Y-%m-%d-%H-%M-%S')"
KST_TIME="$(TZ='Asia/Seoul' date '+%Y-%m-%d %H:%M:%S %Z')"
START_EPOCH="$(date '+%s')"

_full_tag=""
[ "$FULL_MODE" -eq 1 ] && _full_tag="_full"
if [ "$PRIV_LEVEL" = "root" ]; then
    REPORT_NAME="troubleshooting_report_${KST_DATETIME}${_full_tag}.log"
else
    REPORT_NAME="troubleshooting_report_${KST_DATETIME}${_full_tag}_INCOMPLETE.log"
fi
REPORT_FILE="${PWD}/${REPORT_NAME}"

# A timestamped name makes this near-impossible, but a tool that advertises
# non-destructiveness should not truncate whatever a symlink points at.
if [ -L "$REPORT_FILE" ]; then
    printf "  [FATAL] %s is a symlink; refusing to write through it.\n" "$REPORT_FILE" >&2
    exit 1
fi

# Fall back to a temp directory when the current directory is not writable.
if ! : > "$REPORT_FILE" 2>/dev/null; then
    if ! _fallback_dir="$(mktemp -d /tmp/xcena_troubleshooting_XXXXXX)" \
       || [ -z "$_fallback_dir" ]; then
        printf "  [FATAL] cannot create a working directory. Aborting.\n" >&2
        exit 1
    fi
    # mktemp -d creates the directory 0700 root-owned, which the invoking user
    # cannot traverse once sudo exits. Hand it over rather than widening the
    # mode: the report inside carries serials, machine-id and the PCI inventory,
    # and 0755 would expose all of that to every local account.
    if [ -n "${SUDO_UID:-}" ]; then
        chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$_fallback_dir" 2>/dev/null || true
    fi
    REPORT_FILE="${_fallback_dir}/${REPORT_NAME}"
    if ! : > "$REPORT_FILE" 2>/dev/null; then
        printf "  [FATAL] cannot create a report file. Aborting.\n" >&2
        exit 1
    fi
    printf "  [INFO] current directory is not writable; using %s\n" "$_fallback_dir" >&2
fi

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
# Per-command timeout — a wedged CXL device can hang lspci/cxl indefinitely.
# ---------------------------------------------------------------------------
CMD_TIMEOUT=120
if command -v timeout >/dev/null 2>&1; then
    # -k sends SIGKILL after the grace period. Without it a child stuck in
    # uninterruptible sleep ignores SIGTERM and `timeout` waits for it forever.
    TIMEOUT="timeout -k 5 ${CMD_TIMEOUT}"
    TO2="timeout -k 1 2"     # short timeout for individual sysfs attribute reads
else
    TIMEOUT=""
    TO2=""
fi

# Same journal-first source as kernel_log_boot, as a string the run_sh payloads
# can use: they execute under `bash -c`, where the parent's shell functions are
# not in scope. A conclusion drawn from the journal whose supporting evidence
# came from a wrapped dmesg is worse than either source alone.
KLOG_CMD='{
    _j="$(journalctl -k -b 0 --no-pager 2>/dev/null)"
    case "$_j" in
        ""|*"No entries"*) dmesg -T 2>/dev/null || dmesg 2>/dev/null ;;
        *)                 printf "%s\\n" "$_j" ;;
    esac
}'

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
SEC_NUM=0
SUB_NUM=0
CURRENT_LABEL=""
OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_ITEMS=""
RUN_OUTPUT=""

log() {
    printf '%s\n' "$*" >> "$REPORT_FILE"
}

section() {
    local title="$1"
    SEC_NUM=$((SEC_NUM + 1))
    SUB_NUM=0
    local divider
    divider="$(printf '%0.s=' $(seq 1 78))"
    log ""
    log "$divider"
    log "  ${SEC_NUM}. ${title}"
    log "$divider"
    printf "\n${C_BOLD}${C_CYAN}[%2d] %s${C_RESET}\n" "$SEC_NUM" "$title"
}

# begin <label> [command string shown in the log header]
begin() {
    SUB_NUM=$((SUB_NUM + 1))
    CURRENT_LABEL="${SEC_NUM}-${SUB_NUM}. $1"
    local divider
    divider="$(printf '%0.s-' $(seq 1 78))"
    log ""
    log "$divider"
    if [ -n "${2:-}" ]; then
        log ">>> ${CURRENT_LABEL}"
        # A multi-line shell snippet printed in full makes the report hard to
        # scan; the first line is enough to say what produced the output.
        case "$2" in
            *"
"*) log "    \$ $(printf '%s' "$2" | head -1) ..." ;;
            *)  log "    \$ ${2}" ;;
        esac
    else
        log ">>> ${CURRENT_LABEL}"
    fi
    log "$divider"
    printf "  ${C_DIM}-> %-58s${C_RESET}" "$CURRENT_LABEL"
}

status_ok()   { printf "${C_GREEN}[OK]${C_RESET}\n";   OK_COUNT=$((OK_COUNT + 1)); }
status_skip() { printf "${C_YELLOW}[SKIP]${C_RESET}\n"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
status_fail() {
    printf "${C_RED}[FAIL]${C_RESET}\n"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_ITEMS="${FAILED_ITEMS}${CURRENT_LABEL}"$'\n'
}

# run_cmd <label> <command> [args...]
run_cmd() {
    local label="$1"
    shift
    begin "$label" "$*"
    if ! command -v "$1" >/dev/null 2>&1; then
        log "($1: command not found — skipped)"
        status_skip
        return 0
    fi
    local output rc
    output="$($TIMEOUT "$@" 2>&1)"
    rc=$?
    RUN_OUTPUT="$output"
    if [ "$rc" -eq 0 ]; then
        if [ -n "$output" ]; then log "$output"; else log "(no output)"; fi
        status_ok
    elif [ "$rc" -eq 124 ]; then
        log "(TIMED OUT after ${CMD_TIMEOUT}s — the device or driver may be wedged)"
        [ -n "$output" ] && log "$output"
        status_fail
    else
        log "(command failed, exit code $rc)"
        [ -n "$output" ] && log "$output"
        status_fail
    fi
}

# run_sh <label> <shell command string>
run_sh() {
    local label="$1" cmd="$2"
    begin "$label" "$cmd"
    local output rc
    output="$($TIMEOUT bash -c "$cmd" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        if [ -n "$output" ]; then log "$output"; else log "(no output)"; fi
        status_ok
    elif [ "$rc" -eq 124 ]; then
        log "(TIMED OUT after ${CMD_TIMEOUT}s)"
        [ -n "$output" ] && log "$output"
        status_fail
    else
        log "(command failed, exit code $rc)"
        [ -n "$output" ] && log "$output"
        status_fail
    fi
}

# run_opt <label> <command> [args...]
#
# Like run_cmd, but a non-zero exit is reported as SKIP rather than FAIL. For
# optional capabilities where failure means "this build of the tool does not
# support it", which is not something the customer's host did wrong.
run_opt() {
    local label="$1"
    shift
    begin "$label" "$*"
    if ! command -v "$1" >/dev/null 2>&1; then
        log "($1: command not found — skipped)"
        status_skip
        return 0
    fi
    local output rc
    output="$($TIMEOUT "$@" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        if [ -n "$output" ]; then log "$output"; else log "(no output)"; fi
        status_ok
    elif [ "$rc" -eq 124 ]; then
        # A hang is never a "the tool is too old" result — it is the wedged
        # device this collector exists to catch, and it must reach FAILED_ITEMS.
        log "(TIMED OUT after ${CMD_TIMEOUT}s — the device or driver may be wedged)"
        [ -n "$output" ] && log "$output"
        status_fail
    else
        log "(exit code $rc — this build of $1 may not support the option, or the"
        log " device rejected the command; see the output below)"
        [ -n "$output" ] && log "$output"
        status_skip
    fi
}

# dump_file <label> <path> [tail lines]
dump_file() {
    local label="$1" path="$2" lines="${3:-0}"
    begin "$label" "cat $path"
    if [ ! -e "$path" ]; then
        log "($path not found — skipped)"
        status_skip
        return 0
    fi
    if [ ! -r "$path" ]; then
        log "($path not readable — insufficient privileges)"
        status_fail
        return 0
    fi
    local output
    if [ "$lines" -gt 0 ]; then
        output="$(tail -n "$lines" "$path" 2>&1)"
    else
        output="$(cat "$path" 2>&1)"
    fi
    if [ -n "$output" ]; then log "$output"; else log "(empty)"; fi
    status_ok
}

# dump_sysfs <label> <dir> [maxdepth]
#
# The original script used `find -ls`, which records only file names and
# permissions. The attribute *values* are what actually matter (decoder
# start/size/interleave, region commit state, memdev ram_size/serial ...), so
# read every attribute file. `-L` is required because /sys/bus/*/devices/ holds
# symlinks; each read is wrapped in a short timeout because a wedged device can
# block a sysfs read forever.
dump_sysfs() {
    local label="$1" dir="$2" depth="${3:-3}"
    begin "$label" "read attribute values under $dir"
    if [ ! -d "$dir" ]; then
        log "($dir not found — skipped)"
        status_skip
        return 0
    fi

    log "[symlinks]"
    find "$dir" -maxdepth 1 -type l -printf '  %p -> %l\n' 2>/dev/null | sort | \
        while IFS= read -r l; do log "$l"; done
    log ""
    log "[attribute values]"

    local f v n=0
    while IFS= read -r f; do
        case "$f" in
            */uevent|*/power/*|*/driver_override|*/msi_irqs/*) continue ;;
            # Large binary blobs. PCI config space is already dumped in full by
            # `lspci -xxxx` in the PCIe section; ROM and BAR contents are not
            # diagnostic and would bloat the report by megabytes.
            */config|*/rom|*/resource[0-9]*) continue ;;
            # Reading PCI VPD is not a passive attribute read: the kernel polls
            # config space per dword, up to 125 ms each. On a device that does
            # not answer, the task sits in uninterruptible sleep where SIGTERM
            # cannot reach it, so the timeout below cannot rescue us. VPD says
            # nothing about CXL — skip it.
            */vpd) continue ;;
        esac

        # CDAT is a binary table carrying the device's self-reported bandwidth
        # and latency attributes — the source the kernel uses to describe a CXL
        # node when the platform HMAT does not cover it. Keep it as a hexdump
        # rather than mangling it into text.
        case "$f" in
            */CDAT)
                log "  $f (binary CDAT table, hexdump):"
                $TO2 head -c 8192 "$f" 2>/dev/null | od -A d -t x1z | sed 's/^/    /' \
                    >> "$REPORT_FILE" 2>/dev/null
                n=$((n + 1))
                continue
                ;;
        esac

        # `tr -d '\000'` must run inside the pipeline: command substitution
        # emits a "ignored null byte in input" warning to stderr (which corrupts
        # the progress column) and silently drops the byte otherwise.
        v="$($TO2 head -c 4096 "$f" 2>/dev/null | tr -d '\000' | tr '\n' ' ')"
        log "$(printf '  %-72s = %s' "$f" "${v:-(empty/unreadable)}")"
        n=$((n + 1))
    done < <(find -L "$dir" -maxdepth "$depth" -type f 2>/dev/null | sort)

    log ""
    log "($n attribute files read)"
    if [ "$n" -eq 0 ]; then status_skip; else status_ok; fi
}

# filter_acpi_subtables <keep-regex> <table name>
#
# Reads an iasl-decompiled table on stdin, keeps the header and the subtables
# whose type line matches the regex. A subtable is not one blank-line-separated
# paragraph — iasl breaks longer ones across several — so track state from each
# "Subtable Type" line to the next rather than filtering paragraph by paragraph.
filter_acpi_subtables() {
    awk -v keep="$1" -v tbl="$2" '
        /Subtable Type/ {
            if ($0 ~ keep) { keeping = 1; kept++ } else { keeping = 0; omitted++ }
        }
        # everything before the first subtable is the table header
        !seen_subtable && !/Subtable Type/ { print; next }
        /Subtable Type/ { seen_subtable = 1 }
        keeping { print }
        END {
            printf "\n(%d subtables kept, %d omitted — only [%s] is retained.\n", \
                   kept, omitted, keep
            printf " The omitted entries are per-CPU affinity records that do not bear\n"
            printf " on CXL. Recover the full table with:\n"
            printf "   acpidump -n %s > t.out && acpixtract -a t.out && iasl -d %s.dat)\n", \
                   tbl, tolower(tbl)
        }
    '
}

# dump_acpi_table <TABLE NAME> [subtable-keep-regex]
#
# With a keep-regex, only the header and the matching subtables are retained.
# SRAT on a large server decompiles to ~25k lines, of which all but a dozen are
# per-CPU affinity entries that say nothing about CXL; carrying them makes the
# report unreadable and unnecessarily exposes the customer's machine layout.
dump_acpi_table() {
    local name="$1" keep="${2:-}"
    local path="/sys/firmware/acpi/tables/$name"
    begin "ACPI table: $name" "acpidump -n $name | acpixtract | iasl -d"
    if [ ! -f "$path" ]; then
        log "($name not present on this platform — skipped)"
        status_skip
        return 0
    fi
    if command -v acpidump >/dev/null 2>&1 \
       && command -v acpixtract >/dev/null 2>&1 \
       && command -v iasl >/dev/null 2>&1; then
        local tmpdir
        # An unchecked mktemp leaves tmpdir empty, and every redirection below
        # then targets /<name> — which succeeds when running as root.
        if ! tmpdir="$(mktemp -d /tmp/acpi_dump_XXXXXX)" || [ -z "$tmpdir" ]; then
            log "(mktemp failed — cannot decode $name)"
            status_skip
            return 0
        fi
        (
            cd "$tmpdir" || exit 1
            acpidump -n "$name" > table.out 2>/dev/null
            acpixtract -a table.out >/dev/null 2>&1 || true
            dat_file="$(ls ./*.dat 2>/dev/null | head -1)"
            if [ -n "$dat_file" ]; then
                iasl -d "$dat_file" >/dev/null 2>&1 || true
                dsl_file="${dat_file%.dat}.dsl"
                if [ -f "$dsl_file" ]; then
                    cat "$dsl_file"
                else
                    echo "(iasl decompile failed)"
                fi
            else
                echo "(acpixtract produced no .dat file — acpidump needs root)"
            fi
        ) > "$tmpdir/raw_decoded.txt" 2>&1

        # iasl appends a hex dump of the whole table after the decoded fields.
        # It says nothing the decode above does not, and on SRAT alone it is
        # 2,600 lines. Cut it at the marker.
        if [ "$FULL_MODE" -eq 1 ]; then
            cp "$tmpdir/raw_decoded.txt" "$tmpdir/decoded.txt"
        else
            awk '/^Raw Table Data:/ { exit } { print }' \
                "$tmpdir/raw_decoded.txt" > "$tmpdir/decoded.txt"
        fi
        if [ -n "$keep" ]; then
            filter_acpi_subtables "$keep" "$name" < "$tmpdir/decoded.txt" \
                >> "$REPORT_FILE" 2>&1
        else
            cat "$tmpdir/decoded.txt" >> "$REPORT_FILE" 2>&1
        fi
        rm -rf "$tmpdir"
        status_ok
    else
        log "(acpidump/acpixtract/iasl not installed — raw hexdump below)"
        log "(install with: apt install acpica-tools)"
        if command -v xxd >/dev/null 2>&1; then
            xxd "$path" >> "$REPORT_FILE" 2>&1
        else
            od -A x -t x1z "$path" >> "$REPORT_FILE" 2>&1
        fi
        status_ok
    fi
}

# ---------------------------------------------------------------------------
# Initialize report
# ---------------------------------------------------------------------------
log "XCENA Troubleshooting Report"
log "Generated : $KST_TIME"
log "Host      : $(hostname 2>/dev/null || echo 'unknown')"
log "User      : $(whoami 2>/dev/null || echo 'unknown') (uid $(id -u))"
log "Privilege : $PRIV_LEVEL"
if [ "$FULL_MODE" -eq 1 ]; then
    log "Mode      : FULL (nothing summarised)"
else
    log "Mode      : default (some large sources summarised; --full for raw)"
fi
log "Masking   : host-identifying fields are masked"
log "Script    : ${BASH_SOURCE[0]:-<stdin>}"
if [ "$PRIV_LEVEL" != "root" ]; then
    log ""
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "!! THIS REPORT WAS COLLECTED WITHOUT ROOT PRIVILEGES.                !!"
    log "!! dmesg / dmidecode / lspci -vv / acpidump / journalctl output is   !!"
    log "!! missing or truncated. Please ask for a re-run with:               !!"
    log "!!     sudo bash troubleshooting.sh                                  !!"
    log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi

printf "\n${C_BOLD}  XCENA Troubleshooting Report${C_RESET}\n"
printf "  %s\n" "$KST_TIME"
printf "  Privilege: %s\n" "$PRIV_LEVEL"
[ "$FULL_MODE" -eq 1 ] && printf "  Mode:      ${C_BOLD}FULL${C_RESET} (nothing summarised)\n"
printf "  Output:    ${C_CYAN}%s${C_RESET}\n" "$REPORT_FILE"

# ===========================================================================
# Host Validation
# ===========================================================================
collect_host_validation() {
    section "Host Validation"

    local validate_script="validate_host.sh"
    local script_dir=""
    if [ -f "${BASH_SOURCE[0]:-}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    if [ -n "$script_dir" ] && [ -f "$script_dir/$validate_script" ]; then
        begin "validate_host.sh (local)" "bash $script_dir/$validate_script"
        local output
        output="$($TIMEOUT bash "$script_dir/$validate_script" 2>&1)" || true
        log "$output"
        status_ok
    else
        begin "validate_host.sh (fetched)" "fetch + run validate_host.sh at $VALIDATE_HOST_REV"
        local tmp_script
        # An unchecked mktemp leaves this empty, and the download below would
        # then write to /scripts/... as root.
        if ! tmp_script="$(mktemp /tmp/validate_host_XXXXXX.sh)" || [ -z "$tmp_script" ]; then
            log "(mktemp failed — cannot fetch validate_host.sh)"
            status_skip
            return 0
        fi

        local url="https://raw.githubusercontent.com/xcena-dev/public_sdk_release"
        url="$url/$VALIDATE_HOST_REV/scripts/validate_host.sh"
        log "Fetching: $url"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL -o "$tmp_script" "$url" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -q -O "$tmp_script" "$url" 2>/dev/null || true
        fi

        # "Non-empty" is not evidence that we got the right thing: a proxy that
        # answers 200 with an HTML notice passes that test. Check that it at
        # least looks like the script we asked for before running it as root.
        if [ -s "$tmp_script" ] \
           && head -1 "$tmp_script" | grep -q '^#!/bin/bash' \
           && grep -q 'XCENA Host Environment Validation' "$tmp_script"; then
            local output
            output="$($TIMEOUT bash "$tmp_script" 2>&1)" || true
            log "$output"
            status_ok
        elif [ -s "$tmp_script" ]; then
            log "(downloaded content is not validate_host.sh — not executed.)"
            log "(A proxy or captive portal may have answered instead. First line:)"
            log "  $(head -1 "$tmp_script" | cut -c1-100)"
            status_fail
        else
            log "(failed to download validate_host.sh — offline host?)"
            log "(Place validate_host.sh next to this script to skip the download.)"
            status_fail
        fi
        rm -f "$tmp_script"
    fi
}

# ===========================================================================
# Host Platform & BIOS
# ===========================================================================
collect_platform() {
    section "Host Platform & BIOS"

    run_cmd "System identity" hostnamectl
    dump_file "OS release" /etc/os-release
    run_cmd "Kernel (uname -a)" uname -a
    run_cmd "Uptime" uptime
    run_cmd "BIOS information" dmidecode -t bios
    run_cmd "System information" dmidecode -t system
    run_cmd "Baseboard information" dmidecode -t baseboard
    run_cmd "Processor information" dmidecode -t processor
    # DRAM population is useful only as a baseline to compare CXL bandwidth
    # against, so summarise it. The full type 17 output is 700+ lines and
    # includes a serial number for every DIMM — customer-identifying data with
    # no bearing on a CXL diagnosis.
    if [ "$FULL_MODE" -eq 1 ]; then
        run_cmd "Physical memory array (full)" dmidecode -t 16 -t 17
    else
    begin "DRAM population (summary)" "dmidecode -t 16 -t 17, summarised"
    if ! command -v dmidecode >/dev/null 2>&1; then
        log "(dmidecode not installed — skipped)"
        status_skip
    else
        dmidecode -t 16 2>/dev/null \
            | grep -E 'Maximum Capacity|Number of Devices' \
            | sed 's/^[[:space:]]*/  /' >> "$REPORT_FILE"
        # Flush on the next record header, not on a field: dmidecode prints
        # Configured Memory Speed *after* Rank, so flushing mid-record loses it.
        # Match leading whitespace as a class rather than a \t escape.
        dmidecode -t 17 2>/dev/null | awk '
            function flush() {
                if (size != "") {
                    if (size ~ /No Module Installed/) empty++
                    else populated[size "  " type "  @ " speed]++
                }
                size = ""; type = ""; speed = ""
            }
            /^Memory Device/                        { flush() }
            /^[ \t]+Size:/                          { size  = substr($0, index($0, ": ") + 2) }
            /^[ \t]+Type:/                          { type  = substr($0, index($0, ": ") + 2) }
            /^[ \t]+Configured Memory Speed:/       { speed = substr($0, index($0, ": ") + 2) }
            END {
                flush()
                for (k in populated) printf "  %3d x %s\n", populated[k], k
                if (empty) printf "  %3d empty slots\n", empty
            }' >> "$REPORT_FILE"
        log ""
        log "(summary only — per-DIMM serial numbers and asset tags are omitted."
        log " Re-run with --full for the complete type 16/17 output.)"
        status_ok
    fi
    fi

    # SMBIOS type 9 is the only DMI table that actually carries CXL information:
    # it names the physical slot each device sits in and says which slots are
    # Flexbus/CXL capable at all. A card in a non-CXL slot enumerates as plain
    # PCIe and never comes up as CXL — this answers that in one line, and no
    # amount of lspci output can give you the silkscreen slot label.
    begin "System slots (CXL capability)" "dmidecode -t 9"
    if ! command -v dmidecode >/dev/null 2>&1; then
        log "(dmidecode not installed — skipped)"
        status_skip
    else
        local slots
        slots="$(dmidecode -t 9 2>/dev/null)"
        if [ -z "$slots" ]; then
            log "(no SMBIOS slot records — dmidecode needs root)"
            status_fail
        else
            log "[summary]"
            log "$(printf '  %-40s %-22s %-13s %-9s %s' \
                 "DESIGNATION" "TYPE" "USAGE" "CXL" "BUS ADDRESS")"
            printf '%s' "$slots" | awk '
                function emit() {
                    if (des != "")
                        printf "  %-40s %-22s %-13s %-9s %s\n",
                               des, typ, use, (cxl ? cxl : "-"), (addr ? addr : "-")
                    des=""; typ=""; use=""; addr=""; cxl=""
                }
                /^Handle/          { emit() }
                /^\tDesignation:/  { des  = substr($0, index($0, ": ")+2) }
                /^\tType:/         { typ  = substr($0, index($0, ": ")+2) }
                /^\tCurrent Usage:/{ use  = substr($0, index($0, ": ")+2) }
                /^\tBus Address:/  { addr = substr($0, index($0, ": ")+2) }
                /CXL 2.0 capable/  { cxl = "CXL 2.0" }
                /CXL 1.0 capable/  { if (cxl == "") cxl = "CXL 1.0" }
                END { emit() }
            ' >> "$REPORT_FILE" 2>&1
            if [ "$FULL_MODE" -eq 1 ]; then
                log ""
                log "[full dmidecode -t 9 output]"
                printf '%s\n' "$slots" >> "$REPORT_FILE"
            else
                log ""
                log "(summary only — the per-slot raw records add ~600 lines and say"
                log " nothing beyond the columns above. The full slot record for each"
                log " CXL device is printed in the PCIe section; --full adds them all.)"
            fi
            status_ok
        fi
    fi

    run_cmd "CPU topology (lscpu)" lscpu
    # Every timestamp in this report is only comparable to a customer's account
    # of "when it broke" if the host clock is actually synced.
    run_cmd "Time & clock synchronisation" timedatectl
    # -l keeps this to local filesystems. Without it, df names every network
    # mount — server address and share path included — which says nothing about
    # CXL and exposes the customer's internal storage layout.
    run_sh  "Filesystem space (local)" \
            "df -hl -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | head -20"
    run_cmd "Memory summary" free -h
    dump_file "/proc/meminfo" /proc/meminfo

    begin "Firmware mode & Secure Boot" "EFI / mokutil"
    if [ -d /sys/firmware/efi ]; then
        log "Firmware mode : UEFI"
        log "EFI vars      : $(ls /sys/firmware/efi/efivars 2>/dev/null | wc -l) entries"
    else
        log "Firmware mode : Legacy BIOS (no /sys/firmware/efi)"
    fi
    if command -v mokutil >/dev/null 2>&1; then
        log "Secure Boot   : $(mokutil --sb-state 2>&1 | tr '\n' ' ')"
    else
        log "Secure Boot   : (mokutil not installed)"
    fi
    status_ok
}

# ===========================================================================
# Software & Tool Versions
# ===========================================================================
collect_versions() {
    section "Software & Tool Versions"

    # ver <display name> <command> [args...]
    ver() {
        local name="$1"
        shift
        local out
        if ! command -v "$1" >/dev/null 2>&1; then
            log "$(printf '  %-24s %s' "$name" "(not installed)")"
            return
        fi
        if command -v timeout >/dev/null 2>&1; then
            out="$(timeout 10 "$@" 2>&1 | head -3 | tr '\n' ' ')"
        else
            out="$("$@" 2>&1 | head -3 | tr '\n' ' ')"
        fi
        log "$(printf '  %-24s %s' "$name" "${out:-(no output)}")"
    }

    # xcena_bin_info <binary name>
    xcena_bin_info() {
        local name="$1" path pkg pkgver mtime sum
        path="$(command -v "$name" 2>/dev/null)"
        if [ -z "$path" ]; then
            log "$(printf '  %-24s %s' "$name" "(not installed)")"
            return
        fi
        pkg="$(dpkg -S "$(readlink -f "$path")" 2>/dev/null | cut -d: -f1)"
        [ -n "$pkg" ] && pkgver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)" || pkgver=""
        mtime="$(date -r "$path" '+%Y-%m-%d %H:%M' 2>/dev/null)"
        sum="$(sha256sum "$path" 2>/dev/null | cut -c1-16)"
        log "$(printf '  %-24s %s' "$name" "$path")"
        log "$(printf '  %-24s   package=%s  version=%s' "" "${pkg:-<not dpkg-owned>}" "${pkgver:-N/A}")"
        log "$(printf '  %-24s   mtime=%s  sha256=%s' "" "${mtime:-N/A}" "${sum:-N/A}")"
    }

    begin "Tool versions" "various --version"
    log "[kernel]"
    log "$(printf '  %-24s %s' "kernel release" "$(uname -r)")"
    log "$(printf '  %-24s %s' "kernel version" "$(cat /proc/version 2>/dev/null)")"
    log ""
    log "[CXL / memory tooling]"
    # cxl / daxctl / ndctl print a bare number (e.g. "77"), not a version string.
    ver "cxl (cxl-cli)"      cxl version
    ver "daxctl"             daxctl version
    ver "ndctl"              ndctl version
    ver "numactl"            numactl --version
    ver "lsmem (util-linux)" lsmem --version
    log ""
    log "[PCI / ACPI / platform tooling]"
    ver "lspci (pciutils)"   lspci --version
    ver "dmidecode"          dmidecode --version
    ver "iasl (acpica)"      iasl -v
    ver "acpidump"           acpidump -v
    log ""
    log "[XCENA stack]"
    # Neither xcena_cli nor xtop implements --version, so identify the build
    # from the owning dpkg package plus a binary fingerprint instead. This is
    # what distinguishes a version mismatch from a genuine failure.
    xcena_bin_info xcena_cli
    xcena_bin_info xtop
    log "$(printf '  %-24s %s' "libpxl (dpkg)" \
        "$(dpkg-query -W -f='${Version}' libpxl 2>/dev/null || echo '(not installed)')")"
    log ""
    log "[misc]"
    ver "jq"                 jq --version
    ver "gcc"                gcc --version
    ver "clang"              clang --version
    ver "python3"            python3 --version
    status_ok

    run_sh "XCENA / CXL related packages" \
           "dpkg -l 2>/dev/null \
              | grep -Ei 'libpxl|xcena|ndctl|daxctl|cxl|pciutils|numactl|acpica|dmidecode' \
              || echo '(dpkg unavailable or no matching packages)'"

    # The mx_dma driver version is what tells a version-mismatch apart from a
    # real failure; validate_host.sh only checks that the module is loaded.
    run_cmd "mx_dma driver module info" modinfo mx_dma

    run_sh "CXL/DAX kernel module info" \
           "for m in cxl_core cxl_pci cxl_mem cxl_acpi cxl_port cxl_pmem device_dax dax_cxl kmem; do
                echo \"--- \$m ---\"
                modinfo \"\$m\" 2>&1 | grep -E '^(filename|version|srcversion|vermagic|description):' || echo '(not found)'
            done"

    begin "MU toolchain version" "/usr/local/mu_library"
    local mu_env="/usr/local/mu_library/mu/script/min_llvm_version_env.sh"
    if [ -f "$mu_env" ]; then
        # Do not source it into this shell: as root, anything that file sets
        # (PATH, IFS, REPORT_FILE, a loop variable) would silently corrupt every
        # later collector. Read the two values out of a throwaway subshell.
        local llvm_ver mu_rev
        llvm_ver="$(bash -c '. "$1" >/dev/null 2>&1; printf %s "${XCENA_LLVM_VERSION:-}"' _ "$mu_env" 2>/dev/null)"
        mu_rev="$(bash -c '. "$1" >/dev/null 2>&1; printf %s "${MU_REVISION:-}"' _ "$mu_env" 2>/dev/null)"
        log "XCENA_LLVM_VERSION : ${llvm_ver:-unset}"
        log "MU_REVISION        : ${mu_rev:-unset}"
        log ""
        log "$(ls -al /usr/local/mu_library/ 2>&1)"
        status_ok
    else
        log "(MU toolchain env script not found — skipped)"
        status_skip
    fi
}

# ===========================================================================
# Kernel
# ===========================================================================
collect_kernel() {
    section "Kernel"

    kernel_log_load

    dump_file "Boot parameters" /proc/cmdline

    # A custom or vendor kernel missing a CONFIG_CXL_* option explains a whole
    # class of "the device does not come up" reports on its own.
    begin "Kernel build configuration (CXL/DAX/NUMA)" "grep /boot/config-\$(uname -r)"
    local kconfig="/boot/config-$(uname -r)"
    if [ ! -f "$kconfig" ] && [ -f /proc/config.gz ]; then
        log "[from /proc/config.gz]"
        zcat /proc/config.gz 2>/dev/null | \
            grep -E 'CONFIG_(CXL|DEV_DAX|EFI_SOFT_RESERVE|MEMORY_HOTPLUG|ZONE_DEVICE|NUMA|MIGRATION|ACPI_HMAT|TRANSPARENT_HUGEPAGE)' \
            >> "$REPORT_FILE" 2>&1
        status_ok
    elif [ -f "$kconfig" ]; then
        log "[from $kconfig]"
        grep -E 'CONFIG_(CXL|DEV_DAX|EFI_SOFT_RESERVE|MEMORY_HOTPLUG|ZONE_DEVICE|NUMA|MIGRATION|ACPI_HMAT|TRANSPARENT_HUGEPAGE)' \
            "$kconfig" >> "$REPORT_FILE" 2>&1
        status_ok
    else
        log "(kernel config not available — no $kconfig and no /proc/config.gz)"
        status_skip
    fi

    # mx_dma is a DMA engine driver: if DMA remapping is misconfigured or the
    # device lands in the wrong IOMMU group, transfers fail in ways that look
    # like device faults.
    run_sh "IOMMU / DMA remapping" \
           "echo '[iommu groups present]'
            ls /sys/class/iommu/ 2>/dev/null | tr '\n' ' '; echo
            echo
            echo '[kernel cmdline iommu parameters]'
            grep -oE '(intel_)?iommu[^ ]*|iommu\.[^ ]*|amd_iommu[^ ]*' /proc/cmdline || echo '(none - platform default)'
            echo
            echo '[iommu group of each PCI device with one]'
            for d in /sys/bus/pci/devices/*/iommu_group; do
                [ -e \"\$d\" ] || continue
                echo \"  \$(basename \$(dirname \$d)) -> group \$(basename \$(readlink -f \$d))\"
            done | head -60
            echo
            echo '[kernel messages]'
            $KLOG_CMD | grep -iE 'iommu|dmar|swiotlb' | head -40
            echo '(end of iommu messages)'"

    run_cmd "Loaded modules (lsmod)" lsmod

    begin "Kernel taint state" "/proc/sys/kernel/tainted"
    local taint
    taint="$(cat /proc/sys/kernel/tainted 2>/dev/null)"
    log "tainted = ${taint:-unknown}"
    if [ "${taint:-0}" != "0" ]; then
        log "(non-zero: the kernel is tainted — out-of-tree/unsigned modules, or a"
        log " previous warning/oops. Decode: see Documentation/admin-guide/tainted-kernels)"
        log ""
        log "[taint-related kernel messages]"
        kernel_log_boot | grep -iE 'taint|oops|BUG:|WARNING:|call trace' \
            | tail -n 60 >> "$REPORT_FILE" 2>&1
    fi
    status_ok

    run_sh "CXL/DAX module parameters" \
           "for d in /sys/module/cxl_*/parameters /sys/module/*dax*/parameters /sys/module/mx_dma/parameters; do
                [ -d \"\$d\" ] || continue
                for p in \"\$d\"/*; do
                    [ -f \"\$p\" ] && echo \"\$p = \$(cat \"\$p\" 2>/dev/null)\"
                done
            done"

    # dmesg -T gives wall-clock timestamps, which is what makes a customer
    # report correlatable with the time the problem was observed.
    begin "dmesg (with timestamps)" "dmesg -T"
    if dmesg -T > /dev/null 2>&1; then
        dmesg -T >> "$REPORT_FILE" 2>&1
        status_ok
    elif dmesg > /dev/null 2>&1; then
        log "(dmesg -T unsupported — falling back to raw timestamps)"
        dmesg >> "$REPORT_FILE" 2>&1
        status_ok
    else
        log "(dmesg failed — kernel.dmesg_restrict is set and we are not root)"
        status_fail
    fi

    # A quick-read view of the same buffer. 'numa' was dropped from the filter:
    # on a multi-socket host it matches hundreds of ordinary boot lines and
    # buries the CXL ones this view exists to surface.
    run_sh "dmesg - filtered highlights" \
           "$KLOG_CMD \
              | grep -iE 'cxl|dax|mx_dma|pxl|aer|soft reserved|hmat|firmware first|acpi.*error|pcie.*error' \
              || echo '(no matching lines)'"

    # The dmesg ring buffer only holds the current boot and can wrap. If the
    # host rebooted after the incident, the interesting log is in the previous
    # boot's journal.
    # The boot-time CXL/CEDT/_OSC lines are what several conclusions rest on, and
    # they are the first to fall out of the dmesg ring buffer.
    run_sh "Kernel journal - current boot" \
           "journalctl -k -b 0 -o short-precise --no-pager 2>&1 || echo '(journald unavailable)'"

    run_sh "Kernel journal - previous boot" \
           "journalctl -k -b -1 -o short-precise --no-pager -n 3000 2>&1 || echo '(no previous boot recorded / journald not persistent)'"
}

# ===========================================================================
# XCENA Runtime (driver, daemon, access)
# ===========================================================================
collect_runtime() {
    section "XCENA Runtime (driver / PXL daemon / access)"

    begin "mx_dma device nodes" "ls -al /dev/mx_dma/"
    if [ -d /dev/mx_dma ]; then
        log "$(ls -al /dev/mx_dma/ 2>&1)"
        status_ok
    else
        log "(/dev/mx_dma does not exist — the mx_dma driver is not loaded or"
        log " failed to bind. See section 3 (modinfo) and section 4 (dmesg).)"
        status_skip
    fi
    run_sh "mx_dma kernel messages" \
           "$KLOG_CMD | grep -i mx_dma || echo '(no mx_dma messages)'"

    run_cmd "pxl_resourced service status" \
            systemctl status pxl_resourced --no-pager -l
    run_cmd "pxl_resourced unit file" systemctl cat pxl_resourced
    run_sh "pxl_resourced journal (last 7 days)" \
           "journalctl -u pxl_resourced.service --since '7 days ago' \
                       -o short-precise --no-pager -n 5000 2>&1 \
              || echo '(journald unavailable)'"

    local pxl_history="/tmp/pxl/history.log"
    dump_file "pxl_resourced history.log" "$pxl_history" 500

    # /proc/interrupts is one column per CPU — 288 of them here, so a raw dump is
    # unreadable. Sum across CPUs instead: what matters is whether the device's
    # interrupt has ever fired. Zero on a driver that expects interrupts is a
    # real finding; zero on a polling driver is normal.
    run_sh "Interrupt delivery (per-IRQ totals)" \
           "awk 'NR==1 { next }
                 {
                     irq = \$1; sub(/:\$/, \"\", irq)
                     total = 0
                     for (i = 2; i <= NF; i++) if (\$i ~ /^[0-9]+\$/) total += \$i
                     desc = \"\"
                     for (i = 2; i <= NF; i++) if (\$i !~ /^[0-9]+\$/) desc = desc \" \" \$i
                     if (desc ~ /mx_dma|cxl|dax|xcena/) printf \"  %-8s %12d %s\n\", irq, total, desc
                 }' /proc/interrupts
            echo '  (only device-related IRQs shown; --full includes /proc/interrupts raw)'"

    if [ "$FULL_MODE" -eq 1 ]; then
        dump_file "/proc/interrupts (raw)" /proc/interrupts
    fi

    # Match on comm (the executable name), not the whole ps line. Grepping the
    # full line also matches the user column and any argument that happens to
    # contain the pattern, which drags in unrelated processes — and a process's
    # arguments are exactly where credentials and internal paths show up.
    # No user column: the owner of a process is not a CXL fact, and an arbitrary
    # account name here cannot be masked by value the way the invoking user's
    # can. PID, command and arguments are what diagnose a stuck daemon.
    run_sh "XCENA/PXL processes" \
           "ps -eo pid,ppid,pcpu,pmem,rss,etime,stat,comm,args --no-headers 2>/dev/null \
              | awk '\$8 ~ /^(pxl|xcena|xtop|mx_)/' \
              | head -40
            echo '(matched on executable name; empty means no XCENA process is running)'"

    # "device busy" reports are almost always another process still holding the
    # DAX character device.
    run_sh "Holders of /dev/dax* and /dev/mx_dma*" \
           "if command -v lsof >/dev/null 2>&1; then
                lsof -F pcn /dev/dax* /dev/mx_dma/* 2>/dev/null \
                  | sed 's/^c/  command: /; s/^p/PID /; s/^n/  path: /' \
                  || echo '(no open handles)'
            else
                echo '(lsof not installed)'
                for p in /proc/[0-9]*/fd/*; do
                    t=\$(readlink \"\$p\" 2>/dev/null)
                    case \"\$t\" in /dev/dax*|/dev/mx_dma*) echo \"\$p -> \$t\";; esac
                done
            fi"

    # memlock is the classic cause of a DAX mmap failing for a non-root user.
    run_sh "Resource limits (memlock matters for DAX mmap)" \
           "echo '[current shell]'; ulimit -a; echo; echo '[limits.conf memlock entries]';
            grep -rhE '^[^#]*memlock' /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null || echo '(none configured)'"

    run_sh "Invoking user & groups" \
           "echo \"SUDO_USER=\${SUDO_USER:-<none>}\"; id; echo; id \"\${SUDO_USER:-}\" 2>/dev/null || true"

    # SELinux/AppArmor can silently deny access to /dev/dax*.
    run_sh "Mandatory access control (SELinux / AppArmor)" \
           "if command -v getenforce >/dev/null 2>&1; then echo \"SELinux: \$(getenforce)\"; else echo 'SELinux: (not installed)'; fi
            if command -v aa-status >/dev/null 2>&1; then
                echo; echo '[AppArmor]'; aa-status 2>&1 | head -20
            else
                echo 'AppArmor: (aa-status not installed)'
            fi"

    # Only admin-installed rules, plus vendor rules whose *filename* names the
    # subsystem. A blind content grep pulls in unrelated files (for example
    # 40-usb_modeswitch.rules contains the unrelated USB id 20a6).
    run_sh "udev rules for dax / mx_dma / cxl" \
           "found=0
            for f in /etc/udev/rules.d/*.rules \
                     /lib/udev/rules.d/*dax*.rules \
                     /lib/udev/rules.d/*mx_dma*.rules \
                     /lib/udev/rules.d/*cxl*.rules; do
                [ -f \"\$f\" ] || continue
                grep -qEi 'dax|mx_dma|cxl|20a6' \"\$f\" 2>/dev/null || continue
                found=1
                echo \"--- \$f (\$(wc -l < \"\$f\") lines) ---\"
                head -60 \"\$f\"
                echo
            done
            [ \"\$found\" -eq 0 ] && echo '(no dax/mx_dma/cxl udev rules found)'
            exit 0"

    run_sh "Recent core dumps" \
           "if command -v coredumpctl >/dev/null 2>&1; then
                coredumpctl list --no-pager 2>&1 | tail -30
            else
                echo '(coredumpctl not available)'
            fi
            echo; echo \"core_pattern: \$(cat /proc/sys/kernel/core_pattern 2>/dev/null)\""
}

# ===========================================================================
# Memory & NUMA Topology
# ===========================================================================
collect_memory() {
    section "Memory & NUMA Topology"

    dump_file "/proc/iomem" /proc/iomem
    run_cmd "NUMA hardware summary" numactl --hardware
    run_cmd "NUMA statistics" numastat
    run_cmd "Memory ranges (lsmem)" lsmem -o RANGE,SIZE,STATE,REMOVABLE,BLOCK,NODE,ZONES
    run_cmd "Swap" swapon --show

    begin "Per-node detail (distance / meminfo / cpus)" "/sys/devices/system/node"
    if [ -d /sys/devices/system/node ]; then
        for node_dir in /sys/devices/system/node/node*; do
            [ -d "$node_dir" ] || continue
            local node_name dist meminfo_total cpulist
            node_name="$(basename "$node_dir")"
            dist="$(cat "$node_dir/distance" 2>/dev/null)"
            cpulist="$(cat "$node_dir/cpulist" 2>/dev/null)"
            meminfo_total="$(grep 'MemTotal' "$node_dir/meminfo" 2>/dev/null | awk '{print $4, $5}')"
            log "  $node_name: distance=[${dist:-N/A}]  cpus=[${cpulist:-none}]  MemTotal=${meminfo_total:-N/A}"
        done
        status_ok
    else
        log "(/sys/devices/system/node not found)"
        status_skip
    fi

    # HMAT-derived bandwidth/latency is the basis for every judgement about
    # whether a CXL node is performing as expected.
    begin "HMAT performance attributes" "/sys/devices/system/node/node*/access*/initiators"
    local hmat_found=0
    for acc in /sys/devices/system/node/node*/access*/initiators; do
        [ -d "$acc" ] || continue
        hmat_found=1
        log "[$acc]"
        for attr in "$acc"/*; do
            [ -f "$attr" ] && log "  $(basename "$attr") = $(cat "$attr" 2>/dev/null)"
        done
    done
    if [ "$hmat_found" -eq 1 ]; then
        status_ok
    else
        log "(no HMAT access attributes — BIOS did not publish an HMAT table,"
        log " or CONFIG_ACPI_HMAT is disabled. CXL nodes will have no bandwidth/"
        log " latency information for tiering decisions.)"
        status_skip
    fi

    run_sh "Memory block online state summary" \
           "echo '[state]'; cat /sys/devices/system/memory/memory*/state 2>/dev/null | sort | uniq -c
            echo; echo '[valid_zones]'; cat /sys/devices/system/memory/memory*/valid_zones 2>/dev/null | sort | uniq -c
            echo; echo \"auto_online_blocks: \$(cat /sys/devices/system/memory/auto_online_blocks 2>/dev/null)\"
            echo \"block_size_bytes:   \$(cat /sys/devices/system/memory/block_size_bytes 2>/dev/null)\""

    run_sh "Memory tiering & demotion" \
           "echo \"demotion_enabled: \$(cat /sys/kernel/mm/numa/demotion_enabled 2>/dev/null || echo N/A)\"
            echo; echo '[memory tiers]'
            for t in /sys/devices/virtual/memory_tiering/memory_tier*; do
                [ -d \"\$t\" ] || continue
                echo \"\$t nodelist=\$(cat \"\$t/nodelist\" 2>/dev/null)\"
            done"

    # /proc/zoneinfo is deliberately not collected: it is ~12k lines of per-CPU
    # pageset statistics. The one thing it would answer for CXL — which zone the
    # memory landed in — is already covered by lsmem's ZONES column and the
    # memory-block valid_zones summary above.
    if [ "$FULL_MODE" -eq 1 ]; then
        dump_file "/proc/zoneinfo" /proc/zoneinfo
    fi
    dump_file "/proc/buddyinfo" /proc/buddyinfo

    run_sh "THP, pressure and NUMA counters" \
           "echo '[transparent hugepage]'
            for f in enabled defrag; do
                echo \"  \$f = \$(cat /sys/kernel/mm/transparent_hugepage/\$f 2>/dev/null)\"
            done
            echo
            echo '[pressure stall information]'
            for r in cpu memory io; do
                [ -f /proc/pressure/\$r ] && echo \"  \$r: \$(head -1 /proc/pressure/\$r)\"
            done
            echo
            echo '[NUMA allocation counters]'
            grep -E '^(numa_|pgmigrate|pgdemote|pgpromote)' /proc/vmstat 2>/dev/null || echo '(no NUMA counters in this kernel)'"

    run_sh "EDAC / memory error counters" \
           "if [ -d /sys/devices/system/edac ]; then
                find /sys/devices/system/edac -maxdepth 4 -name '*_count' 2>/dev/null | sort | while read -r f; do
                    echo \"\$f = \$(cat \"\$f\" 2>/dev/null)\"
                done
            else
                echo '(no EDAC subsystem)'
            fi
            echo
            if command -v ras-mc-ctl >/dev/null 2>&1; then
                echo '[ras-mc-ctl --errors]'; ras-mc-ctl --errors 2>&1 | head -60
            else
                echo '(ras-mc-ctl not installed — apt install rasdaemon)'
            fi"
}

# ===========================================================================
# CXL Subsystem
# ===========================================================================
collect_cxl() {
    section "CXL Subsystem"

    # -vvv covers buses/ports/endpoints/decoders/targets/regions; the previous
    # -RDMu missed the whole port/endpoint half of the topology.
    run_cmd "cxl list (full topology, verbose)" cxl list -vvv -u
    # Without -i, a disabled device does not appear at all — exactly the case
    # someone reports as "the device is not detected".
    run_cmd "cxl list (including idle/disabled devices)" cxl list -M -i -u
    # -H/-I/-A/-X were added in later cxl-cli releases. On an older build these
    # exit non-zero, which is a tool-version difference, not a device fault —
    # counting them as FAIL would put three false entries at the top of the
    # summary that support reads first.
    run_opt "cxl list (memdev health)" cxl list -M -H -u
    run_opt "cxl list (memdev partition)" cxl list -M -I -u
    run_opt "cxl list (memdev alert config)" cxl list -M -A -u
    run_opt "cxl list (regions with dax devices)" cxl list -R -X -u

    dump_sysfs "CXL sysfs attributes" /sys/bus/cxl/devices 3

    begin "CXL memdev firmware versions" "/sys/bus/cxl/devices/mem*/firmware_version"
    local found_mem=0
    for mem_dir in /sys/bus/cxl/devices/mem*; do
        [ -d "$mem_dir" ] || continue
        found_mem=1
        local mem_name fw_ver serial numa
        mem_name="$(basename "$mem_dir")"
        fw_ver="$(cat "$mem_dir/firmware_version" 2>/dev/null)"
        serial="$(cat "$mem_dir/serial" 2>/dev/null)"
        numa="$(cat "$mem_dir/numa_node" 2>/dev/null)"
        log "  $mem_name: firmware_version=${fw_ver:-N/A}  serial=${serial:-N/A}  numa_node=${numa:-N/A}"
    done
    if [ "$found_mem" -eq 1 ]; then
        status_ok
    else
        log "(no /sys/bus/cxl/devices/mem* devices found — the CXL driver did not"
        log " bind, or the platform did not enumerate the device)"
        status_skip
    fi

    run_sh "CXL debugfs" \
           "if [ -d /sys/kernel/debug/cxl ]; then
                find /sys/kernel/debug/cxl -maxdepth 3 2>/dev/null | sort
            else
                echo '(/sys/kernel/debug/cxl not present — debugfs unmounted or CXL debug disabled)'
            fi"

    run_sh "CXL tracepoints available" \
           "ls /sys/kernel/tracing/events/cxl/ 2>/dev/null \
              || ls /sys/kernel/debug/tracing/events/cxl/ 2>/dev/null \
              || echo '(cxl tracepoints not available)'"

    # ---- ACPI tables --------------------------------------------------------
    # CEDT alone is not enough: whether CXL memory becomes a NUMA node is
    # decided by SRAT, and its performance attributes come from HMAT.
    run_sh "ACPI tables present" "ls -l /sys/firmware/acpi/tables/ 2>&1"
    dump_acpi_table CEDT
    # Only the subtables that describe memory ranges and CXL host bridges;
    # the per-CPU affinity entries are not what a CXL question turns on.
    if [ "$FULL_MODE" -eq 1 ]; then
        dump_acpi_table SRAT
    else
        dump_acpi_table SRAT "Memory Affinity|Generic Port Affinity|Generic Initiator Affinity"
    fi
    dump_acpi_table HMAT
    dump_acpi_table SLIT
    dump_acpi_table MCFG
    # HEST describes how the platform reports hardware errors. On a
    # firmware-first host this is what decides whether Linux ever sees them.
    dump_acpi_table HEST
}

# ===========================================================================
# DAX
# ===========================================================================
collect_dax() {
    section "DAX"

    run_cmd "daxctl list (regions + devices)" daxctl list -R -D -u
    run_cmd "daxctl list (including idle)" daxctl list -D -i -u
    run_sh  "DAX device nodes" "ls -al /dev/dax* 2>&1 || echo '(no /dev/dax* devices)'"
    dump_sysfs "DAX sysfs attributes" /sys/bus/dax/devices 3

    begin "DAX mode check" "daxctl mode per device"
    if command -v daxctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        local dax_json
        dax_json="$(daxctl list -D 2>/dev/null)"
        if [ -n "$dax_json" ] && [ "$dax_json" != "[]" ]; then
            echo "$dax_json" | jq -r '.[] | "  \(.chardev)  mode=\(.mode)  size=\(.size)  target_node=\(.target_node // "N/A")"' \
                >> "$REPORT_FILE" 2>&1
            local non_devdax
            non_devdax="$(echo "$dax_json" | jq -r '.[] | select(.mode != "devdax") | .chardev' 2>/dev/null)"
            if [ -n "$non_devdax" ]; then
                log ""
                log "WARNING: the following devices are not in devdax mode."
                log "devdax mode is required for computing:"
                log "$non_devdax"
                log "Fix with: sudo daxctl reconfigure-device --mode=devdax <dax_device>"
            fi
            status_ok
        else
            log "(no DAX devices reported by daxctl)"
            status_skip
        fi
    else
        log "(daxctl or jq not installed — skipped)"
        status_skip
    fi
}

# ===========================================================================
# Device Firmware (xcena_cli)
# ===========================================================================
IM_DEVICES=""

collect_fw_info() {
    section "Device Firmware (xcena_cli)"

    if ! command -v xcena_cli >/dev/null 2>&1; then
        begin "xcena_cli fw-info" "xcena_cli"
        log "(xcena_cli not found in PATH — skipped)"
        status_skip
        return
    fi

    run_cmd "xcena_cli num-device" xcena_cli num-device

    local num_out num_devices=0
    num_out="$(xcena_cli num-device 2>/dev/null)" || true
    if [ -n "$num_out" ]; then
        num_devices="$(echo "$num_out" | grep -oP 'Number of devices\s*:\s*\K[0-9]+' | head -1)" || true
        if [ -z "$num_devices" ] && [[ "$num_out" =~ ^[0-9]+$ ]]; then
            num_devices="$num_out"
        fi
        num_devices="${num_devices:-0}"
    fi
    # A non-numeric value here makes every later `[ "$i" -lt "$num_devices" ]`
    # print "integer expression expected" over the progress output.
    case "$num_devices" in
        ''|*[!0-9]*) num_devices=0 ;;
    esac

    if [ "$num_devices" -le 0 ] 2>/dev/null; then
        begin "xcena_cli fw-info" "xcena_cli fw-info <dev>"
        log "(no devices detected — skipped)"
        status_skip
        return
    fi

    local i=0
    while [ "$i" -lt "$num_devices" ]; do
        run_cmd "xcena_cli device-info (device $i)" xcena_cli device-info "$i"
        case "$RUN_OUTPUT" in
            *"(InfiniteMemory)"*) IM_DEVICES="${IM_DEVICES}${i} " ;;
        esac
        run_cmd "xcena_cli fw-info (device $i)" xcena_cli fw-info "$i"
        i=$((i + 1))
    done
}

# ===========================================================================
# InfiniteMemory SMART (xcena_cli)
# ===========================================================================
collect_im_smart() {
    section "InfiniteMemory SMART (xcena_cli)"

    if [ -z "$IM_DEVICES" ]; then
        begin "xcena_cli im get-smart" "xcena_cli im get-smart -v <dev>"
        log "(no InfiniteMemory device detected — skipped)"
        status_skip
        return
    fi

    local i
    for i in $IM_DEVICES; do
        run_cmd "xcena_cli im get-smart (device $i)" xcena_cli im get-smart -v "$i"
    done
}

# ===========================================================================
# PCIe
# ===========================================================================

# Print one line of link state for a PCI device sysfs directory.
# pci_link_info <sysfs dir> [upstream max_link_speed]
pci_link_info() {
    local d="$1" upstream_max="${2:-}"
    local bdf cls node cur_s cur_w max_s max_w note=""
    bdf="$(basename "$d")"
    cls="$(cat "$d/class" 2>/dev/null)"
    node="$(cat "$d/numa_node" 2>/dev/null)"
    cur_s="$(cat "$d/current_link_speed" 2>/dev/null)"
    cur_w="$(cat "$d/current_link_width" 2>/dev/null)"
    max_s="$(cat "$d/max_link_speed" 2>/dev/null)"
    max_w="$(cat "$d/max_link_width" 2>/dev/null)"
    # A link below its own maximum is not automatically a fault: an idle link
    # legitimately downtrains (ASPM), and an endpoint is also capped by whatever
    # the upstream port supports. Name the upstream cap when that explains it,
    # so this reads as an answer rather than something to go chase.
    if [ -n "$cur_s" ] && [ -n "$max_s" ] && [ "$cur_s" != "$max_s" ]; then
        if [ -n "$upstream_max" ] && [ "$cur_s" = "$upstream_max" ]; then
            note="  <-- capped by upstream port (upstream max ${upstream_max})"
        else
            note="  <-- speed below max (check ASPM/idle vs. real degradation)"
        fi
    fi
    if [ -n "$cur_w" ] && [ -n "$max_w" ] && [ "$cur_w" != "$max_w" ]; then
        note="${note}  <-- width below max"
    fi
    log "$(printf '  %-14s class=%-8s numa=%-4s link=%s x%s (max %s x%s)%s' \
        "$bdf" "${cls:-N/A}" "${node:-N/A}" \
        "${cur_s:-N/A}" "${cur_w:-N/A}" "${max_s:-N/A}" "${max_w:-N/A}" "$note")"
}

collect_pcie() {
    section "PCIe"

    kernel_log_load

    run_cmd "PCI topology tree" lspci -tvnn
    run_cmd "All PCI devices" lspci -Dnn

    # The previous version matched only `lspci | grep -i CXL`. If the device
    # description does not literally contain "CXL" (it may present as a plain
    # memory controller) the whole section came out empty. Match on the XCENA
    # vendor ID and the CXL memory device class as well.
    begin "CXL/XCENA device discovery" "lspci -D -d 20a6: / class 0502 / name match"
    local cxl_bdfs
    cxl_bdfs="$( {
            lspci -D -d 20a6: 2>/dev/null
            lspci -D -d ::0502 2>/dev/null
            lspci -D 2>/dev/null | grep -i 'CXL'
        } | awk '{print $1}' | sort -u )"
    if [ -z "$cxl_bdfs" ]; then
        log "(no XCENA/CXL PCI devices found)"
        log "Searched: vendor 20a6, class 0502 (CXL memory device), name containing 'CXL'"
        status_fail
    else
        log "Discovered devices:"
        log "$cxl_bdfs"
        status_ok
    fi

    if [ -z "$cxl_bdfs" ]; then
        return
    fi

    # Link state along the whole path (root port -> switch -> endpoint): a
    # downtrained upstream link is invisible when only the endpoint is checked.
    # Map each discovered device back to the slot it is physically installed in.
    # This is what lets support say "move the card to SLOT_B" instead of quoting
    # a BDF the customer cannot find on the chassis.
    begin "Physical slot of each CXL device" "dmidecode -t 9 matched by bus address"
    if ! command -v dmidecode >/dev/null 2>&1; then
        log "(dmidecode not installed — skipped)"
        status_skip
    else
        local dmi_slots slot_blk
        dmi_slots="$(dmidecode -t 9 2>/dev/null)"
        if [ -z "$dmi_slots" ]; then
            log "(no SMBIOS slot records available)"
            status_skip
        else
            while IFS= read -r bdf; do
                [ -n "$bdf" ] || continue
                slot_blk="$(printf '%s\n' "$dmi_slots" | awk -v b="$bdf" '
                    /^Handle/ { blk = "" }
                    { blk = blk $0 "\n" }
                    index($0, "Bus Address: " b) { printf "%s", blk; exit }')"
                if [ -n "$slot_blk" ]; then
                    log "[$bdf]"
                    printf '%s' "$slot_blk" | sed 's/^/  /' >> "$REPORT_FILE"
                else
                    log "[$bdf] (no SMBIOS slot record references this bus address)"
                fi
                log ""
            done <<< "$cxl_bdfs"
            status_ok
        fi
    fi

    begin "PCIe link state (endpoint to root port)" "sysfs current/max_link_*"
    local bdf p chain d
    while IFS= read -r bdf; do
        [ -n "$bdf" ] || continue
        log ""
        log "[path to $bdf]"
        p="$(readlink -f "/sys/bus/pci/devices/$bdf" 2>/dev/null)"
        chain=""
        while [ -n "$p" ] && [ "$p" != "/" ]; do
            case "$(basename "$p")" in
                ????:??:??.?) chain="${p}"$'\n'"${chain}" ;;
                *) break ;;
            esac
            p="$(dirname "$p")"
        done
        # The chain is ordered root port -> ... -> endpoint, so each device
        # can be compared against the link above it.
        local upstream_max=""
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            pci_link_info "$d" "$upstream_max"
            upstream_max="$(cat "$d/max_link_speed" 2>/dev/null)"
        done <<< "$chain"
    done <<< "$cxl_bdfs"
    status_ok

    begin "PCIe AER error counters" "/sys/bus/pci/devices/*/aer_dev_*"
    # In APEI firmware-first mode the platform — not Linux — owns PCIe error
    # handling, and _OSC withholds AER/DPC from the OS. The counters below then
    # stay at zero even when errors did occur, so state that explicitly: an
    # all-zero table otherwise reads as "no errors" and hides the real record.
    if kernel_log_boot | grep -q 'firmware first mode is enabled'; then
        log "NOTE: APEI firmware-first error handling is ENABLED on this platform."
        log "      Linux does not own PCIe AER here, so the counters below may read"
        log "      zero even when errors occurred. The authoritative record is in"
        log "      the GHES messages (see the kernel log) and the BMC/IPMI SEL."
        log ""
    fi
    local aer_found=0
    while IFS= read -r bdf; do
        [ -n "$bdf" ] || continue
        p="$(readlink -f "/sys/bus/pci/devices/$bdf" 2>/dev/null)"
        while [ -n "$p" ] && [ "$p" != "/" ]; do
            case "$(basename "$p")" in
                ????:??:??.?) ;;
                *) break ;;
            esac
            for f in "$p"/aer_dev_correctable "$p"/aer_dev_fatal "$p"/aer_dev_nonfatal "$p"/aer_rootport_total_err_cor; do
                if [ -f "$f" ]; then
                    aer_found=1
                    log "[$(basename "$p") $(basename "$f")]"
                    sed 's/^/    /' "$f" >> "$REPORT_FILE" 2>&1
                fi
            done
            p="$(dirname "$p")"
        done
    done <<< "$cxl_bdfs"
    if [ "$aer_found" -eq 1 ]; then status_ok; else log "(no AER counters exposed)"; status_skip; fi

    run_sh "ACPI _OSC negotiation (who owns error reporting)" \
           "$KLOG_CMD | grep -E '_OSC|firmware first mode' | sed 's/^\\[[^]]*\\] //' | sort -u
            echo '(end of _OSC negotiation)'"

    # ASPM is the other reason a link legitimately sits below its maximum.
    # $cxl_bdfs is passed through the environment rather than interpolated into
    # the payload: it is the only place a collected value would reach `bash -c`
    # as code, and that shape should not exist in a script that runs as root.
    XCENA_BDFS="$cxl_bdfs" run_sh "PCIe ASPM policy" \
           "echo \"policy: \$(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo 'N/A')\"
            for b in \$XCENA_BDFS; do
                for f in /sys/bus/pci/devices/\$b/link/l0s_aspm /sys/bus/pci/devices/\$b/link/l1_aspm; do
                    [ -f \"\$f\" ] && echo \"  \$f = \$(cat \$f 2>/dev/null)\"
                done
            done
            echo
            grep -oE 'pcie_aspm[^ ]*' /proc/cmdline || echo '(no aspm kernel parameter)'"

    # Firmware-first hosts record PCIe/CXL errors through GHES rather than AER,
    # so collect the GHES side explicitly — otherwise the report shows an
    # all-zero AER table and nothing else.
    run_sh "GHES / APEI error records" \
           "$KLOG_CMD | grep -iE 'ghes|apei|hest|erst|einj' || echo '(no GHES/APEI messages)'"

    # ...and the authoritative log for those errors is the BMC's event log.
    run_sh "BMC / IPMI system event log" \
           "if ! command -v ipmitool >/dev/null 2>&1; then
                echo '(ipmitool not installed — apt install ipmitool)'
            elif [ ! -e /dev/ipmi0 ] && [ ! -e /dev/ipmi/0 ]; then
                echo '(no IPMI device node — BMC interface not available)'
            else
                echo '[sel info]'; ipmitool sel info 2>&1 | head -12
                echo; echo '[last 40 events]'; ipmitool sel list last 40 2>&1 | tail -40
            fi"

    run_sh "AER / PCIe errors in kernel log" \
           "$KLOG_CMD \
              | grep -iE 'aer|pcie bus error|corrected error|uncorrectable|Malformed TLP|Bad TLP' \
              || echo '(no PCIe error messages)'"

    # Dump the whole path, not just the endpoint: the root port carries its own
    # CXL DVSEC and AER configuration, and a problem there presents as an
    # endpoint symptom.
    local path_bdfs=""
    while IFS= read -r bdf; do
        [ -n "$bdf" ] || continue
        p="$(readlink -f "/sys/bus/pci/devices/$bdf" 2>/dev/null)"
        while [ -n "$p" ] && [ "$p" != "/" ]; do
            case "$(basename "$p")" in
                ????:??:??.?) path_bdfs="${path_bdfs}$(basename "$p")"$'\n' ;;
                *) break ;;
            esac
            p="$(dirname "$p")"
        done
    done <<< "$cxl_bdfs"
    path_bdfs="$(printf '%s' "$path_bdfs" | sort -u)"

    while IFS= read -r bdf; do
        [ -n "$bdf" ] || continue
        run_cmd "lspci verbose ($bdf)" lspci -vvv -s "$bdf"
    done <<< "$path_bdfs"

    # Raw config space carries the CXL DVSEC contents, which lspci may not
    # decode on older pciutils.
    while IFS= read -r bdf; do
        [ -n "$bdf" ] || continue
        run_cmd "PCI config space dump ($bdf)" lspci -xxxx -s "$bdf"
    done <<< "$cxl_bdfs"

    while IFS= read -r bdf; do
        [ -n "$bdf" ] || continue
        dump_sysfs "PCI sysfs attributes ($bdf)" "/sys/bus/pci/devices/$bdf" 1
    done <<< "$cxl_bdfs"
}


# ---------------------------------------------------------------------------
# Boot-time kernel log
#
# The dmesg ring buffer holds only what has not yet been overwritten. On a
# long-running server the boot messages are long gone, and several conclusions
# in this report are drawn from boot-time lines (APEI firmware-first, module
# taint, unsigned-module rejection). Read the journal, which keeps the whole
# boot, and fall back to dmesg only when journald is unavailable.
# ---------------------------------------------------------------------------
KERNEL_BOOT_LOG=""
KERNEL_BOOT_LOG_LOADED=0

# Load the log into the global. Must be called directly, never inside a pipeline
# or command substitution: those run in a subshell, where the assignment is
# discarded and the "cache" silently reloads on every use.
kernel_log_load() {
    [ "$KERNEL_BOOT_LOG_LOADED" -eq 1 ] && return 0
    KERNEL_BOOT_LOG_LOADED=1
    if command -v journalctl >/dev/null 2>&1; then
        local probe
        probe="$(journalctl -k -b 0 --no-pager -n 1 2>/dev/null)"
        # journalctl exits 0 and prints "-- No entries --" when the caller
        # cannot read the journal, so the exit status alone is not a usable
        # probe: it would hide the fact that we got nothing and skip dmesg.
        case "$probe" in
            ''|*'No entries'*) : ;;
            *) KERNEL_BOOT_LOG="$(journalctl -k -b 0 --no-pager 2>/dev/null)" ;;
        esac
    fi
    if [ -z "$KERNEL_BOOT_LOG" ]; then
        KERNEL_BOOT_LOG="$(dmesg 2>/dev/null)"
    fi
    return 0
}

kernel_log_boot() {
    kernel_log_load
    printf '%s\n' "$KERNEL_BOOT_LOG"
}

# True when the log we have actually reaches the beginning of this boot. If it
# does not, the absence of a boot-time message proves nothing.
kernel_log_reaches_boot() {
    kernel_log_boot | grep -q 'Linux version\|Command line:'
}

# ===========================================================================
# Analysis helpers
#
# The summary is a triage aid, not a verdict: it states what was observed and
# points at the section holding the evidence. validate_host.sh is the script
# that passes or fails a host. Levels are used strictly:
#   OK   - observed and unremarkable
#   NOTE - worth a human's eye, but a legitimate configuration
#   WARN - likely to mislead or to block something
#   --   - not determined (a tool was missing, or the data was unavailable);
#          never a judgement about the host
# ===========================================================================
ANALYSIS_NOTES=0
ANALYSIS_WARNS=0

a_head() {
    log ""
    log "[$1]"
    printf "\n  ${C_BOLD}[%s]${C_RESET}\n" "$1"
}

a_line() {
    local level="$1" label="$2"
    shift 2
    local detail="$*" tag color
    case "$level" in
        ok)   tag="OK  "; color="$C_GREEN" ;;
        note) tag="NOTE"; color="$C_CYAN";   ANALYSIS_NOTES=$((ANALYSIS_NOTES + 1)) ;;
        warn) tag="WARN"; color="$C_YELLOW"; ANALYSIS_WARNS=$((ANALYSIS_WARNS + 1)) ;;
        *)    tag="--  "; color="$C_DIM" ;;
    esac
    log "$(printf '  %-4s  %-21s %s' "$tag" "$label" "$detail")"
    printf "  ${color}%-4s${C_RESET}  %-21s %s\n" "$tag" "$label" "$detail"
}

# continuation line, aligned under the detail column
a_cont() {
    log "$(printf '  %-4s  %-21s %s' "" "" "$*")"
    printf "  %-4s  %-21s %s\n" "" "" "$*"
}

# first line of a sysfs file, empty string when absent
sysread() { [ -f "$1" ] && head -c 256 "$1" 2>/dev/null | head -1 || true; }

# SMBIOS slot designation / CXL capability for a bus address
slot_for_bdf() {
    command -v dmidecode >/dev/null 2>&1 || return 0
    dmidecode -t 9 2>/dev/null | awk -v b="$1" '
        /^Handle/ { des=""; cxl="" }
        /^\tDesignation:/ { des = substr($0, index($0, ": ")+2) }
        /CXL 2.0 capable/ { cxl = "CXL 2.0 capable" }
        /CXL 1.0 capable/ { if (cxl == "") cxl = "CXL 1.0 capable" }
        index($0, "Bus Address: " b) {
            printf "%s|%s", des, (cxl ? cxl : "NOT CXL capable"); exit
        }'
}

# ===========================================================================
# Summary analysis
# ===========================================================================
collect_analysis() {
    section "Summary"

    # Load once here, outside any pipeline, so the checks below read a
    # cached copy instead of re-running journalctl on each one.
    kernel_log_load

    # ---- device chain ---------------------------------------------------
    a_head "device chain"

    local bdfs bdf slot des cap
    bdfs="$( { lspci -D -d 20a6: 2>/dev/null
               lspci -D -d ::0502 2>/dev/null
               lspci -D 2>/dev/null | grep -i 'CXL'
             } | awk '{print $1}' | sort -u )"
    if [ -z "$bdfs" ]; then
        a_line warn "XCENA/CXL PCI" "no device found (vendor 20a6 / class 0502 / name match)"
    else
        for bdf in $bdfs; do
            slot="$(slot_for_bdf "$bdf")"
            des="${slot%%|*}"
            cap="${slot##*|}"
            if [ -z "$slot" ]; then
                a_line ok "XCENA/CXL PCI" "$bdf"
            elif [ "$cap" = "NOT CXL capable" ]; then
                a_line warn "XCENA/CXL PCI" "$bdf in ${des}"
                a_cont "this slot is NOT CXL capable - the card will enumerate as"
                a_cont "plain PCIe and never bind the CXL driver. See section 2."
            else
                a_line ok "XCENA/CXL PCI" "$bdf  slot: ${des}  ($cap)"
            fi
        done
    fi

    local memdir mem fw ram ram_bytes szf mem_count=0
    for memdir in /sys/bus/cxl/devices/mem*; do
        [ -d "$memdir" ] || continue
        mem_count=$((mem_count + 1))
        mem="$(basename "$memdir")"
        fw="$(sysread "$memdir/firmware_version")"
        # cxl-cli already renders this human-readable and works across kernel
        # versions; sysfs moved the attribute (memdev/ram_size in older kernels,
        # memdev/ram/size since ~6.8), so use the tool first and fall back.
        ram=""
        if command -v cxl >/dev/null 2>&1; then
            # Scope to this memdev: unscoped, every row on a multi-device host
            # printed device 0's size.
            ram="$(cxl list -m "$mem" -M -u 2>/dev/null \
                   | grep -oP '"ram_size":"\K[^"]+' | head -1)"
        fi
        if [ -z "$ram" ]; then
            ram_bytes=""
            for szf in "$memdir/ram/size" "$memdir/ram_size"; do
                [ -f "$szf" ] || continue
                ram_bytes="$(sysread "$szf")"
                [ -n "$ram_bytes" ] && break
            done
            # Convert with bash arithmetic (handles the 0x prefix) rather than
            # awk's strtonum(), which only exists in gawk — Ubuntu ships mawk.
            # Guard the pattern strictly: `$(( ))` on a non-numeric string
            # prints "value too great for base" to the terminal before any
            # redirection applies, corrupting the progress column.
            # A digit-leading hex token like "12ab" passed the old guard, and
            # $(( )) then failed with "value too great for base" — an expansion
            # error, which unwinds out of this function and silently truncates
            # the rest of the Summary. Accept 0x-hex or plain decimal, nothing
            # else.
            case "${ram_bytes:-}" in
                0x*[!0-9a-fA-F]*) ram_bytes="" ;;
                0x*)              : ;;
                *[!0-9]*)         ram_bytes="" ;;
            esac
            case "${ram_bytes:-}" in
                0x*|[0-9]*)
                    if [ "$((ram_bytes))" -gt 0 ] 2>/dev/null; then
                        ram="$(awk -v b="$((ram_bytes))" \
                               'BEGIN{ printf "%.2f GiB", b/1073741824 }')"
                    fi
                    ;;
            esac
        fi
        a_line ok "CXL memdev" "$mem  fw=${fw:-unknown}  ${ram:-size unknown}"
    done
    if [ "$mem_count" -eq 0 ]; then
        a_line warn "CXL memdev" "no /sys/bus/cxl/devices/mem* - CXL driver did not bind"
    fi

    # Report every region, not just the first: on a multi-device host a single
    # uncommitted region is exactly what the summary needs to surface.
    local regdir reg rmode rcommit reg_count=0
    for regdir in /sys/bus/cxl/devices/region*; do
        [ -d "$regdir" ] || continue
        reg_count=$((reg_count + 1))
        reg="$(basename "$regdir")"
        rmode="$(sysread "$regdir/mode")"
        rcommit="$(sysread "$regdir/commit")"
        if [ "$rcommit" = "1" ]; then
            a_line ok "CXL region" "$reg  mode=${rmode:-?}  commit=1"
        else
            a_line warn "CXL region" "$reg  commit=${rcommit:-?} - region is not committed"
        fi
    done
    if [ "$reg_count" -eq 0 ]; then
        a_line warn "CXL region" "no region configured"
    fi

    # jq is optional (see README), so its absence must read as "not determined"
    # rather than "no DAX device" — the latter is a false alarm on a healthy host.
    local dax_json dax_line dchar dmode dnode dax_count=0
    if ! command -v daxctl >/dev/null 2>&1; then
        a_line na "DAX device" "daxctl not installed - see section 8"
    elif ! command -v jq >/dev/null 2>&1; then
        a_line na "DAX device" "jq not installed, cannot parse - see section 8"
    else
        dax_json="$(daxctl list -D 2>/dev/null)"
        while IFS='|' read -r dchar dmode dnode; do
            [ -n "$dchar" ] || continue
            dax_count=$((dax_count + 1))
            if [ "$dmode" != "devdax" ]; then
                a_line warn "DAX device" "$dchar mode=${dmode:-?} - devdax is required for computing"
                a_cont "fix: sudo daxctl reconfigure-device --mode=devdax $dchar"
            else
                a_line ok "DAX device" "$dchar  mode=devdax  target_node=${dnode:-?}"
            fi
        done <<< "$(printf '%s' "${dax_json:-[]}" \
                    | jq -r '.[]? | "\(.chardev)|\(.mode)|\(.target_node // "?")"' 2>/dev/null)"
        [ "$dax_count" -eq 0 ] && a_line warn "DAX device" "no DAX device found"
    fi

    if lsmod 2>/dev/null | grep -q '^mx_dma '; then
        a_line ok "mx_dma driver" "loaded  ($(ls /dev/mx_dma 2>/dev/null | wc -l) device nodes)"
    else
        a_line warn "mx_dma driver" "module not loaded"
    fi

    local svc
    if ! command -v systemctl >/dev/null 2>&1; then
        a_line na "pxl_resourced" "systemctl not available - cannot determine"
    else
        svc="$(systemctl is-active pxl_resourced 2>/dev/null)"
        if [ "$svc" = "active" ]; then
            a_line ok "pxl_resourced" "active"
        else
            a_line warn "pxl_resourced" "${svc:-unknown} - the daemon is not running"
        fi
    fi

    # ---- link -----------------------------------------------------------
    a_head "link"
    if [ -n "$bdfs" ]; then
        for bdf in $bdfs; do
            local d="/sys/bus/pci/devices/$bdf"
            local cs cw ms mw parent pms
            cs="$(sysread "$d/current_link_speed")"; cw="$(sysread "$d/current_link_width")"
            ms="$(sysread "$d/max_link_speed")";     mw="$(sysread "$d/max_link_width")"
            parent="$(dirname "$(readlink -f "$d" 2>/dev/null)")"
            pms="$(sysread "$parent/max_link_speed")"
            if [ -z "$cs" ]; then
                a_line na "PCIe link" "$bdf  link state unavailable"
            elif [ "$cs" = "$ms" ] && [ "$cw" = "$mw" ]; then
                a_line ok "PCIe link" "$bdf  $cs x$cw (at device maximum)"
            else
                a_line note "PCIe link" "$bdf  $cs x$cw  (device max $ms x$mw)"
                if [ -n "$pms" ] && [ "$cs" = "$pms" ]; then
                    a_cont "capped by upstream port $(basename "$parent") (max $pms)"
                    a_cont "expected: the device outruns the platform, not a fault"
                else
                    a_cont "below device maximum - check ASPM/idle vs. real degradation (see 10-8)"
                fi
            fi
        done
    else
        a_line na "PCIe link" "no device to report on"
    fi

    # ---- errors ---------------------------------------------------------
    a_head "errors"

    local fw_first=0
    if kernel_log_boot | grep -q 'firmware first mode is enabled'; then
        fw_first=1
        a_line warn "AER ownership" "APEI firmware-first is ENABLED"
        a_cont "Linux does not own PCIe AER, so the AER counters below are not"
        a_cont "authoritative on this host — read them together with the BMC"
        a_cont "event log line beneath."
    elif kernel_log_reaches_boot; then
        a_line ok "AER ownership" "OS-native AER"
    else
        # Saying "OS-native" here because a boot-time line is missing would turn
        # a truncated log into a false all-clear — the exact misdiagnosis this
        # section exists to prevent.
        a_line na "AER ownership" "cannot determine - the kernel log does not reach boot"
        a_cont "treat the AER counters below as inconclusive and check the BMC log"
        fw_first=1
    fi

    local aer_total=0 f v
    for bdf in ${bdfs:-}; do
        for f in /sys/bus/pci/devices/"$bdf"/aer_dev_correctable \
                 /sys/bus/pci/devices/"$bdf"/aer_dev_fatal \
                 /sys/bus/pci/devices/"$bdf"/aer_dev_nonfatal; do
            [ -f "$f" ] || continue
            v="$(awk '{ s += $2 } END { print s+0 }' "$f" 2>/dev/null)"
            aer_total=$((aer_total + ${v:-0}))
        done
    done
    if [ "$aer_total" -eq 0 ]; then
        if [ "$fw_first" -eq 1 ]; then
            a_line note "AER counters" "all zero (but not authoritative — see above)"
        else
            a_line ok "AER counters" "all zero"
        fi
    else
        a_line warn "AER counters" "$aer_total logged errors - see section 11"
    fi

    # On a firmware-first host this is where hardware errors actually land, so
    # checking it is what lets the report conclude rather than defer.
    local sel_entries=""
    if command -v ipmitool >/dev/null 2>&1 \
       && { [ -e /dev/ipmi0 ] || [ -e /dev/ipmi/0 ]; }; then
        sel_entries="$(ipmitool sel info 2>/dev/null \
                       | awk -F: '/^Entries/ { gsub(/[^0-9]/, "", $2); print $2; exit }')"
    fi
    if [ -z "$sel_entries" ]; then
        a_line na "BMC event log" "not reachable (no ipmitool or no BMC interface)"
        [ "$fw_first" -eq 1 ] && a_cont "on this firmware-first host that leaves the error picture incomplete"
    elif [ "$sel_entries" = "0" ]; then
        a_line ok "BMC event log" "0 entries"
    else
        a_line warn "BMC event log" "$sel_entries entries — see section 11"
    fi

    # A DMA driver whose interrupt has never fired is worth a look; on a
    # polling-mode driver it is expected.
    local irq_total
    irq_total="$(awk '
        NR == 1 { next }
        {
            d = ""; t = 0
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^[0-9]+$/) t += $i; else d = d " " $i
            }
            if (d ~ /mx_dma/) s += t
        }
        END { print s + 0 }' /proc/interrupts 2>/dev/null)"
    if lsmod 2>/dev/null | grep -q '^mx_dma '; then
        if [ "${irq_total:-0}" -eq 0 ] 2>/dev/null; then
            a_line note "mx_dma interrupts" "0 delivered since boot"
            a_cont "expected if the driver polls; a real finding if it relies on MSI"
        else
            a_line ok "mx_dma interrupts" "${irq_total} delivered"
        fi
    fi

    if ! command -v cxl >/dev/null 2>&1; then
        a_line na "CXL media" "cxl-cli not installed - cannot query device health"
    else
        local h media dirty verr life temp
        h="$(cxl list -M -H -u 2>/dev/null)"
        if [ -z "$h" ]; then
            a_line na "CXL media" "no health data returned - see section 7"
        else
            media="$(printf '%s' "$h" | grep -oP '"media_normal":\s*\K\w+' | head -1)"
            dirty="$(printf '%s' "$h" | grep -oP '"dirty_shutdowns":\s*\K-?\d+' | head -1)"
            verr="$(printf '%s' "$h"  | grep -oP '"volatile_errors":\s*\K-?\d+' | head -1)"
            life="$(printf '%s' "$h"  | grep -oP '"life_used_percent":\s*\K-?\d+' | head -1)"
            temp="$(printf '%s' "$h"  | grep -oP '"temperature":\s*\K-?\d+' | head -1)"
            if [ "${media:-}" = "true" ]; then
                a_line ok "CXL media" "media_normal=true  dirty_shutdowns=${dirty:-?}  volatile_errors=${verr:-?}"
            else
                a_line warn "CXL media" "media_normal=${media:-unknown} - see section 7"
            fi
            # Values outside their defined range mean the firmware does not
            # populate the field; reporting them as real would be misleading.
            if [ -n "${life:-}" ] && { [ "$life" -lt 0 ] || [ "$life" -gt 100 ]; } 2>/dev/null; then
                a_line note "health raw values" "life_used_percent=$life out of the 0-100 range"
                [ -n "${temp:-}" ] && a_cont "temperature=$temp (0x7FFF is the 'not implemented' sentinel)"
                a_cont "the firmware appears not to populate these fields (7-3)"
            fi
        fi
    fi

    # ---- kernel ---------------------------------------------------------
    a_head "kernel"

    local taint
    taint="$(cat /proc/sys/kernel/tainted 2>/dev/null)"
    if [ "${taint:-0}" = "0" ]; then
        a_line ok "kernel taint" "0 (clean)"
    else
        local why
        why="$(kernel_log_boot | grep -oiP '\w+: (loading out-of-tree module|module verification failed)' \
               | awk -F: '{print $1}' | sort -u | paste -sd, -)"
        a_line note "kernel taint" "$taint  ${why:+(}${why:-}${why:+)}"
        a_cont "expected for an out-of-tree vendor driver; see the kernel taint item"
    fi

    local kconfig="/boot/config-$(uname -r)" missing=""
    if [ -f "$kconfig" ]; then
        local opt
        for opt in CONFIG_CXL_BUS CONFIG_CXL_PCI CONFIG_CXL_ACPI CONFIG_CXL_MEM \
                   CONFIG_CXL_REGION CONFIG_DEV_DAX CONFIG_DEV_DAX_CXL; do
            grep -qE "^${opt}=(y|m)" "$kconfig" || missing="${missing}${opt} "
        done
        if [ -z "$missing" ]; then
            a_line ok "CXL kernel config" "all required CONFIG_CXL_*/DEV_DAX options enabled"
        else
            a_line warn "CXL kernel config" "not enabled: $missing"
            a_cont "this kernel cannot bring the device up; see 4-2"
        fi
    else
        a_line na "CXL kernel config" "$kconfig not available"
    fi

    if ls /sys/devices/system/node/node*/access0/initiators/read_bandwidth >/dev/null 2>&1; then
        a_line ok "HMAT" "present ($(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l) nodes)"
    else
        a_line note "HMAT" "no HMAT performance attributes published by the BIOS"
        a_cont "CXL nodes will carry no bandwidth/latency data for tiering (6-7)"
    fi

    # Secure Boot plus an unsigned vendor module is the combination that stops
    # the driver from loading at all, so only flag the pair.
    if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        if kernel_log_boot | grep -q 'module verification failed'; then
            a_line warn "Secure Boot" "enabled, and unsigned modules were rejected"
            a_cont "sign mx_dma or disable Secure Boot; see the Secure Boot and taint items"
        else
            a_line note "Secure Boot" "enabled - unsigned vendor modules will not load"
        fi
    fi
}

# ===========================================================================
# Host-identifying data
# ===========================================================================

# Tell the reader plainly what identifying data the report carries, so whoever
# has to approve sending it can check rather than guess.
report_data_inventory() {
    a_head "host-identifying data"

    # Every status below was established by searching the finished report for
    # the value itself, not by observing that a substitution ran.
    local rows="hostname (all forms)|$MASK_STATE_HOST
machine-id|$MASK_STATE_MID
hardware serials, UUIDs, asset tags, account names, MAC/IP|$MASK_STATE_ID
BIOS vendor, version and date|kept - needed for diagnosis
system / baseboard manufacturer and product name|kept - needed for diagnosis
physical slot labels and slot inventory|kept - needed for diagnosis
CXL device serial number and firmware version|kept - identifies the unit
full PCI device inventory (all installed hardware)|kept
local filesystem sizes and mount points|kept"

    local failed=0
    case "$MASK_STATE_HOST$MASK_STATE_MID$MASK_STATE_ID" in
        *"NOT MASKED"*|*"NOT VERIFIED"*) failed=1 ;;
    esac

    local headline
    if [ "$failed" -eq 0 ]; then
        headline="Host-identifying fields were masked, and their absence was verified."
        log "  $headline"
        printf "  %s\n" "$headline"
    else
        headline="NOT FULLY MASKED - see the rows below."
        log "  $headline"
        printf "  ${C_RED}%s${C_RESET}\n" "$headline"
    fi

    local label where
    printf '%s\n' "$rows" | while IFS='|' read -r label where; do
        log "$(printf '    %-56s %s' "$label" "$where")"
        printf "    %-56s %s\n" "$label" "$where"
    done

    log ""
    log "  Verification searches this report for the values themselves, so a row"
    log "  saying MASKED means the value is not in this file. It cannot cover"
    log "  what it was never given: an internal hostname mentioned only inside"
    log "  an application's log line, a custom path, an identifier in a format"
    log "  no rule recognises. A quad directly introduced as a version or"
    log "  firmware revision is left alone, because it is indistinguishable"
    log "  from an IP address and removing it would break the diagnosis."

    return "$failed"
}

# ---------------------------------------------------------------------------
# Masking
#
# The report may only claim a field is masked when that field is verifiably
# gone. Earlier versions inferred "MASKED" from "the substitution ran", which is
# a different statement: it is still true when the pass was pointed at the wrong
# value, when the value reached the report by a route no pass covers, or when
# the pattern silently matched nothing. Every false claim found in review came
# from that one inference.
#
# So: capture the concrete values before masking, substitute, then grep the
# finished report for each of them. A row says MASKED only when the count is
# zero. A pass that fails, skips, or simply misses all land in the same place.
# ---------------------------------------------------------------------------

# Newline-separated sets of literal values that must not survive.
MASK_VALUES_HOST=""
MASK_VALUES_MID=""
MASK_VALUES_ID=""

# Per-category outcome, filled in by mask_verify.
MASK_STATE_HOST=""
MASK_STATE_MID=""
MASK_STATE_ID=""

# mask_add <set-name> <value>
# Values shorter than 4 characters are refused: substituting them across a
# report full of short tokens corrupts more than it protects.
mask_add() {
    local set_name="$1" v="$2"
    [ -n "$v" ] || return 0
    [ "${#v}" -ge 4 ] || return 0
    case "$v" in *[!!-~]*) return 0 ;; esac      # printable, no whitespace
    case "$set_name" in
        host) case "$MASK_VALUES_HOST" in *"$v"$'\n'*) return 0 ;; esac
              MASK_VALUES_HOST="${MASK_VALUES_HOST}${v}"$'\n' ;;
        mid)  MASK_VALUES_MID="${MASK_VALUES_MID}${v}"$'\n' ;;
        id)   case "$MASK_VALUES_ID" in *"$v"$'\n'*) return 0 ;; esac
              MASK_VALUES_ID="${MASK_VALUES_ID}${v}"$'\n' ;;
    esac
}

# The report acquires the hostname from more places than `hostname` reports:
# hostnamectl prints static, transient and pretty forms independently, the
# journal stamps whichever the kernel had at boot, and /etc/hostname is free
# text. Gather every form, then verify against all of them.
mask_gather() {
    local v

    for v in "$(hostname 2>/dev/null)" "$(hostname -s 2>/dev/null)" \
             "$(hostname -f 2>/dev/null)" "$(uname -n 2>/dev/null)" \
             "$(cat /etc/hostname 2>/dev/null)"; do
        mask_add host "$v"
    done
    if command -v hostnamectl >/dev/null 2>&1; then
        while IFS= read -r v; do
            mask_add host "$v"
        done <<< "$(hostnamectl 2>/dev/null \
                    | sed -n 's/^[[:space:]]*\(Static\|Transient\|Pretty\) hostname:[[:space:]]*//p')"
    fi

    mask_add mid "$(cat /etc/machine-id 2>/dev/null)"

    # Hardware identity, as dmidecode actually prints it, plus the account names
    # that appear in ps/lsof/ls/coredumpctl output where no labelled rule reaches.
    if command -v dmidecode >/dev/null 2>&1; then
        while IFS= read -r v; do
            case "$v" in
                ''|'Not Specified'|'Not Provided'|'Unknown'|'Default string'|\
                'To be filled by O.E.M.'|'None'|*[!!-~]*) continue ;;
            esac
            mask_add id "$v"
        done <<< "$(dmidecode -t 1 -t 2 -t 3 -t 4 -t 17 2>/dev/null \
                    | sed -n 's/^[[:space:]]*\(Serial Number\|UUID\|Asset Tag\):[[:space:]]*//p')"
    fi
    mask_add id "${SUDO_USER:-}"
    mask_add id "$(logname 2>/dev/null)"
}

# Escape every character that is live in a BRE and in the s/// delimiter.
mask_escape() { printf '%s' "$1" | sed 's/[][\\.^$*/&]/\\&/g'; }

# Fixed expressions. A syntax error here is a defect in this script, so each is
# applied on its own: one unsupported construct then costs one rule instead of
# disabling the whole set, which is what would happen on a non-GNU sed.
# Assembled rather than written inline so the line stays readable: it marks a
# quad that is directly introduced as a version, by replacing its dots, so the
# IPv4 rule below cannot see a quad. The dots are restored after that rule runs.
_VER_MARK='\([Vv]ersion[: ]\+\|[Rr]evision[: ]\+\|\bfw[ =]\+\|\bv\)'
_VER_QUAD='\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)'
_VER_GUARD_EXPR="s/${_VER_MARK}${_VER_QUAD}/\\1\\2@@D@@\\3@@D@@\\4@@D@@\\5/g"

IDENTITY_EXPRS=(
    # MAC. Anchored on both sides so it cannot consume six octets out of the
    # middle of an 8-octet WWN, which would destroy the WWN as diagnostic data
    # while leaving the rest of it in place.
    's/\(^\|[^:0-9A-Fa-f]\)\([0-9A-Fa-f]\{2\}:\)\{5\}[0-9A-Fa-f]\{2\}\([^:0-9A-Fa-f]\|$\)/\1<mac-redacted>\3/g'
    # IPv6 and other colon-hex identifiers (WWN, NQN fragments). Needs four
    # or more groups, so a PCI BDF (two colons) and a timestamp are untouched.
    's/\b[0-9A-Fa-f]\{0,4\}\(:[0-9A-Fa-f]\{0,4\}\)\{3,7\}\b/<hex-id-redacted>/g'
    # IPv4. The exemption is deliberately narrow: it disarms only a quad that is
    # directly introduced as a version, rather than exempting a whole line that
    # happens to contain the word "firmware" — which in a CXL report is most of
    # them, and would let a real address through.
    "$_VER_GUARD_EXPR"
    's/\b\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\([^-.0-9A-Za-z]\|$\)/<ipv4-redacted>\2/g'

    's/^\([[:space:]]*Machine ID:\).*/\1 <redacted>/'
    's/^\([[:space:]]*Serial Number:\).*/\1 <redacted>/'
    's/^\([[:space:]]*UUID:\).*/\1 <redacted>/'
    's/^\([[:space:]]*Asset Tag:\).*/\1 <redacted>/'
    's/SUDO_USER=[^ ]*/SUDO_USER=<redacted>/g'
    's/uid=\([0-9]*\)([^)]*)/uid=\1(<redacted>)/g'
    's/gid=\([0-9]*\)([^)]*)/gid=\1(<redacted>)/g'
    's/\([0-9]\{1,7\}\)([a-z_][a-z0-9_-]*)/\1(<redacted>)/g'
    # Home directories carry the account name through ps args and coredump paths.
    's|/home/[A-Za-z0-9._-]\{1,32\}|/home/<user-redacted>|g'
    's|/Users/[A-Za-z0-9._-]\{1,32\}|/Users/<user-redacted>|g'
)

mask_apply() {
    local expr err applied=0
    for expr in "${IDENTITY_EXPRS[@]}"; do
        if ! err="$(sed -i -e "$expr" "$REPORT_FILE" 2>&1)"; then
            log ""
            log "MASKING: expression not applied on this system's sed:"
            log "  $expr"
            [ -n "$err" ] && log "  $err"
        else
            applied=$((applied + 1))
        fi
    done
    # Put the dots back into version quads the exemption parked out of the way.
    sed -i 's/@@D@@/./g' "$REPORT_FILE" 2>/dev/null || true

    # Literal values, longest first so an FQDN is replaced before its short form
    # leaves a fragment behind. A plain literal substitution is used rather than
    # a \b-anchored one: \b fails open at a non-word edge, and reports rc=0
    # while matching nothing.
    local v esc
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        esc="$(mask_escape "$v")"
        sed -i "s/${esc}/<host-redacted>/g" "$REPORT_FILE" 2>/dev/null || true
    done <<< "$(printf '%s' "$MASK_VALUES_HOST" | awk '{ print length, $0 }' \
                | sort -rn | cut -d' ' -f2-)"

    while IFS= read -r v; do
        [ -n "$v" ] || continue
        esc="$(mask_escape "$v")"
        sed -i "s/${esc}/<machine-id-redacted>/g" "$REPORT_FILE" 2>/dev/null || true
    done <<< "$MASK_VALUES_MID"

    while IFS= read -r v; do
        [ -n "$v" ] || continue
        esc="$(mask_escape "$v")"
        sed -i "s/${esc}/<redacted>/g" "$REPORT_FILE" 2>/dev/null || true
    done <<< "$MASK_VALUES_ID"

    [ "$applied" -gt 0 ]
}

# mask_check_values <newline-separated values> -> prints surviving count
mask_count_survivors() {
    local v n=0
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        if grep -qF -- "$v" "$REPORT_FILE" 2>/dev/null; then
            n=$((n + 1))
        fi
    done <<< "$1"
    printf '%s' "$n"
}

# The verification the whole design rests on: look for the values themselves in
# the finished report, and for the address shapes no literal list can enumerate.
mask_verify() {
    local rc=0 n

    n="$(mask_count_survivors "$MASK_VALUES_HOST")"
    if [ -z "$MASK_VALUES_HOST" ]; then
        MASK_STATE_HOST="NOT VERIFIED - no hostname could be determined"; rc=1
    elif [ "$n" -eq 0 ]; then
        MASK_STATE_HOST="MASKED"
    else
        MASK_STATE_HOST="NOT MASKED - $n value(s) still present"; rc=1
    fi

    n="$(mask_count_survivors "$MASK_VALUES_MID")"
    if [ -z "$MASK_VALUES_MID" ]; then
        MASK_STATE_MID="NOT VERIFIED - /etc/machine-id unreadable"; rc=1
    elif [ "$n" -eq 0 ]; then
        MASK_STATE_MID="MASKED"
    else
        MASK_STATE_MID="NOT MASKED - still present"; rc=1
    fi

    n="$(mask_count_survivors "$MASK_VALUES_ID")"

    # Address shapes cannot be checked with a bare pattern: a version number
    # preserved on purpose is indistinguishable from an IPv4 address by shape
    # alone, and grepping for one reports the other as a leak. Ask the question
    # the rules themselves define instead — apply them again to a copy, and see
    # whether anything is left for them to change. Idempotence means clean.
    local shapes=0 recheck
    recheck="$(mktemp "${TMPDIR:-/tmp}/xcena_mask_recheck_XXXXXX" 2>/dev/null)" || recheck=""
    if [ -n "$recheck" ]; then
        if cp "$REPORT_FILE" "$recheck" 2>/dev/null; then
            local expr
            for expr in "${IDENTITY_EXPRS[@]}"; do
                sed -i -e "$expr" "$recheck" 2>/dev/null || true
            done
            sed -i 's/@@D@@/./g' "$recheck" 2>/dev/null || true
            cmp -s "$REPORT_FILE" "$recheck" || shapes=1
        fi
        rm -f "$recheck"
    fi

    if [ "$n" -eq 0 ] && [ "$shapes" -eq 0 ]; then
        MASK_STATE_ID="MASKED"
    elif [ "$n" -gt 0 ]; then
        MASK_STATE_ID="NOT MASKED - $n value(s) still present"; rc=1
    else
        MASK_STATE_ID="NOT MASKED - the masking rules still match something"; rc=1
    fi

    return "$rc"
}

redact_report() {
    local rc=0
    mask_gather
    mask_apply || rc=1
    mask_verify || rc=1
    return "$rc"
}

# ===========================================================================
# Main
# ===========================================================================
collect_host_validation
collect_platform
collect_versions
collect_kernel
collect_runtime
collect_memory
collect_cxl
collect_dax
collect_fw_info
collect_im_smart
collect_pcie

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
collect_analysis

# Mask before the closing sections are written, so the inventory below can state
# what actually happened to each field. Nothing written after this point carries
# host-identifying data — the inventory names field categories, and the
# collection block holds counts and section labels.
REDACT_FAILED=0
redact_report || REDACT_FAILED=1

report_data_inventory || REDACT_FAILED=1

# Measured after the analysis phase, which re-runs dmesg, cxl and ipmitool.
END_EPOCH="$(date '+%s')"
ELAPSED=$((END_EPOCH - START_EPOCH))

a_head "collection"
log "Privilege        : $PRIV_LEVEL"
log "Collected items  : OK=$OK_COUNT  FAIL=$FAIL_COUNT  SKIP=$SKIP_COUNT"
log "Summary flags    : $ANALYSIS_WARNS WARN, $ANALYSIS_NOTES NOTE"
log "Elapsed          : ${ELAPSED}s"
if [ -n "$FAILED_ITEMS" ]; then
    log ""
    log "[failed items]"
    printf '%s' "$FAILED_ITEMS" | sed 's/^/  - /' >> "$REPORT_FILE"
fi
# No status_ok here: the summary is not itself a collected item, and counting
# it would make the terminal total disagree with the total inside the report.

# ---------------------------------------------------------------------------
# If anything was left unmasked, say so where it cannot be missed
# ---------------------------------------------------------------------------
if [ "$REDACT_FAILED" -eq 1 ]; then
    # The detail is in the inventory near the end of a 20,000-line file; nobody
    # scrolling to check before sending will find it there.
    _banner_tmp="${REPORT_FILE}.prepend.$$"
    if {
        printf '%s\n' \
          "########################################################################" \
          "##  THIS REPORT WAS NOT FULLY MASKED                                  ##" \
          "##                                                                    ##" \
          "##  Some host-identifying fields are still present. The table at the  ##" \
          "##  end of this report, under [host-identifying data], names exactly  ##" \
          "##  which ones and why.                                               ##" \
          "##                                                                    ##" \
          "##  Review it by hand before sending this file anywhere.              ##" \
          "########################################################################" \
          ""
        cat "$REPORT_FILE"
    } > "$_banner_tmp" 2>/dev/null; then
        mv "$_banner_tmp" "$REPORT_FILE" 2>/dev/null || rm -f "$_banner_tmp"
    else
        rm -f "$_banner_tmp"
    fi

    # Rename so the filename cannot assert something the content does not.
    _failed_name="${REPORT_FILE%.log}_NOT_FULLY_MASKED.log"
    if mv "$REPORT_FILE" "$_failed_name" 2>/dev/null; then
        REPORT_FILE="$_failed_name"
    fi
fi

# ---------------------------------------------------------------------------
# Hand the report to the invoking user
#
# No archive is produced. The report is plain text that compresses well, and a
# customer who wants it smaller will compress it themselves; shipping a second
# file only creates a way to send the wrong one.
# ---------------------------------------------------------------------------
if [ -n "${SUDO_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
    chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$REPORT_FILE" 2>/dev/null || true
fi

# Build the format in a variable rather than splitting it across printf
# arguments: printf reuses its format for every remaining argument, so a split
# format prints the line once per argument group.
_done_fmt="\n${C_BOLD}  Done.${C_RESET}  collected"
_done_fmt="${_done_fmt} OK=${C_GREEN}%d${C_RESET}  FAIL=${C_RED}%d${C_RESET}"
_done_fmt="${_done_fmt}  SKIP=${C_YELLOW}%d${C_RESET}  (%ds)\n"
printf "$_done_fmt" "$OK_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$ELAPSED"
if [ "$ANALYSIS_WARNS" -gt 0 ] || [ "$ANALYSIS_NOTES" -gt 0 ]; then
    printf "  Summary: ${C_YELLOW}%d WARN${C_RESET}, ${C_CYAN}%d NOTE${C_RESET} — see the Summary section above\n" \
        "$ANALYSIS_WARNS" "$ANALYSIS_NOTES"
else
    printf "  Summary: ${C_GREEN}nothing flagged${C_RESET}\n"
fi
printf "  Report : ${C_CYAN}%s${C_RESET} (%s)\n" "$REPORT_FILE" "$(du -h "$REPORT_FILE" 2>/dev/null | cut -f1)"
if [ "$REDACT_FAILED" -eq 1 ]; then
    printf "\n  ${C_RED}${C_BOLD}NOT FULLY MASKED.${C_RESET} %s\n" \
           "Some host-identifying fields are still present."
    printf "  ${C_YELLOW}%s${C_RESET}\n" \
           "See [host-identifying data] at the end of the report for which ones,"
    printf "  ${C_YELLOW}%s${C_RESET}\n" \
           "and review by hand before sending it anywhere."
fi
if [ "$PRIV_LEVEL" != "root" ]; then
    printf "\n  ${C_RED}${C_BOLD}This report is INCOMPLETE (collected without root).${C_RESET}\n"
    printf "  ${C_YELLOW}Please re-run with: sudo bash %s${C_RESET}\n" "${BASH_SOURCE[0]:-troubleshooting.sh}"
fi
printf "\n"

# A wrapper or CI job must be able to tell that the report is not safe to send.
if [ "$REDACT_FAILED" -eq 1 ]; then
    exit 3
fi
exit 0
