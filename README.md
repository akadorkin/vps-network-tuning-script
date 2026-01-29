# VPS Network Tuning Script

## TL;DR

One command to tune a fresh Linux VPS for lots of concurrent connections.
It auto-picks a profile, makes a backup, and you can roll everything back.

```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/main/initial.sh | sudo bash -s -- apply
```

---

## What it does

- Enables BBR + fq
- Raises network and connection limits for high-connection workloads
- Enables IP forwarding
- Tunes conntrack for many concurrent connections
- Sets higher NOFILE limits
- Creates or resizes /swapfile if needed
- Limits journald disk usage
- Configures logrotate
- Disables unattended-upgrades auto reboot

Everything is applied safely and is reversible with rollback.

---

## Commands

- apply - apply tuning and create a backup
- rollback - undo changes using a backup
- status - show current tuning state

Examples:

```bash
sudo bash initial.sh apply
sudo bash initial.sh rollback
sudo bash initial.sh status
```

Using curl:

```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/main/initial.sh | sudo bash -s -- apply
```

---

## Automatic profiles

The script detects CPU cores and RAM, then rounds them to common "plan" sizes:

- RAM: rounded to nearest GiB (1024 MiB)
- CPU: rounded to nearest tier (1, 2, 4, 8, 16, 32, 64)

Then it picks a profile from RAM and CPU and uses the larger one (so you do not get an underpowered profile).

You can override manually:

```bash
FORCE_PROFILE=high sudo bash initial.sh apply
```

Supported values: low, mid, high, xhigh, dedicated

---

## Profiles table

This table shows the main limits per profile (the most important knobs for many connections).

| Profile   | Typical VPS size           | Conntrack max | NOFILE   | Swap   |
|-----------|----------------------------|---------------|----------|--------|
| low       | 1 CPU, ~1 GiB RAM          | 32K           | 65K      | 1 GB   |
| mid       | 2-4 CPU, ~2-8 GiB RAM      | 131K          | 262K     | 2-4 GB |
| high      | 4-8 CPU, ~12 GiB RAM       | 262K          | 524K     | 4-6 GB |
| xhigh     | 16+ CPU, ~16-31 GiB RAM    | 1M            | 1M       | 8 GB   |
| dedicated | 32+ CPU, 32+ GiB RAM       | 2M            | 2M       | 8 GB   |

Note: swap is only created/managed if there is no swap partition. If a swap partition exists, the script does not touch it.

---

## Backups and rollback

Each apply creates a backup folder:

```
/root/edge-tuning-backup-YYYYMMDD-HHMMSS
```

It includes:
- copies of original files
- any conflicting configs moved aside
- MANIFEST.tsv for exact restore

Rollback (latest backup):

```bash
sudo bash initial.sh rollback
```

Rollback (specific backup):

```bash
sudo BACKUP_DIR=/root/edge-tuning-backup-YYYYMMDD-HHMMSS bash initial.sh rollback
```

---

## When NOT to use

Do NOT use this script if:
- this is a database server with strict latency requirements
- you already have careful custom kernel tuning you want to keep
- this is not a VPS/server (for example, embedded systems)

---

## License

GNU General Public License v3.0
