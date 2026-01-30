#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Minimal logging + colors
###############################################################################
LOG_TS="${EDGE_LOG_TS:-1}"
ts() { [[ "$LOG_TS" == "1" ]] && date +"%Y-%m-%d %H:%M:%S" || true; }

_is_tty() { [[ -t 1 ]]; }
c_reset=$'\033[0m'
c_dim=$'\033[2m'
c_bold=$'\033[1m'
c_red=$'\033[31m'
c_yel=$'\033[33m'
c_grn=$'\033[32m'
c_cyan=$'\033[36m'
c_mag=$'\033[35m'

_pfx() { _is_tty && printf "%s%s%s" "${c_dim}" "$(ts) " "${c_reset}" || true; }

ok()   { _pfx; _is_tty && printf "%sOK%s " "$c_grn" "$c_reset" || printf "OK "; echo "$*"; }
warn() { _pfx; _is_tty && printf "%sWARN%s " "$c_yel" "$c_reset" || printf "WARN "; echo "$*"; }
err()  { _pfx; _is_tty && printf "%sERROR%s " "$c_red" "$c_reset" || printf "ERROR "; echo "$*"; }
die()  { err "$*"; exit 1; }

hdr() { _is_tty && printf "%s%s%s\n" "$c_bold$c_cyan" "$*" "$c_reset" || echo "$*"; }
key() { _is_tty && printf "%s%s%s" "$c_mag" "$*" "$c_reset" || printf "%s" "$*"; }
val() { _is_tty && printf "%s%s%s" "$c_bold" "$*" "$c_reset" || printf "%s" "$*"; }

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
# Helpers
###############################################################################
to_int() {
  local s="${1:-}"
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    echo "$s"
  else
    echo 0
  fi
}
imax() {
  local a b
  a="$(to_int "${1:-0}")"
  b="$(to_int "${2:-0}")"
  [[ "$a" -ge "$b" ]] && echo "$a" || echo "$b"
}
clamp() {
  local v lo hi
  v="$(to_int "${1:-0}")"
  lo="$(to_int "${2:-0}")"
  hi="$(to_int "${3:-0}")"
  [[ "$v" -lt "$lo" ]] && v="$lo"
  [[ "$v" -gt "$hi" ]] && v="$hi"
  echo "$v"
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
# Tiered selection (RAM + CPU), and disk-aware logging caps
###############################################################################
ceil_gib() { local mem_mb="$1"; echo $(( (mem_mb + 1023) / 1024 )); }

ceil_to_tier() {
  local x="$1"
  if   [[ "$x" -le 1  ]]; then echo 1
  elif [[ "$x" -le 2  ]]; then echo 2
  elif [[ "$x" -le 4  ]]; then echo 4
  elif [[ "$x" -le 8  ]]; then echo 8
  elif [[ "$x" -le 16 ]]; then echo 16
  elif [[ "$x" -le 32 ]]; then echo 32
  else echo 64
  fi
}

profile_from_tier() {
  local t="$1"
  case "$t" in
    1)  echo "low" ;;
    2)  echo "mid" ;;
    4)  echo "high" ;;
    8)  echo "xhigh" ;;
    16) echo "2xhigh" ;;
    32) echo "dedicated" ;;
    *)  echo "dedicated+" ;;
  esac
}

tier_rank() {
  case "$1" in
    1) echo 1 ;;
    2) echo 2 ;;
    4) echo 3 ;;
    8) echo 4 ;;
    16) echo 5 ;;
    32) echo 6 ;;
    *) echo 7 ;;
  esac
}
tier_max() {
  local a="$1" b="$2"
  local ra rb
  ra="$(tier_rank "$a")"; rb="$(tier_rank "$b")"
  if [[ "$ra" -ge "$rb" ]]; then echo "$a"; else echo "$b"; fi
}

# Conntrack: not too low for small VPS
# ct_soft = RAM_MiB * 64 + CPU * 8192
ct_soft_from_ram_cpu() {
  local mem_mb="$1" cpu="$2"
  local ct=$(( mem_mb * 64 + cpu * 8192 ))
  [[ "$ct" -lt 32768 ]] && ct=32768
  echo "$ct"
}

disk_size_mb_for_logs() {
  local mb=""
  mb="$(df -Pm /var/log 2>/dev/null | awk 'NR==2{print $2}' || true)"
  [[ -n "$mb" ]] || mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $2}' || true)"
  [[ -n "$mb" ]] || mb="0"
  echo "$mb"
}

