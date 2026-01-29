#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Minimal logging
###############################################################################
LOG_TS="${EDGE_LOG_TS:-1}"
ts() { [[ "$LOG_TS" == "1" ]] && date +"%Y-%m-%d %H:%M:%S" || true; }

_is_tty() { [[ -t 1 ]]; }
c_reset=$'\033[0m'; c_dim=$'\033[2m'; c_red=$'\033[31m'; c_yel=$'\033[33m'; c_grn=$'\033[32m'

_pfx() { _is_tty && printf "%s%s%s" "${c_dim}" "$(ts) " "${c_reset}" || true; }
ok()   { _pfx; _is_tty && printf "%sOK%s " "$c_grn" "$c_reset" || printf "OK "; echo "$*"; }
warn() { _pfx; _is_tty && printf "%sWARN%s " "$c_yel" "$c_reset" || printf "WARN "; echo "$*"; }
err()  { _pfx; _is_tty && printf "%sERROR%s " "$c_red" "$c_reset" || printf "ERROR "; echo "$*"; }
die() { err "$*"; exit 1; }

host_short() { hostname -s 2>/dev/null || hostname; }

###############################################################################
# Root / sudo
###############################################################################
need_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  local self="${BASH_SOURCE[0]:-}"
  if [[ -n "$self" && -f "$self" && -r "$self" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      warn "Not root -> re-exec via sudo"
      exec sudo -E bash "$self" "$@"
    fi
    die "Not root and sudo not found."
  fi

  die "Not root. Use: curl ... | sudo bash -s -- <cmd>"
}

###############################################################################
# Confirmation (OFF by default)
###############################################################################
confirm() {
  [[ "${EDGE_CONFIRM:-0}" == "1" ]] || return 0
  [[ -t 0 ]] || return 0
  echo
  echo "This will tune sysctl, swap, limits, journald, unattended-upgrades, logrotate, tmpfiles."
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "Cancelled."
}

###############################################################################
# Backup + manifest
###############################################################################
backup_dir=""
moved_dir=""
manifest=""

mkbackup() {
  local tsd="${BACKUP_TS:-${EDGE_BACKUP_TS:-}}"
  [[ -n "$tsd" ]] || tsd="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/root/edge-tuning-backup-${tsd}"
  moved_dir="${backup_dir}/moved"
  manifest="${backup_dir}/MANIFEST.tsv"
  mkdir -p "$backup_dir" "$moved_dir"
  : > "$manifest"
}

backup_file() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  local rel="${src#/}"
  local dst="${backup_dir}/files/${rel}"
  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  printf "COPY\t%s\t%s\n" "$src" "$dst" >> "$manifest"
}

move_aside() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  local rel="${src#/}"
  local dst="${moved_dir}/${rel}"
  mkdir -p "$(dirname "$dst")"
  mv -f "$src" "$dst"
  printf "MOVE\t%s\t%s\n" "$src" "$dst" >> "$manifest"
}

restore_manifest() {
  local bdir="$1"
  local man="${bdir}/MANIFEST.tsv"
  [[ -f "$man" ]] || die "Manifest not found: $man"

  while IFS=$'\t' read -r kind a b; do
    [[ -n "${kind:-}" ]] || continue
    case "$kind" in
      COPY)
        [[ -f "$b" ]] || continue
        mkdir -p "$(dirname "$a")"
        cp -a "$b" "$a"
        ;;
      MOVE)
        [[ -f "$b" ]] || continue
        mkdir -p "$(dirname "$a")"
        mv -f "$b" "$a"
        ;;
    esac
  done < "$man"
}

latest_backup_dir() {
  ls -1dt /root/edge-tuning-backup-* 2>/dev/null | head -n1 || true
}

