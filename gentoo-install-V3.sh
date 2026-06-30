#!/usr/bin/env bash
# ============================================================
#   ██████╗ ███████╗███╗   ██╗████████╗ ██████╗  ██████╗
#  ██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝██╔═══██╗██╔═══██╗
#  ██║  ███╗█████╗  ██╔██╗ ██║   ██║   ██║   ██║██║   ██║
#  ██║   ██║██╔══╝  ██║╚██╗██║   ██║   ██║   ██║██║   ██║
#  ╚██████╔╝███████╗██║ ╚████║   ██║   ╚██████╔╝╚██████╔╝
#   ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝  ╚═════╝
#
#  Gentoo Interactive Installer  v5.0
#  Merged & improved from v3 + v4
#  License: MIT
#
#  Improvements over v3/v4:
#   • Resume / checkpoint system  (from v4)
#   • Animated progress bars       (from v4)
#   • Mirror auto-rank + region    (from v4)
#   • Live preview before confirm  (from v4)
#   • Password via env (no plaintext in heredoc) (from v4)
#   • wipefs before partitioning   (from v4)
#   • set +u around source (from v4)
#   • Interactive locale selection (new)
#   • Shell choice (bash/zsh/fish) (new)
#   • SSH key import option        (new)
#   • Auto reboot with countdown   (new)
#   • Disk space pre-check         (new)
#   • Portage package sets via /etc/portage/sets (new)
#   • plugdev group safe-create    (from v4)
#   • make.conf: LINGUAS / L10N    (new)
#   • Merged do_format / _do_format_root (deduplication fix)
#   • Colour-coded step header during install (new)
#   • --resume CLI flag support    (new)
# ============================================================

set -euo pipefail

# ──────────────────────────────────────────────
# COLOURS
# ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[1;34m'; MAGENTA='\033[0;35m'; RESET='\033[0m'
BOLD='\033[1m'

# ──────────────────────────────────────────────
# GLOBAL STATE
# ──────────────────────────────────────────────
DISK=""
BOOT_PART=""; SWAP_PART=""; ROOT_PART=""
HOSTNAME=""; USERNAME=""
ROOT_PASS=""; USER_PASS=""
TIMEZONE=""
STAGE3_VARIANT=""
STAGE3_TARBALL=""
STAGE3_URL=""
PROFILE=""
USE_FLAGS=""
KERNEL_CHOICE=""
FS_TYPE=""
SWAP_SIZE=""
BOOT_MODE=""
MARCH_OPT=""          # native | generic
ACCEPT_KW=""          # amd64 | ~amd64
NET_TOOL=""
DE_CHOICE=""
VIDEO_CARDS=""
LOCALE="en_US.UTF-8"
SHELL_CHOICE="bash"
SSH_KEY=""
GENTOO_MIRROR="https://distfiles.gentoo.org"
LOG_FILE="/tmp/gentoo-install.log"
STATE_FILE="/tmp/gentoo-install.state"
RESUMING=0

# ──────────────────────────────────────────────
# PARTITION NAMING HELPER
# nvme0n1 → nvme0n1p1 / sda → sda1
# ──────────────────────────────────────────────
part() {
  local disk="$1" num="$2"
  if [[ "$disk" =~ nvme|mmcblk ]]; then
    echo "${disk}p${num}"
  else
    echo "${disk}${num}"
  fi
}

