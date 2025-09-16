#!/usr/bin/env bash
# install.sh
# Downloads Apple Broadcom firmware from Noa’s package, detects platform variant,
# and installs the proper family files (bin/clm_blob/txcap_blob/txt) into /lib/firmware/brcm.
#
# Variant resolution:
#  - Detect BCM4364 revision (B2=/3, B3=/2) and SMBIOS model (iMac19,1 / iMac19,2 / iMac20,x / MBP / Mac mini / iMac Pro / Mac Pro)
#  - Map to Apple board-name family:
#      B2: midway (iMac19,1 27"), nihau (iMac19,2 21.5"), kauai, maui, lanai, ekans
#      B3: borneo, bali, trinidad, kahana, hanauma, kure
#  - TXT selection (simplified):
#      * If exactly one ...-HRPN-u.txt exists → use it.
#      * Else if versioned ...-HRPN-u-*.txt exist → use the highest version.
#      * Else fallback to ...-HRPN-m*.txt / ...-HRPN-m.txt
#
# Extras: Kernel pre-check (Stable ≥ 6.8 preferred; fallback Backports), optional P2P-off, country/regdom setting,
#         robust reload + NetworkManager rescan.
# NEW:    --dry-run → simulate detection & selection without changes (incl. kernel check output).

set -euo pipefail

FW_URL_DEFAULT="https://github.com/NoaHimesaka1873/apple-bcm-firmware/releases/download/v14.0/apple-bcm-firmware-14.0-1-any.pkg.tar.zst"
FW_URL="$FW_URL_DEFAULT"
DST="/lib/firmware/brcm"
KEEP_TEMP=0
AUTO_YES=0          # --yes
SKIP_KERNEL_CHECK=0 # --no-kernel-check
P2P_OFF=0           # --p2p-off (default: keep P2P)
COUNTRY=""          # --country XX      : Set & persist regdom (e.g., DE, US)
DO_RESCAN=1         # --no-rescan disables it
RESTART_NM=1        # --no-restart-nm disables it
FORCE_FAM=""        # --family <midway|nihau|kauai|maui|lanai|ekans|borneo|bali|trinidad|kahana|hanauma|kure>
DRY_RUN=0           # --dry-run

# Minimal kernel
KMIN_MAJ=6
KMIN_MIN=8

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "• %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
warn(){ printf "⚠️  %s\n" "$*"; }
die(){ printf "❌ %s\n" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
export PATH="$PATH:/usr/sbin:/sbin"

ensure_deps(){
  # Ensure iw and regulatory DB are present
  local need=()
  if ! have iw; then need+=("iw"); fi
  if [[ ! -e /lib/firmware/regulatory.db ]]; then need+=("wireless-regdb"); fi
  if (( ${#need[@]} == 0 )); then return 0; fi

  info "Installing prerequisites: ${need[*]}"
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}" || warn "Some packages failed: ${need[*]}"
  elif have dnf; then
    dnf -y install "${need[@]}" || warn "dnf install failed"
  elif have pacman; then
    pacman -S --needed --noconfirm "${need[@]}" || warn "pacman install failed"
  elif have zypper; then
    zypper --non-interactive install -y "${need[@]}" || warn "zypper install failed"
  else
    warn "Unknown package manager; please install manually: ${need[*]}"
  fi
}

ask_yes_no(){
  local p="${1:-Continue?}" d=${2:-1} a
  if (( AUTO_YES==1 )); then return 0; fi
  if (( d==1 )); then
    read -r -p "$p [Y/n]: " a || true
    [[ -z "${a:-}" || "${a,,}" =~ ^y ]]
  else
    read -r -p "$p [y/N]: " a || true
    [[ "${a,,}" =~ ^y ]]
  fi
}

usage(){
  cat <<'EOF'
Usage: sudo ./install-wifi-wrapper.sh [--family <name>] [--url <pkg-url>] [--keep-temp] [--yes]
                                      [--no-kernel-check] [--p2p-off] [--country XX]
                                      [--no-rescan] [--no-restart-nm] [--dry-run]
  --family <name>   : Force family (midway|nihau|kauai|maui|lanai|ekans|borneo|bali|trinidad|kahana|hanauma|kure)
  --url <URL>       : Alternative package (zst)
  --keep-temp       : Keep temporary folder
  --yes             : Answer all questions with YES (non-interactive)
  --no-kernel-check : Skip kernel pre-check
  --p2p-off         : Disable Wi-Fi Direct (p2pon=0) on module load
  --country XX      : Set regdom (e.g. DE, US, …)
  --no-rescan       : Do not rescan Wi-Fi at the end
  --no-restart-nm   : Do not restart NetworkManager
  --dry-run         : Simulate detection & selection only (no system changes)
EOF
}

# ---- Argparse ----
if [[ $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --family)        FORCE_FAM="${2:?}"; shift 2;;
      --url)           FW_URL="${2:?}"; shift 2;;
      --keep-temp)     KEEP_TEMP=1; shift;;
      --yes|-y)        AUTO_YES=1; shift;;
      --no-kernel-check) SKIP_KERNEL_CHECK=1; shift;;
      --p2p-off)       P2P_OFF=1; shift;;
      --country)       COUNTRY="${2:?}"; shift 2;;
      --no-rescan)     DO_RESCAN=0; shift;;
      --no-restart-nm) RESTART_NM=0; shift;;
      --dry-run)       DRY_RUN=1; shift;;
      -h|--help)       usage; exit 0;;
      *) die "Unknown option: $1";;
    esac
  done
