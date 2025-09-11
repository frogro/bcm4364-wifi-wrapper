#!/usr/bin/env bash
# install-wifi-wrapper.sh
# Downloads Apple Broadcom firmware from Noa’s package, detects BCM4364 variant,
# preferred: BCM4364/3 => b2 (midway), BCM4364/2 => b3 (borneo),
# copies the correct files to /lib/firmware/brcm and sets symlinks.
#
# Extras: Kernel pre-check (Backports >= 6.8), optional P2P-off, country/regdom setting,
#         robust reload + network list (GUI + CLI consistent, even after overwriting TXT files).

set -euo pipefail

FW_URL_DEFAULT="https://github.com/NoaHimesaka1873/apple-bcm-firmware/releases/download/v14.0/apple-bcm-firmware-14.0-1-any.pkg.tar.zst"
FW_URL="$FW_URL_DEFAULT"
DST="/lib/firmware/brcm"
KEEP_TEMP=0
FORCE_FAM=""        # "b2" or "b3"
AUTO_YES=0          # --yes
SKIP_KERNEL_CHECK=0 # --no-kernel-check
P2P_OFF=0           # --p2p-off (default: keep P2P)
COUNTRY=""          # --country DE
DO_RESCAN=1         # --no-rescan disables it
RESTART_NM=1        # --no-restart-nm disables it

KMIN_MAJ=6
KMIN_MIN=8

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "• %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
warn(){ printf "⚠️  %s\n" "$*"; }
die(){ printf "❌ %s\n" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
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
Usage: sudo ./install-wifi-wrapper.sh [--b2|--b3] [--url <pkg-url>] [--keep-temp] [--yes]
                                      [--no-kernel-check] [--p2p-off] [--country XX]
                                      [--no-rescan] [--no-restart-nm]
  --b2/--b3          : Force variant (overrides auto detection)
  --url <URL>        : Alternative package (zst)
  --keep-temp        : Keep temporary folder
  --yes              : Answer all questions with YES (non-interactive)
  --no-kernel-check  : Skip kernel pre-check
  --p2p-off          : Disable Wi-Fi Direct (P2P) when loading module (p2pon=0)
  --country XX       : Set regdom (e.g. DE, US, …)
  --no-rescan        : Do not rescan Wi-Fi at the end
  --no-restart-nm    : Do not restart NetworkManager
EOF
}

# ---- Argparse ----
if [[ $# -gt 0 ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --b2|--B2) FORCE_FAM="b2"; shift;;
      --b3|--B3) FORCE_FAM="b3"; shift;;
      --url) FW_URL="${2:?}"; shift 2;;
      --keep-temp) KEEP_TEMP=1; shift;;
      --yes|-y) AUTO_YES=1; shift;;
      --no-kernel-check) SKIP_KERNEL_CHECK=1; shift;;
      --p2p-off) P2P_OFF=1; shift;;
      --country) COUNTRY="${2:?}"; shift 2;;
      --no-rescan) DO_RESCAN=0; shift;;
      --no-restart-nm) RESTART_NM=0; shift;;
      -h|--help) usage; exit 0;;
      *) die "Unknown option: $1";;
    esac
  done
fi

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root/sudo."; }
require_root

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

ensure_backports_line(){
  local code
  code="$(os_codename)"
  if [[ "$code" != "bookworm" ]]; then
    warn "Not Debian 12 (bookworm) – skipping backports auto config."
    return 1
  fi
  local line='deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware'
  if ! grep -qE '^deb .*bookworm-backports ' /etc/apt/sources.list 2>/dev/null; then
    info "Adding bookworm-backports to /etc/apt/sources.list"
    echo "$line" >> /etc/apt/sources.list
  fi
  return 0
}

maybe_upgrade_kernel(){
  if (( SKIP_KERNEL_CHECK==1 )); then
    info "Kernel check skipped (--no-kernel-check)."
    return
  fi
  local kr
  kr="$(uname -r)"
  bold "Running kernel: $kr"
  if kernel_meets_min; then
    ok "Kernel meets minimum >= ${KMIN_MAJ}.${KMIN_MIN}."
    return
  fi
  warn "Kernel < ${KMIN_MAJ}.${KMIN_MIN}. For Broadcom BCM4364, Wi-Fi often only works with >= ${KMIN_MAJ}.${KMIN_MIN} (Backports)."
  if ask_yes_no "Install Backports kernel (linux-image-amd64 + linux-headers-amd64) now?" 1; then
    have apt || die "apt not found."
    if ensure_backports_line; then
      info "Updating package lists (including backports)…"
      apt update
      info "Installing backports kernel…"
      DEBIAN_FRONTEND=noninteractive apt -y -t bookworm-backports install linux-image-amd64 linux-headers-amd64
      ok "Kernel installed. A reboot is required."
      warn "⚠️  Please note: after reboot you MUST run this script again to finish Wi-Fi installation."
      if ask_yes_no "Reboot now?" 1; then
        echo "System will reboot in a few seconds…"
        sleep 3
        reboot
      else
        warn "Please reboot manually and re-run this script afterwards."
        exit 0
      fi
    else
      warn "Backports not configured – kernel upgrade skipped."
    fi
  else
    warn "Kernel upgrade declined – continuing with firmware installation (may fail)."
  fi
}

