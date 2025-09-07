#!/usr/bin/env bash
# install-wifi-wrapper.sh
# Lädt Apple-Broadcom-FW aus Noa-Paket, erkennt BCM4364-Variante,
# bevorzugt: BCM4364/3 => b2(midway), BCM4364/2 => b3(borneo),
# kopiert passende Dateien nach /lib/firmware/brcm und setzt Symlinks.

set -euo pipefail

FW_URL_DEFAULT="https://github.com/NoaHimesaka1873/apple-bcm-firmware/releases/download/v14.0/apple-bcm-firmware-14.0-1-any.pkg.tar.zst"
FW_URL="$FW_URL_DEFAULT"
DST="/lib/firmware/brcm"
KEEP_TEMP=0
FORCE_FAM=""   # "--b2" oder "--b3"

bold(){ printf "\033[1m%s\033[0m\n" "$*"; }
info(){ printf "• %s\n" "$*"; }
ok(){ printf "✅ %s\n" "$*"; }
warn(){ printf "⚠️  %s\n" "$*"; }
die(){ printf "❌ %s\n" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

usage(){
  cat <<EOF
Usage: sudo ./install-wifi-wrapper.sh [--b2|--b3] [--url <pkg-url>] [--keep-temp]
  --b2/--b3      : Variante erzwingen (überschreibt Auto-Erkennung)
  --url <URL>    : alternatives Paket (zst)
  --keep-temp    : Temp-Ordner behalten
EOF
}

[[ $# -gt 0 ]] && {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --b2|--B2) FORCE_FAM="b2"; shift;;
      --b3|--B3) FORCE_FAM="b3"; shift;;
      --url) FW_URL="${2:?}"; shift 2;;
      --keep-temp) KEEP_TEMP=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "Unbekannte Option: $1";;
    esac
  done
}

require_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Bitte mit sudo/root starten."; }
require_root

chip_present(){
  lspci -nn | grep -qi '14e4:4464'
}

detect_hw_rev(){
  # gibt "2" oder "3" zurück, falls im dmesg gefunden, sonst leer
  local d
  d="$(dmesg | grep -m1 -o 'BCM4364/[23]' || true)"
  [[ -n "$d" ]] && echo "${d##*/}" || echo ""
}

detect_preferred_family(){
  # Mapping (gewünscht): /3 -> b2(midway), /2 -> b3(borneo)
  local rev="$1"
  case "$rev" in
    3) echo "b2";;
    2) echo "b3";;
    *) echo "";;
  esac
}

pick_txt(){
  # wählt eine passende TXT aus dem entpackten Paket und gibt ZIELNAME zurück,
  # kopiert dabei als Apple-konformen Dateinamen nach $DST
  local fam="$1" src="$2" picked=""
  shopt -s nullglob
  if [[ "$fam" == "b2" ]]; then
    # midway: bevorzuge HRPN-m, sonst HRPN-u
    for cand in \
      brcmfmac4364b2-pcie.apple,midway-HRPN-m.txt \
      brcmfmac4364b2-pcie.apple,midway-HRPN-u.txt; do
      [[ -f "$src/$cand" ]] && { picked="$cand"; break; }
    done
    if [[ -n "$picked" ]]; then
      install -m0644 "$src/$picked" "$DST/brcmfmac4364b2-pcie.apple,midway.txt"
      ok "TXT gewählt: $picked → brcmfmac4364b2-pcie.apple,midway.txt"
    fi
  else
    # b3/borneo: bevorzuge HRPN-u-7.9, dann 7.7, dann HRPN-m
    for cand in \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-u-7.9.txt \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-u-7.7.txt \
      brcmfmac4364b3-pcie.apple,borneo-HRPN-m.txt; do
      [[ -f "$src/$cand" ]] && { picked="$cand"; break; }
    done
    if [[ -n "$picked" ]]; then
      install -m0644 "$src/$picked" "$DST/brcmfmac4364b3-pcie.apple,borneo.txt"
      ok "TXT gewählt: $picked → brcmfmac4364b3-pcie.apple,borneo.txt"
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

  # bin/clm/txcap kopieren
  for ext in bin clm_blob txcap_blob; do
    [[ -f "$src/${base}.${ext}" ]] || die "Fehlt im Paket: ${base}.${ext}"
    install -m0644 "$src/${base}.${ext}" "$DST/${base}.${ext}"
  done

  # TXT wählen & kopieren
  if ! pick_txt "$fam" "$src"; then
    warn "Keine passende .txt im Paket gefunden (Kalibrierung ggf. suboptimal)."
  fi

  # generische Symlinks
  ln -sf "${base}.bin"       "$DST/brcmfmac4364-pcie.bin"
  ln -sf "${base}.clm_blob"  "$DST/brcmfmac4364-pcie.clm_blob"
  ln -sf "${base}.txcap_blob" "$DST/brcmfmac4364-pcie.txcap_blob"
  # Apple-Board TXT-Link (zeigt auf die soeben gewählte TXT – wenn vorhanden)
  if [[ -f "$DST/${base}.txt" ]]; then
    ln -sf "${base}.txt" "$DST/brcmfmac4364-pcie.txt"
    ln -sf "${base}.txt" "$DST/brcmfmac4364-pcie.Apple Inc.-iMac19,1.txt"
  fi
  # Apple-Board bin/clm/txcap
  ln -sf "${base}.bin"       "$DST/brcmfmac4364-pcie.Apple Inc.-iMac19,1.bin"
  ln -sf "${base}.clm_blob"  "$DST/brcmfmac4364-pcie.Apple Inc.-iMac19,1.clm_blob"
  ln -sf "${base}.txcap_blob" "$DST/brcmfmac4364-pcie.Apple Inc.-iMac19,1.txcap_blob"

  ok "Installiert: ${label} (${fam}) → $DST"
}

