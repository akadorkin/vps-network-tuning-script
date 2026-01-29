#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# logging
###############################################################################
LOG_TS="${EDGE_LOG_TS:-1}"

ts() { [[ "$LOG_TS" == "1" ]] && date +"%Y-%m-%d %H:%M:%S" || true; }
_is_tty() { [[ -t 1 ]]; }

c_reset=$'\033[0m'
c_dim=$'\033[2m'
c_red=$'\033[31m'
c_yel=$'\033[33m'
c_grn=$'\033[32m'

log()  { local p="INFO";  _is_tty && printf "%s%s[%s]%s %s\n" "${c_dim}" "$(ts) " "$p" "${c_reset}" "$*" || printf "[%s] %s\n" "$p" "$*"; }
ok()   { local p="OK";    _is_tty && printf "%s%s[%s]%s %s\n" "${c_dim}" "$(ts) " "${c_grn}${p}${c_reset}" "${c_reset}" "$*" || printf "[%s] %s\n" "$p" "$*"; }
warn() { local p="WARN";  _is_tty && printf "%s%s[%s]%s %s\n" "${c_dim}" "$(ts) " "${c_yel}${p}${c_reset}" "${c_reset}" "$*" || printf "[%s] %s\n" "$p" "$*"; }
err()  { local p="ERROR"; _is_tty && printf "%s%s[%s]%s %s\n" "${c_dim}" "$(ts) " "${c_red}${p}${c_reset}" "${c_reset}" "$*" || printf "[%s] %s\n" "$p" "$*"; }

die() { err "$*"; exit 1; }

###############################################################################
# root / sudo handling
###############################################################################
need_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  # If script is a real file, we can re-exec with sudo.
  local self="${BASH_SOURCE[0]:-}"
  if [[ -n "$self" && -f "$self" && -r "$self" ]]; then
    if command -v sudo >/dev/null 2>&1; then
      warn "Not running as root. Re-executing via sudo..."
      exec sudo -E bash "$self" "$@"
    fi
    die "Not root and sudo not found. Run as root."
  fi

  # Probably running from stdin (curl | bash). Can't re-exec reliably.
  die "Not root. Use: curl ... | sudo bash -s -- <cmd>"
}

host_short() { hostname -s 2>/dev/null || hostname; }

###############################################################################
# confirmation (OFF by default)
###############################################################################
confirm() {
  # never prompt by default; enable only if EDGE_CONFIRM=1 and stdin is a tty
  [[ "${EDGE_CONFIRM:-0}" == "1" ]] || return 0
  [[ -t 0 ]] || return 0

  echo
  echo "This will modify sysctl, swap, limits, journald, unattended-upgrades, logrotate, tmpfiles."
  echo "A backup + manifest will be created under /root/edge-tuning-backup-<timestamp>."
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "Cancelled."
}

###############################################################################
# backup helpers with manifest (restore exact original locations)
###############################################################################
backup_dir=""
moved_dir=""
manifest=""

mkbackup() {
  local tsd
  tsd="${BACKUP_TS:-${EDGE_BACKUP_TS:-}}"
  if [[ -z "$tsd" ]]; then
    tsd="$(date +%Y%m%d-%H%M%S)"
  fi
  backup_dir="/root/edge-tuning-backup-${tsd}"
  moved_dir="${backup_dir}/moved"
  manifest="${backup_dir}/MANIFEST.tsv"
  mkdir -p "$backup_dir" "$moved_dir"
  : > "$manifest"
  ok "Backup dir: $backup_dir"
}

backup_file() {
  local src="$1"
  [[ -f "$src" ]] || return 0

  local rel
  rel="${src#/}"

  local dst
  dst="${backup_dir}/files/${rel}"

  mkdir -p "$(dirname "$dst")"
  cp -a "$src" "$dst"
  printf "COPY\t%s\t%s\n" "$src" "$dst" >> "$manifest"
}

move_aside() {
  local src="$1"
  [[ -f "$src" ]] || return 0

  local rel
  rel="${src#/}"

  local dst
  dst="${moved_dir}/${rel}"

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
# state snapshots (for nice table output)
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
  local s
  s="$(grep -R --no-messages -h 'Unattended-Upgrade::Automatic-Reboot' /etc/apt/apt.conf.d/*.conf 2>/dev/null | tr -d ' ' | tr '\n' '|' | sed 's/|$//' || true)"
  echo "${s:--}"
}

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
# pretty output: tables
###############################################################################
_print_table_row() {
  # args: label before after
  printf "%-20s | %-34s | %-34s\n" "$1" "$2" "$3"
}