###############################################################################
# Snapshots (before/after)
###############################################################################
_journald_caps() {
  local f="/etc/systemd/journald.conf.d/90-edge.conf"
  if [[ -f "$f" ]]; then
    local s r
    s="$(awk -F= '/^\s*SystemMaxUse=/{print $2}' "$f" | tr -d ' ' | head -n1)"
    r="$(awk -F= '/^\s*RuntimeMaxUse=/{print $2}' "$f" | tr -d ' ' | head -n1)"
    [[ -n "$s" || -n "$r" ]] && echo "${s:-?}/${r:-?}" && return 0
  fi
  echo "-"
}

_logrotate_mode() {
  local f="/etc/logrotate.conf"
  [[ -f "$f" ]] || { echo "-"; return 0; }
  local freq rot
  freq="$(awk 'tolower($1)=="daily"||tolower($1)=="weekly"||tolower($1)=="monthly"{print tolower($1); exit}' "$f" 2>/dev/null || true)"
  rot="$(awk 'tolower($1)=="rotate"{print $2; exit}' "$f" 2>/dev/null || true)"
  echo "${freq:-?} / rotate ${rot:-?}"
}

_unattended_reboot_setting() {
  local reboot time
  reboot="$(grep -Rhs 'Unattended-Upgrade::Automatic-Reboot' /etc/apt/apt.conf.d/*.conf 2>/dev/null \
    | sed -nE 's/.*Automatic-Reboot\s+"([^"]+)".*/\1/p' | tail -n1 || true)"
  time="$(grep -Rhs 'Unattended-Upgrade::Automatic-Reboot-Time' /etc/apt/apt.conf.d/*.conf 2>/dev/null \
    | sed -nE 's/.*Automatic-Reboot-Time\s+"([^"]+)".*/\1/p' | tail -n1 || true)"
  [[ -z "${reboot:-}" ]] && reboot="-"
  [[ -z "${time:-}" ]] && time="-"
  echo "${reboot} / ${time}"
}
_unattended_state() { echo "${1%% / *}"; }
_unattended_time()  { echo "${1##* / }"; }

_swap_state() {
  local s
  s="$(/sbin/swapon --noheadings --show=NAME,SIZE 2>/dev/null | awk '{$1=$1; print}' | tr '\n' ';' | sed 's/;$//' || true)"
  [[ -n "$s" ]] && echo "$s" || echo "none"
}

_nofile_systemd() {
  local n
  n="$(systemctl show --property DefaultLimitNOFILE 2>/dev/null | cut -d= -f2 || true)"
  echo "${n:--}"
}

snapshot_before() {
  B_TCP_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"
  B_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"
  B_FWD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '-')"
  B_CT_MAX="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '-')"
  B_TW="$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo '-')"
  B_SWAPPINESS="$(sysctl -n vm.swappiness 2>/dev/null || echo '-')"
  B_SWAP="$(_swap_state)"
  B_NOFILE="$(_nofile_systemd)"
  B_JOURNAL="$(_journald_caps)"
  B_LOGROT="$(_logrotate_mode)"
  B_UNATT="$(_unattended_reboot_setting)"
}

snapshot_after() {
  A_TCP_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '-')"
  A_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '-')"
  A_FWD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '-')"
  A_CT_MAX="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo '-')"
  A_TW="$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo '-')"
  A_SWAPPINESS="$(sysctl -n vm.swappiness 2>/dev/null || echo '-')"
  A_SWAP="$(_swap_state)"
  A_NOFILE="$(_nofile_systemd)"
  A_JOURNAL="$(_journald_caps)"
  A_LOGROT="$(_logrotate_mode)"
  A_UNATT="$(_unattended_reboot_setting)"
}

###############################################################################
# Profile selection helpers (rounding)
###############################################################################
# Round MiB to nearest GiB (1 GiB = 1024 MiB)
round_gib() {
  local mem_mb="$1"
  echo $(( (mem_mb + 512) / 1024 ))
}