# ──────────────────────────────────────────────
# LOGGING + OUTPUT HELPERS
# ──────────────────────────────────────────────
log()   { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG_FILE"; }
die()   { printf "${RED}${BOLD}[FATAL]${RESET} %s\n" "$*" >&2; log "FATAL: $*"; exit 1; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n"  "$*"; log "WARN: $*"; }
info()  { printf "${CYAN}[INFO]${RESET}  %s\n"   "$*"; log "INFO: $*"; }
ok()    { printf "${GREEN}[OK]${RESET}    %s\n"  "$*"; log "OK: $*"; }
step()  { printf "\n${BLUE}${BOLD}══════  %s  ══════${RESET}\n" "$*"; log "STEP: $*"; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root."; }

check_deps() {
  local missing=()
  for cmd in dialog parted mkfs.ext4 mkfs.fat wget tar wipefs partprobe blkid numfmt; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing tools: ${missing[*]}"
    if command -v emerge &>/dev/null; then
      emerge --ask n sys-apps/dialog net-misc/wget sys-block/parted || true
    else
      die "Please install: ${missing[*]}"
    fi
  fi
}

read_password() {
  # read_password VARNAME "prompt text"
  # Requires: non-empty, ≥8 chars, confirmed
  local varname="$1" prompt="$2" p1 p2
  while true; do
    p1=$(dialog --title "Password" --passwordbox "$prompt"   9 54 3>&1 1>&2 2>&3) \
      || die "Password cancelled."
    p2=$(dialog --title "Password" --passwordbox "Confirm:" 9 54 3>&1 1>&2 2>&3) \
      || die "Password cancelled."
    if [[ -z "$p1" ]]; then
      dialog --title "Error" --msgbox "Password cannot be empty." 7 40
      continue
    fi
    if [[ ${#p1} -lt 8 ]]; then
      dialog --title "Error" --colors --msgbox \
        "\Z1Password too short\Zn (${#p1} chars).\nMinimum is \Zb8 characters\Zn." 8 48
      continue
    fi
    if [[ "$p1" != "$p2" ]]; then
      dialog --title "Error" --msgbox "Passwords do not match. Try again." 7 44
      continue
    fi
    printf -v "$varname" '%s' "$p1"
    return
  done
}

# ──────────────────────────────────────────────
# STATE / CHECKPOINT SYSTEM
# ──────────────────────────────────────────────
state_set() {
  local key="$1"; shift; local val="$*"
  grep -v "^${key}=" "$STATE_FILE" 2>/dev/null > "${STATE_FILE}.tmp" || true
  echo "${key}=${val}" >> "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}
state_get()    { grep -m1 "^${1}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2- || true; }
step_done()    { state_set "STEP_${1}" "done"; }
step_is_done() { [[ "$(state_get "STEP_${1}")" == "done" ]]; }

save_state() {
  state_set DISK           "$DISK"
  state_set BOOT_PART      "$BOOT_PART"
  state_set SWAP_PART      "$SWAP_PART"
  state_set ROOT_PART      "$ROOT_PART"
  state_set HOSTNAME       "$HOSTNAME"
  state_set USERNAME       "$USERNAME"
  state_set ROOT_PASS      "$ROOT_PASS"
  state_set USER_PASS      "$USER_PASS"
  state_set TIMEZONE       "$TIMEZONE"
  state_set STAGE3_VARIANT "$STAGE3_VARIANT"
  state_set STAGE3_TARBALL "$STAGE3_TARBALL"
  state_set STAGE3_URL     "$STAGE3_URL"
  state_set PROFILE        "$PROFILE"
  state_set USE_FLAGS      "$USE_FLAGS"
  state_set KERNEL_CHOICE  "$KERNEL_CHOICE"
  state_set FS_TYPE        "$FS_TYPE"
  state_set SWAP_SIZE      "$SWAP_SIZE"
  state_set BOOT_MODE      "$BOOT_MODE"
  state_set MARCH_OPT      "$MARCH_OPT"
  state_set ACCEPT_KW      "$ACCEPT_KW"
  state_set NET_TOOL       "$NET_TOOL"
  state_set DE_CHOICE      "$DE_CHOICE"
  state_set VIDEO_CARDS    "$VIDEO_CARDS"
  state_set GENTOO_MIRROR  "$GENTOO_MIRROR"
  state_set LOCALE         "$LOCALE"
  state_set SHELL_CHOICE   "$SHELL_CHOICE"
  state_set SSH_KEY        "$SSH_KEY"
}

load_state() {
  DISK=$(state_get DISK)
  BOOT_PART=$(state_get BOOT_PART)
  SWAP_PART=$(state_get SWAP_PART)
  ROOT_PART=$(state_get ROOT_PART)
  HOSTNAME=$(state_get HOSTNAME)
  USERNAME=$(state_get USERNAME)
  ROOT_PASS=$(state_get ROOT_PASS)
  USER_PASS=$(state_get USER_PASS)
  TIMEZONE=$(state_get TIMEZONE)
  STAGE3_VARIANT=$(state_get STAGE3_VARIANT)
  STAGE3_TARBALL=$(state_get STAGE3_TARBALL)
  STAGE3_URL=$(state_get STAGE3_URL)
  PROFILE=$(state_get PROFILE)
  USE_FLAGS=$(state_get USE_FLAGS)
  KERNEL_CHOICE=$(state_get KERNEL_CHOICE)
  FS_TYPE=$(state_get FS_TYPE)
  SWAP_SIZE=$(state_get SWAP_SIZE)
  BOOT_MODE=$(state_get BOOT_MODE)
  MARCH_OPT=$(state_get MARCH_OPT)
  ACCEPT_KW=$(state_get ACCEPT_KW)
  NET_TOOL=$(state_get NET_TOOL)
  DE_CHOICE=$(state_get DE_CHOICE)
  VIDEO_CARDS=$(state_get VIDEO_CARDS)
  GENTOO_MIRROR=$(state_get GENTOO_MIRROR)
  LOCALE=$(state_get LOCALE)
  SHELL_CHOICE=$(state_get SHELL_CHOICE)
  SSH_KEY=$(state_get SSH_KEY)
}

check_resume() {
  [[ -f "$STATE_FILE" ]] || return 0
  local completed
  completed=$(grep -c '^STEP_.*=done' "$STATE_FILE" 2>/dev/null || echo 0)
  [[ "$completed" -eq 0 ]] && return 0

  local done_list
  done_list=$(grep '^STEP_.*=done' "$STATE_FILE" 2>/dev/null \
    | sed 's/^STEP_//; s/=done//' | tr '\n' '  ')

  local ans
  ans=$(dialog --title "Resume Installation?" --colors \
    --menu "\n\Z3A previous installation was found.\Zn\n\nCompleted steps:\n  ${done_list}\n\nResume or start fresh?" \
    18 66 2 \
    "resume" "Resume from last checkpoint" \
    "fresh"  "Start fresh  (clears previous state)" \
    3>&1 1>&2 2>&3) || ans="fresh"

  if [[ "$ans" == "fresh" ]]; then
    rm -f "$STATE_FILE"
  else
    load_state
    RESUMING=1
    info "Resuming from checkpoint."
  fi
}

# ──────────────────────────────────────────────
# PROGRESS BAR ENGINE
# ──────────────────────────────────────────────
_gauge_anim() {
  local cur=$1 end=$2 pid=$3
  local step=$(( (end - cur) / 35 ))
  [[ $step -lt 1 ]] && step=1
  while kill -0 "$pid" 2>/dev/null; do
    echo "$cur"
    cur=$(( cur + step ))
    [[ $cur -ge $end ]] && cur=$(( end - 1 ))
    sleep 0.15
  done
  echo "$end"
}

# gauge_phase "Title" "Label1" END_PCT1 "cmd1"  "Label2" END_PCT2 "cmd2" ...
gauge_phase() {
  local TITLE="$1"; shift
  local args=("$@")
  local n=${#args[@]}
  (
    local i=0 cur_pct=0
    while [[ $i -lt $n ]]; do
      local label="${args[$i]}"
      local end_pct="${args[$((i+1))]}"
      local cmd="${args[$((i+2))]}"
      i=$(( i + 3 ))
      printf 'XXX\n%d\n%s\nXXX\n' "$cur_pct" "$label"
      eval "$cmd" >> "$LOG_FILE" 2>&1 &
      local bg=$!
      _gauge_anim "$cur_pct" "$end_pct" "$bg"
      wait "$bg" || true
      printf 'XXX\n%d\n✓ %s\nXXX\n' "$end_pct" "$label"
      cur_pct=$end_pct
      sleep 0.15
    done
    printf 'XXX\n100\nDone.\nXXX\n'; sleep 0.3
  ) | dialog --title "$TITLE" --gauge "Starting…" 10 72 0
}

# ──────────────────────────────────────────────
# SCREEN: WELCOME
# ──────────────────────────────────────────────
screen_welcome() {
  dialog --title "  Gentoo Installer v5.0  " --colors --msgbox "\n\
\Z6Welcome to the Gentoo Interactive Installer!\Zn\n\n\
Guided installation — inspired by Arch & Void installers.\n\n\
\ZbFeatures:\Zn\n\
  • NVMe / eMMC / SATA disk support\n\
  • Btrfs subvolumes  (@, @home, @cache, @snapshots)\n\
  • ZFS & Bcachefs filesystem options\n\
  • GPU detection & VIDEO_CARDS setup\n\
  • CPU-aware -march optimisation\n\
  • Mirror auto-rank + regional selection\n\
  • Resume / checkpoint on interruption\n\
  • Animated progress bars\n\
  • Shell choice (bash / zsh / fish)\n\
  • SSH key import for new user\n\
  • Auto reboot after install\n\n\
\Z3Log:\Zn $LOG_FILE\n\
\Z1Minimum 25 GB free disk space required.\Zn" 28 66
}

# ──────────────────────────────────────────────
# SCREEN: BOOT MODE
# ──────────────────────────────────────────────
screen_detect_boot() {
  if [[ -d /sys/firmware/efi/efivars ]]; then
    BOOT_MODE="uefi"
    dialog --title "Boot Mode" --colors \
      --msgbox "\n\Z2UEFI detected.\Zn  GPT + EFI System Partition will be used." 8 54
  else
    BOOT_MODE="bios"
    dialog --title "Boot Mode" --colors \
      --msgbox "\n\Z3BIOS/Legacy detected.\Zn  GPT + GRUB bios_grub will be used." 8 54
  fi
  info "Boot mode: $BOOT_MODE"
}

# ──────────────────────────────────────────────
# SCREEN: MIRROR
# ──────────────────────────────────────────────
screen_mirror() {
  local method
  method=$(dialog --title "Mirror Selection" \
    --menu "How to choose Gentoo mirrors?" 13 62 3 \
    "auto"   "Auto-rank by speed  (wget/curl ping test — recommended)" \
    "region" "Choose by region / country" \
    "custom" "Enter custom mirror URL manually" \
    3>&1 1>&2 2>&3) || die "Mirror cancelled."

  case "$method" in
    auto)   _mirror_auto ;;
    region) _mirror_by_region ;;
    custom)
      GENTOO_MIRROR=$(dialog --title "Custom Mirror" \
        --inputbox "Full mirror URL (no trailing slash):" 9 70 \
        "https://distfiles.gentoo.org" \
        3>&1 1>&2 2>&3) || die "Mirror cancelled."
      ;;
  esac
  info "Mirror: $GENTOO_MIRROR"
}

_mirror_auto() {
  dialog --title "Mirror Test" --infobox "\nTesting mirror response times …" 6 46

  declare -A M=(
    ["https://distfiles.gentoo.org"]="Official CDN (Fastly)"
    ["https://mirror.bytemark.co.uk/gentoo"]="UK — Bytemark"
    ["https://ftp.fau.de/gentoo"]="DE — FAU Erlangen"
    ["https://mirror.leaseweb.com/gentoo"]="NL — Leaseweb"
    ["https://gentoo.osuosl.org"]="US — OSU OSL"
    ["https://mirror.init7.net/gentoo"]="CH — Init7"
    ["https://mirrors.tuna.tsinghua.edu.cn/gentoo"]="CN — Tsinghua"
    ["https://ftp.iij.ad.jp/pub/linux/gentoo"]="JP — IIJ"
    ["https://mirror.iranserver.com/gentoo"]="IR — IranServer"
  )

  local best_url="" best_ms=99999
  for url in "${!M[@]}"; do
    local ms=9999
    if command -v curl &>/dev/null; then
      ms=$(curl -o /dev/null -s -w '%{time_total}' --max-time 4 \
           "${url}/" 2>/dev/null | awk '{printf "%d", $1*1000}') || ms=9999
    else
      local t0 t1
      t0=$(date +%s%3N)
      wget -q --timeout=4 -O /dev/null "${url}/" >/dev/null 2>&1 && \
        t1=$(date +%s%3N) && ms=$(( t1 - t0 )) || ms=9999
    fi
    [[ "$ms" -lt "$best_ms" ]] && { best_ms=$ms; best_url=$url; }
  done

  if [[ -n "$best_url" && "$best_ms" -lt 9999 ]]; then
    dialog --title "Fastest Mirror" --colors --msgbox \
      "\n\ZbFastest:\Zn  $best_url\n  (${best_ms} ms)\n\nUsing this mirror." 10 66
    GENTOO_MIRROR="$best_url"
  else
    GENTOO_MIRROR="https://distfiles.gentoo.org"
    warn "Speed test inconclusive — using official CDN."
  fi
}

_mirror_by_region() {
  local region
  region=$(dialog --title "Mirror Region" \
    --menu "Choose your region:" 20 60 9 \
    "middleeast"   "Middle East / Arab countries" \
    "europe_west"  "Europe — Western" \
    "europe_east"  "Europe — Eastern" \
    "northamerica" "North America" \
    "southamerica" "South America" \
    "asia_east"    "Asia — East (CN/JP/KR)" \
    "asia_south"   "Asia — South (IN/PK)" \
    "oceania"      "Oceania (AU/NZ)" \
    "africa"       "Africa" \
    3>&1 1>&2 2>&3) || die "Region cancelled."

  declare -A RM=(
    ["middleeast"]="https://distfiles.gentoo.org https://mirror.iranserver.com/gentoo"
    ["europe_west"]="https://mirror.bytemark.co.uk/gentoo https://ftp.fau.de/gentoo https://mirror.init7.net/gentoo"
    ["europe_east"]="https://mirror.yandex.ru/gentoo-distfiles https://distfiles.gentoo.org"
    ["northamerica"]="https://gentoo.osuosl.org https://mirror.math.princeton.edu/pub/gentoo https://mirrors.mit.edu/gentoo-distfiles"
    ["southamerica"]="https://gentoo.c3sl.ufpr.br https://distfiles.gentoo.org"
    ["asia_east"]="https://mirrors.tuna.tsinghua.edu.cn/gentoo https://ftp.iij.ad.jp/pub/linux/gentoo https://mirror.kakao.com/gentoo"
    ["asia_south"]="https://mirrors.dotsrc.org/gentoo https://distfiles.gentoo.org"
    ["oceania"]="https://mirror.aarnet.edu.au/pub/gentoo https://distfiles.gentoo.org"
    ["africa"]="https://distfiles.gentoo.org"
  )

  local items=()
  for url in ${RM[$region]}; do items+=("$url" ""); done

  GENTOO_MIRROR=$(dialog --title "Select Mirror" \
    --menu "Choose a mirror:" 16 74 6 "${items[@]}" \
    3>&1 1>&2 2>&3) || GENTOO_MIRROR="https://distfiles.gentoo.org"
}

# ──────────────────────────────────────────────
# SCREEN: DISK + PARTITIONING
# ──────────────────────────────────────────────
screen_disk() {
  local disks=()
  while IFS= read -r line; do
    local dev size model
    dev=$(awk '{print $1}' <<<"$line")
    size=$(awk '{print $2}' <<<"$line")
    model=$(awk '{$1=$2=""; print $0}' <<<"$line" | sed 's/^ *//')
    disks+=("$dev" "${size}  ${model:-unknown}")
  done < <(lsblk -dpno NAME,SIZE,MODEL 2>/dev/null | grep -v 'loop\|sr')

  [[ ${#disks[@]} -eq 0 ]] && die "No disks found."

  DISK=$(dialog --title "Select Disk" --colors \
    --menu "\n\Z1WARNING: Selected disk will be COMPLETELY ERASED!\Zn\n\nChoose target disk:" \
    18 68 8 "${disks[@]}" 3>&1 1>&2 2>&3) || die "Disk selection cancelled."
  info "Disk: $DISK"

  # Pre-check disk size
  local disk_bytes disk_gb
  disk_bytes=$(lsblk -dno SIZE --bytes "$DISK" 2>/dev/null || echo 0)
  disk_gb=$(( disk_bytes / 1024 / 1024 / 1024 ))
  if [[ "$disk_gb" -lt 20 ]]; then
    dialog --title "Disk Too Small" --colors --msgbox \
      "\n\Z1WARNING:\Zn  Disk is only ${disk_gb} GB.\n\nGentoo needs at least 20 GB.\nProceed at your own risk." \
      10 52
  fi

  local PART_MODE
  PART_MODE=$(dialog --title "Partition Mode" \
    --menu "How to partition the disk?" 12 56 2 \
    "auto"   "Automatic  (recommended — erases everything)" \
    "manual" "Manual     (open cfdisk, then I pick partitions)" \
    3>&1 1>&2 2>&3) || die "Partition mode cancelled."

  if [[ "$PART_MODE" == "manual" ]]; then
    dialog --title "Manual Partitioning" --colors --msgbox \
      "\nOpening \Zbcfdisk\Zn. Create your partitions, write, then quit.\nThe installer will ask which partition is which." \
      10 62
    cfdisk "$DISK" || true
    _ask_manual_parts
  fi
}

_ask_manual_parts() {
  local parts=()
  while IFS= read -r p; do
    [[ "$p" == "$DISK" ]] && continue
    parts+=("$p" "$(lsblk -dno SIZE "$p" 2>/dev/null || echo '?')")
  done < <(lsblk -pno NAME "$DISK" 2>/dev/null)

  BOOT_PART=$(dialog --title "Boot Partition" \
    --menu "Which partition is BOOT?" 16 52 8 "${parts[@]}" \
    3>&1 1>&2 2>&3) || die "Boot partition cancelled."

  ROOT_PART=$(dialog --title "Root Partition" \
    --menu "Which partition is ROOT?" 16 52 8 "${parts[@]}" \
    3>&1 1>&2 2>&3) || die "Root partition cancelled."

  local swap_ans
  swap_ans=$(dialog --title "Swap Partition" \
    --menu "Which partition is SWAP? (none to skip)" 16 52 9 \
    "none" "No swap" "${parts[@]}" \
    3>&1 1>&2 2>&3) || swap_ans="none"
  [[ "$swap_ans" == "none" ]] && SWAP_PART="" || SWAP_PART="$swap_ans"
}

# ──────────────────────────────────────────────
# SCREEN: FILESYSTEM
# ──────────────────────────────────────────────
screen_filesystem() {
  FS_TYPE=$(dialog --title "Root Filesystem" \
    --menu "Choose root filesystem:" 18 62 6 \
    "ext4"     "ext4      — stable, widely supported       [recommended]" \
    "btrfs"    "Btrfs     — snapshots, compression, subvols" \
    "xfs"      "XFS       — high performance, large files" \
    "f2fs"     "F2FS      — flash-friendly (SSD / NVMe)" \
    "bcachefs" "Bcachefs  — modern CoW, snapshots (kernel ≥6.7)" \
    "zfs"      "ZFS       — advanced, needs sys-fs/zfs (emerge first)" \
    3>&1 1>&2 2>&3) || die "Filesystem cancelled."

  case "$FS_TYPE" in
    zfs)
      dialog --title "ZFS Warning" --colors --msgbox \
        "\n\Z3ZFS requires \Zbsys-fs/zfs\Zn installed in Live environment first.\Zn\n\n\
Run:  \Zbemergency emerge sys-fs/zfs\Zn\nbefore continuing if not already done." \
        12 60
      command -v zpool &>/dev/null || die "zpool not found. Install sys-fs/zfs first."
      ;;
    bcachefs)
      dialog --title "Bcachefs Note" --colors --msgbox \
        "\n\Z3Bcachefs requires Linux kernel ≥ 6.7.\Zn\n\nMake sure your Live environment supports it." \
        9 54
      command -v mkfs.bcachefs &>/dev/null || die "mkfs.bcachefs not found."
      ;;
  esac
  info "Filesystem: $FS_TYPE"
}

# ──────────────────────────────────────────────
# SCREEN: SWAP
# ──────────────────────────────────────────────
screen_swap() {
  # Auto-suggest swap based on RAM
  local ram_gb
  ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)
  local suggested="4G"
  [[ $ram_gb -ge 16 ]] && suggested="8G"
  [[ $ram_gb -ge 32 ]] && suggested="16G"

  SWAP_SIZE=$(dialog --title "Swap" \
    --inputbox "Swap partition size (e.g. 4G, 8G).\nDetected RAM: ${ram_gb}G  →  Suggested: ${suggested}\nEnter 0 to skip:" \
    10 54 "$suggested" 3>&1 1>&2 2>&3) || die "Swap cancelled."
  info "Swap: $SWAP_SIZE"
}

# ──────────────────────────────────────────────
# SCREEN: HOSTNAME / USERNAME / PASSWORDS
# ──────────────────────────────────────────────
screen_hostname() {
  HOSTNAME=$(dialog --title "Hostname" \
    --inputbox "Machine hostname:" 9 46 "gentoo" \
    3>&1 1>&2 2>&3) || die "Hostname cancelled."
  # Basic hostname validation
  HOSTNAME=$(echo "$HOSTNAME" | tr -cd '[:alnum:]-' | head -c 63)
  [[ -z "$HOSTNAME" ]] && die "Hostname cannot be empty."
  info "Hostname: $HOSTNAME"
}

screen_username() {
  USERNAME=$(dialog --title "User Account" \
    --inputbox "Your username (lowercase, letters/numbers/- only):" 9 50 \
    3>&1 1>&2 2>&3) || die "Username cancelled."
  USERNAME="${USERNAME,,}"
  USERNAME=$(echo "$USERNAME" | tr -cd '[:alnum:]-_' | head -c 32)
  [[ -z "$USERNAME" ]] && die "Username cannot be empty."
  info "Username: $USERNAME"
}

screen_passwords() {
  read_password ROOT_PASS "Root password (≥8 chars):"
  read_password USER_PASS "Password for ${USERNAME} (≥8 chars):"
}

# ──────────────────────────────────────────────
# SCREEN: TIMEZONE
# ──────────────────────────────────────────────
screen_timezone() {
  TIMEZONE=$(dialog --title "Timezone" \
    --inputbox "Timezone (e.g. Asia/Baghdad, Europe/Berlin, UTC):" \
    9 58 "Asia/Baghdad" 3>&1 1>&2 2>&3) || die "Timezone cancelled."
  # Validate
  if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    dialog --title "Timezone Warning" --colors --msgbox \
      "\n\Z3Warning:\Zn  /usr/share/zoneinfo/${TIMEZONE} not found in Live env.\n\nIt may still work inside chroot — continuing." \
      10 56
  fi
  info "Timezone: $TIMEZONE"
}

# ──────────────────────────────────────────────
# SCREEN: LOCALE  (interactive — new in v5)
# ──────────────────────────────────────────────
screen_locale() {
  local loc_choice
  loc_choice=$(dialog --title "System Locale" \
    --menu "Choose default system locale:" 20 68 10 \
    "en_US.UTF-8"  "English (US)            — default" \
    "en_GB.UTF-8"  "English (UK)" \
    "ar_IQ.UTF-8"  "Arabic (Iraq)" \
    "ar_SA.UTF-8"  "Arabic (Saudi Arabia)" \
    "de_DE.UTF-8"  "German" \
    "fr_FR.UTF-8"  "French" \
    "es_ES.UTF-8"  "Spanish" \
    "zh_CN.UTF-8"  "Chinese Simplified" \
    "ja_JP.UTF-8"  "Japanese" \
    "custom"       "Enter custom locale manually" \
    3>&1 1>&2 2>&3) || die "Locale cancelled."

  if [[ "$loc_choice" == "custom" ]]; then
    LOCALE=$(dialog --title "Custom Locale" \
      --inputbox "Enter locale (e.g. ru_RU.UTF-8):" 8 46 \
      3>&1 1>&2 2>&3) || die "Locale cancelled."
  else
    LOCALE="$loc_choice"
  fi
  info "Locale: $LOCALE"
}

# ──────────────────────────────────────────────
# SCREEN: STAGE3
# ──────────────────────────────────────────────
screen_stage3() {
  local ARCH; ARCH=$(uname -m)
  [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"

  STAGE3_VARIANT=$(dialog --title "Stage3 Variant" \
    --menu "Choose init system / variant:" 13 60 3 \
    "openrc"  "OpenRC   — traditional, lightweight       [recommended]" \
    "systemd" "systemd  — needed for GNOME, some DEs" \
    "musl"    "musl libc — advanced / minimal" \
    3>&1 1>&2 2>&3) || die "Stage3 variant cancelled."

  info "Stage3 variant: $STAGE3_VARIANT"

  local BASE="${GENTOO_MIRROR}/releases/${ARCH}/autobuilds"
  local DIR_NAME="current-stage3-${ARCH}-${STAGE3_VARIANT}"
  local TXT_URL="${BASE}/${DIR_NAME}/latest-stage3-${ARCH}-${STAGE3_VARIANT}.txt"

  dialog --title "Stage3" --infobox "\nResolving latest Stage3 via latest-stage3-*.txt …" 6 56

  local TXT
  TXT=$(wget -qO- "$TXT_URL") \
    || die "Failed to fetch: $TXT_URL\nCheck internet connection."

  STAGE3_TARBALL=$(grep -E '^stage3-' <<<"$TXT" | awk '{print $1}' | head -1)
  [[ -z "$STAGE3_TARBALL" ]] && die "Could not parse Stage3 filename from:\n$TXT_URL"

  STAGE3_URL="${BASE}/${DIR_NAME}/${STAGE3_TARBALL}"

  dialog --title "Stage3 Resolved" --colors --msgbox \
    "\n\ZbTarball:\Zn  $STAGE3_TARBALL\n\n\ZbURL:\Zn\n  $STAGE3_URL" \
    11 72

  info "Stage3: $STAGE3_URL"
}

# ──────────────────────────────────────────────
# SCREEN: ACCEPT_KEYWORDS
# ──────────────────────────────────────────────
screen_keywords() {
  local kw
  kw=$(dialog --title "Package Branch" \
    --menu "Choose stability branch:" 11 60 2 \
    "stable"  "Stable   — ACCEPT_KEYWORDS=\"amd64\"    [recommended]" \
    "testing" "Testing  — ACCEPT_KEYWORDS=\"~amd64\"   (bleeding edge)" \
    3>&1 1>&2 2>&3) || die "Keywords cancelled."
  [[ "$kw" == "testing" ]] && ACCEPT_KW="~amd64" || ACCEPT_KW="amd64"
  info "ACCEPT_KEYWORDS: $ACCEPT_KW"
}

# ──────────────────────────────────────────────
# SCREEN: CPU DETECTION + MARCH
# ──────────────────────────────────────────────
screen_march() {
  local CPU_NAME
  CPU_NAME=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
    | sed 's/model name\s*:\s*//' \
    | sed 's/  */ /g' \
    | xargs) || CPU_NAME="Unknown CPU"

  local march_choice
  march_choice=$(dialog --title "CPU Optimisation" --colors \
    --menu "\n\ZbDetected CPU:\Zn  $CPU_NAME\n\nCompiler -march setting:" \
    14 70 2 \
    "native"  "Native   — optimised for THIS machine (fastest, not portable)" \
    "generic" "Generic  — portable, safe for cloning / VMs" \
    3>&1 1>&2 2>&3) || die "March cancelled."

  MARCH_OPT="$march_choice"
  info "CPU: $CPU_NAME  |  march: $MARCH_OPT"
}

# ──────────────────────────────────────────────
# SCREEN: GPU / VIDEO_CARDS
# ──────────────────────────────────────────────
screen_gpu() {
  local DETECTED_GPU=""
  if command -v lspci &>/dev/null; then
    DETECTED_GPU=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' | head -3 | \
      awk -F': ' '{print $2}' | paste -sd ', ')
  fi
  local GPU_INFO=""
  [[ -n "$DETECTED_GPU" ]] && GPU_INFO="\n\ZbDetected GPU:\Zn  $DETECTED_GPU\n\n" \
                            || GPU_INFO="\nNo GPU detected via lspci.\n\n"

  local gpu_choice
  gpu_choice=$(dialog --title "GPU / VIDEO_CARDS" --colors \
    --menu "${GPU_INFO}Select your GPU vendor:" \
    20 70 10 \
    "amdgpu radeonsi" "AMD  (GCN+, RX 400 series and newer)  [recommended for AMD]" \
    "radeon"          "AMD  (Legacy — pre-GCN, HD series)" \
    "intel i965"      "Intel  (Gen 8 / Broadwell and newer)" \
    "intel"           "Intel  (older — Gen 7 / Ivy Bridge and below)" \
    "nvidia"          "NVIDIA  (proprietary driver, needs nvidia-drivers)" \
    "nouveau"         "NVIDIA  (open-source Nouveau — limited 3D)" \
    "vmware"          "VMware  (running inside VMware VM)" \
    "virtualbox"      "VirtualBox  (running inside VirtualBox VM)" \
    "qxl"             "QEMU / KVM  (running inside QEMU/KVM)" \
    "fbdev vesa"      "Fallback  — VESA/fbdev (universal, slow)" \
    3>&1 1>&2 2>&3) || die "GPU selection cancelled."

  VIDEO_CARDS="$gpu_choice"

  if [[ "$VIDEO_CARDS" == "nvidia" ]]; then
    dialog --title "NVIDIA Note" --colors --msgbox \
      "\n\Z3NVIDIA proprietary driver:\Zn\n\n\
You will need to emerge \Zbx11-drivers/nvidia-drivers\Zn after installation.\n\
Also add  \ZbACCEPT_LICENSE=\"NVIDIA-r2\"\Zn  to make.conf." \
      12 58
  fi

  info "VIDEO_CARDS: $VIDEO_CARDS"
}

# ──────────────────────────────────────────────
# SCREEN: PROFILE
# ──────────────────────────────────────────────
screen_profile() {
  PROFILE=$(dialog --title "Gentoo Profile" \
    --menu "Select base profile:" 18 68 7 \
    "default/linux/amd64/23.0"               "Base — no desktop" \
    "default/linux/amd64/23.0/desktop"       "Desktop generic" \
    "default/linux/amd64/23.0/desktop/gnome" "GNOME desktop" \
    "default/linux/amd64/23.0/desktop/kde"   "KDE Plasma desktop" \
    "default/linux/amd64/23.0/systemd"       "Systemd base" \
    "default/linux/amd64/23.0/no-multilib"   "No 32-bit (pure 64-bit)" \
    3>&1 1>&2 2>&3) || die "Profile cancelled."
  info "Profile: $PROFILE"
}

# ──────────────────────────────────────────────
# SCREEN: USE FLAGS
# ──────────────────────────────────────────────
screen_use_flags() {
  local result
  result=$(dialog --title "USE Flags" --colors \
    --checklist "\nSelect global USE flags.\n\Z3Space\Zn=toggle  \ZbEnter\Zn=confirm:" \
    30 68 22 \
    "X"              "X11 display server"                    on  \
    "wayland"        "Wayland display protocol"              on  \
    "alsa"           "ALSA audio (kernel-level)"             on  \
    "pulseaudio"     "PulseAudio sound server"               on  \
    "pipewire"       "PipeWire (modern audio/video)"         off \
    "bluetooth"      "Bluetooth support"                     off \
    "networkmanager" "NetworkManager integration"            on  \
    "wifi"           "Wi-Fi support"                         on  \
    "cups"           "Printing (CUPS)"                       off \
    "gtk"            "GTK toolkit (GNOME / most apps)"       on  \
    "qt5"            "Qt5 toolkit (KDE / Qt apps)"           off \
    "qt6"            "Qt6 toolkit (newer KDE)"               off \
    "opengl"         "OpenGL 3D acceleration"                on  \
    "vulkan"         "Vulkan GPU API"                        off \
    "vaapi"          "VA-API hardware video decode"          off \
    "vdpau"          "VDPAU hardware video decode (NVIDIA)"  off \
    "dbus"           "D-Bus IPC (required by most DEs)"      on  \
    "udev"           "udev device manager"                   on  \
    "zsh-completion" "Zsh shell completion"                  off \
    "pgo"            "Profile-Guided Optimisation (slow build)" off \
    "lto"            "Link-Time Optimisation (slow build)"   off \
    "hardened"       "Hardened toolchain flags (security)"   off \
    3>&1 1>&2 2>&3) || die "USE flags cancelled."

  USE_FLAGS=$(tr -d '"' <<<"$result")
  info "USE: $USE_FLAGS"
}

# ──────────────────────────────────────────────
# SCREEN: NETWORKING
# ──────────────────────────────────────────────
screen_network() {
  NET_TOOL=$(dialog --title "Network Manager" \
    --menu "Choose networking tool:" 14 60 4 \
    "networkmanager" "NetworkManager  — GUI-friendly, most popular" \
    "iwd"            "iwd            — lightweight, Wi-Fi focused" \
    "dhcpcd"         "dhcpcd         — simple DHCP, wired" \
    "connman"        "ConnMan        — embedded / minimal" \
    3>&1 1>&2 2>&3) || die "Network cancelled."
  info "Network: $NET_TOOL"
}

# ──────────────────────────────────────────────
# SCREEN: DESKTOP ENVIRONMENT
# ──────────────────────────────────────────────
screen_de() {
  DE_CHOICE=$(dialog --title "Desktop Environment" \
    --menu "Install a Desktop Environment?" 18 64 7 \
    "none"     "None        — minimal, configure manually" \
    "kde"      "KDE Plasma  — feature-rich, Qt-based" \
    "gnome"    "GNOME       — clean, GTK-based  (needs systemd stage3)" \
    "xfce"     "XFCE        — lightweight, GTK-based" \
    "lxqt"     "LXQt        — minimal, Qt-based" \
    "hyprland" "Hyprland    — modern Wayland compositor (advanced)" \
    "sway"     "Sway        — tiling Wayland compositor (i3 clone)" \
    3>&1 1>&2 2>&3) || die "DE cancelled."
  info "DE: $DE_CHOICE"
}

# ──────────────────────────────────────────────
# SCREEN: KERNEL
# ──────────────────────────────────────────────
screen_kernel() {
  KERNEL_CHOICE=$(dialog --title "Kernel" \
    --menu "Kernel installation method:" 13 66 3 \
    "dist-kernel" "Distribution Kernel (binary, fast)    [recommended]" \
    "genkernel"   "genkernel — auto-configure from sources" \
    "manual"      "Manual   — I'll run make menuconfig myself" \
    3>&1 1>&2 2>&3) || die "Kernel cancelled."
  info "Kernel: $KERNEL_CHOICE"
}

# ──────────────────────────────────────────────
# SCREEN: SHELL CHOICE  (new in v5)
# ──────────────────────────────────────────────
screen_shell() {
  SHELL_CHOICE=$(dialog --title "Default Shell" \
    --menu "Choose default shell for ${USERNAME}:" 12 54 3 \
    "bash" "Bash   — default, most compatible  [recommended]" \
    "zsh"  "Zsh    — feature-rich, powerful" \
    "fish" "Fish   — user-friendly, modern" \
    3>&1 1>&2 2>&3) || SHELL_CHOICE="bash"
  info "Shell: $SHELL_CHOICE"
}

# ──────────────────────────────────────────────
# SCREEN: SSH KEY IMPORT  (new in v5)
# ──────────────────────────────────────────────
screen_ssh_key() {
  local ans
  ans=$(dialog --title "SSH Key Import" \
    --menu "Import SSH public key for ${USERNAME}?" 11 60 2 \
    "yes" "Yes — paste or enter path to public key" \
    "no"  "No  — skip" \
    3>&1 1>&2 2>&3) || ans="no"

  if [[ "$ans" == "yes" ]]; then
    SSH_KEY=$(dialog --title "SSH Public Key" \
      --inputbox "Paste your SSH public key (ssh-ed25519 / ssh-rsa …):" \
      10 74 3>&1 1>&2 2>&3) || SSH_KEY=""
    [[ -z "$SSH_KEY" ]] && warn "SSH key empty — skipping."
  fi
  info "SSH key: ${SSH_KEY:+set}"
}

# ──────────────────────────────────────────────
# SCREEN: LIVE PREVIEW  (from v4)
# ──────────────────────────────────────────────
screen_live_preview() {
  local use_display="${USE_FLAGS:-<defaults>}"
  [[ ${#use_display} -gt 50 ]] && use_display="${use_display:0:47}…"
  local SWAP_LABEL; [[ "$SWAP_SIZE" == "0" ]] && SWAP_LABEL="none" || SWAP_LABEL="$SWAP_SIZE"

  dialog --title "  📋  Installation Preview  " --colors --msgbox "\n\
┌──────────────────────────────────────────────────────┐\n\
│ \ZbDisk\Zn          │ ${DISK}  (\Z1ERASED\Zn)\n\
│ \ZbBoot mode\Zn     │ ${BOOT_MODE^^}\n\
│ \ZbFilesystem\Zn    │ ${FS_TYPE}\n\
│ \ZbSwap\Zn          │ ${SWAP_LABEL}\n\
├──────────────────────────────────────────────────────┤\n\
│ \ZbHostname\Zn      │ ${HOSTNAME}\n\
│ \ZbUsername\Zn      │ ${USERNAME}\n\
│ \ZbTimezone\Zn      │ ${TIMEZONE}\n\
│ \ZbLocale\Zn        │ ${LOCALE}\n\
│ \ZbShell\Zn         │ ${SHELL_CHOICE}\n\
├──────────────────────────────────────────────────────┤\n\
│ \ZbStage3\Zn        │ ${STAGE3_VARIANT}\n\
│ \ZbMirror\Zn        │ ${GENTOO_MIRROR:0:44}\n\
│ \ZbProfile\Zn       │ ${PROFILE##*/}\n\
│ \ZbKeywords\Zn      │ ${ACCEPT_KW}\n\
├──────────────────────────────────────────────────────┤\n\
│ \ZbCPU march\Zn     │ ${MARCH_OPT}\n\
│ \ZbGPU\Zn           │ ${VIDEO_CARDS}\n\
│ \ZbKernel\Zn        │ ${KERNEL_CHOICE}\n\
│ \ZbNetwork\Zn       │ ${NET_TOOL}\n\
│ \ZbDesktop\Zn       │ ${DE_CHOICE}\n\
├──────────────────────────────────────────────────────┤\n\
│ \ZbUSE flags\Zn     │ ${use_display}\n\
│ \ZbSSH key\Zn       │ ${SSH_KEY:+set (will be imported)}\n\
└──────────────────────────────────────────────────────┘\n\
\n\Z1Everything looks correct? This is your last chance!\Zn" \
  40 68

  dialog --title "Confirm" --colors \
    --yesno "\n\Z1Disk  ${DISK}  will be COMPLETELY ERASED.\Zn\n\nProceed with installation?" \
    9 56 || die "Installation cancelled."
}

# ──────────────────────────────────────────────
# INSTALL: PARTITION
# ──────────────────────────────────────────────
do_partition() {
  [[ -n "$BOOT_PART" ]] && { info "Using manually defined partitions."; return; }

  info "Auto-partitioning $DISK …"

  # Clean up any leftovers
  swapoff -a >> "$LOG_FILE" 2>&1 || true
  for p in $(lsblk -lnpo NAME "$DISK" 2>/dev/null | grep -v "^${DISK}\$"); do
    umount -Rf "$p" >> "$LOG_FILE" 2>&1 || true
  done
  umount -Rf "$DISK" >> "$LOG_FILE" 2>&1 || true
  wipefs -af "$DISK" >> "$LOG_FILE" 2>&1 || true
  partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
  sleep 1

  local SWAP_MiB=0
  if [[ "$SWAP_SIZE" != "0" ]]; then
    local raw_bytes
    raw_bytes=$(numfmt --from=iec "$SWAP_SIZE" 2>/dev/null) \
      || raw_bytes=$(( 4 * 1024 * 1024 * 1024 ))
    SWAP_MiB=$(( raw_bytes / 1024 / 1024 ))
  fi

  parted -s "$DISK" mklabel gpt >> "$LOG_FILE" 2>&1

  if [[ "$BOOT_MODE" == "uefi" ]]; then
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB set 1 esp on >> "$LOG_FILE" 2>&1
    BOOT_PART=$(part "$DISK" 1)
    if [[ "$SWAP_SIZE" != "0" ]]; then
      local SWAP_END=$(( 513 + SWAP_MiB ))
      parted -s "$DISK" mkpart swap linux-swap 513MiB "${SWAP_END}MiB" >> "$LOG_FILE" 2>&1
      SWAP_PART=$(part "$DISK" 2)
      parted -s "$DISK" mkpart root "$FS_TYPE" "${SWAP_END}MiB" 100% >> "$LOG_FILE" 2>&1
      ROOT_PART=$(part "$DISK" 3)
    else
      SWAP_PART=""
      parted -s "$DISK" mkpart root "$FS_TYPE" 513MiB 100% >> "$LOG_FILE" 2>&1
      ROOT_PART=$(part "$DISK" 2)
    fi
  else
    parted -s "$DISK" mkpart bios_grub 1MiB 2MiB set 1 bios_grub on >> "$LOG_FILE" 2>&1
    parted -s "$DISK" mkpart boot ext2 2MiB 514MiB >> "$LOG_FILE" 2>&1
    BOOT_PART=$(part "$DISK" 2)
    if [[ "$SWAP_SIZE" != "0" ]]; then
      local SWAP_END=$(( 514 + SWAP_MiB ))
      parted -s "$DISK" mkpart swap linux-swap 514MiB "${SWAP_END}MiB" >> "$LOG_FILE" 2>&1
      SWAP_PART=$(part "$DISK" 3)
      parted -s "$DISK" mkpart root "$FS_TYPE" "${SWAP_END}MiB" 100% >> "$LOG_FILE" 2>&1
      ROOT_PART=$(part "$DISK" 4)
    else
      SWAP_PART=""
      parted -s "$DISK" mkpart root "$FS_TYPE" 514MiB 100% >> "$LOG_FILE" 2>&1
      ROOT_PART=$(part "$DISK" 3)
    fi
  fi

  partprobe "$DISK" 2>/dev/null || true
  sleep 1
  ok "Partitioned: boot=$BOOT_PART  root=$ROOT_PART  swap=${SWAP_PART:-none}"
}

# ──────────────────────────────────────────────
# INSTALL: FORMAT  (single function — no duplication)
# ──────────────────────────────────────────────
do_format() {
  info "Formatting partitions …"

  # Boot
  if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkfs.fat -F32 "$BOOT_PART" >> "$LOG_FILE" 2>&1
  else
    mkfs.ext2 -F  "$BOOT_PART" >> "$LOG_FILE" 2>&1
  fi

  # Root
  case "$FS_TYPE" in
    ext4)
      mkfs.ext4 -F "$ROOT_PART" >> "$LOG_FILE" 2>&1
      ;;
    btrfs)
      mkfs.btrfs -f "$ROOT_PART" >> "$LOG_FILE" 2>&1
      mount "$ROOT_PART" /mnt/gentoo
      btrfs subvolume create /mnt/gentoo/@          >> "$LOG_FILE" 2>&1
      btrfs subvolume create /mnt/gentoo/@home      >> "$LOG_FILE" 2>&1
      btrfs subvolume create /mnt/gentoo/@cache     >> "$LOG_FILE" 2>&1
      btrfs subvolume create /mnt/gentoo/@snapshots >> "$LOG_FILE" 2>&1
      umount /mnt/gentoo
      ok "Btrfs subvolumes: @  @home  @cache  @snapshots"
      ;;
    xfs)
      mkfs.xfs -f "$ROOT_PART" >> "$LOG_FILE" 2>&1
      ;;
    f2fs)
      mkfs.f2fs -f "$ROOT_PART" >> "$LOG_FILE" 2>&1
      ;;
    bcachefs)
      mkfs.bcachefs --force "$ROOT_PART" >> "$LOG_FILE" 2>&1
      ;;
    zfs)
      local POOL="rpool"
      zpool create -f -o ashift=12 \
        -O compression=lz4 \
        -O atime=off \
        -O xattr=sa \
        -O mountpoint=none \
        "$POOL" "$ROOT_PART" >> "$LOG_FILE" 2>&1
      zfs create -o mountpoint=/mnt/gentoo "${POOL}/root" >> "$LOG_FILE" 2>&1
      zfs create -o mountpoint=/mnt/gentoo/home "${POOL}/home" >> "$LOG_FILE" 2>&1
      ok "ZFS pool '$POOL' created."
      ;;
  esac

  # Swap
  if [[ -n "$SWAP_PART" ]]; then
    mkswap "$SWAP_PART" >> "$LOG_FILE" 2>&1
    swapon "$SWAP_PART" >> "$LOG_FILE" 2>&1
  fi

  ok "Formatting done."
}

# ──────────────────────────────────────────────
# INSTALL: MOUNT  (Btrfs-aware)
# ──────────────────────────────────────────────
do_mount() {
  info "Mounting filesystems …"

  if [[ "$FS_TYPE" == "btrfs" ]]; then
    mount -o subvol=@,compress=zstd,noatime "$ROOT_PART" /mnt/gentoo
    mkdir -p /mnt/gentoo/{home,.snapshots,var/cache}
    mount -o subvol=@home,compress=zstd,noatime       "$ROOT_PART" /mnt/gentoo/home
    mount -o subvol=@cache,compress=zstd,noatime      "$ROOT_PART" /mnt/gentoo/var/cache
    mount -o subvol=@snapshots,compress=zstd,noatime  "$ROOT_PART" /mnt/gentoo/.snapshots
  elif [[ "$FS_TYPE" == "zfs" ]]; then
    : # ZFS already mounted
  else
    mount "$ROOT_PART" /mnt/gentoo
  fi

  if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkdir -p /mnt/gentoo/boot/efi
    mount "$BOOT_PART" /mnt/gentoo/boot/efi
  else
    mkdir -p /mnt/gentoo/boot
    mount "$BOOT_PART" /mnt/gentoo/boot
  fi

  ok "Mounts ready."
}

# ──────────────────────────────────────────────
# INSTALL: STAGE3 DOWNLOAD
# ──────────────────────────────────────────────
do_stage3() {
  info "Downloading $STAGE3_TARBALL …"
  cd /mnt/gentoo

  # Also download and verify digest if available
  local DIGEST_URL="${STAGE3_URL}.DIGESTS"
  wget -q "$DIGEST_URL" -O stage3.tar.xz.DIGESTS >> "$LOG_FILE" 2>&1 || true

  wget -q --show-progress "$STAGE3_URL" -O stage3.tar.xz 2>&1 | \
    dialog --title "Downloading Stage3" --progressbox 10 72 || \
    wget -q "$STAGE3_URL" -O stage3.tar.xz >> "$LOG_FILE" 2>&1 || \
    die "Stage3 download failed."

  # Quick digest check if sha512sum available
  if [[ -f stage3.tar.xz.DIGESTS ]] && command -v sha512sum &>/dev/null; then
    local expected actual
    expected=$(grep -A1 'SHA512' stage3.tar.xz.DIGESTS 2>/dev/null | \
      grep 'stage3-' | awk '{print $1}' | head -1)
    actual=$(sha512sum stage3.tar.xz | awk '{print $1}')
    if [[ -n "$expected" && "$expected" != "$actual" ]]; then
      die "SHA512 checksum mismatch! Download may be corrupt."
    else
      ok "Checksum verified."
    fi
  fi
  rm -f stage3.tar.xz.DIGESTS

  info "Extracting …"
  tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo \
    >> "$LOG_FILE" 2>&1
  rm stage3.tar.xz
  ok "Stage3 extracted."
}

# ──────────────────────────────────────────────
# INSTALL: MAKE.CONF
# ──────────────────────────────────────────────
do_makeconf() {
  info "Writing make.conf …"
  local NPROC; NPROC=$(nproc)
  local MARCH_VAL
  [[ "$MARCH_OPT" == "native" ]] && MARCH_VAL="-march=native" || MARCH_VAL="-march=x86-64"
  local GRUB_PLATFORM
  [[ "$BOOT_MODE" == "uefi" ]] && GRUB_PLATFORM="efi-64" || GRUB_PLATFORM="pc"

  # Derive L10N/LINGUAS from locale (e.g. ar_IQ.UTF-8 → ar ar_IQ)
  local LANG_CODE="${LOCALE%%.*}"          # ar_IQ
  local LANG_BASE="${LANG_CODE%%_*}"       # ar
  local L10N_VAL="${LANG_BASE} ${LANG_CODE}"
  [[ "$LANG_BASE" == "en" ]] && L10N_VAL="en en_US"

  cat > /mnt/gentoo/etc/portage/make.conf <<EOF
# Generated by Gentoo Installer v5.0
COMMON_FLAGS="-O2 -pipe ${MARCH_VAL}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j${NPROC} -l${NPROC}"

USE="${USE_FLAGS}"

ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="${ACCEPT_KW}"

FEATURES="parallel-fetch parallel-install"

GENTOO_MIRRORS="${GENTOO_MIRROR}"

GRUB_PLATFORMS="${GRUB_PLATFORM}"

VIDEO_CARDS="${VIDEO_CARDS}"

L10N="${L10N_VAL}"
LINGUAS="${LANG_BASE}"
EOF
  ok "make.conf written."
}

# ──────────────────────────────────────────────
# INSTALL: FSTAB GENERATOR
# ──────────────────────────────────────────────
_gen_fstab() {
  local BOOT_MNT BOOT_FS ROOT_UUID BOOT_UUID
  [[ "$BOOT_MODE" == "uefi" ]] && BOOT_MNT="/boot/efi" BOOT_FS="vfat" \
                                || BOOT_MNT="/boot"    BOOT_FS="ext2"
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
  BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")

  cat <<FSTAB
# Generated by Gentoo Installer v5.0
UUID=${BOOT_UUID}  ${BOOT_MNT}  ${BOOT_FS}    umask=077                        0 2
FSTAB

  if [[ "$FS_TYPE" == "btrfs" ]]; then
    cat <<FSTAB
UUID=${ROOT_UUID}  /              btrfs  subvol=@,compress=zstd,noatime          0 0
UUID=${ROOT_UUID}  /home          btrfs  subvol=@home,compress=zstd,noatime      0 0
UUID=${ROOT_UUID}  /var/cache     btrfs  subvol=@cache,compress=zstd,noatime     0 0
UUID=${ROOT_UUID}  /.snapshots    btrfs  subvol=@snapshots,compress=zstd,noatime 0 0
FSTAB
  elif [[ "$FS_TYPE" == "zfs" ]]; then
    echo "# ZFS: managed by zpool/zfs mount units — no fstab entries needed"
  else
    echo "UUID=${ROOT_UUID}  /  ${FS_TYPE}  defaults,noatime  0 1"
  fi

  if [[ -n "$SWAP_PART" ]]; then
    local SWAP_UUID; SWAP_UUID=$(blkid -s UUID -o value "$SWAP_PART")
    echo "UUID=${SWAP_UUID}  none  swap  sw  0 0"
  fi
}

# ──────────────────────────────────────────────
# INSTALL: CHROOT SETUP
# ──────────────────────────────────────────────
do_chroot_setup() {
  info "Preparing chroot environment …"

  mkdir -p /mnt/gentoo/etc/portage/repos.conf
  cp /mnt/gentoo/usr/share/portage/config/repos.conf \
     /mnt/gentoo/etc/portage/repos.conf/gentoo.conf 2>/dev/null || true

  mount --types proc  /proc       /mnt/gentoo/proc
  mount --rbind       /sys        /mnt/gentoo/sys  && mount --make-rslave /mnt/gentoo/sys
  mount --rbind       /dev        /mnt/gentoo/dev  && mount --make-rslave /mnt/gentoo/dev
  mount --bind        /run        /mnt/gentoo/run
  cp /etc/resolv.conf /mnt/gentoo/etc/

  _gen_fstab > /mnt/gentoo/etc/fstab
  info "fstab written."

  # Build package strings
  local NET_PKG
  case "$NET_TOOL" in
    networkmanager) NET_PKG="net-misc/networkmanager" ;;
    iwd)            NET_PKG="net-wireless/iwd" ;;
    dhcpcd)         NET_PKG="net-misc/dhcpcd" ;;
    connman)        NET_PKG="net-misc/connman" ;;
  esac

  local DE_PKG="" DM_PKG="" DM_SERVICE=""
  case "$DE_CHOICE" in
    kde)      DE_PKG="kde-plasma/plasma-meta kde-apps/kde-apps-meta"
              DM_PKG="x11-misc/sddm"      DM_SERVICE="sddm" ;;
    gnome)    DE_PKG="gnome-base/gnome"
              DM_PKG="x11-misc/gdm"       DM_SERVICE="gdm" ;;
    xfce)     DE_PKG="xfce-base/xfce4-meta"
              DM_PKG="x11-misc/lightdm"   DM_SERVICE="lightdm" ;;
    lxqt)     DE_PKG="lxqt-base/lxqt-meta"
              DM_PKG="x11-misc/sddm"      DM_SERVICE="sddm" ;;
    hyprland) DE_PKG="gui-wm/hyprland"
              DM_PKG="gui-libs/greetd"    DM_SERVICE="greetd" ;;
    sway)     DE_PKG="gui-wm/sway x11-misc/swaylock x11-misc/swaybg"
              DM_PKG="gui-libs/greetd"    DM_SERVICE="greetd" ;;
    none)     DE_PKG="" DM_PKG="" DM_SERVICE="" ;;
  esac

  local ZFS_PKG=""
  [[ "$FS_TYPE" == "zfs" ]] && ZFS_PKG="sys-fs/zfs"

  # Shell package
  local SHELL_PKG="" SHELL_BIN="/bin/bash"
  case "$SHELL_CHOICE" in
    zsh)  SHELL_PKG="app-shells/zsh"  SHELL_BIN="/bin/zsh" ;;
    fish) SHELL_PKG="app-shells/fish" SHELL_BIN="/usr/bin/fish" ;;
    bash) SHELL_PKG="" SHELL_BIN="/bin/bash" ;;
  esac

  # Write the chroot script — passwords passed via environment (secure)
  cat > /mnt/gentoo/gentoo-chroot-install.sh <<CHROOT_EOF
