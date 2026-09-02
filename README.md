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
| [`scripts/troubleshooting.sh`](scripts/troubleshooting.sh) | Full diagnostic collection to send to XCENA support | `.log` + `.tar.gz` |

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

**Run it as root.** Without root, `dmesg`, `dmidecode`, `lspci -vv`, `acpidump`,
`journalctl` and most of the CXL sysfs tree return nothing useful. The script
re-executes itself under `sudo` automatically; if that is not possible it still
runs, but marks the report `_INCOMPLETE` so the recipient can tell at a glance.

It writes two files to the current directory:

```
troubleshooting_report_YYYY-MM-DD-HH-MM.log       full report
troubleshooting_report_YYYY-MM-DD-HH-MM.tar.gz    same, compressed — send this one
```

### Options

| Option | Effect |
| --- | --- |
| *(none)* | Collects everything needed for a diagnosis. A few very large, low-signal sources are summarised. |
| `--full` | No summarising. Use only if XCENA asks for it — the report grows several times larger. |
| `--redact` | Masks host-identifying fields before archiving. See [Privacy](#privacy). |
| `-h`, `--help` | Usage. |

Options can be combined (`--full --redact`).

On a 2-socket, 6-NUMA-node test server the default report is about 1.3 MB
(150 KB compressed); `--full` is about 5.6 MB (320 KB compressed).

### What it collects

The report is organised into numbered sections. Every item records the command
that produced it, so any result can be reproduced by hand.

| # | Section | Contents |
| --- | --- | --- |
| 1 | Host Validation | Embedded `validate_host.sh` run |
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

The report describes the machine it ran on. What matters for a diagnosis is
kept in every mode; `--redact` masks only the fields that identify *whose*
machine it is.

**Always kept — these are what a diagnosis turns on:**

- BIOS vendor, version and release date
- system and baseboard manufacturer, product name and model
- CPU model, memory configuration, PCI device inventory
- physical slot labels and per-slot CXL capability
- the CXL device's serial number and firmware version

**Masked by `--redact`:**

| Field | Where it comes from |
| --- | --- |
| hostname, machine-id | `hostnamectl`, and every journal line |
| chassis, board and CPU serial numbers, UUIDs, asset tags | `dmidecode` |
| account names of the invoking and logged-in users | `id`, `ps` |
| MAC and IP addresses | kernel log (see below) |

MAC addresses are not collected deliberately — the script runs no network
commands at all. They appear because the kernel logs a NIC's address when it
probes the device, and the report includes the kernel log.

The full list of identifying fields is printed at the end of every report, so
it can be reviewed rather than guessed at.

Redaction is best effort. Labelled fields and well-formed addresses are
handled, but free-text kernel logs may still contain identifying strings such
as internal hostnames, application names or custom paths. If the hostname is
too short or collides with terms used throughout the report, it is left
unmasked and the report says so rather than risk corrupting the output.

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