pick_log_caps() {
  local disk_mb="$1"
  J_SYSTEM="100M"; J_RUNTIME="50M"; LR_ROTATE="7"
  if [[ "$disk_mb" -lt 15000 ]]; then
    J_SYSTEM="80M";  J_RUNTIME="40M";  LR_ROTATE="5"
  elif [[ "$disk_mb" -lt 30000 ]]; then
    J_SYSTEM="120M"; J_RUNTIME="60M";  LR_ROTATE="7"
  elif [[ "$disk_mb" -lt 60000 ]]; then
    J_SYSTEM="200M"; J_RUNTIME="100M"; LR_ROTATE="10"
  elif [[ "$disk_mb" -lt 120000 ]]; then
    J_SYSTEM="300M"; J_RUNTIME="150M"; LR_ROTATE="14"
  else
    J_SYSTEM="400M"; J_RUNTIME="200M"; LR_ROTATE="21"
  fi
}

###############################################################################
# Output tables
###############################################################################
print_run_table() {
  local mode="$1" profile="$2" backup="$3"
  local cpu="$4" mem_mb="$5" gib="$6"
  local ram_tier="$7" cpu_tier="$8" tier="$9"
  local disk_mb="${10}" jcap="${11}" lrrot="${12}"

  echo
  hdr "Run"
  printf "%-12s | %s\n" "$(key Host)"   "$(val "$(host_short)")"
  printf "%-12s | %s\n" "$(key Mode)"   "$(val "$mode")"
  printf "%-12s | %s\n" "$(key CPU)"    "$(val "${cpu:-"-"}")"
  printf "%-12s | %s MiB (~%s GiB)\n" "$(key RAM)" "$(val "${mem_mb:-"-"}")" "$(val "${gib:-"-"}")"
  printf "%-12s | %s MB\n" "$(key Disk(/var))" "$(val "${disk_mb:-"-"}")"
  printf "%-12s | %s (RAM %s / CPU %s)\n" "$(key Tier)" \
    "$(val "${tier:-"-"}")" "$(val "${ram_tier:-"-"}")" "$(val "${cpu_tier:-"-"}")"

  echo
  hdr "Why this tier"
  echo "  RAM ~${gib} GiB -> RAM tier ${ram_tier}"
  echo "  CPU ${cpu} -> CPU tier ${cpu_tier}"
  echo "  Final tier = max(RAM tier, CPU tier) = ${tier}"

  echo
  printf "%-12s | %s\n" "$(key Profile)"      "$(val "${profile:-"-"}")"
  printf "%-12s | %s\n" "$(key Journald cap)" "$(val "${jcap:-"-"}")"
  printf "%-12s | rotate %s\n" "$(key Logrotate)" "$(val "${lrrot:-"-"}")"
  printf "%-12s | %s\n" "$(key Backup)"       "$(val "${backup:-"-"}")"

  echo
  hdr "Verdict"
  echo "  Tier ${tier} -> profile ${profile} looks OK for CPU=${cpu}, RAM~${gib} GiB, disk(/var)=${disk_mb} MB."
}

print_planned_table() {
  echo
  hdr "Planned (computed targets)"
  printf "%-16s | %s\n" "TCP"           "${P_TCP_CC}"
  printf "%-16s | %s\n" "Qdisc"         "${P_QDISC}"
  printf "%-16s | %s\n" "Forward"       "${P_FWD}"
  printf "%-16s | %s\n" "Conntrack"     "${P_CT_FINAL} (soft ${P_CT_SOFT}, clamp ${P_CT_CLAMPED})"
  printf "%-16s | %s\n" "TW buckets"    "${P_TW_FINAL}"
  printf "%-16s | %s\n" "Nofile"        "${P_NOFILE_FINAL}"
  printf "%-16s | %s\n" "Swappiness"    "${P_SWAPPINESS}"
  printf "%-16s | %s\n" "Journald cap"  "${P_JOURNAL_CAP}"
  printf "%-16s | %s\n" "Logrotate"     "rotate ${P_LR_ROTATE}"
  printf "%-16s | %s\n" "Auto reboot"   "false"
  printf "%-16s | %s\n" "Reboot time"   "04:00"
}