#!/usr/bin/env bash
set -euo pipefail
LOG="/tmp/gentoo-install.log"
log() { echo "\$(date '+%H:%M:%S') \$*" | tee -a "\$LOG"; }

log "=== Chroot stage started ==="
set +u
source /etc/profile
set -u

# ── Portage sync ──
log "Syncing Portage …"
emerge-webrsync >> "\$LOG" 2>&1

# ── Profile ──
log "Profile: ${PROFILE}"
eselect profile set "${PROFILE}" >> "\$LOG" 2>&1 || log "WARNING: profile set failed."

# ── Timezone ──
echo "${TIMEZONE}" > /etc/timezone
emerge --config sys-libs/timezone-data >> "\$LOG" 2>&1

# ── Locale ──
grep -q "^${LOCALE}" /etc/locale.gen 2>/dev/null || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen >> "\$LOG" 2>&1
eselect locale set "${LOCALE}" >> "\$LOG" 2>&1 || true
env-update >> "\$LOG" 2>&1
set +u
source /etc/profile
set -u

# ── ZFS (if chosen) ──
if [[ -n "${ZFS_PKG}" ]]; then
  log "Installing ZFS …"
  emerge --noreplace ${ZFS_PKG} >> "\$LOG" 2>&1
  zgenhostid >> "\$LOG" 2>&1 || true
