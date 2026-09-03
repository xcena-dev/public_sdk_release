# public_sdk_release

Host-side diagnostic scripts for XCENA CXL devices.

Both scripts issue only read-only queries. They never write kernel or device
state, change configuration, or load and unload modules. Note that reading
device health does involve talking to the device: `cxl list -H/-I/-A` sends
Get Health Info, Get Partition Info and Get Alert Configuration mailbox
commands, which are themselves read-only operations.

| Script | Purpose | Output |
| --- | --- | --- |
| [`scripts/validate_host.sh`](scripts/validate_host.sh) | Quick pass/fail check that the host is set up correctly | Terminal only |
| [`scripts/troubleshooting.sh`](scripts/troubleshooting.sh) | Full diagnostic collection to send to XCENA support | One `.log` file |

---

## validate_host.sh

Run this first. It answers "is this host configured correctly?" in a few
seconds and needs no privileges.

```bash
bash validate_host.sh
```

Checks the system environment, XCENA PCI device presence, the `mx_dma` driver,
CXL/DAX configuration, the `libpxl` package and `pxl_resourced` service, the
CLI tools, and the MU toolchain. Each line is reported as `OK`, `WARN`, `FAIL`
or `INFO`; the script exits non-zero if anything failed.

## troubleshooting.sh

Run this when something is wrong and you need XCENA support to look at it.

```bash
sudo bash troubleshooting.sh
```

Keep `validate_host.sh` in the same directory. Section 1 of the report runs it
from there; if it is missing, the collector fetches it from a **pinned commit**
of this repository — not from `main` — and refuses to run anything that does
not look like the expected script. Bump `VALIDATE_HOST_REV` at the top of
`troubleshooting.sh` whenever `validate_host.sh` changes.

**Run it as root.** Without root, `dmesg`, `dmidecode`, `lspci -vv`, `acpidump`,
`journalctl` and most of the CXL sysfs tree return nothing useful. The script
re-executes itself under `sudo` automatically; if that is not possible it still
runs, but marks the report `_INCOMPLETE` so the recipient can tell at a glance.

It writes one file to the current directory:

```
troubleshooting_report_YYYY-MM-DD-HH-MM-SS.log
```

Host-identifying fields are always masked; the report lists exactly what was
masked and what was kept. Compress it yourself if you want it smaller — it is
plain text and compresses to roughly a tenth of its size.

### Options

| Option | Effect |
| --- | --- |
| *(none)* | Collects everything needed for a diagnosis. A few very large, low-signal sources are summarised. |
| `--full` | No summarising. Use only if XCENA asks for it — the report grows several times larger. |
| `-h`, `--help` | Usage. |

On a 2-socket, 6-NUMA-node test server the default report is about 1.7 MB and
`--full` about 6 MB. Both compress to roughly a tenth.

### What it collects

The report is organised into numbered sections. Every item records the command
that produced it, so any result can be reproduced by hand.

| # | Section | Contents |
| --- | --- | --- |
| 1 | Host Validation | `validate_host.sh`, run from the same directory or fetched at a pinned revision |
| 2 | Host Platform & BIOS | `hostnamectl`, BIOS/board/CPU via `dmidecode`, `lscpu`, DRAM population, **PCIe slot inventory with per-slot CXL capability**, Secure Boot, clock sync |
| 3 | Software & Tool Versions | `cxl`/`daxctl`/`ndctl`/`numactl`/`lspci` versions, XCENA packages, `modinfo mx_dma`, CXL/DAX module versions, MU toolchain |
| 4 | Kernel | `/proc/cmdline`, `CONFIG_CXL_*` build options, loaded modules, taint state, module parameters, IOMMU/DMA remapping, `dmesg -T` plus a filtered view, previous boot's kernel journal |
| 5 | XCENA Runtime | `mx_dma` device nodes and messages, `pxl_resourced` status/unit/journal, running processes, interrupt delivery, holders of `/dev/dax*`, `memlock` limits, SELinux/AppArmor, udev rules, core dumps |
| 6 | Memory & NUMA | `/proc/iomem`, NUMA topology and distances, `lsmem`, **HMAT bandwidth/latency per node**, memory block zones, tiering, THP/pressure counters, EDAC error counters |
| 7 | CXL Subsystem | Full `cxl list` topology, **device health / partition / alert configuration**, every CXL sysfs attribute *value*, CDAT, debugfs, and the CEDT, SRAT, HMAT, SLIT, MCFG and HEST ACPI tables |
| 8 | DAX | `daxctl` regions and devices, sysfs attributes, `devdax` mode check |
| 9 | Device Firmware | `xcena_cli device-info` and `fw-info` per device |
| 10 | PCIe | Topology tree, device discovery, **physical slot of each CXL device**, **link speed/width from endpoint to root port**, AER counters, ASPM policy, ACPI `_OSC` negotiation, GHES records, BMC/IPMI event log, `lspci -vvv` and config space for the whole path |
| 11 | Summary | Automated triage — see below |