fi

require_root(){
  if (( DRY_RUN==1 )); then return 0; fi
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root/sudo."
}

os_codename(){ . /etc/os-release 2>/dev/null || true; echo "${VERSION_CODENAME:-}"; }

kernel_meets_min(){
  local kr kmaj kmin
  kr="$(uname -r)"
  kmaj=$(awk -F'[.-]' '{print $1}' <<<"$kr")
  kmin=$(awk -F'[.-]' '{print $2}' <<<"$kr")
  [[ -z "$kmaj" || -z "$kmin" ]] && return 1
  if (( kmaj > KMIN_MAJ )); then return 0; fi
  if (( kmaj == KMIN_MAJ && kmin >= KMIN_MIN )); then return 0; fi
  return 1
}

# ---- Robust helpers: version compare + apt policy parsing (locale-agnostic) ----
ver_ge(){ dpkg --compare-versions "$1" le "$2"; }  # true if $2 >= $1

stable_candidate_version(){  # "Candidate:" OR "Installationskandidat:"
  apt-cache policy linux-image-amd64 2>/dev/null \
  | awk '/(Candidate|Installationskandidat):/ {print $2; exit}'
}

backports_best_version(){   # first version in Version table that comes from any "*backports*" repo; fallback: -t <codename>-backports Candidate
  local code ver
  code="$(os_codename)"

  # 1) Parse version table (locale independent)
  ver="$(
    apt-cache policy linux-image-amd64 2>/dev/null \
    | awk '
        /^[[:space:]]{2,}[0-9]/ {ver=$1; next}
        /backports/ && ver {print ver; exit}
      '
  )"
  if [[ -n "$ver" ]]; then
    echo "$ver"
    return 0
  fi

  # 2) Fallback: read candidate with -t <suite>-backports (locale tolerant)
  ver="$(
    apt-cache -o Dir::Etc::sourcelist=/etc/apt/sources.list \
              -o Dir::Etc::sourceparts=/etc/apt/sources.list.d \
              policy -t "${code}-backports" linux-image-amd64 2>/dev/null \
    | awk '/(Candidate|Installationskandidat):/ {print $2; exit}'
  )"
  [[ -n "$ver" && "$ver" != "(none)" ]] && echo "$ver" || true
}

stable_has_kernel_ge_min(){
  local cand min="${KMIN_MAJ}.${KMIN_MIN}"
  cand="$(stable_candidate_version)"
  [[ -n "$cand" && "$cand" != "(none)" ]] && ver_ge "$min" "$cand"
}