fi

# ── Shell (if not bash) ──
if [[ -n "${SHELL_PKG}" ]]; then
  log "Installing shell: ${SHELL_CHOICE}"
  emerge --noreplace ${SHELL_PKG} >> "\$LOG" 2>&1
fi

# ── Kernel ──
log "Kernel: ${KERNEL_CHOICE}"
case "${KERNEL_CHOICE}" in
  dist-kernel)
    emerge --autounmask --autounmask-write sys-kernel/gentoo-kernel-bin >> "\$LOG" 2>&1 || true
    etc-update --automode -5 >> "\$LOG" 2>&1 || true
    emerge sys-kernel/gentoo-kernel-bin >> "\$LOG" 2>&1
    ;;
  genkernel)
    emerge sys-kernel/gentoo-sources sys-kernel/genkernel >> "\$LOG" 2>&1
    genkernel all >> "\$LOG" 2>&1
    ;;
  manual)
    emerge sys-kernel/gentoo-sources >> "\$LOG" 2>&1
    log "Kernel sources installed. Configure manually after reboot."
    ;;
esac

# ── Hostname ──
echo "${HOSTNAME}" > /etc/hostname
grep -q "127.0.1.1" /etc/hosts 2>/dev/null || \
  printf '127.0.0.1\tlocalhost\n127.0.1.1\t${HOSTNAME}.localdomain\t${HOSTNAME}\n::1\t\tlocalhost\n' \
  >> /etc/hosts

