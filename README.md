# BCM4364 Wi‑Fi Firmware Wrapper (Debian/Ubuntu on Intel Macs)

This repository provides a **wrapper installer** for Macs (**iMac**, **MacBook**, **Mac mini**, **iMac Pro**, **Mac Pro**) that ship with **Apple’s Broadcom BCM4364** Wi‑Fi chipset **and run Linux (Debian/Ubuntu)**. On these T2‑era Intel Macs, **Wi‑Fi does not work out of the box** because the Linux `brcmfmac` driver **requires device‑specific Apple firmware blobs** — and the correct *family/variant* for hardware revisions **B2/B3** — which Linux distributions do **not** include for licensing reasons. This wrapper **does not ship any firmware**; it downloads the upstream package, picks the right set, and installs the correct **family** variant for your machine.

- Default upstream firmware package:  
  `https://github.com/NoaHimesaka1873/apple-bcm-firmware/releases/download/v14.0/apple-bcm-firmware-14.0-1-any.pkg.tar.zst`

> **TL;DR**  
> Run `sudo ./install.sh` on a BCM4364‑equipped Mac. The script detects your model/revision, picks the right **family** (e.g. `midway`, `nihau`, `bali`, `borneo`, `kure`, …), installs the matching `bin`, `clm_blob`, `txcap_blob` and `.txt`, creates the generic symlinks the kernel expects, and refreshes Wi‑Fi. You may override the family manually if you already know it from macOS (see **Determine your family on macOS**).

---

## Supported hardware (examples)

Apple Intel Macs using **Broadcom BCM4364** (PCI ID `14e4:4464`), typically:
- **iMac 2019/2020** — families like `midway`, `nihau`, `hanauma`, `kure`
- **MacBook Pro 2018–2020** — families like `kauai`, `maui`, `bali`, `borneo`, `trinidad`
- **Mac mini 2018** — `lanai`
- **iMac Pro** — `ekans`
- **Mac Pro 2019** — `kahana`

> The installer automatically detects your **hardware revision** (**B2** vs **B3**) and selects a matching family set. You can force a family with `--family <name>` if needed.

---

## What the installer actually does

1. **Sanity checks**
   - Verifies **root**.
   - Confirms **BCM4364** presence (`lspci` shows `14e4:4464`) — unless `--dry-run`.

2. **Optional kernel pre‑check (Debian/Ubuntu)**
   - Recommends a modern kernel (≥ **6.8**) for stable BCM4364.
   - On Debian, may suggest installing `linux-image-amd64` + headers. Skip with `--no-kernel-check`.

3. **Variant (family) detection**
   - Reads **BCM4364 revision** (`/3 → B2`, `/2 → B3`) from `dmesg`.
   - Checks **SMBIOS model** (e.g. `iMac19,1`, `iMac20,2`, `Macmini8,1`, `MacBookPro16,1`).
   - Uses hints (e.g. GPU model) where relevant for late iMac/MBP variants.
   - Maps to an Apple **family** (observed families include: `midway`, `nihau`, `kauai`, `maui`, `lanai`, `ekans`, `bali`, `borneo`, `trinidad`, `kahana`, `hanauma`, `kure`, `sid`).

4. **Fetch & extract the firmware package**
   - Downloads the **`.pkg.tar.zst`** (default URL above) with `curl`.
   - Extracts with `tar --zstd` (or `unzstd` fallback).

5. **Install files to `/lib/firmware/brcm`**
   - Installs the family‑specific trio:
     - `brcmfmac4364b[2/3]-pcie.apple,<family>.bin`
     - `brcmfmac4364b[2/3]-pcie.apple,<family>.clm_blob`
     - `brcmfmac4364b[2/3]-pcie.apple,<family>.txcap_blob`
   - Picks the **best `.txt`** for the chosen family using this order:
     1) exactly one `…-HRPN-u.txt` → use it  
     2) else highest‑versioned `…-HRPN-u-*.txt`  
     3) else fallback to `…-HRPN-m*.txt` then `…-HRPN-m.txt`
   - Creates **generic symlinks** used by the kernel:
     - `brcmfmac4364-pcie.bin` → chosen `.bin`
     - `brcmfmac4364-pcie.clm_blob` → chosen `.clm_blob`
     - `brcmfmac4364-pcie.txcap_blob` → chosen `.txcap_blob`
     - `brcmfmac4364-pcie.txt` → chosen `.txt` (if selected)

6. **Driver reload & Wi‑Fi refresh**
   - Reloads `brcmfmac` (with `p2pon=0` if `--p2p-off`).
   - Optionally **restarts NetworkManager** and triggers a **rescan**.
   - Optionally sets **regulatory domain** (e.g. `DE`) if you used `--country`.

7. **Quick report**
   - Prints recent `dmesg` lines related to `brcmfmac/firmware`.
   - Lists visible networks (via `nmcli` or `iw`) unless `--no-rescan`.

---

## Requirements

- **Debian 12/13** or **Ubuntu 22.04+**
- Tools: `git`, `curl`, `tar` (with `--zstd` support or `unzstd`), `zstd`, `network-manager`, `rfkill`, `iw`, `pciutils` (`lspci`), `dmidecode`

Install helpers (Debian/Ubuntu):
```bash
sudo apt update
sudo apt install -y git curl tar zstd unzstd network-manager rfkill iw pciutils dmidecode
```