# >>> FIXED: no pre-grep; rely solely on policy parsing
backports_has_kernel_ge_min(){
  local cand min="${KMIN_MAJ}.${KMIN_MIN}"
  cand="$(backports_best_version)"
  [[ -n "$cand" ]] && ver_ge "$min" "$cand"
}

ensure_backports_line(){
  local code
  code="$(os_codename)"
  if [[ "$code" != "bookworm" && "$code" != "trixie" ]]; then
    warn "Not Debian stable (bookworm/trixie) – skipping backports auto config."
    return 1
  fi
  local line="deb http://deb.debian.org/debian ${code}-backports main contrib non-free non-free-firmware"
  if ! grep -qE '^deb .*'"${code}"'-backports ' /etc/apt/sources.list 2>/dev/null; then
    info "Adding ${code}-backports to /etc/apt/sources.list"
    echo "$line" >> /etc/apt/sources.list
  fi
  return 0
}

# ---- Kernel decision: prefer Stable ≥ 6.8, else Backports, else hint to release upgrade ----
maybe_upgrade_kernel(){
  local kr min="${KMIN_MAJ}.${KMIN_MIN}"
  kr="$(uname -r)"

  if (( DRY_RUN==1 )); then
    bold "[dry-run] Kernel check"
    echo "   Running kernel: $kr"
    if kernel_meets_min; then
      ok "[dry-run] Kernel meets minimum >= ${min}."
      return
    fi
    warn "[dry-run] Kernel below minimum ${min}."

    # Debug: show what apt sees
    local st_cand bp_best
    st_cand="$(stable_candidate_version || true)"
    bp_best="$(backports_best_version || true)"
    echo "   Stable candidate:   ${st_cand:-<none>}"
    echo "   Backports (best):   ${bp_best:-<none>}"

    if have apt; then
      if stable_has_kernel_ge_min; then
        local cand; cand="$(stable_candidate_version)"
        ok "[dry-run] Stable has linux-image-amd64 ${cand} ≥ ${min}."
        echo "   → Would install from STABLE:  apt -y install linux-image-amd64 linux-headers-amd64"
      else
        if backports_has_kernel_ge_min; then
          local cand; cand="$(backports_best_version)"
          ok "[dry-run] Backports has linux-image-amd64 ${cand} ≥ ${min}."
          echo "   → Would install from BACKPORTS:  apt -y -t $(os_codename)-backports install linux-image-amd64 linux-headers-amd64"
        else
          warn "[dry-run] No suitable kernel ≥ ${min} found in Stable or Backports."
          echo "   → Consider upgrading to the next Debian release (major upgrade)."
          echo "   → This is a broader change and may affect other packages — backup recommended."
        fi
      fi
    else
      warn "[dry-run] apt not found; cannot probe available kernels."
    fi
    return
  fi

  if (( SKIP_KERNEL_CHECK==1 )); then
    info "Kernel check skipped (--no-kernel-check)."
    return
  fi

  bold "Running kernel: $kr"
  if kernel_meets_min; then
    ok "Kernel meets minimum >= ${min}."
    return
  fi

  warn "Kernel < ${min}. BCM4364 Wi-Fi is typically reliable only with >= ${min}."
  have apt || die "apt not found."

  # 1) Try Stable first
  if stable_has_kernel_ge_min; then
    local cand; cand="$(stable_candidate_version)"
    info "Stable candidate detected: linux-image-amd64 ${cand} (>= ${min})."
    if ask_yes_no "Install Stable kernel now (linux-image-amd64 + linux-headers-amd64)?" 1; then
      apt update
      DEBIAN_FRONTEND=noninteractive apt -y install linux-image-amd64 linux-headers-amd64
      ok "Stable kernel installed. A reboot is required."
      warn "After reboot, re-run this script to finish Wi-Fi installation."
      if ask_yes_no "Reboot now?" 1; then sleep 3; reboot; else exit 0; fi
    else
      warn "Stable kernel upgrade declined – continuing (may fail)."
    fi
    return
  fi

  # 2) Fallback to Backports
  if ensure_backports_line; then
    apt update || true
  fi
  if backports_has_kernel_ge_min; then
    local cand; cand="$(backports_best_version)"
    info "Backports candidate detected: linux-image-amd64 ${cand} (>= ${min})."
    if ask_yes_no "Install Backports kernel now (linux-image-amd64 + linux-headers-amd64)?" 1; then
      DEBIAN_FRONTEND=noninteractive apt -y -t "$(os_codename)-backports" install linux-image-amd64 linux-headers-amd64
      ok "Backports kernel installed. A reboot is required."
      warn "After reboot, re-run this script to finish Wi-Fi installation."
      if ask_yes_no "Reboot now?" 1; then sleep 3; reboot; else exit 0; fi
    else
      warn "Backports kernel upgrade declined – continuing (may fail)."
    fi
  else
    warn "No suitable kernel ≥ ${min} found in Backports."
    echo "   Consider upgrading to the next Debian release (major upgrade)."
    echo "   This is a broader change and may affect other packages — backup recommended."
  fi
}