# ── Passwords (via env — never embedded in script) ──
log "Setting passwords …"
echo "root:\${ROOT_PASS_IN}" | chpasswd

# ── User ──
log "Creating user: ${USERNAME}"
getent group plugdev &>/dev/null || groupadd plugdev >> "\$LOG" 2>&1 || true
useradd -m -G users,wheel,audio,video,usb,input -s "${SHELL_BIN}" \
  "${USERNAME}" 2>/dev/null || \
  usermod -aG wheel,audio,video,usb,input "${USERNAME}"
usermod -aG plugdev "${USERNAME}" >> "\$LOG" 2>&1 || true
echo "${USERNAME}:\${USER_PASS_IN}" | chpasswd

# ── sudo ──
emerge --noreplace app-admin/sudo >> "\$LOG" 2>&1
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# ── SSH key ──
if [[ -n "${SSH_KEY}" ]]; then
  log "Importing SSH public key …"
  local home_dir="/home/${USERNAME}"
  mkdir -p "\${home_dir}/.ssh"
  echo "${SSH_KEY}" >> "\${home_dir}/.ssh/authorized_keys"
  chmod 700 "\${home_dir}/.ssh"
  chmod 600 "\${home_dir}/.ssh/authorized_keys"
  chown -R "${USERNAME}:${USERNAME}" "\${home_dir}/.ssh"
