# VPS Network Tuning Script
> **Disclaimer**
>
> This script is provided **as is**, without any warranties or guarantees of any kind.
> You run it **at your own risk**.
>
> Always review the script before running it on production systems.
> 
## TL;DR

One command to tune a Linux VPS or VDS for lots of concurrent connections
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

- Enables BBR + fq
- Raises network limits for high-connection workloads
- Enables IP forwarding
- Tunes conntrack for many concurrent connections
- Increases NOFILE limits
- Creates or resizes /swapfile if needed
- Limits journald disk usage based on disk size
- Configures logrotate
- Disables unattended-upgrades automatic reboot

All changes are applied safely and can be fully reverted.

---

## When NOT to use

Do NOT use this script if:

- this is a database server with strict latency requirements
- you already have custom kernel or network tuning you want to keep
- this is not a VPS/server (for example, embedded systems)
- you are not sure what you are doing (review the script first)

---

## Commands

- `apply` - apply tuning and create a backup
- `rollback` - undo changes using a backup
- `status` - show current tuning state

---

## How to verify

After running `apply`, you can quickly check that tuning was applied.

### Check TCP congestion control and qdisc

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

Expected:
```
bbr
fq
```

### Check conntrack limits

```bash
sysctl net.netfilter.nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count
```

The count value should be lower than the max.

### Check NOFILE limits

```bash
ulimit -n
systemctl show --property DefaultLimitNOFILE
```

### Check swap

```bash
swapon --show
free -h
```

### Check journald usage

```bash
journalctl --disk-usage
```

### Check IP forwarding

```bash
sysctl net.ipv4.ip_forward
```

Expected:
```
1
```

### Check applied profile

```bash
sudo bash initial.sh status
```

---

## Automatic profiles

The script detects CPU and RAM and maps them to common VPS tiers.

### Hardware detection

- CPU cores: nproc
- RAM: /proc/meminfo (MiB)
- Disk size for logs: df -Pm /var/log (fallback: /)

### Tiering rules

- RAM is rounded up to the next whole GiB
- CPU is mapped to the same tier scale

Final tier is:

tier = max(RAM tier, CPU tier)

This prevents selecting a profile that is too weak for the hardware.

### Tier to profile mapping

| Tier | Profile |
|------|---------|
| 1    | low |
| 2    | mid |
| 4    | high |
| 8    | xhigh |
| 16   | 2xhigh |
| 32   | dedicated |
| 64+  | dedicated+ |

---

## Profiles table

| Profile     | Conntrack max | NOFILE     | Swap |
|------------|---------------|------------|------|
| low        | 65536         | 65536      | ~1 GB |
| mid        | 131072        | 131072     | ~2 GB |
| high       | 262144        | 262144     | ~4 GB |
| xhigh      | 524288        | 524288     | ~6 GB |
| 2xhigh     | 1048576       | 1048576    | ~8 GB |
| dedicated  | 2097152       | 2097152    | ~8 GB |
| dedicated+ | 4194304       | 4194304    | ~8 GB |

---

## Backups and rollback

Each apply creates a backup directory:

```
/root/edge-tuning-backup-YYYYMMDD-HHMMSS
```

Rollback latest:

```bash
sudo bash initial.sh rollback
```

Rollback specific:

```bash
sudo BACKUP_DIR=/root/edge-tuning-backup-YYYYMMDD-HHMMSS bash initial.sh rollback
```

---

## License

GNU General Public License v3.0