print_changes_table() {
  echo
  echo "Changes summary (before -> after)"
  printf "%-20s-+-%-34s-+-%-34s\n" "$(printf '%.0s-' {1..20})" "$(printf '%.0s-' {1..34})" "$(printf '%.0s-' {1..34})"
  _print_table_row "TCP"         "${B_TCP_CC}"     "${A_TCP_CC}"
  _print_table_row "Qdisc"       "${B_QDISC}"      "${A_QDISC}"
  _print_table_row "IP forward"  "${B_FWD}"        "${A_FWD}"
  _print_table_row "Conntrack"   "${B_CT_MAX}"     "${A_CT_MAX}"
  _print_table_row "TW buckets"  "${B_TW}"         "${A_TW}"
  _print_table_row "Swappiness"  "${B_SWAPPINESS}" "${A_SWAPPINESS}"
  _print_table_row "Swap"        "${B_SWAP}"       "${A_SWAP}"
  _print_table_row "Nofile"      "${B_NOFILE}"     "${A_NOFILE}"
  _print_table_row "Journald"    "${B_JOURNAL}"    "${A_JOURNAL}"
  _print_table_row "Logrotate"   "${B_LOGROT}"     "${A_LOGROT}"
  _print_table_row "Unattended"  "${B_UNATT}"      "${A_UNATT}"
}

print_manifest_table() {
  local man="$1"
  [[ -f "$man" ]] || return 0

  local copies moves
  copies="$(awk -F'\t' '$1=="COPY"{c++} END{print c+0}' "$man" 2>/dev/null || echo 0)"
  moves="$(awk -F'\t' '$1=="MOVE"{c++} END{print c+0}' "$man" 2>/dev/null || echo 0)"

  echo
  echo "Files snapshot"
  echo "  copied to backup: $copies"
  echo "  moved aside:      $moves"

  if [[ "$moves" -gt 0 ]]; then
    echo
    echo "Moved aside (original -> stored in backup)"
    printf "%-52s | %s\n" "Original path" "Backup path"
    printf "%-52s-+-%s\n" "$(printf '%.0s-' {1..52})" "$(printf '%.0s-' {1..60})"
    awk -F'\t' '$1=="MOVE"{printf "%-52s | %s\n",$2,$3}' "$man" | head -n 200
    if [[ "$moves" -gt 200 ]]; then
      echo "(showing first 200 moved files)"
    fi
  fi

  if [[ "$copies" -gt 0 ]]; then
    echo
    echo "Backed up (original -> stored in backup)"
    printf "%-52s | %s\n" "Original path" "Backup path"
    printf "%-52s-+-%s\n" "$(printf '%.0s-' {1..52})" "$(printf '%.0s-' {1..60})"
    awk -F'\t' '$1=="COPY"{printf "%-52s | %s\n",$2,$3}' "$man" | head -n 200
    if [[ "$copies" -gt 200 ]]; then
      echo "(showing first 200 copied files)"
    fi
  fi
}

###############################################################################
# status
###############################################################################
print_summary() {
  local mode="$1" profile="$2" backup="$3"

  local bbr qdisc fwd ctmax ctcnt nof swap_mib swpns twb jr_sys jr_run lr_freq lr_rot ureb
  bbr="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
  qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo '?')"
  fwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
  ctmax="$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'n/a')"
  ctcnt="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 'n/a')"
  nof="$(systemctl show --property DefaultLimitNOFILE 2>/dev/null | cut -d= -f2 || echo '?')"
  swap_mib="$(awk '/SwapTotal:/ {print int(($2+1023)/1024)}' /proc/meminfo 2>/dev/null || echo '?')"
  swpns="$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
  twb="$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo '?')"
  jr_sys="$(awk -F= '/^\s*SystemMaxUse=/{print $2}' /etc/systemd/journald.conf.d/90-edge.conf 2>/dev/null | tr -d ' ' || true)"
  jr_run="$(awk -F= '/^\s*RuntimeMaxUse=/{print $2}' /etc/systemd/journald.conf.d/90-edge.conf 2>/dev/null | tr -d ' ' || true)"
  lr_freq="$(awk 'tolower($1)=="daily"||tolower($1)=="weekly"||tolower($1)=="monthly"{print $1; exit}' /etc/logrotate.conf 2>/dev/null || echo '?')"
  lr_rot="$(awk 'tolower($1)=="rotate"{print $2; exit}' /etc/logrotate.conf 2>/dev/null || echo '?')"
  ureb="$(grep -R --no-messages -h 'Unattended-Upgrade::Automatic-Reboot' /etc/apt/apt.conf.d/*.conf 2>/dev/null | tr -d ' ' | tr '\n' '|' | sed 's/|$//' || true)"

  echo "SUMMARY status=OK host=$(host_short) mode=$mode profile=$profile bbr=$bbr qdisc=$qdisc ip_forward=$fwd twbuckets=$twb ct=${ctcnt}/${ctmax} nofile=$nof swap_mib=$swap_mib swappiness=$swpns journald=${jr_sys:-?}/${jr_run:-?} logrotate=${lr_freq}/rotate=${lr_rot} unattended=${ureb:-n/a} backup=${backup:-n/a}"
}