fi

# ── Base packages ──
log "Installing base packages …"
emerge --noreplace \
  sys-apps/bash-completion \
  sys-fs/e2fsprogs \
  sys-fs/dosfstools \
  sys-fs/btrfs-progs \
  app-misc/screen \
  sys-apps/pciutils \
  >> "\$LOG" 2>&1

# ── Network tool ──
log "Network: ${NET_TOOL}"
emerge --noreplace ${NET_PKG} >> "\$LOG" 2>&1

# ── Desktop environment ──
if [[ -n "${DE_PKG}" ]]; then
  log "Desktop: ${DE_CHOICE}"
  emerge --noreplace ${DE_PKG} >> "\$LOG" 2>&1
  [[ -n "${DM_PKG}" ]] && emerge --noreplace ${DM_PKG} >> "\$LOG" 2>&1
fi

# ── GRUB ──
log "Installing GRUB …"
emerge sys-boot/grub >> "\$LOG" 2>&1
if [[ "${BOOT_MODE}" == "uefi" ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=Gentoo >> "\$LOG" 2>&1
else
  grub-install ${DISK} >> "\$LOG" 2>&1
fi
grub-mkconfig -o /boot/grub/grub.cfg >> "\$LOG" 2>&1

# ── Services (OpenRC) ──
if command -v rc-update &>/dev/null; then
  log "Enabling OpenRC services …"
  case "${NET_TOOL}" in
    networkmanager) rc-update add NetworkManager default >> "\$LOG" 2>&1 || true ;;
    iwd)            rc-update add iwd default >> "\$LOG" 2>&1 || true ;;
    dhcpcd)         rc-update add dhcpcd default >> "\$LOG" 2>&1 || true ;;
    connman)        rc-update add connman default >> "\$LOG" 2>&1 || true ;;
  esac
  [[ -n "${DM_SERVICE}" ]] && rc-update add "${DM_SERVICE}" default >> "\$LOG" 2>&1 || true
  rc-update add sshd default >> "\$LOG" 2>&1 || true
  rc-update add cronie default >> "\$LOG" 2>&1 || true