reload_driver(){
  info "Treiber neu laden…"
  modprobe -r brcmfmac brcmutil cfg80211 2>/dev/null || true
  modprobe cfg80211 || true
  modprobe brcmutil || true
  modprobe brcmfmac || true
}

# ---- Ablauf ----
chip_present || die "BCM4364 (14e4:4464) nicht gefunden."

# Preferenz ableiten (oder override)
HWREV="$(detect_hw_rev || true)"
if [[ -n "$FORCE_FAM" ]]; then
  FAM="$FORCE_FAM"
else
  PREF="$(detect_preferred_family "$HWREV")"
  FAM="${PREF:-b2}"  # fallback b2, wenn nichts erkennbar
fi
bold "→ Erkannt/gewählt: $FAM (Override mit --b2 / --b3)"

# Tools
have curl || die "curl fehlt."
have tar  || die "tar fehlt."
ZSTD_FLAG="--zstd"; tar --help | grep -q -- --zstd || ZSTD_FLAG="--use-compress-program=unzstd"

TMP="$(mktemp -d /tmp/bcm4364.XXXXXX)"
cleanup(){ [[ "$KEEP_TEMP" -eq 1 ]] || rm -rf "$TMP"; }
trap cleanup EXIT
PKG="$TMP/fw.pkg.tar.zst"
EX="$TMP/extract"

# Download
bold "==> Lade Firmware-Paket"
curl -fL "$FW_URL" -o "$PKG"
ok "Download ok: $(du -h "$PKG" | awk '{print $1}')"

# Entpacken
bold "==> Entpacke Paket"
mkdir -p "$EX"
tar $ZSTD_FLAG -xvf "$PKG" -C "$EX" >/dev/null
SRC="$EX/usr/lib/firmware/brcm"
[[ -d "$SRC" ]] || die "Paket-Struktur unerwartet. Kein brcm/-Ordner gefunden."

# Moduloption: P2P aus (verhindert ret -52)
echo "options brcmfmac p2pon=0" >/etc/modprobe.d/brcmfmac.conf || true

# Installieren
install_family "$FAM" "$SRC"

# Treiber neu laden & Kurzreport
reload_driver
echo
bold "Kurzreport"
dmesg -T | egrep -i 'brcmfmac|firmware|bcm4364' | tail -n 20 || true
nmcli -g WIFI radio || true
nmcli dev status || true
echo
echo "If you do not see Wi-Fi yet, try a reboot."
read -r -p "Reboot now? [y/N]: " ans
[[ "${ans:-N}" =~ ^[Yy]$ ]] && reboot