chip_present(){
  if lspci -nn | grep -qi '14e4:4464'; then
    return 0
  else
    if (( DRY_RUN==1 )); then
      warn "[dry-run] BCM4364 (14e4:4464) not detected; continuing for simulation."
      return 0
    fi
    die "BCM4364 (14e4:4464) not found."
  fi
}

# ---- Model/Revision detection and mapping to family ----
get_model_id() {
  if have dmidecode; then
    dmidecode -s system-product-name 2>/dev/null | sed 's/[[:space:]]//g'
  elif [[ -r /sys/class/dmi/id/product_name ]]; then
    tr -d ' \t\n' </sys/class/dmi/id/product_name
  fi
}

get_bcm4364_rev() {
  dmesg | grep -m1 -o 'BCM4364/[23]' | cut -d/ -f2 || true
}

get_gpu_hint() {
  local vga
  vga="$(lspci -nn | grep -i 'VGA.*AMD' || true)"
  if   grep -qi '5600M' <<<"$vga"; then echo "5600M"
  elif grep -qi '5700XT' <<<"$vga"; then echo "5700XT"
  elif grep -qi '5700'   <<<"$vga"; then echo "5700"
  else echo ""
  fi
}

detect_board_variant() {
  local rev model gpu variant=""
  rev="$(get_bcm4364_rev || true)"
  model="$(get_model_id || true)"
  gpu="$(get_gpu_hint || true)"

  case "$rev" in
    3)  # B2 = /3
      case "$model" in
        iMac19,1) variant="midway";;
        iMac19,2) variant="nihau" ;;
        Macmini8,1)             variant="lanai";;
        iMacPro1,1)             variant="ekans";;
        MacBookPro15,1|MacBookPro15,3) variant="kauai";;
        MacBookPro15,2|MacBookPro15,4) variant="maui";;
        *) variant="midway";;
      esac
      ;;
    2)  # B3 = /2
      case "$model" in
        MacBookPro16,2|MacBookPro16,3) variant="trinidad";;
        MacPro7,1)                     variant="kahana";;
        iMac20,1|iMac20,2)
          if [[ "$gpu" == "5700XT" || "$gpu" == "5700" ]]; then
            variant="kure"
          else
            variant="hanauma"
          fi
          ;;
        MacBookPro16,1|MacBookPro16,4)
          if [[ "$gpu" == "5600M" ]]; then
            variant="borneo"
          else
            variant="bali"
          fi
          ;;
        *) variant="borneo";;
      esac
      ;;
    *)  # unknown rev → heuristics
      case "$model" in
        iMac19,1) variant="midway";;
        iMac19,2) variant="nihau";;
        iMac20,1|iMac20,2) variant="hanauma";;
        Macmini8,1) variant="lanai";;
        iMacPro1,1) variant="ekans";;
        *) variant="midway";;
      esac
      ;;
  esac

  echo "$variant"
}