chip_present(){ lspci -nn | grep -qi '14e4:4464'; }

detect_hw_rev(){
  local d
  d="$(dmesg | grep -m1 -o 'BCM4364/[23]' || true)"
  if [[ -n "$d" ]]; then echo "${d##*/}"; else echo ""; fi
}

detect_preferred_family(){
  case "$1" in
    3) echo "b2";;
    2) echo "b3";;
    *) echo "";;
  esac
}

pick_txt(){
  local fam="$1" src="$2" picked=""
  shopt -s nullglob
  if [[ "$fam" == "b2" ]]; then
    for cand in \
      brcmfmac4364b2-pcie.apple,midway-HRPN-u.txt \
      brcmfmac4364b2-pcie.apple,midway-HRPN-m.txt; do
      if [[ -f "$src/$cand" ]]; then picked="$cand"; break; fi
    done
    if [[ -n "$picked" ]]; then
      install -m0644 "$src/$picked" "$DST/brcmfmac4364b2-pcie.apple,midway.txt"
      ok "TXT chosen: $picked → brcmfmac4364b2-pcie.apple,midway.txt"
    fi
  else
    for cand in \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-u-7.9.txt \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-u-7.7.txt \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-m.txt; do
      if [[ -f "$src/$cand" ]]; then picked="$cand"; break; fi
    done
    if [[ -n "$picked" ]]; then
      install -m0644 "$src/$picked" "$DST/brcmfmac4364b3-pcie.apple,borneo.txt"
      ok "TXT chosen: $picked → brcmfmac4364b3-pcie.apple,borneo.txt"
    fi
  fi
  shopt -u nullglob
  [[ -n "$picked" ]]
}

install_family(){
  local fam="$1" src="$2" base label
  if [[ "$fam" == "b2" ]]; then
    base="brcmfmac4364b2-pcie.apple,midway"; label="midway"
  else
    base="brcmfmac4364b3-pcie.apple,borneo"; label="borneo"
  fi

  install -d -m0755 "$DST"

  local ext
  for ext in bin clm_blob txcap_blob; do
    [[ -f "$src/${base}.${ext}" ]] || die "Missing in package: ${base}.${ext}"
    install -m0644 "$src/${base}.${ext}" "$DST/${base}.${ext}"
  done

  if ! pick_txt "$fam" "$src"; then
    warn "No suitable .txt found (calibration may be suboptimal)."
  fi

  ln -sf "${base}.bin"        "$DST/brcmfmac4364-pcie.bin"
  ln -sf "${base}.clm_blob"   "$DST/brcmfmac4364-pcie.clm_blob"
  ln -sf "${base}.txcap_blob" "$DST/brcmfmac4364-pcie.txcap_blob"

  if [[ -f "$DST/${base}.txt" ]]; then
    ln -sf "${base}.txt" "$DST/brcmfmac4364-pcie.txt"
    ln -sf "${base}.txt" "$DST/brcmfmac4364-pcie.Apple Inc.-iMac19,1.txt"
  fi

  ln -sf "${base}.bin"        "$DST/brcmfmac4364-pcie.Apple Inc.-iMac19,1.bin"
  ln -sf "${base}.clm_blob"   "$DST/brcmfmac4364-pcie.Apple Inc.-iMac19,1.clm_blob"
  ln -sf "${base}.txcap_blob" "$DST/brcmfmac4364-pcie.Apple Inc.-iMac19,1.txcap_blob"

  ok "Installed: ${label} (${fam}) → $DST"
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
chip_present || die "BCM4364 (14e4:4464) not found."

# 0) Kernel check / maybe upgrade
maybe_upgrade_kernel

# 1) Family detection
HWREV="$(detect_hw_rev || true)"
if [[ -n "$FORCE_FAM" ]]; then
  FAM="$FORCE_FAM"
else
  PREF="$(detect_preferred_family "$HWREV")"
  FAM="${PREF:-b2}"
fi
bold "→ Detected/chosen: $FAM (Override with --b2 / --b3)"

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

# 5) P2P left untouched unless --p2p-off is given.

# 6) Install family
install_family "$FAM" "$SRC"

# 7) Reload + report
reload_driver
set_regdom
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