# Round CPU cores to nearest tier (1,2,4,8,16,32,64)
round_cpu_tier() {
  local c="$1"
  if   [[ "$c" -le 1  ]]; then echo 1
  elif [[ "$c" -le 2  ]]; then echo 2
  elif [[ "$c" -le 4  ]]; then echo 4
  elif [[ "$c" -le 8  ]]; then echo 8
  elif [[ "$c" -le 16 ]]; then echo 16
  elif [[ "$c" -le 32 ]]; then echo 32
  else echo 64
  fi
}

# Map rounded GiB to profile (includes dedicated)
profile_from_mem_gib() {
  local g="$1"
  # "Dedicated" is for very large boxes
  if   [[ "$g" -ge 32 ]]; then echo "dedicated"
  elif [[ "$g" -ge 16 ]]; then echo "xhigh"
  elif [[ "$g" -ge 12 ]]; then echo "high"
  elif [[ "$g" -ge 2  ]]; then echo "mid"
  else echo "low"
  fi
}

# Map CPU tier to profile
profile_from_cpu_tier() {
  local t="$1"
  if   [[ "$t" -ge 32 ]]; then echo "dedicated"
  elif [[ "$t" -ge 16 ]]; then echo "xhigh"
  elif [[ "$t" -ge 8  ]]; then echo "high"
  elif [[ "$t" -ge 2  ]]; then echo "mid"
  else echo "low"
  fi
}

# max(profileA, profileB) by order: low < mid < high < xhigh < dedicated
profile_rank() {
  case "$1" in
    low) echo 1 ;;
    mid) echo 2 ;;
    high) echo 3 ;;
    xhigh) echo 4 ;;
    dedicated) echo 5 ;;
    *) echo 0 ;;
  esac
}

profile_max() {
  local a="$1" b="$2"
  local ra rb
  ra="$(profile_rank "$a")"
  rb="$(profile_rank "$b")"
  if [[ "$ra" -ge "$rb" ]]; then echo "$a"; else echo "$b"; fi
}

###############################################################################
# Output: compact tables
###############################################################################
print_run_table() {
  local mode="$1" profile="$2" backup="$3" cpu="$4" mem_mb="$5" mem_gib="$6" cpu_tier="$7"
  echo
  echo "Run"
  printf "%-10s | %s\n" "Host"    "$(host_short)"
  printf "%-10s | %s\n" "Mode"    "$mode"
  printf "%-10s | %s (tier %s)\n" "CPU"     "${cpu:-"-"}" "${cpu_tier:-"-"}"
  printf "%-10s | %s MiB (~%s GiB)\n" "RAM"  "${mem_mb:-"-"}" "${mem_gib:-"-"}"
  printf "%-10s | %s\n" "Profile" "${profile:-"-"}"
  printf "%-10s | %s\n" "Backup"  "${backup:-"-"}"
}

_print_diff_row() {
  local label="$1" b="$2" a="$3"
  [[ "$b" == "$a" ]] && return 0
  printf "%-12s | %-24s | %-24s\n" "$label" "$b" "$a"
}

