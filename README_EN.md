<div align="center">

# Host QoS

**One command for a full VPS checkup**

VPS / dedicated-server benchmark script: single Bash file, zero dependencies, read-only

[![version](https://img.shields.io/badge/version-2.8.2-blue)]()
[![bash](https://img.shields.io/badge/bash-4%2B%20%7C%20BusyBox%20ash-green)]()
[![license](https://img.shields.io/badge/license-MIT-orange)]()
[![platform](https://img.shields.io/badge/platform-Linux%20x86_64%20%7C%20arm64-lightgrey)]()

English · **[中文](README.md)**

</div>

---

## Introduction

`hostqos.sh` is a **single-file Bash** VPS benchmark script. One command on the
server under test runs the full battery — system info, provider detection,
performance benchmarks, disk I/O, China return routes & speeds, IP quality &
risk, streaming/AI unlock, and mail port connectivity — prints a terminal
summary and publishes a shareable, searchable online report to
[hostqos.com](https://hostqos.com).

```bash
curl -sL https://hostqos.com/hq.sh | bash
```

### Highlights

- **Zero dependencies**: only `bash` + `curl`; works via `sh` on Alpine/BusyBox
  (auto-switches to bash when available); never calls a package manager
- **Read-only**: no system changes, no packages installed, no sensitive files
  read; **writes nothing to disk by default** — temp files and in-run caches
  are wiped on exit
- **Three modes**: full (default) / simple `-s` / tiny `--tiny` (fits 128MB-RAM
  boxes) — pick by your time and resource budget
- **Dual-stack**: full IPv4 + IPv6 coverage; stacks missing on the host are
  skipped and reported as-is
- **Mobile-friendly reports**: online reports fully adapted to phone screens
  (verified down to 375px)
- **Privacy in your hands**: `--no-upload` for a fully offline run; nothing
  touches disk unless you ask
- **Overcommit detection**: virtio-balloon and KSM page-merge fingerprints
  reveal host-level memory overcommit at a glance
- **Self-hostable**: the server (Python + MySQL, also dependency-free) is
  published by this org; point the client at yours with `--server`

---

## What It Measures

| Module | Checks | Output |
|---|---|---|
| Hardware & System | CPU model/cores/freq, RAM, disk size & type, virtualization, KSM/balloon overcommit fingerprints, OS & arch | Basics card + overcommit warnings |
| Performance | sha256 1-core/n-core, RAM write bandwidth, FIO sequential & 4K random I/O | CPU grading (5 metrics) |
| China Routes | CT/CU/CM return-route detection (163/9929/CMIN2/CN2 GIA/CTGNet/CUII), per-hop traceroute | Route tags per carrier |
| China Speeds | Carrier-targeted single-thread down/up, latency, retransmission/loss | Single-thread table (not multi-thread peaks) |
| Province Grid | 31 provinces × 3 carriers, 93 probes, 4×ICMP each | Zero-loss ratio donut |
| Packet Sizes | 64/512/1200/1400B probes (TCP:80 by default, ICMP-DF fallback) + TCP·443 handshake failure rate | Carrier × size latency/loss matrix |
| International | Nearest-node multi-thread + single-thread from Tokyo/Singapore/HK/US-West/US-East/Frankfurt… | Down/up/latency pair/retrans |
| IP Quality | Scamalytics fraud score, native/broadcast, usage type (DC/business/residential), ASN & org, registered/used geo | IPv4 + IPv6 risk panels |
| Blacklists | Spot checks across 96 DNSBL databases | Valid/clean/marked/blacklisted counts |
| Streaming Unlock | Netflix (orig./full), Disney+, YouTube, TikTok, … | Status + region |
| AI Unlock | ChatGPT, Claude, Gemini, … | Dual-stack status + region |
| Mail Ports | SMTP 25/465/587, IMAP, POP3 outbound; major provider MX probes, PTR, DNSBL | Port matrix + provider panel |

## Quick Start

### Option 1: one-liner (recommended — report is auto-published)

```bash
curl -sL https://hostqos.com/hq.sh | bash                    # full mode
curl -sL https://hostqos.com/hq.sh | bash -s -- -t "note"    # with a tag
```

### Option 2: download and run locally

```bash
wget https://hostqos.com/hq.sh -O hostqos.sh    # or grab it from Releases
bash hostqos.sh
```

### Three run modes

| Command | Mode | For |
|---|---|---|
| `bash hostqos.sh` | Full (default) | Everything: system + provider + perf + disk fio + traceroute + DNSBL + port 25 + more speed nodes |
| `bash hostqos.sh -s` | Simple | Skips disk fio, traceroute, DNSBL and port 25 — faster report (~3-6 min) |
| `bash hostqos.sh --tiny` | Tiny | 128MB-RAM / 1GB-disk boxes: pure-curl speed tests, zero binary downloads (~1-3 min) |

## Common Options

| Option | Description |
|---|---|
| `-p, --provider <s>` | Manually set provider/product (e.g. `"BandwagonHost\|CN2 GIA"`), overrides auto-detect |
| `-t, --tag <s>` | Host note, shown in the report header and list |
| `--plan-bandwidth <s>` | Nominal bandwidth (e.g. `2Gbps`) — the report adds measured comparison |
| `--plan-traffic <s>` | Monthly traffic quota |
| `--report` | Save the HTML report locally (default `./hostqos/`); nothing is written by default |
| `-o, --html <dir>` | Report output directory (implies `--report`) |
| `-4` / `-6` | IPv4 / IPv6 only (dual-stack by default) |
| `-E, --lang en` | English output |
| `--route` | Force-enable return-route detection in any mode (incl. `--tiny`) |
| `--skip <mods>` | Skip modules: `cpu,disk,ping,tcpmtu,speed,intl,ipq,media,mail,route` |
| `--only <mods>` | Run only the given modules |
| `--mirror [url]` | Download binaries via a GitHub mirror (default ghfast.top) |
| `--low-traffic` | Halve speed-test durations |
| `--low-mem` | Force low-resource mode (auto-enabled below 700MB free RAM) |
| `--json` | Emit full JSON (written next to the report with `--report`, printed to stdout otherwise) |
| `--no-upload` | Fully offline — skip the online upload |
| `--server <url>` | Online report site (default `https://hostqos.com`; point to your own deployment) |
| `--token <s>` | Site access token (when auth is enabled; auto-carried by the one-liner) |
| `--keep` / `--no-color` / `-h` | Keep temp files / disable colors / help |

### Examples

```bash
bash hostqos.sh -s -p "RackNerd|2C2G" --skip media   # simple + manual provider + skip unlock
bash hostqos.sh --only speed,ipq -4 --no-upload      # speed + IP quality only, IPv4, offline
bash hostqos.sh --tiny --route                       # tiny box, still want return routes
bash hostqos.sh --report --json                      # save local report (with JSON)
```

## What You Get

1. **Terminal summary**: score, CPU/RAM/disk, per-carrier rows, packet-size
   matrix, unlock results, NAT verdicts — plus a copy-ready share snippet
   formatted for forums.
2. **Online report** (default): returns a `https://hostqos.com/run/<id>` link —
   light/dark themes, Chinese/English, fully responsive; all historical reports
   searchable by provider / host / route on the site.
3. **Local report** (only with `--report` / `-o`):
   `hostqos/report_<host>_<time>.html` (a single file with Print and
   Save-as-image buttons) + an `index.html` index; `--json` also writes the
   full JSON.

## Privacy & Safety

**What gets uploaded** (the report JSON only): system info
(hostname/CPU/RAM/disk/OS), public IP & ownership, virtualization/provider
detection, measured performance and network data. **Never** passwords, keys,
`/etc` contents or process lists. Hostnames are masked on the list page.

**Safety commitments**:

- The script **never executes** shell code fetched from the network —
  downloads are limited to test binaries (nexttrace / speedtest-go / fio …)
  from GitHub Releases;
- No package installs, no sensitive file reads, no crontab writes, no
  backdoors;
- Binaries and intermediates live in a temp dir (`$HQ_TMP`) and are deleted on
  exit; leftovers from past crashes are swept (24h threshold) on the next run;
  `--keep` preserves everything for your own audit;
- Probe targets are limited to: carrier nodes, public speedtest nodes, public
  IP-reputation/DNSBL APIs, official streaming endpoints, and GitHub Releases.

## FAQ

- **Alpine / no bash?** Run `sh hostqos.sh` — it finds and switches to bash
  when present; otherwise it prints manual install instructions (it never
  installs packages itself).
- **Slow GitHub downloads?** Use `--mirror`, or `--tiny` (no binaries at all).
- **Tiny boxes?** `--tiny`; keep ≥80MB free on a 1GB disk.
- **Production workloads?** Low-resource mode kicks in below 700MB free RAM;
  or pass `--low-mem --low-traffic` manually.
- **Self-host the collector?** The server (Python3 + MySQL, dependency-free)
  is published by this org — then run the client with
  `--server https://your-domain`.

## Compatibility

- **OS**: Debian/Ubuntu/CentOS/Alma/Rocky/Fedora/Alpine/Arch and friends
- **Arch**: x86_64 / arm64
- **Needs**: `bash 4+` (or BusyBox ash) + `curl`; missing `dd`/`ping`/`dig`
  degrade gracefully with a notice

## Acknowledgements

Detection ideas reference excellent community scripts and public practice
(NodeQuality / TcpQuality / RegionRestrictionCheck, among others); speed,
route and disk testing build on official prebuilt binaries of speedtest-go,
nexttrace and fio. Thanks, open source.

---

## License

[MIT](LICENSE)

<div align="center">
<sub>Host QoS · VPS Quality Benchmark · <a href="https://hostqos.com">hostqos.com</a></sub>
</div>