print_before_after_all() {
  echo
  hdr "Before -> After (all)"
  printf "%-12s-+-%-24s-+-%-24s\n" "$(printf '%.0s-' {1..12})" "$(printf '%.0s-' {1..24})" "$(printf '%.0s-' {1..24})"

  row() {
    local k="$1" b="$2" a="$3"
    if [[ "$b" != "$a" ]]; then
      if _is_tty; then
        printf "%-12s | %s%-24s%s | %s%-24s%s\n" "$k" "$c_grn" "$b" "$c_reset" "$c_grn" "$a" "$c_reset"
      else
        printf "%-12s | %-24s | %-24s\n" "$k" "$b" "$a"
      fi
    else
      printf "%-12s | %-24s | %-24s\n" "$k" "$b" "$a"
    fi
  }

  row "TCP"        "$B_TCP_CC" "$A_TCP_CC"
  row "Qdisc"      "$B_QDISC" "$A_QDISC"
  row "Forward"    "$B_FWD" "$A_FWD"
  row "Conntrack"  "$B_CT_MAX" "$A_CT_MAX"
  row "TW buckets" "$B_TW" "$A_TW"
  row "Swappiness" "$B_SWAPPINESS" "$A_SWAPPINESS"
  row "Swap"       "$B_SWAP" "$A_SWAP"
  row "Nofile"     "$B_NOFILE" "$A_NOFILE"
  row "Journald"   "$B_JOURNAL" "$A_JOURNAL"
  row "Logrotate"  "$B_LOGROT" "$A_LOGROT"
  row "Auto reboot" "$(_unattended_state "$B_UNATT")" "$(_unattended_state "$A_UNATT")"
  row "Reboot time" "$(_unattended_time "$B_UNATT")"  "$(_unattended_time "$A_UNATT")"
}

print_manifest_compact() {
  local man="$1"
  [[ -f "$man" ]] || return 0
  local copies moves
  copies="$(awk -F'\t' '$1=="COPY"{c++} END{print c+0}' "$man" 2>/dev/null || echo 0)"
  moves="$(awk -F'\t' '$1=="MOVE"{c++} END{print c+0}' "$man" 2>/dev/null || echo 0)"

  echo
  hdr "Files"
  echo "  backed up:   $copies"
  echo "  moved aside: $moves"

  if [[ "$moves" -gt 0 ]]; then
    echo
    hdr "Moved aside"
    awk -F'\t' '$1=="MOVE"{print "  - " $2}' "$man" | head -n 50
    [[ "$moves" -gt 50 ]] && echo "  (showing first 50)"
  fi
}

###############################################################################
# apply / rollback
###############################################################################
on_apply_fail() {
  local code=$?
  err "Apply failed (exit code=$code)."
  warn "Rollback: sudo BACKUP_DIR=$backup_dir $0 rollback"
  exit "$code"
}