> On **Ubuntu**, keep your kernel ≥ **6.8** (e.g. `linux-generic` on current releases) and run the installer with `--no-kernel-check` if you don’t want Debian‑specific prompts.

---

## Quick start

```bash
git clone https://github.com/frogro/bcm4364-wifi-wrapper
cd bcm4364-wifi-wrapper
chmod +x install.sh
sudo ./install.sh --country DE
```

If Wi‑Fi networks do not appear afterwards, **reboot once**.

---

## Determine your family on macOS (optional but useful)

If you still have macOS on the machine, you can confirm the **exact firmware family** macOS uses:

- **Directly read the requested firmware path (often includes the family name):**
  ```bash
  ioreg -l | grep RequestedFiles
  ```
  Example output may contain: `C-4364__s-B3/**bali**/...` or `C-4364__s-B2/**midway**/...` — the bold part is the **family**. Use that with `--family <name>` if you want to override auto‑detection.

- **Also capture your model + board‑id (useful for debugging/mapping):**
  ```bash
  system_profiler SPHardwareDataType | awk -F': ' '/Model Identifier/{print $2}'
  ioreg -rd1 -c IOPlatformExpertDevice | awk -F" '/board-id/{print $4}'
  ```

---

## Command‑line options

```
sudo ./install.sh [--family <name>] [--url <pkg-url>] [--keep-temp] [--yes]
                  [--no-kernel-check] [--p2p-off] [--country XX]
                  [--no-rescan] [--no-restart-nm] [--dry-run]
```

- `--family <name>`  
  Force a family override:  
  `midway|nihau|kauai|maui|lanai|ekans|bali|borneo|trinidad|kahana|hanauma|kure|sid`
- `--url <pkg-url>`  
  Use a different firmware package URL (`.pkg.tar.zst`).
- `--keep-temp`  
  Keep the temporary working directory (debugging).
- `--yes`, `-y`  
  Assume “yes” to prompts (non‑interactive).
- `--no-kernel-check`  
  Skip kernel probing/suggestions.
- `--p2p-off`  
  Load `brcmfmac` with `p2pon=0` (disables Wi‑Fi Direct).
- `--country XX`  
  Set regulatory domain (e.g. `DE`, `US`).
- `--no-rescan`  
  Don’t scan for networks at the end.
- `--no-restart-nm`  
  Don’t restart NetworkManager before rescanning.
- `--dry-run`  
  Simulate everything without changing the system.

### Examples

- **Typical unattended install**:
  ```bash
  sudo ./install.sh --yes --country DE
  ```
- **Force a specific family (from macOS logs)**:
  ```bash
  sudo ./install.sh --family hanauma
  ```
- **Disable Wi‑Fi Direct (P2P), skip kernel checks**:
  ```bash
  sudo ./install.sh --p2p-off --no-kernel-check
  ```
- **Test without changing the system**:
  ```bash
  sudo ./install.sh --dry-run
  ```

---

## Uninstall / Revert

This wrapper only places files in `/lib/firmware/brcm` and creates symlinks.  
To revert, remove the installed family files and the generic symlinks:

```bash
cd /lib/firmware/brcm
sudo rm -f brcmfmac4364-pcie.bin brcmfmac4364-pcie.clm_blob brcmfmac4364-pcie.txcap_blob brcmfmac4364-pcie.txt

# Remove family‑specific files you installed (adjust the <family> you used)
sudo rm -f brcmfmac4364b2-pcie.apple,<family>.bin            brcmfmac4364b2-pcie.apple,<family>.clm_blob            brcmfmac4364b2-pcie.apple,<family>.txcap_blob            brcmfmac4364b2-pcie.apple,<family>.txt            brcmfmac4364b3-pcie.apple,<family>.bin            brcmfmac4364b3-pcie.apple,<family>.clm_blob            brcmfmac4364b3-pcie.apple,<family>.txcap_blob            brcmfmac4364b3-pcie.apple,<family>.txt

# Then reload driver (or just reboot)
sudo modprobe -r brcmfmac brcmutil cfg80211 || true
sudo modprobe cfg80211 && sudo modprobe brcmutil && sudo modprobe brcmfmac
```

---

## Troubleshooting

- **No networks appear**
  - `nmcli radio wifi on && nmcli dev wifi rescan`
  - Check logs: `dmesg | egrep -i 'brcmfmac|firmware|bcm4364' | tail -n 80`
  - Keep kernel ≥ **6.8**.
  - Try `--p2p-off` and/or set `--country DE|US|…`.

- **Family seems wrong**
  - If macOS shows a different family (see **Determine your family on macOS**), re‑run with `--family <name>`.

- **Ubuntu users**
  - Keep a ≥6.8 kernel via the normal Ubuntu meta‑packages (e.g. `linux-generic` on 24.04/24.10+) and use `--no-kernel-check`.

---

## Security and integrity

- This repo **does not** distribute Apple firmware.  
  The installer downloads from the upstream release URL you specify (default linked above).
- For strict verification, download the package yourself, verify its checksum, and pass it via a local `file://` URL or a trusted mirror with `--url`.

---

## Acknowledgements

- Firmware packaging: **Noa Himesaka** (apple-bcm-firmware)  
- Kernel driver: **brcmfmac** (Linux kernel)  
- Thanks to the community for mapping BCM4364 families across Macs.

---

## License

This wrapper is released under the **MIT License**. See [`LICENSE`](./LICENSE) for details.