### Summary section

The report ends with a triage summary, also printed to the terminal, covering
the device chain (PCI → memdev → region → DAX → driver → daemon), link state,
error sources and kernel configuration. Each line is one of:

- `OK` — observed and unremarkable
- `NOTE` — worth a human's eye, but a legitimate configuration
- `WARN` — likely to mislead, or to block something

```
  [device chain]
  OK    XCENA/CXL PCI         0000:2a:00.0  slot: J2A16 - SLOT_C  (CXL 2.0 capable)
  OK    CXL memdev            mem0  fw=1.0.11  233.00 GiB
  OK    CXL region            region0  mode=ram  commit=1
  OK    DAX device            dax0.0  mode=devdax  target_node=6

  [link]
  NOTE  PCIe link             0000:2a:00.0  32.0 GT/s PCIe x8  (device max 64.0 GT/s x8)
                              capped by upstream port 0000:29:02.0 (max 32.0 GT/s PCIe)
```

This is a triage aid, not a verdict — `validate_host.sh` is the script that
passes or fails a host.

---

## Privacy

The report describes the machine it ran on. Fields that identify *whose*
machine it is are always masked — there is no option to disable it, because
none of them answers a CXL question. Everything a diagnosis turns on is kept.
The report ends with a table stating exactly what was masked and what was kept,
so it can be reviewed rather than guessed at.

**Always kept — these are what a diagnosis turns on:**

- BIOS vendor, version and release date
- system and baseboard manufacturer, product name and model
- CPU model, memory configuration, PCI device inventory
- physical slot labels and per-slot CXL capability
- the CXL device's serial number and firmware version

**Always masked:**

| Field | Where it comes from |
| --- | --- |
| hostname, machine-id | `hostnamectl`, and every journal line |
| chassis, board and CPU serial numbers, UUIDs, asset tags | `dmidecode` |
| account names, and home-directory paths that contain them | `id`, and process arguments |
| MAC, IPv4 and IPv6 addresses | kernel log (see below) |

MAC addresses are not collected deliberately — the script runs no network
commands at all. They appear because the kernel logs a NIC's address when it
probes the device, and the report includes the kernel log.

Every row above is verified rather than assumed: after masking, the report is
searched for the values themselves, and a row says `MASKED` only when the count
is zero. If anything survives, the report says so in that table, carries a
banner at the top, is renamed `_NOT_FULLY_MASKED.log`, and the script exits 3.

Verification can only cover what it was given. Free-text kernel logs may still
contain identifying strings — an internal hostname mentioned inside an
application's own log line, a custom path, an identifier in a format no rule
recognises. A four-part number directly introduced as a version or firmware
revision is left alone, because it is indistinguishable from an IPv4 address
and removing it would break the diagnosis.

## Reading a report

The report is plain text. Sections are marked `>>> <n>-<m>. <title>`, so a
specific item can be pulled out directly:

```bash
# list the sections
grep '^>>> ' troubleshooting_report_*.log

# read one item
awk '/^>>> 7-3\./,/^>>> 7-4\./' troubleshooting_report_*.log

# find something and see which section it came from
grep -n 'firmware first mode' troubleshooting_report_*.log
```

## Requirements

Ubuntu or another `systemd` Linux with `bash` 4. The scripts degrade gracefully
when a tool is missing and mark the item `SKIP` rather than failing, but the
report is most useful with these installed:

```bash
sudo apt install cxl ndctl daxctl numactl pciutils dmidecode acpica-tools jq lsof ipmitool
```