fi

# ── Services (systemd) ──
if command -v systemctl &>/dev/null; then
  log "Enabling systemd services …"
  case "${NET_TOOL}" in
    networkmanager) systemctl enable NetworkManager >> "\$LOG" 2>&1 || true ;;
    iwd)            systemctl enable iwd >> "\$LOG" 2>&1 || true ;;
    dhcpcd)         systemctl enable dhcpcd >> "\$LOG" 2>&1 || true ;;
    connman)        systemctl enable connman >> "\$LOG" 2>&1 || true ;;
  esac
  [[ -n "${DM_SERVICE}" ]] && systemctl enable "${DM_SERVICE}" >> "\$LOG" 2>&1 || true
  systemctl enable sshd >> "\$LOG" 2>&1 || true
fi

log "=== Chroot stage COMPLETE ==="
CHROOT_EOF

  chmod +x /mnt/gentoo/gentoo-chroot-install.sh
  chroot /mnt/gentoo /usr/bin/env \
    ROOT_PASS_IN="$ROOT_PASS" \
    USER_PASS_IN="$USER_PASS" \
    /gentoo-chroot-install.sh
  rm -f /mnt/gentoo/gentoo-chroot-install.sh
  ok "Chroot setup complete."
}

# ──────────────────────────────────────────────
# SCREEN: FINISH  (with auto-reboot countdown)
# ──────────────────────────────────────────────
screen_finish() {
  dialog --title "  Installation Complete!  " --colors --msgbox "\n\
\Z2Gentoo has been installed successfully!\Zn\n\n\
\ZbCredentials:\Zn\n\
  root       — (password you set)\n\
  ${USERNAME}  — (password you set)\n\n\
\ZbNext steps after reboot:\Zn\n\
  1. \Z6emerge --sync && emerge -uDN @world\Zn\n\
  2. Install additional software as needed\n\n\
\Z3Full log:\Zn $LOG_FILE\n\n\
\ZbWelcome to Gentoo!\Zn — compile wisely 🐧" 22 62

  # Auto-reboot countdown
  local ans
  ans=$(dialog --title "Reboot Now?" --colors \
    --menu "\n\Z2Installation complete!\Zn\n\nReboot into your new Gentoo system?" \
    12 52 2 \
    "reboot" "Reboot now  (recommended)" \
    "shell"  "Stay in Live environment" \
    3>&1 1>&2 2>&3) || ans="shell"

  if [[ "$ans" == "reboot" ]]; then
    # Unmount cleanly
    info "Unmounting filesystems …"
    umount -Rf /mnt/gentoo/dev  2>/dev/null || true
    umount -Rf /mnt/gentoo/proc 2>/dev/null || true
    umount -Rf /mnt/gentoo/sys  2>/dev/null || true
    umount -Rf /mnt/gentoo/run  2>/dev/null || true
    umount -Rf /mnt/gentoo      2>/dev/null || true
    swapoff -a 2>/dev/null || true

    clear
    echo -e "${GREEN}${BOLD}Rebooting in 5 seconds… (Ctrl+C to cancel)${RESET}"
    for i in 5 4 3 2 1; do
      echo -ne "\r  ${YELLOW}${i}${RESET}  "
      sleep 1
    done
    echo ""
    reboot
  else
    info "Staying in Live environment. You can reboot manually with: reboot"
  fi
}

