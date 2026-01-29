# VPS Network Tuning Script

**TL;DR**

- For a fresh VPS with **many simultaneous connections** (VPN / proxy / NAT).
- Automatically selects a profile based on CPU and RAM.
- Makes a backup before changes.
- One-command rollback.
- Run via `curl | bash`:

```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/refs/heads/main/initial.sh   | sudo bash -s -- apply
```

Rollback:
```bash
sudo ./initial.sh rollback
```

---

## Quick start

### Run without saving the file
```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/refs/heads/main/initial.sh   | sudo bash -s -- apply
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
# or use a specific backup
sudo BACKUP_DIR=/root/edge-tuning-backup-YYYYMMDD-HHMMSS ./initial.sh rollback
```

---

## Commands

- `apply` â apply tuning and create a backup
- `rollback` â undo changes
- `status` â show current settings

---

## Automatic profile selection

The script selects a profile automatically based on CPU and RAM:
- smaller VPS â smaller limits
- larger VPS â larger limits

Override it if you want:
```bash
sudo FORCE_PROFILE=mid ./initial.sh apply
```

---

## Environment variables

- `EDGE_LOG_TS=1` â timestamps in logs (default: 1)
- `EDGE_AUTO_ROLLBACK=1` â auto rollback if apply fails

### Backup control
- `BACKUP_DIR=...` â choose backup for rollback
- `BACKUP_TS=YYYYMMDD-HHMMSS` â set backup folder name manually (useful for automation)

Example:
```bash
sudo BACKUP_TS="$(date +%Y%m%d-%H%M%S)" ./initial.sh apply
```

---

## What the script changes

### Backups
Creates a backup directory under `/root/edge-tuning-backup-...` before doing anything.

Rollback restores original files from that directory.

### Existing config files
If the script finds config fragments that conflict with what it manages (for example in `/etc/sysctl.d/` or `journald.conf.d/`),
it moves them into the backup folder and records everything in a manifest. Rollback puts them back.

### Network settings
Enables modern TCP mode (BBR + fq) and increases limits for busy servers.

### Forwarding
Enables IPv4 forwarding for VPN and routing use cases.

### Conntrack
Increases connection tracking limits for NAT and VPN workloads.

### Memory and swap
Adjusts swap behavior and creates `/swapfile` if no swap exists.

### Open files limit
Raises the maximum number of open files for services.

### System logs
Limits journald size and configures log rotation.

### Auto reboot
Disables automatic reboots from unattended upgrades.

### Temporary files
Configures automatic cleanup for `/tmp` and `/var/tmp`.

---

## Profiles overview

| Profile | Typical usage | Conntrack max | Open files |
|---|---|---:|---:|
| low   | very small VPS | 32,768 | 65,536 |
| mid   | small / medium VPS | 131,072 | 262,144 |
| high  | larger servers | 262,144 | 524,288 |
| xhigh | many connections | 1,048,576 | 1,048,576 |

---

## When not to use

- Database servers or latency-critical workloads
- Managed environments that already control sysctl and limits
- Systems where IPv4 forwarding must stay disabled
- Hosts with custom tuning

---

## Status output

The `status` command shows:
- TCP mode
- forwarding state
- conntrack usage
- open file limits
- swap settings
- log retention
- auto reboot setting

---

## How to rollback after a pipe run

After `apply`, the script prints something like:
`BACKUP_DIR=/root/edge-tuning-backup-20260129-234533`

Use it like this:
```bash
sudo BACKUP_DIR=/root/edge-tuning-backup-20260129-234533 ./initial.sh rollback
```
