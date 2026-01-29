# VPS Network Tuning Script

## TL;DR

Safe one-command tuning for new Linux VPS with many connections.
Automatically selects a profile, creates a backup, and can be fully rolled back.

```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/main/initial.sh | sudo bash -s -- apply
```

---

## What this script does

This script prepares a fresh VPS for high connection load:

- enables **BBR + fq**
- increases network buffers and connection limits
- enables IP forwarding
- configures **conntrack** for many concurrent connections
- sets sane **NOFILE** limits
- creates or resizes **/swapfile** if needed
- limits **journald** disk usage
- configures **logrotate**
- disables automatic reboots from unattended upgrades

Everything is applied **safely** and **reversibly**.

---

## Automatic profiles

The script automatically selects a profile based on CPU and RAM.

### Profiles overview

| Profile | Typical VPS size        | Conntrack max | NOFILE | Swap |
|--------|--------------------------|---------------|--------|------|
| low    | 1 CPU, < 2 GB RAM        | 32K           | 65K    | 1 GB |
| mid    | 2-4 CPU, 2-8 GB RAM      | 131K          | 262K   | 2-4 GB |
| high   | 4-8 CPU, 8-12 GB RAM     | 262K          | 524K   | 4-6 GB |
| xhigh  | 8+ CPU, 16+ GB RAM       | 1M            | 1M     | 8 GB |

The profile is chosen automatically.
You can override it manually if needed:

```bash
FORCE_PROFILE=high sudo bash initial.sh apply
```

---

## Commands

- **apply** - tune the system and create a backup
- **rollback** - revert all changes using a backup
- **status** - show current tuning state

Examples:

```bash
sudo bash initial.sh apply
sudo bash initial.sh rollback
sudo bash initial.sh status
```

When using `curl | bash`:

```bash
curl -fsSL https://raw.githubusercontent.com/akadorkin/vps-network-tuning-script/main/initial.sh | sudo bash -s -- apply
```

---

## Backups and rollback

Each run creates a backup directory:

```
/root/edge-tuning-backup-YYYYMMDD-HHMMSS
```

It contains:
- original config files
- moved conflicting configs
- a manifest for exact restore

Rollback example:

```bash
sudo BACKUP_DIR=/root/edge-tuning-backup-YYYYMMDD-HHMMSS bash initial.sh rollback
```

If BACKUP_DIR is not set, the latest backup is used.

---

## When NOT to use

Do NOT use this script if:

- the server is a database with strict latency requirements
- you already have carefully hand-tuned kernel parameters
- the system is not a VPS (for example, embedded devices)

---

## License

GNU General Public License v3.0
