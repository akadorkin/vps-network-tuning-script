# VPS Network Tuning Script

## TL;DR

One command to tune a Linux VPS or VDS for **lots of concurrent connections**
(for example, a VPN server).

The script automatically selects a profile based on hardware, creates a backup,
and allows you to roll everything back.

```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/main/initial.sh | sudo bash -s -- apply
```

Rollback (latest backup):

```bash
sudo bash initial.sh rollback
```

---

## What it does

- Enables **BBR + fq**
- Raises network limits for high-connection workloads
- Enables **IP forwarding**
- Tunes **conntrack** for many concurrent connections
- Increases **NOFILE** limits
- Creates or resizes **/swapfile** if needed
- Limits **journald** disk usage based on disk size
- Configures **logrotate**
- Disables unattended-upgrades **automatic reboot**

All changes are applied safely and can be fully reverted.

---

## When NOT to use

Do **NOT** use this script if:

- this is a database server with strict latency requirements
- you already have custom kernel or network tuning you want to keep
- this is not a VPS/server (for example, embedded systems)
- you are not sure what you are doing (review the script first)

---

## Commands

- `apply` â apply tuning and create a backup
- `rollback` â undo changes using a backup
- `status` â show current tuning state

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

The script detects CPU and RAM and maps them to common VPS âtiersâ.

### Hardware detection

- CPU cores: `nproc`
- RAM: `/proc/meminfo` (MiB)
- Disk size for logs: `df -Pm /var/log` (fallback: `/`)

### Tiering rules

- **RAM** is rounded **up** to the next whole GiB and mapped to tiers  
  (1, 2, 4, 8, 16, 32, 64+)
- **CPU** is mapped to the same tiers  
  (1, 2, 4, 8, 16, 32, 64+)

Final tier is:

**tier = max(RAM tier, CPU tier)**

This prevents selecting a profile that is too weak for the hardware.

### Tier â profile mapping

| Tier | Profile |
|------|---------|
| 1    | low |
| 2    | mid |
| 4    | high |
| 8    | xhigh |
| 16   | 2xhigh |
| 32   | dedicated |
| 64+  | dedicated+ |

Manual override:

```bash
FORCE_PROFILE=high sudo bash initial.sh apply
```

Supported values:  
`low`, `mid`, `high`, `xhigh`, `2xhigh`, `dedicated`, `dedicated+`

---

## Profiles table

This table shows the most important limits for workloads with many connections.

| Profile     | Typical tier | Conntrack max | NOFILE     | Swap (if no partition) |
|------------|--------------|---------------|------------|-------------------------|
| low        | 1            | 65,536        | 65,536     | ~1 GB |
| mid        | 2            | 131,072       | 131,072    | ~2 GB |
| high       | 4            | 262,144       | 262,144    | ~4 GB |
| xhigh      | 8            | 524,288       | 524,288    | ~6 GB |
| 2xhigh     | 16           | 1,048,576     | 1,048,576  | ~8 GB |
| dedicated  | 32           | 2,097,152     | 2,097,152  | ~8 GB |
| dedicated+ | 64+          | 4,194,304     | 4,194,304  | ~8 GB |

Notes:

- Swap is only created or resized if there is **no swap partition**
- Conntrack size is computed from RAM and CPU, then limited to the profile range
- Existing limits are **never decreased**

---

## Backups and rollback

Each `apply` creates a backup directory:

```
/root/edge-tuning-backup-YYYYMMDD-HHMMSS
```

It contains:

- `files/` â copies of original configuration files
- `moved/` â conflicting configs moved aside
- `MANIFEST.tsv` â exact restore instructions

Rollback (latest backup):

```bash
sudo bash initial.sh rollback
```

Rollback (specific backup):

```bash
sudo BACKUP_DIR=/root/edge-tuning-backup-YYYYMMDD-HHMMSS bash initial.sh rollback
```

---

## License

GNU General Public License v3.0