print_changes_table_diff() {
  echo
  echo "Changed (before -> after)"
  printf "%-12s-+-%-24s-+-%-24s\n" "$(printf '%.0s-' {1..12})" "$(printf '%.0s-' {1..24})" "$(printf '%.0s-' {1..24})"

  local printed=0
  _print_diff_row "TCP"        "$B_TCP_CC" "$A_TCP_CC" && [[ "$B_TCP_CC" != "$A_TCP_CC" ]] && printed=1 || true
  _print_diff_row "Qdisc"      "$B_QDISC" "$A_QDISC" && [[ "$B_QDISC" != "$A_QDISC" ]] && printed=1 || true
  _print_diff_row "Forward"    "$B_FWD" "$A_FWD" && [[ "$B_FWD" != "$A_FWD" ]] && printed=1 || true
  _print_diff_row "Conntrack"  "$B_CT_MAX" "$A_CT_MAX" && [[ "$B_CT_MAX" != "$A_CT_MAX" ]] && printed=1 || true
  _print_diff_row "TW buckets" "$B_TW" "$A_TW" && [[ "$B_TW" != "$A_TW" ]] && printed=1 || true
  _print_diff_row "Swappiness" "$B_SWAPPINESS" "$A_SWAPPINESS" && [[ "$B_SWAPPINESS" != "$A_SWAPPINESS" ]] && printed=1 || true
  _print_diff_row "Swap"       "$B_SWAP" "$A_SWAP" && [[ "$B_SWAP" != "$A_SWAP" ]] && printed=1 || true
  _print_diff_row "Nofile"     "$B_NOFILE" "$A_NOFILE" && [[ "$B_NOFILE" != "$A_NOFILE" ]] && printed=1 || true
  _print_diff_row "Journald"   "$B_JOURNAL" "$A_JOURNAL" && [[ "$B_JOURNAL" != "$A_JOURNAL" ]] && printed=1 || true
  _print_diff_row "Logrotate"  "$B_LOGROT" "$A_LOGROT" && [[ "$B_LOGROT" != "$A_LOGROT" ]] && printed=1 || true

  local b_ar b_rt a_ar a_rt
  b_ar="$(_unattended_state "$B_UNATT")"; b_rt="$(_unattended_time "$B_UNATT")"
  a_ar="$(_unattended_state "$A_UNATT")"; a_rt="$(_unattended_time "$A_UNATT")"
  _print_diff_row "Auto reboot" "$b_ar" "$a_ar" && [[ "$b_ar" != "$a_ar" ]] && printed=1 || true
  _print_diff_row "Reboot time" "$b_rt" "$a_rt" && [[ "$b_rt" != "$a_rt" ]] && printed=1 || true

  if [[ "$printed" -eq 0 ]]; then
    echo "(no changes - already tuned)"
  fi
}

print_manifest_compact() {
  local man="$1"
  [[ -f "$man" ]] || return 0

  local copies moves
  copies="$(awk -F'\t' '$1=="COPY"{c++} END{print c+0}' "$man" 2>/dev/null || echo 0)"
  moves="$(awk -F'\t' '$1=="MOVE"{c++} END{print c+0}' "$man" 2>/dev/null || echo 0)"

  echo
  echo "Files"
  echo "  backed up:   $copies"
  echo "  moved aside: $moves"

  if [[ "$moves" -gt 0 ]]; then
    echo
    echo "Moved aside:"
    awk -F'\t' '$1=="MOVE"{print "  - " $2}' "$man" | head -n 50
    [[ "$moves" -gt 50 ]] && echo "  (showing first 50)"
  fi
}

###############################################################################
# apply / rollback
###############################################################################
_APPLY_CREATED_BACKUP="0"
on_apply_fail() {
  local code=$?
  err "Apply failed (exit code=$code)."
  if [[ "$_APPLY_CREATED_BACKUP" == "1" && "${EDGE_AUTO_ROLLBACK:-0}" == "1" ]]; then
    warn "Auto rollback from: $backup_dir"
    BACKUP_DIR="$backup_dir" rollback_cmd || true
  else
    warn "Rollback: sudo BACKUP_DIR=$backup_dir $0 rollback"
  fi
  exit "$code"
}