apply_cmd() {
  need_root "$@"
  confirm
  trap on_apply_fail ERR

  mkbackup
  snapshot_before

  # Discover resources
  local mem_kb mem_mb cpu
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  mem_mb="$((mem_kb / 1024))"
  cpu="$(nproc)"

  local disk_mb
  disk_mb="$(disk_size_mb_for_logs)"

  # Tiers
  local gib ram_tier cpu_tier tier profile
  gib="$(ceil_gib "$mem_mb")"
  ram_tier="$(ceil_to_tier "$gib")"
  cpu_tier="$(ceil_to_tier "$cpu")"
  tier="$(tier_max "$ram_tier" "$cpu_tier")"
  profile="$(profile_from_tier "$tier")"

  # Manual override
  if [[ "${FORCE_PROFILE:-}" =~ ^(low|mid|high|xhigh|2xhigh|dedicated|dedicated\+)$ ]]; then
    profile="${FORCE_PROFILE}"
  fi

  # Disk-aware log caps
  pick_log_caps "$disk_mb"
  local j_system="$J_SYSTEM" j_runtime="$J_RUNTIME" logrotate_rotate="$LR_ROTATE"

  # Defaults by profile (network + limits)
  local somaxconn netdev_backlog syn_backlog rmem_max wmem_max rmem_def wmem_def tcp_rmem tcp_wmem
  local swappiness nofile_profile tw_profile
  local ct_min ct_cap

  case "$profile" in
    low)
      somaxconn=4096;  netdev_backlog=16384;  syn_backlog=4096
      rmem_max=$((32*1024*1024));  wmem_max=$((32*1024*1024))
      rmem_def=$((8*1024*1024));   wmem_def=$((8*1024*1024))
      tcp_rmem="4096 262144 ${rmem_max}"
      tcp_wmem="4096 262144 ${wmem_max}"
      swappiness=5
      nofile_profile=65536
      tw_profile=50000
      ct_min=32768;   ct_cap=65536
      ;;
    mid)
      somaxconn=16384; netdev_backlog=65536;  syn_backlog=16384
      rmem_max=$((64*1024*1024));  wmem_max=$((64*1024*1024))
      rmem_def=$((16*1024*1024));  wmem_def=$((16*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      swappiness=10
      nofile_profile=131072
      tw_profile=90000
      ct_min=65536;   ct_cap=131072
      ;;
    high)
      somaxconn=65535; netdev_backlog=131072; syn_backlog=65535
      rmem_max=$((128*1024*1024)); wmem_max=$((128*1024*1024))
      rmem_def=$((32*1024*1024));  wmem_def=$((32*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      swappiness=10
      nofile_profile=262144
      tw_profile=150000
      ct_min=131072;  ct_cap=262144
      ;;
    xhigh)
      somaxconn=65535; netdev_backlog=250000; syn_backlog=65535
      rmem_max=$((256*1024*1024)); wmem_max=$((256*1024*1024))
      rmem_def=$((64*1024*1024));  wmem_def=$((64*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      swappiness=10
      nofile_profile=524288
      tw_profile=250000
      ct_min=262144;  ct_cap=524288
      ;;
    2xhigh)
      somaxconn=65535; netdev_backlog=350000; syn_backlog=65535
      rmem_max=$((384*1024*1024)); wmem_max=$((384*1024*1024))
      rmem_def=$((96*1024*1024));  wmem_def=$((96*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      swappiness=10
      nofile_profile=1048576
      tw_profile=350000
      ct_min=524288;  ct_cap=1048576
      ;;
    dedicated)
      somaxconn=65535; netdev_backlog=500000; syn_backlog=65535
      rmem_max=$((512*1024*1024)); wmem_max=$((512*1024*1024))
      rmem_def=$((128*1024*1024)); wmem_def=$((128*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      swappiness=10
      nofile_profile=2097152
      tw_profile=600000
      ct_min=1048576; ct_cap=2097152
      ;;
    dedicated+)
      somaxconn=65535; netdev_backlog=700000; syn_backlog=65535
      rmem_max=$((768*1024*1024)); wmem_max=$((768*1024*1024))
      rmem_def=$((192*1024*1024)); wmem_def=$((192*1024*1024))
      tcp_rmem="4096 87380 ${rmem_max}"
      tcp_wmem="4096 65536 ${wmem_max}"
      swappiness=10
      nofile_profile=4194304
      tw_profile=900000
      ct_min=2097152; ct_cap=4194304
      ;;
  esac

  # Never decrease: use current as floor
  local current_ct current_tw current_nofile
  current_ct="$(to_int "$B_CT_MAX")"
  current_tw="$(to_int "$B_TW")"
  current_nofile="$(to_int "$B_NOFILE")"

  local nofile_final tw_final
  nofile_final="$(imax "$current_nofile" "$nofile_profile")"
  tw_final="$(imax "$current_tw" "$tw_profile")"

  # Conntrack: compute -> clamp -> never-decrease
  local ct_soft ct_clamped ct_final
  ct_soft="$(ct_soft_from_ram_cpu "$mem_mb" "$cpu")"
  ct_clamped="$(clamp "$ct_soft" "$ct_min" "$ct_cap")"
  ct_final="$(imax "$current_ct" "$ct_clamped")"
  local ct_buckets=$((ct_final/4)); [[ "$ct_buckets" -lt 4096 ]] && ct_buckets=4096

  # Populate "planned" globals for printing
  P_TCP_CC="bbr"
  P_QDISC="fq"
  P_FWD="1"
  P_CT_SOFT="$ct_soft"
  P_CT_CLAMPED="$ct_clamped"
  P_CT_FINAL="$ct_final"
  P_TW_FINAL="$tw_final"
  P_NOFILE_FINAL="$nofile_final"
  P_SWAPPINESS="$swappiness"
  P_JOURNAL_CAP="${j_system}/${j_runtime}"
  P_LR_ROTATE="$logrotate_rotate"

  # ---- swap sizing ----
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

  # ---- sysctl ----
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
net.netfilter.nf_conntrack_max = ${ct_final}
net.netfilter.nf_conntrack_buckets = ${ct_buckets}
net.netfilter.nf_conntrack_tcp_timeout_established = 900
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
EOM

  cat > /etc/sysctl.d/92-edge-safe.conf <<EOM
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = ${tw_final}
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
EOM

  sysctl --system >/dev/null 2>&1 || true

  # ---- NOFILE ----
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
DefaultLimitNOFILE=${nofile_final}
EOM

  mkdir -p /etc/security/limits.d
  shopt -s nullglob
  for f in /etc/security/limits.d/*.conf; do
    [[ "$f" == "/etc/security/limits.d/90-edge.conf" ]] && continue
    grep -qE '^\s*[*a-zA-Z0-9._-]+\s+(soft|hard)\s+nofile\s+' "$f" && move_aside "$f"
  done
  shopt -u nullglob

  cat > /etc/security/limits.d/90-edge.conf <<EOM
* soft nofile ${nofile_final}
* hard nofile ${nofile_final}
root soft nofile ${nofile_final}
root hard nofile ${nofile_final}
EOM

  systemctl daemon-reexec >/dev/null 2>&1 || true

  # ---- journald ----
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

  # ---- unattended-upgrades ----
  mkdir -p /etc/apt/apt.conf.d
  backup_file /etc/apt/apt.conf.d/99-edge-unattended.conf
  cat > /etc/apt/apt.conf.d/99-edge-unattended.conf <<'EOM'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOM

  # irqbalance
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^irqbalance\.service'; then
    systemctl enable --now irqbalance >/dev/null 2>&1 || true
  fi

  # ---- logrotate ----
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

  # ---- tmpfiles ----
  mkdir -p /etc/tmpfiles.d
  backup_file /etc/tmpfiles.d/edge-tmp.conf
  cat > /etc/tmpfiles.d/edge-tmp.conf <<'EOM'
D /tmp            1777 root root 7d
D /var/tmp        1777 root root 14d
EOM
  systemd-tmpfiles --create >/dev/null 2>&1 || true

  snapshot_after

  ok "Applied. Backup: $backup_dir"
  print_run_table "apply" "$profile" "$backup_dir" "$cpu" "$mem_mb" "$gib" "$ram_tier" "$cpu_tier" "$tier" "$disk_mb" "${j_system}/${j_runtime}" "$logrotate_rotate"
  print_planned_table
  print_before_after_all
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
  echo
  hdr "Run"
  printf "%-12s | %s\n" "$(key Host)"   "$(val "$(host_short)")"
  printf "%-12s | %s\n" "$(key Mode)"   "$(val "rollback")"
  printf "%-12s | %s\n" "$(key Backup)" "$(val "$backup")"
  print_before_after_all
  print_manifest_compact "$man"
}

status_cmd() {
  snapshot_before
  echo
  hdr "Current"
  printf "%-12s | %s\n" "$(key Host)"       "$(val "$(host_short)")"
  printf "%-12s | %s\n" "$(key TCP)"        "$(val "$B_TCP_CC")"
  printf "%-12s | %s\n" "$(key Qdisc)"      "$(val "$B_QDISC")"
  printf "%-12s | %s\n" "$(key Forward)"    "$(val "$B_FWD")"
  printf "%-12s | %s\n" "$(key Conntrack)"  "$(val "$B_CT_MAX")"
  printf "%-12s | %s\n" "$(key TW buckets)" "$(val "$B_TW")"
  printf "%-12s | %s\n" "$(key Swappiness)" "$(val "$B_SWAPPINESS")"
  printf "%-12s | %s\n" "$(key Swap)"       "$(val "$B_SWAP")"
  printf "%-12s | %s\n" "$(key Nofile)"     "$(val "$B_NOFILE")"
  printf "%-12s | %s\n" "$(key Journald)"   "$(val "$B_JOURNAL")"
  printf "%-12s | %s\n" "$(key Logrotate)"  "$(val "$B_LOGROT")"
  printf "%-12s | %s\n" "$(key AutoReboot)" "$(val "$(_unattended_state "$B_UNATT")")"
  printf "%-12s | %s\n" "$(key RebootTime)" "$(val "$(_unattended_time "$B_UNATT")")"
}

case "${1:-}" in
  apply)    shift; apply_cmd "$@" ;;
  rollback) shift; rollback_cmd "$@" ;;
  status)   shift; status_cmd "$@" ;;
  *)
    echo "Usage: sudo $0 {apply|rollback|status}"
    exit 1
    ;;
esac