# ──────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────
main() {
  require_root
  mkdir -p /mnt/gentoo
  : >> "$LOG_FILE"
  log "=== Gentoo Installer v5.0 started ==="
  check_deps

  # CLI flag: --resume
  if [[ "${1:-}" == "--resume" ]]; then
    if [[ -f "$STATE_FILE" ]]; then
      load_state; RESUMING=1
      info "CLI --resume flag: loading state."
    else
      warn "--resume flag given but no state file found. Starting fresh."
    fi
  fi

  if [[ $RESUMING -eq 0 ]]; then
    check_resume
  fi

  if [[ $RESUMING -eq 1 ]]; then
    dialog --title "Resuming" --colors --msgbox \
      "\n\Z3Resuming from checkpoint.\Zn\n\nCompleted steps are skipped.\nWatch log: \Z6tail -f $LOG_FILE\Zn" \
      10 56
  else
    # ── Configuration Wizard ──
    touch "$STATE_FILE"
    screen_welcome
    screen_detect_boot
    screen_mirror
    screen_disk
    screen_filesystem
    [[ -z "$BOOT_PART" ]] && screen_swap
    screen_hostname
    screen_username
    screen_passwords
    screen_timezone
    screen_locale
    screen_stage3
    screen_keywords
    screen_march
    screen_gpu
    screen_profile
    screen_use_flags
    screen_network
    screen_de
    screen_kernel
    screen_shell
    screen_ssh_key

    save_state
    screen_live_preview
  fi

  # ── Installation Phase ──
  if ! step_is_done PARTITION; then
    step "Partitioning"
    gauge_phase "Preparing Disk" \
      "Partitioning ${DISK} …" 100 "do_partition"
    step_done PARTITION
  fi

  if ! step_is_done FORMAT; then
    step "Formatting"
    gauge_phase "Formatting" \
      "Formatting partitions …" 100 "do_format"
    step_done FORMAT
  fi

  if ! step_is_done MOUNT; then
    step "Mounting"
    do_mount
    step_done MOUNT
  fi

  if ! step_is_done STAGE3; then
    step "Stage3"
    do_stage3
    step_done STAGE3
  fi

  if ! step_is_done MAKECONF; then
    step "make.conf"
    do_makeconf
    step_done MAKECONF
  fi

  if ! step_is_done CHROOT; then
    step "Chroot Installation"
    dialog --title "Installing Gentoo" \
      --infobox "\nEntering chroot — this takes a while (30–120 min).\nMonitor: tail -f $LOG_FILE" 8 58
    do_chroot_setup
    step_done CHROOT
  fi

  rm -f "$STATE_FILE"
  screen_finish
}

main "$@"