status_cmd() {
  print_summary "status" "-" "-"
}

###############################################################################
# apply
###############################################################################
_APPLY_CREATED_BACKUP="0"

on_apply_fail() {
  local code=$?
  err "Apply failed (exit code=$code)."
  if [[ "$_APPLY_CREATED_BACKUP" == "1" && "${EDGE_AUTO_ROLLBACK:-0}" == "1" ]]; then
    warn "EDGE_AUTO_ROLLBACK=1 -> attempting rollback from: $backup_dir"
    BACKUP_DIR="$backup_dir" rollback_cmd || true
  else
    warn "Rollback is available via: sudo BACKUP_DIR=$backup_dir $0 rollback (or use latest backup)."
  fi
  exit "$code"
}

apply_cmd() {
  need_root "$@"
  confirm

  trap on_apply_fail ERR

  log "Step 1/9: create backup"
  mkbackup
  _APPLY_CREATED_BACKUP="1"

  # snapshot BEFORE any changes
  snapshot_before

  log "Step 2/9: discover resources"
  local mem_kb mem_mb cpu
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  mem_mb="$((mem_kb / 1024))"
  cpu="$(nproc)"
  ok "Detected: cpu=$cpu mem_mb=$mem_mb"

  log "Step 3/9: choose profile"
  local profile="xhigh"
  if [[ "$cpu" -le 1 || "$mem_mb" -lt 2048 ]]; then
    profile="low"
  elif [[ "$mem_mb" -lt 8192 ]]; then
    profile="mid"
  elif [[ "$mem_mb" -lt 12288 ]]; then
    profile="high"
  fi
  if [[ "${FORCE_PROFILE:-}" =~ ^(low|mid|high|xhigh)$ ]]; then
    profile="${FORCE_PROFILE}"
    warn "FORCE_PROFILE set -> profile=$profile"
  fi
  ok "Profile: $profile"

  local somaxconn netdev_backlog syn_backlog rmem_max wmem_max rmem_def wmem_def tcp_rmem tcp_wmem
  local ct_max swappiness nofile tw_buckets j_system j_runtime logrotate_rotate

  case "$profile" in
    low)
      somaxconn=4096;  netdev_backlog=16384;  syn_backlog=4096
      rmem_max=$((32*1024*1024)); wmem_max=$((32*1024*1024))
      rmem_def=$((8*1024*1024));  wmem_def=$((8*1024*1024))
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
      rmem_max=$((64*1024*1024)); wmem_max=$((64*1024*1024))
      rmem_def=$((16*1024*1024)); wmem_def=$((16*1024*1024))
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
      rmem_def=$((32*1024*1024)); wmem_def=$((32*1024*1024))
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
      rmem_def=$((64*1024*1024)); wmem_def=$((64*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      ct_max=1048576
      swappiness=10
      nofile=1048576
      tw_buckets=300000
      j_system="400M"; j_runtime="200M"
      logrotate_rotate=21
      ;;
  esac

  local ct_buckets=$((ct_max/4)); [[ "$ct_buckets" -lt 4096 ]] && ct_buckets=4096

  log "Step 4/9: swap sizing (/swapfile if no swap partition)"
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

  if [[ "$has_swap_partition" == "1" ]]; then
    ok "Swap partition detected -> leaving swap as-is."
  else
    local active_swapfile="0"
    if /sbin/swapon --show=NAME 2>/dev/null | grep -qx '/swapfile'; then
      active_swapfile="1"
    fi

    local need_swapfile="0"
    if [[ "$swap_total_mb" -eq 0 ]]; then
      need_swapfile="1"
    elif [[ "$active_swapfile" == "1" ]]; then
      local diff=$(( swap_total_mb > swap_target_mb ? swap_total_mb - swap_target_mb : swap_target_mb - swap_total_mb ))
      if [[ "$diff" -ge 256 ]]; then need_swapfile="1"; fi
    elif [[ -f /swapfile ]]; then
      need_swapfile="1"
    fi

    if [[ "$need_swapfile" == "1" ]]; then
      log "Configuring /swapfile size=${swap_gb}G"
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
      ok "/swapfile enabled"
    else
      ok "Swap looks OK (swap_total_mb=${swap_total_mb} target_mb=${swap_target_mb})"
    fi
  fi

  log "Step 5/9: sysctl tuning (BBR+fq, forwarding, safe tcp, conntrack, vm)"
  backup_file /etc/sysctl.conf

  shopt -s nullglob
  for f in /etc/sysctl.d/*.conf; do
    [[ -f "$f" ]] || continue
    case "$f" in
      /etc/sysctl.d/90-edge-network.conf|/etc/sysctl.d/92-edge-safe.conf|/etc/sysctl.d/95-edge-forward.conf|/etc/sysctl.d/96-edge-vm.conf|/etc/sysctl.d/99-edge-conntrack.conf) continue ;;
    esac
    if grep -Eq 'nf_conntrack_|tcp_congestion_control|default_qdisc|ip_forward|somaxconn|netdev_max_backlog|tcp_rmem|tcp_wmem|rmem_max|wmem_max|vm\.swappiness|vfs_cache_pressure|tcp_syncookies|tcp_max_tw_buckets|tcp_keepalive|tcp_mtu_probing|tcp_fin_timeout|tcp_tw_reuse|tcp_slow_start_after_idle|tcp_rfc1337' "$f"; then
      warn "Moving aside conflicting sysctl fragment: $f"
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

  sysctl --system >/dev/null
  ok "sysctl applied"

  log "Step 6/9: NOFILE (systemd + limits.d)"
  backup_file /etc/systemd/system.conf
  mkdir -p /etc/systemd/system.conf.d
  shopt -s nullglob
  for f in /etc/systemd/system.conf.d/*.conf; do
    [[ "$f" == "/etc/systemd/system.conf.d/90-edge.conf" ]] && continue
    if grep -qE '^\s*DefaultLimitNOFILE\s*=' "$f"; then
      warn "Moving aside DefaultLimitNOFILE override: $f"
      move_aside "$f"
    fi
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
    if grep -qE '^\s*[*a-zA-Z0-9._-]+\s+(soft|hard)\s+nofile\s+' "$f"; then
      warn "Moving aside nofile limits: $f"
      move_aside "$f"
    fi
  done
  shopt -u nullglob

  cat > /etc/security/limits.d/90-edge.conf <<EOM
* soft nofile ${nofile}
* hard nofile ${nofile}
root soft nofile ${nofile}
root hard nofile ${nofile}
EOM

  systemctl daemon-reexec >/dev/null 2>&1 || true
  ok "nofile configured (may require new session to fully apply)"

  log "Step 7/9: journald limits"
  mkdir -p /etc/systemd/journald.conf.d
  shopt -s nullglob
  for f in /etc/systemd/journald.conf.d/*.conf; do
    [[ "$f" == "/etc/systemd/journald.conf.d/90-edge.conf" ]] && continue
    warn "Moving aside journald override: $f"
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
  ok "journald configured"

  log "Step 8/9: unattended-upgrades (disable auto reboot)"
  mkdir -p /etc/apt/apt.conf.d
  backup_file /etc/apt/apt.conf.d/99-edge-unattended.conf
  cat > /etc/apt/apt.conf.d/99-edge-unattended.conf <<'EOM'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOM
  ok "unattended-upgrades configured"

  log "Step 9/9: irqbalance, logrotate, tmpfiles"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^irqbalance\.service'; then
    systemctl enable --now irqbalance >/dev/null 2>&1 || true
  fi

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

  mkdir -p /etc/tmpfiles.d
  backup_file /etc/tmpfiles.d/edge-tmp.conf
  cat > /etc/tmpfiles.d/edge-tmp.conf <<'EOM'
D /tmp            1777 root root 7d
D /var/tmp        1777 root root 14d
EOM
  systemd-tmpfiles --create >/dev/null 2>&1 || true

  ok "apply finished"
  trap - ERR

  # snapshot AFTER changes and print tables
  snapshot_after
  print_changes_table
  print_manifest_table "$manifest"

  print_summary "apply" "$profile" "$backup_dir"
  echo "BACKUP_DIR=$backup_dir"
}

###############################################################################
# rollback
###############################################################################
rollback_cmd() {
  need_root "$@"

  local backup="${BACKUP_DIR:-}"
  if [[ -z "$backup" ]]; then
    backup="$(latest_backup_dir)"
  fi
  [[ -n "$backup" && -d "$backup" ]] || die "Backup not found. Set BACKUP_DIR=/root/edge-tuning-backup-... or run apply first."

  local man="${backup}/MANIFEST.tsv"

  # snapshot BEFORE rollback
  snapshot_before

  log "Rollback: using backup=$backup"

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

  log "Restoring from manifest"
  restore_manifest "$backup"

  if /sbin/swapon --show=NAME 2>/dev/null | grep -qx '/swapfile'; then
    /sbin/swapoff /swapfile 2>/dev/null || true
  fi
  sed -i -E '/^\s*\/swapfile\s+none\s+swap\s+/d' /etc/fstab 2>/dev/null || true
  rm -f /swapfile 2>/dev/null || true

  sysctl --system >/dev/null 2>&1 || true
  systemctl daemon-reexec >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true

  ok "rollback finished"

  # snapshot AFTER rollback and print tables
  snapshot_after
  print_changes_table
  print_manifest_table "$man"

  print_summary "rollback" "-" "$backup"
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