apply_cmd() {
  need_root "$@"
  confirm
  trap on_apply_fail ERR

  mkbackup
  _APPLY_CREATED_BACKUP="1"

  snapshot_before

  # Discover resources
  local mem_kb mem_mb cpu
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  mem_mb="$((mem_kb / 1024))"
  cpu="$(nproc)"

  # Rounded "plans"
  local mem_gib cpu_tier
  mem_gib="$(round_gib "$mem_mb")"
  cpu_tier="$(round_cpu_tier "$cpu")"

  # Choose profile from rounded memory + rounded CPU, then take max
  local p_mem p_cpu profile
  p_mem="$(profile_from_mem_gib "$mem_gib")"
  p_cpu="$(profile_from_cpu_tier "$cpu_tier")"
  profile="$(profile_max "$p_mem" "$p_cpu")"

  # Manual override
  if [[ "${FORCE_PROFILE:-}" =~ ^(low|mid|high|xhigh|dedicated)$ ]]; then
    profile="${FORCE_PROFILE}"
  fi

  # Profile defaults
  local somaxconn netdev_backlog syn_backlog rmem_max wmem_max rmem_def wmem_def tcp_rmem tcp_wmem
  local ct_max swappiness nofile tw_buckets j_system j_runtime logrotate_rotate

  case "$profile" in
    low)
      somaxconn=4096;  netdev_backlog=16384;  syn_backlog=4096
      rmem_max=$((32*1024*1024));  wmem_max=$((32*1024*1024))
      rmem_def=$((8*1024*1024));   wmem_def=$((8*1024*1024))
      tcp_rmem="4096 262144 ${rmem_max}"
      tcp_wmem="4096 262144 ${wmem_max}"
      ct_max=32768
      swappiness=5
      nofile=65536
      tw_buckets=50000
      j_system="100M"; j_runtime="50M"
      logrotate_rotate=7
      ;;
    mid)
      somaxconn=16384; netdev_backlog=65536;  syn_backlog=16384
      rmem_max=$((64*1024*1024));  wmem_max=$((64*1024*1024))
      rmem_def=$((16*1024*1024));  wmem_def=$((16*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      ct_max=131072
      swappiness=10
      nofile=262144
      tw_buckets=120000
      j_system="200M"; j_runtime="100M"
      logrotate_rotate=10
      ;;
    high)
      somaxconn=65535; netdev_backlog=131072; syn_backlog=65535
      rmem_max=$((128*1024*1024)); wmem_max=$((128*1024*1024))
      rmem_def=$((32*1024*1024));  wmem_def=$((32*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      ct_max=262144
      swappiness=10
      nofile=524288
      tw_buckets=200000
      j_system="300M"; j_runtime="150M"
      logrotate_rotate=14
      ;;
    xhigh)
      somaxconn=65535; netdev_backlog=250000; syn_backlog=65535
      rmem_max=$((256*1024*1024)); wmem_max=$((256*1024*1024))
      rmem_def=$((64*1024*1024));  wmem_def=$((64*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      ct_max=1048576
      swappiness=10
      nofile=1048576
      tw_buckets=300000
      j_system="400M"; j_runtime="200M"
      logrotate_rotate=21
      ;;
    dedicated)
      somaxconn=65535; netdev_backlog=500000; syn_backlog=65535
      rmem_max=$((512*1024*1024)); wmem_max=$((512*1024*1024))
      rmem_def=$((128*1024*1024)); wmem_def=$((128*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      ct_max=2097152
      swappiness=10
      nofile=2097152
      tw_buckets=600000
      j_system="800M"; j_runtime="400M"
      logrotate_rotate=30
      ;;
  esac

  local ct_buckets=$((ct_max/4)); [[ "$ct_buckets" -lt 4096 ]] && ct_buckets=4096

  # Swap sizing
  backup_file /etc/fstab
  local swap_gb=2
  if   [[ "$mem_mb" -lt 2048  ]]; then swap_gb=1
  elif [[ "$mem_mb" -lt 4096  ]]; then swap_gb=2
  elif [[ "$mem_mb" -lt 8192  ]]; then swap_gb=4
  elif [[ "$mem_mb" -lt 16384 ]]; then swap_gb=6
  else swap_gb=8
  fi

  local swap_target_mb=$((swap_gb * 1024))
  local swap_total_mb; swap_total_mb="$(awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo)"
  local has_swap_partition="0"
  if /sbin/swapon --show=TYPE 2>/dev/null | grep -q '^partition$'; then
    has_swap_partition="1"
  fi

  if [[ "$has_swap_partition" == "0" ]]; then
    local active_swapfile="0"
    if /sbin/swapon --show=NAME 2>/dev/null | grep -qx '/swapfile'; then
      active_swapfile="1"
    fi

    local need_swapfile="0"
    if [[ "$swap_total_mb" -eq 0 ]]; then
      need_swapfile="1"
    elif [[ "$active_swapfile" == "1" ]]; then
      local diff=$(( swap_total_mb > swap_target_mb ? swap_total_mb - swap_target_mb : swap_target_mb - swap_total_mb ))
      [[ "$diff" -ge 256 ]] && need_swapfile="1"
    elif [[ -f /swapfile ]]; then
      need_swapfile="1"
    fi

    if [[ "$need_swapfile" == "1" ]]; then
      /sbin/swapoff /swapfile 2>/dev/null || true
      rm -f /swapfile
      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${swap_gb}G" /swapfile
      else
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_target_mb" status=none
      fi
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      /sbin/swapon /swapfile
      if ! grep -qE '^\s*/swapfile\s+none\s+swap\s' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
      fi
    fi
  fi

  # Sysctl
  backup_file /etc/sysctl.conf
  shopt -s nullglob
  for f in /etc/sysctl.d/*.conf; do
    [[ -f "$f" ]] || continue
    case "$f" in
      /etc/sysctl.d/90-edge-network.conf|/etc/sysctl.d/92-edge-safe.conf|/etc/sysctl.d/95-edge-forward.conf|/etc/sysctl.d/96-edge-vm.conf|/etc/sysctl.d/99-edge-conntrack.conf) continue ;;
    esac
    if grep -Eq 'nf_conntrack_|tcp_congestion_control|default_qdisc|ip_forward|somaxconn|netdev_max_backlog|tcp_rmem|tcp_wmem|rmem_max|wmem_max|vm\.swappiness|vfs_cache_pressure|tcp_syncookies|tcp_max_tw_buckets|tcp_keepalive|tcp_mtu_probing|tcp_fin_timeout|tcp_tw_reuse|tcp_slow_start_after_idle|tcp_rfc1337' "$f"; then
      move_aside "$f"
    fi
  done
  shopt -u nullglob

  if [[ -f /etc/sysctl.conf ]]; then
    sed -i -E \
      's/^\s*(net\.netfilter\.nf_conntrack_|net\.ipv4\.tcp_congestion_control|net\.core\.default_qdisc|net\.ipv4\.ip_forward|net\.core\.somaxconn|net\.core\.netdev_max_backlog|net\.ipv4\.tcp_(rmem|wmem)|net\.core\.(rmem|wmem)_(max|default)|vm\.swappiness|vm\.vfs_cache_pressure|net\.ipv4\.tcp_syncookies|net\.ipv4\.tcp_max_tw_buckets|net\.ipv4\.tcp_(keepalive_time|keepalive_intvl|keepalive_probes)|net\.ipv4\.tcp_rfc1337)/# \0/' \
      /etc/sysctl.conf || true
  fi

  modprobe nf_conntrack >/dev/null 2>&1 || true
  mkdir -p /etc/modules-load.d
  backup_file /etc/modules-load.d/edge-conntrack.conf
  echo nf_conntrack > /etc/modules-load.d/edge-conntrack.conf

  cat > /etc/sysctl.d/90-edge-network.conf <<EOM
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = ${somaxconn}
net.core.netdev_max_backlog = ${netdev_backlog}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.rmem_default = ${rmem_def}
net.core.wmem_default = ${wmem_def}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOM

  echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/95-edge-forward.conf

  cat > /etc/sysctl.d/96-edge-vm.conf <<EOM
vm.swappiness = ${swappiness}
vm.vfs_cache_pressure = 50
EOM

  cat > /etc/sysctl.d/99-edge-conntrack.conf <<EOM
net.netfilter.nf_conntrack_max = ${ct_max}
net.netfilter.nf_conntrack_buckets = ${ct_buckets}
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
EOM

  cat > /etc/sysctl.d/92-edge-safe.conf <<EOM
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = ${tw_buckets}
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOM

  sysctl --system >/dev/null 2>&1 || true

  # NOFILE
  backup_file /etc/systemd/system.conf || true
  mkdir -p /etc/systemd/system.conf.d
  shopt -s nullglob
  for f in /etc/systemd/system.conf.d/*.conf; do
    [[ "$f" == "/etc/systemd/system.conf.d/90-edge.conf" ]] && continue
    grep -qE '^\s*DefaultLimitNOFILE\s*=' "$f" && move_aside "$f"
  done
  shopt -u nullglob

  cat > /etc/systemd/system.conf.d/90-edge.conf <<EOM
[Manager]
DefaultLimitNOFILE=${nofile}
EOM

  mkdir -p /etc/security/limits.d
  shopt -s nullglob
  for f in /etc/security/limits.d/*.conf; do
    [[ "$f" == "/etc/security/limits.d/90-edge.conf" ]] && continue
    grep -qE '^\s*[*a-zA-Z0-9._-]+\s+(soft|hard)\s+nofile\s+' "$f" && move_aside "$f"
  done
  shopt -u nullglob

  cat > /etc/security/limits.d/90-edge.conf <<EOM
* soft nofile ${nofile}
* hard nofile ${nofile}
root soft nofile ${nofile}
root hard nofile ${nofile}
EOM

  systemctl daemon-reexec >/dev/null 2>&1 || true

  # journald
  mkdir -p /etc/systemd/journald.conf.d
  shopt -s nullglob
  for f in /etc/systemd/journald.conf.d/*.conf; do
    [[ "$f" == "/etc/systemd/journald.conf.d/90-edge.conf" ]] && continue
    move_aside "$f"
  done
  shopt -u nullglob

  cat > /etc/systemd/journald.conf.d/90-edge.conf <<EOM
[Journal]
Compress=yes
SystemMaxUse=${j_system}
RuntimeMaxUse=${j_runtime}
RateLimitIntervalSec=30s
RateLimitBurst=1000
EOM
  systemctl restart systemd-journald >/dev/null 2>&1 || true

  # unattended upgrades
  mkdir -p /etc/apt/apt.conf.d
  backup_file /etc/apt/apt.conf.d/99-edge-unattended.conf
  cat > /etc/apt/apt.conf.d/99-edge-unattended.conf <<'EOM'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOM

  # irqbalance (best effort)
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^irqbalance\.service'; then
    systemctl enable --now irqbalance >/dev/null 2>&1 || true
  fi

  # logrotate
  backup_file /etc/logrotate.conf
  cat > /etc/logrotate.conf <<EOM
daily
rotate ${logrotate_rotate}
compress
delaycompress
missingok
notifempty
create
su root adm
include /etc/logrotate.d
EOM

  mkdir -p /etc/logrotate.d
  backup_file /etc/logrotate.d/edge-all-text-logs
  cat > /etc/logrotate.d/edge-all-text-logs <<EOM
/var/log/syslog
/var/log/kern.log
/var/log/auth.log
/var/log/daemon.log
/var/log/user.log
/var/log/messages
/var/log/dpkg.log
/var/log/apt/history.log
/var/log/apt/term.log
/var/log/*.log
/var/log/*/*.log
/var/log/*/*/*.log
/var/log/*.out
/var/log/*/*.out
/var/log/*.err
/var/log/*/*.err
{
  daily
  rotate ${logrotate_rotate}
  compress
  delaycompress
  missingok
  notifempty
  copytruncate
  sharedscripts
  postrotate
    systemctl kill -s HUP rsyslog.service >/dev/null 2>&1 || true
  endscript
}
EOM

  # tmpfiles
  mkdir -p /etc/tmpfiles.d
  backup_file /etc/tmpfiles.d/edge-tmp.conf
  cat > /etc/tmpfiles.d/edge-tmp.conf <<'EOM'
D /tmp            1777 root root 7d
D /var/tmp        1777 root root 14d
EOM
  systemd-tmpfiles --create >/dev/null 2>&1 || true

  trap - ERR
  snapshot_after

  ok "Applied. Backup: $backup_dir"
  print_run_table "apply" "$profile" "$backup_dir" "$cpu" "$mem_mb" "$mem_gib" "$cpu_tier"
  print_changes_table_diff
  print_manifest_compact "$manifest"
  echo "BACKUP_DIR=$backup_dir"
}

rollback_cmd() {
  need_root "$@"

  local backup="${BACKUP_DIR:-}"
  [[ -n "$backup" ]] || backup="$(latest_backup_dir)"
  [[ -n "$backup" && -d "$backup" ]] || die "Backup not found. Set BACKUP_DIR=/root/edge-tuning-backup-... or run apply first."

  local man="${backup}/MANIFEST.tsv"

  snapshot_before

  rm -f /etc/sysctl.d/90-edge-network.conf \
        /etc/sysctl.d/92-edge-safe.conf \
        /etc/sysctl.d/95-edge-forward.conf \
        /etc/sysctl.d/96-edge-vm.conf \
        /etc/sysctl.d/99-edge-conntrack.conf \
        /etc/modules-load.d/edge-conntrack.conf \
        /etc/systemd/system.conf.d/90-edge.conf \
        /etc/security/limits.d/90-edge.conf \
        /etc/systemd/journald.conf.d/90-edge.conf \
        /etc/apt/apt.conf.d/99-edge-unattended.conf \
        /etc/logrotate.d/edge-all-text-logs \
        /etc/tmpfiles.d/edge-tmp.conf 2>/dev/null || true

  restore_manifest "$backup"

  if /sbin/swapon --show=NAME 2>/dev/null | grep -qx '/swapfile'; then
    /sbin/swapoff /swapfile 2>/dev/null || true
  fi
  sed -i -E '/^\s*\/swapfile\s+none\s+swap\s+/d' /etc/fstab 2>/dev/null || true
  rm -f /swapfile 2>/dev/null || true

  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reexec >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true

  snapshot_after

  ok "Rolled back. Backup used: $backup"
  # CPU/RAM unknown here (rollback doesn't re-detect on purpose)
  print_run_table "rollback" "-" "$backup" "-" "-" "-" "-"
  print_changes_table_diff
  print_manifest_compact "$man"
}

status_cmd() {
  snapshot_before
  echo
  echo "Current"
  printf "%-12s | %s\n" "Host"       "$(host_short)"
  printf "%-12s | %s\n" "TCP"        "$B_TCP_CC"
  printf "%-12s | %s\n" "Qdisc"      "$B_QDISC"
  printf "%-12s | %s\n" "Forward"    "$B_FWD"
  printf "%-12s | %s\n" "Conntrack"  "$B_CT_MAX"
  printf "%-12s | %s\n" "Swap"       "$B_SWAP"
  printf "%-12s | %s\n" "Nofile"     "$B_NOFILE"
  printf "%-12s | %s\n" "Journald"   "$B_JOURNAL"
  printf "%-12s | %s\n" "Logrotate"  "$B_LOGROT"
  printf "%-12s | %s\n" "AutoReboot" "$(_unattended_state "$B_UNATT")"
  printf "%-12s | %s\n" "RebootTime" "$(_unattended_time "$B_UNATT")"
}

###############################################################################
# main
###############################################################################
case "${1:-}" in
  apply)    shift; apply_cmd "$@" ;;
  rollback) shift; rollback_cmd "$@" ;;
  status)   shift; status_cmd "$@" ;;
  *)
    echo "Usage: sudo $0 {apply|rollback|status}"
    exit 1
    ;;
esac
