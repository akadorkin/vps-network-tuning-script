# VPS Network Tuning Script (with rollback)

A safe, single-file tuning script for fresh Ubuntu/Debian VPS machines that are expected to handle **high concurrent connection counts**
(VPN gateways, NAT routers, reverse proxies, relays, “many conns” workloads).

It applies a predictable baseline and creates a **rollbackable backup** on each run.

---

## Quick start

### Run directly (pipe mode)
```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/refs/heads/main/initial.sh \
  | sudo bash -s -- apply
```

### Download, edit locally, run
```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/refs/heads/main/initial.sh -o initial.sh
chmod +x initial.sh
nano initial.sh
sudo ./initial.sh apply
```

Rollback:
```bash
sudo ./initial.sh rollback
# or pick a specific backup:
sudo BACKUP_DIR=/root/edge-tuning-backup-YYYYMMDD-HHMMSS ./initial.sh rollback
```

---

## Commands

- `apply` — apply tuning and create a backup folder under `/root/`
- `rollback` — revert changes using `BACKUP_DIR` or the latest backup
- `status` — print a concise runtime summary (BBR/qdisc, conntrack, nofile, swap, etc.)

---

## Environment variables

### Behavior
- `EDGE_ASSUME_YES=1`  
  Non-interactive mode (skip confirmation prompt).
- `EDGE_AUTO_ROLLBACK=1`  
  If `apply` fails after creating a backup, automatically rollback.
- `EDGE_LOG_TS=1`  
  Prefix console logs with a timestamp (default: 1).

### Profile selection
- `FORCE_PROFILE=low|mid|high|xhigh`  
  Override auto-profile selection.

> By default the script **auto-selects a profile** based on CPU/RAM:
> - `low` for very small instances
> - `mid` for small/medium
> - `high` for larger nodes
> - `xhigh` for big/high-throughput boxes

### Backup selection
- `BACKUP_DIR=/root/edge-tuning-backup-...`  
  Choose which backup to use for `rollback`.

### Backup timestamp (deterministic naming)
- `BACKUP_TS=YYYYMMDD-HHMMSS` (or `EDGE_BACKUP_TS=...`)  
  Force the backup directory name. Useful for automation and reproducible runs.

Examples:
```bash
sudo BACKUP_TS="$(date +%Y%m%d-%H%M%S)" ./initial.sh apply
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/refs/heads/main/initial.sh \
  | sudo BACKUP_TS=20260129-224500 bash -s -- apply
```

---

## What the script does

### 1) Rollbackable backups (manifest-based)
Before changing anything, `apply` creates:
- `/root/edge-tuning-backup-<timestamp>/`
- `MANIFEST.tsv` — a list of copied files and “moved aside” conflicting fragments (with exact original paths)
- `files/` — saved originals (e.g. `/etc/sysctl.conf`, `/etc/fstab`, `/etc/logrotate.conf`, ...)
- `moved/` — conflicting `.conf` fragments moved aside for clean management

Rollback restores **exact original locations** using the manifest.

### 2) Kernel/network tuning for high connection loads
Writes sysctl fragments under `/etc/sysctl.d/` to:
- enable **BBR** + **fq** (good default for modern kernels / general throughput)
- increase backlog / queues (`somaxconn`, `netdev_max_backlog`, SYN backlog)
- raise TCP buffer maxima/defaults (profile-based)
- set practical TCP knobs (`tcp_fastopen`, timeouts, keepalives)

### 3) IPv4 forwarding
Enables:
- `net.ipv4.ip_forward = 1`  
Useful for routers, NAT gateways, VPN exit nodes, etc.

### 4) Conntrack sizing (NAT/VPN friendly)
Ensures `nf_conntrack` is loaded and sets:
- `nf_conntrack_max`, `nf_conntrack_buckets`
- established/UDP timeouts
Important for machines that track lots of NAT/VPN flows.

### 5) VM memory behavior
Sets:
- `vm.swappiness` (profile-based)
- `vm.vfs_cache_pressure = 50`

### 6) Swapfile management (only if no swap partition)
If the host has no swap partition, the script can create `/swapfile`
sized by RAM and make it persistent via `/etc/fstab`.

### 7) Raise open file limits (nofile)
Applies higher limits using:
- `/etc/systemd/system.conf.d/90-edge.conf` (DefaultLimitNOFILE)
- `/etc/security/limits.d/90-edge.conf`

### 8) Cap journald disk usage
Adds:
- `/etc/systemd/journald.conf.d/90-edge.conf`
with compression and size caps.

### 9) Disable unattended upgrade auto-reboot
Writes:
- `/etc/apt/apt.conf.d/99-edge-unattended.conf`
to prevent surprise reboots.

### 10) Log rotation baseline + “all text logs”
Overwrites `/etc/logrotate.conf` to a predictable baseline and adds:
- `/etc/logrotate.d/edge-all-text-logs`
covering common system logs + globbed `*.log/*.out/*.err`.

### 11) tmp cleanup policy
Adds:
- `/etc/tmpfiles.d/edge-tmp.conf`
to periodically clean `/tmp` and `/var/tmp`.

---

## Profiles (values)

The script auto-selects a profile from CPU/RAM, but you can override with `FORCE_PROFILE`.

| Profile | Typical target | somaxconn | netdev_backlog | syn_backlog | rmem_max / wmem_max | rmem_default / wmem_default | nf_conntrack_max | tcp_max_tw_buckets | nofile | journald (System/Runtime) | logrotate rotate |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|
| low   | 1 vCPU / <2GB RAM | 4,096 | 16,384 | 4,096 | 32 MiB | 8 MiB | 32,768 | 50,000 | 65,536 | 100M / 50M | 7 |
| mid   | <8GB RAM | 16,384 | 65,536 | 16,384 | 64 MiB | 16 MiB | 131,072 | 120,000 | 262,144 | 200M / 100M | 10 |
| high  | 8–12GB+ RAM | 65,535 | 131,072 | 65,535 | 128 MiB | 32 MiB | 262,144 | 200,000 | 524,288 | 300M / 150M | 14 |
| xhigh | big nodes / many conns | 65,535 | 250,000 | 65,535 | 256 MiB | 64 MiB | 1,048,576 | 300,000 | 1,048,576 | 400M / 200M | 21 |

Notes:
- `nf_conntrack_buckets` is set to `nf_conntrack_max / 4` (min 4096).
- Swapfile size is chosen by RAM (1–8GB) **only** if there is no swap partition.

---

## When NOT to use (or use carefully)

Consider skipping or customizing this script if:

- **Database-heavy / latency-sensitive workloads** on the same host  
  Large buffer defaults and aggressive queueing can change latency characteristics. Prefer DB-specific tuning and measure.
- **Kubernetes nodes / managed images** where sysctl/limits are centrally enforced  
  You may fight your cluster or cloud-init policies.
- **Hosts with custom sysctl/limits policies** you must preserve  
  The script may move aside conflicting fragments to gain deterministic control (rollback restores them).
- **Systems where you must not enable `ip_forward`**  
  The script enables IPv4 forwarding.
- **Very small disks**  
  Journald is capped and logrotate is configured, but you should still verify disk pressure and retention.

If in doubt: run `status` first, apply on a staging node, compare metrics, and keep `BACKUP_DIR` for rollback.

---

## Status output

`status` prints a compact summary:
- BBR/qdisc
- ip_forward
- conntrack count/max
- systemd nofile default
- swap size + swappiness
- journald caps
- logrotate schedule/retention
- unattended reboot setting