# Map family name → base filename (assumes Noa naming convention)
family_to_base(){
  case "$1" in
    midway|nihau|kauai|maui|lanai|ekans)
      echo "brcmfmac4364b2-pcie.apple,$1"
      ;;
    borneo|bali|trinidad|kahana|hanauma|kure)
      echo "brcmfmac4364b3-pcie.apple,$1"
      ;;
    *)
      echo ""
      ;;
  esac
}

# ---- TXT selection (simplified & robust) ----
# 1) exactly one ...-HRPN-u.txt? → use it
# 2) else: highest ...-HRPN-u-*.txt
# 3) else: ...-HRPN-m*.txt / ...-HRPN-m.txt
pick_txt(){
  local fam="$1" src="$2" base picked=""
  base="$(family_to_base "$fam")"
  [[ -n "$base" ]] || return 1

  shopt -s nullglob

  # 1) exactly one unversioned -u.txt?
  local u_plain=( "$src/${base}-HRPN-u.txt" )
  if [[ -f "${u_plain[0]}" ]]; then
    picked="$(basename "${u_plain[0]}")"
    shopt -u nullglob
    if (( DRY_RUN==1 )); then
      ok "[dry-run] TXT would be: $picked → ${base}.txt"
    else
      install -m0644 "$src/$picked" "$DST/${base}.txt"
      ok "TXT chosen: $picked → ${base}.txt"
    fi
    return 0
  fi

  # 2) highest versioned u-*.txt
  local u_vers=( "$src/${base}-HRPN-u-"*.txt )
  if (( ${#u_vers[@]} )); then
    picked="$(basename "$(ls -1v "${u_vers[@]}" | tail -n1)")"
    shopt -u nullglob
    if (( DRY_RUN==1 )); then
      ok "[dry-run] TXT would be: $picked → ${base}.txt"
    else
      install -m0644 "$src/$picked" "$DST/${base}.txt"
      ok "TXT chosen: $picked → ${base}.txt"
    fi
    return 0
  fi

  # 3) fallback: m-variant (prefer versioned)
  local m_vers=()
  m_vers=( "$src/${base}-HRPN-m"*.txt )
  if (( ${#m_vers[@]} )); then
    picked="$(basename "$(ls -1v "${m_vers[@]}" | tail -n1)")"
    shopt -u nullglob
    if (( DRY_RUN==1 )); then
      ok "[dry-run] TXT would be (fallback m): $picked → ${base}.txt"
    else
      install -m0644 "$src/$picked" "$DST/${base}.txt"
      ok "TXT chosen (fallback m): $picked → ${base}.txt"
    fi
    return 0
  fi
  if [[ -f "$src/${base}-HRPN-m.txt" ]]; then
    picked="${base}-HRPN-m.txt"
    shopt -u nullglob
    if (( DRY_RUN==1 )); then
      ok "[dry-run] TXT would be (fallback m): $picked → ${base}.txt"
    else
      install -m0644 "$src/$picked" "$DST/${base}.txt"
      ok "TXT chosen (fallback m): $picked → ${base}.txt"
    fi
    return 0
  fi

  shopt -u nullglob
  warn "No suitable .txt found for family '$fam'"
  return 1
}

install_family(){
  local fam="$1" src="$2" base
  base="$(family_to_base "$fam")"
  [[ -n "$base" ]] || die "Unknown family '$fam'"

  if (( DRY_RUN==0 )); then
    install -d -m0755 "$DST"
  fi

  local ext
  for ext in bin clm_blob txcap_blob; do
    [[ -f "$src/${base}.${ext}" ]] || die "Missing in package: ${base}.${ext}"
    if (( DRY_RUN==1 )); then
      ok "[dry-run] Would install: ${base}.${ext} → $DST/${base}.${ext}"
    else
      install -m0644 "$src/${base}.${ext}" "$DST/${base}.${ext}"
    fi
  done

  # TXT selection
  pick_txt "$fam" "$src" || true

  # Generic symlinks for driver lookup
  if (( DRY_RUN==1 )); then
    ok "[dry-run] Would set symlinks brcmfmac4364-pcie.{bin,clm_blob,txcap_blob,txt} → ${base}.*"
  else
    ln -sf "${base}.bin"        "$DST/brcmfmac4364-pcie.bin"
    ln -sf "${base}.clm_blob"   "$DST/brcmfmac4364-pcie.clm_blob"
    ln -sf "${base}.txcap_blob" "$DST/brcmfmac4364-pcie.txcap_blob"
    if [[ -f "$DST/${base}.txt" ]]; then
      ln -sf "${base}.txt" "$DST/brcmfmac4364-pcie.txt"
    fi
  fi

  ok "Installed family '$fam' → $DST"
}

wifi_ifname(){
  local ifn=""
  if have iw; then
    ifn=$(iw dev | awk '/Interface/{print $2; exit}')
  fi
  if [[ -z "$ifn" ]] && have nmcli; then
    ifn=$(nmcli -t -f DEVICE,TYPE dev status | awk -F: '$2=="wifi"{print $1; exit}')
  fi
  echo "$ifn"
}

wait_for_wifi_if(){
  local t=0 ifn=""
  while (( t < 12 )); do
    ifn="$(wifi_ifname)"
    if [[ -n "$ifn" ]]; then echo "$ifn"; return 0; fi
    sleep 0.5
    ((t++))
  done
  echo ""
  return 1
}

set_regdom(){
  if [[ -z "$COUNTRY" ]]; then return 0; fi
  if have iw; then
    info "Setting regdom: $COUNTRY"
    iw reg set "$COUNTRY" || warn "iw reg set $COUNTRY failed"
  fi
}

persist_regdom(){
  if [[ -z "$COUNTRY" ]]; then return 0; fi

  # Prefer wpa_supplicant (NetworkManager setups)
  if have wpa_cli || [[ -e /etc/wpa_supplicant/wpa_supplicant.conf ]]; then
    install -D -m 644 /dev/null /etc/wpa_supplicant/wpa_supplicant.conf
    if grep -q '^\s*country=' /etc/wpa_supplicant/wpa_supplicant.conf; then
      sed -i 's/^\s*country=.*/country='"$COUNTRY"'/' /etc/wpa_supplicant/wpa_supplicant.conf
    else
      sed -i '1icountry='"$COUNTRY" /etc/wpa_supplicant/wpa_supplicant.conf
    fi
    if (( RESTART_NM==1 )); then
      systemctl try-restart NetworkManager.service 2>/dev/null || \
      systemctl try-restart wpa_supplicant.service 2>/dev/null || true
    fi
    ok "Persisted regdom in /etc/wpa_supplicant/wpa_supplicant.conf"
    return 0
  fi

  # iwd alternative
  if have iwd || [[ -d /etc/iwd ]]; then
    install -d -m 755 /etc/iwd
    printf '[General]\nRegulatoryDomain=%s\n' "$COUNTRY" > /etc/iwd/main.conf
    if (( RESTART_NM==1 )); then
      systemctl try-restart iwd.service 2>/dev/null || true
    fi
    ok "Persisted regdom in /etc/iwd/main.conf"
    return 0
  fi

  # Fallback: cfg80211 module option (effective after reboot)
  echo "options cfg80211 ieee80211_regdom=$COUNTRY" > /etc/modprobe.d/cfg80211.conf
  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u || true
  fi
  ok "Persisted regdom via /etc/modprobe.d/cfg80211.conf (reboot may be required)"
}


nm_rescan_and_show(){
  if ! have nmcli; then return 0; fi
  if (( RESTART_NM==1 )); then
    info "Restarting NetworkManager…"
    systemctl restart NetworkManager || warn "NM restart failed"
  fi
  nmcli radio wifi on || true
  sleep 1
  info "Wi-Fi rescan…"
  nmcli dev wifi rescan || true
  sleep 1
  nmcli dev wifi list || true
}

iw_fallback_scan(){
  local ifn
  ifn="$(wifi_ifname)"
  if [[ -z "$ifn" ]]; then return 0; fi
  if have iw; then
    info "iw dev $ifn scan (fallback)…"
    iw dev "$ifn" scan | egrep -i 'SSID:|signal:|primary channel:' -n || true
  elif have iwlist; then
    iwlist "$ifn" scan 2>/dev/null | egrep 'Cell|ESSID|Signal|Channel' -n || true
  fi
}

rfkill_unblock(){
  if have rfkill; then rfkill unblock all || true; fi
}

reload_driver(){
  info "Reloading driver…"
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211 || true
  modprobe brcmutil || true
  if (( P2P_OFF==1 )); then
    modprobe brcmfmac p2pon=0 || true
  else
    modprobe brcmfmac || true
  fi
}

# ---- Flow ----
require_root
chip_present

# 0) Kernel check / maybe upgrade (Stable preferred; in dry-run: report only)
maybe_upgrade_kernel

# Ensure tools present
ensure_deps

# 1) Detect family (or override)
if [[ -n "$FORCE_FAM" ]]; then
  FAM="$FORCE_FAM"
else
  FAM="$(detect_board_variant)"
fi

MODEL_ID="$(get_model_id || true)"
REV_RAW="$(get_bcm4364_rev || true)"
B_REV=""
if [[ "$REV_RAW" == "2" ]]; then B_REV="3"; elif [[ "$REV_RAW" == "3" ]]; then B_REV="2"; else B_REV="?"; fi

bold "Pre-install summary"
cat <<EOF
✅ Compatible hardware detected for this Mac: ${MODEL_ID:-unknown}
   Detected Wi-Fi chipset: Broadcom BCM4364 (revision ${REV_RAW:-?} → B${B_REV})
   Selected firmware family: "${FAM}"

Please verify this family on macOS (if available) with:
  ioreg -l | grep -i RequestedFiles

If macOS reports a different family (e.g., "nihau", "midway", "borneo", ...),
re-run this installer with an explicit override, for example:
  sudo ./install-wifi-wrapper.sh --family <family-name>

Tip: Use --dry-run first to simulate detection and selection without changes.
EOF

# 2) Tools check
have curl || die "curl missing."
have tar  || die "tar missing."
ZSTD_FLAG="--zstd"
if ! tar --help | grep -q -- --zstd; then
  ZSTD_FLAG="--use-compress-program=unzstd"
fi

TMP="$(mktemp -d /tmp/bcm4364.XXXXXX)"
cleanup(){
  if (( KEEP_TEMP==0 )); then rm -rf "$TMP"; fi
}
trap cleanup EXIT
PKG="$TMP/fw.pkg.tar.zst"
EX="$TMP/extract"

# 3) Download
bold "==> Download firmware package"
curl -fL "$FW_URL" -o "$PKG"
ok "Download ok: $(du -h "$PKG" | awk '{print $1}')"

# 4) Extract
bold "==> Extracting package"
mkdir -p "$EX"
tar $ZSTD_FLAG -xvf "$PKG" -C "$EX" >/dev/null
SRC="$EX/usr/lib/firmware/brcm"
[[ -d "$SRC" ]] || die "Unexpected package structure. No brcm/ folder found."

# 5) Install family (files + .txt selection + symlinks)
install_family "$FAM" "$SRC"

# 6) Reload + report (skip in dry-run)
if (( DRY_RUN==0 )); then
  reload_driver
  set_regdom
  persist_regdom
  rfkill_unblock

  IFN="$(wait_for_wifi_if || true)"
  if [[ -z "$IFN" ]]; then
    warn "Wi-Fi interface not found (missing iw/nmcli?)"
  fi

  echo
  bold "Quick report"
  dmesg -T | egrep -i 'brcmfmac|firmware|bcm4364' | tail -n 60 || true

  if (( DO_RESCAN==1 )); then
    nm_rescan_and_show || true
    iw_fallback_scan || true
  fi

  echo
  if have nmcli; then
    echo "If you do not see Wi-Fi yet, try a reboot (or run: nmcli dev wifi rescan)."
  else
    echo "Tip: install network-manager rfkill iw for easier management."
  fi
  read -r -p "Reboot now? [y/N]: " ans || true
  if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then reboot; fi
else
  bold "[dry-run] Done. No changes were made."
fi
