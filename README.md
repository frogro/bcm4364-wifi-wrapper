[![ShellCheck](https://github.com/frogro/bcm4364-wifi-wrapper/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/frogro/bcm4364-wifi-wrapper/actions/workflows/shellcheck.yml)
# BCM4364 Wi‑Fi Firmware Wrapper (Debian/Ubuntu on Intel Macs)

This repository provides a **wrapper installer** for Macs (**iMac**, **MacBook**, **Mac mini**, **iMac Pro**, **Mac Pro**) that ship with **Apple’s Broadcom BCM4364** Wi‑Fi chipset **and run Linux (Debian/Ubuntu)**. On these T2‑era Intel Macs, **Wi‑Fi does not work out of the box** because the Linux `brcmfmac` driver **requires device‑specific Apple firmware blobs** — and the correct *family/variant* for hardware revisions **B2/B3** — which Linux distributions do **not** include for licensing reasons. This wrapper **does not ship any firmware**; it downloads the upstream package, picks the right set, and installs the correct **family** variant for your machine.

- Default upstream firmware package:  
  `https://github.com/NoaHimesaka1873/apple-bcm-firmware/releases/download/v14.0/apple-bcm-firmware-14.0-1-any.pkg.tar.zst`

> **TL;DR**  
> Run `sudo ./install.sh` on a BCM4364‑equipped Mac. The script detects your model/revision, picks the right **family** (e.g. `midway`, `nihau`, `bali`, `borneo`, `kure`, …), installs the matching `bin`, `clm_blob`, `txcap_blob` and `.txt`, creates the generic symlinks the kernel expects, and refreshes Wi‑Fi. You may override the family manually if you already know it from macOS (see **Determine your family on macOS**).

> **Kernel requirement (Debian & Ubuntu)**
> You must run a **Linux kernel ≥ 6.8** for reliable BCM4364 operation.
> - **Debian 12 (bookworm):** this installer includes a **Debian-only kernel checker** that can upgrade you to the **latest Backports kernel** (`linux-image-amd64` + headers). You can accept the prompt or skip it with `--no-kernel-check`.
> - **Ubuntu:** the kernel checker is **not integrated**. Keep your system on **≥ 6.8** (e.g. via the `linux-generic` meta-package on current releases) and run the installer with `--no-kernel-check` if you don’t want Debian-specific prompts.


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

2. **Kernel requirement check (Debian‑only)**
   - Requires kernel **≥ 6.8**. On **Debian 12**, the installer can offer to install/upgrade to the **latest Backports kernel** (`linux-image-amd64` + headers).
   - On **Ubuntu**, no kernel service/check is integrated; keep `linux-generic` on a release that provides ≥ 6.8, or run with `--no-kernel-check` to suppress Debian prompts.

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
- Tools: `git`, `curl`, `tar` (with `--zstd` support or `unzstd`), `zstd`, `network-manager` (or `iwd`), `rfkill`, `iw`, `pciutils` (`lspci`), `dmidecode`, `wireless-regdb`

Install helpers (Debian/Ubuntu):
```bash
sudo apt update
sudo apt install -y git curl tar zstd unzstd network-manager rfkill iw pciutils dmidecode
```

> **Linux kernel ≥ 6.8** required. On **Ubuntu 22.04 LTS**, install the HWE kernel (linux-generic-hwe-22.04); on **Ubuntu 24.04+**, the linux-generic meta-package already provides ≥ 6.8. If you don’t want Debian-specific prompts, run the installer with --no-kernel-check (the Debian kernel upgrade helper isn’t integrated on Ubuntu).

---

## Quick start

```bash
git clone https://github.com/frogro/bcm4364-wifi-wrapper
cd bcm4364-wifi-wrapper
chmod +x install.sh
sudo ./install.sh --country DE
```

If Wi‑Fi networks do not appear afterwards, **reboot once**.

> **Tip:** On **Debian 12**, the installer may prompt to upgrade to the latest **Backports** kernel (≥ 6.8). On **Ubuntu**, ensure `linux-generic` provides ≥ 6.8 and consider `--no-kernel-check`.

---

## Determine your family on macOS (optional but useful)

If you still have macOS on the machine, you can confirm the **exact firmware family** macOS uses:

- **Directly read the requested firmware path (often includes the family name):**
  ```bash
  ioreg -l | grep RequestedFiles
  ```
  Example output may contain: `C-4364__s-B3/bali/...` or `C-4364__s-B2/midway/...` — here `bali` or `midway` is the **family** name. Use that with `--family <name>` if you want to override auto‑detection.

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
sudo rm -f brcmfmac4364b2-pcie.apple,<family>.bin brcmfmac4364b2-pcie.apple,<family>.clm_blob brcmfmac4364b2-pcie.apple,<family>.txcap_blob brcmfmac4364b2-pcie.apple,<family>.txt brcmfmac4364b3-pcie.apple,<family>.bin brcmfmac4364b3-pcie.apple,<family>.clm_blob brcmfmac4364b3-pcie.apple,<family>.txcap_blob brcmfmac4364b3-pcie.apple,<family>.txt

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
  - Ensure kernel **≥ 6.8**. On **22.04 LTS**, install **HWE** (`linux-generic-hwe-22.04`); on **24.04+** `linux-generic` already provides it. You may use `--no-kernel-check`.

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

## Appendix: Kernel upgrade quick guides

### Debian 12 (“bookworm”) — Backports kernel
Use **Backports** to install a kernel ≥ **6.8**:

```bash
# 1) Enable bookworm-backports (once)
echo 'deb http://deb.debian.org/debian bookworm-backports main contrib non-free-firmware' | sudo tee /etc/apt/sources.list.d/backports.list

# 2) Update package lists
sudo apt update

# 3) (Optional) Check the candidate kernel source
apt-cache policy linux-image-amd64 | sed -n '1,20p'

# 4) Install Backports kernel + headers
sudo apt -t bookworm-backports install -y linux-image-amd64 linux-headers-amd64

# 5) Reboot and verify
sudo reboot
# after reboot:
uname -r
```

> The installer’s **kernel checker** can prompt you for this automatically; the commands above are the manual way.

### Ubuntu 22.04 LTS — HWE kernel
Install the **Hardware Enablement (HWE)** stack to get a newer kernel (it **tracks kernels from newer Ubuntu releases**; for example, when **Ubuntu 24.04** is current, the HWE kernel for 22.04 provides **≥ 6.8**):

```bash
# 1) Install HWE meta-package
sudo apt update
sudo apt install -y linux-generic-hwe-22.04

# 2) Reboot and verify
sudo reboot
# after reboot:
uname -r
```

> On **Ubuntu 24.04+**, you normally already have ≥ **6.8** with the standard `linux-generic` meta-package; no HWE step is needed.


---

## License

This wrapper is released under the **MIT License**. See [`LICENSE`](./LICENSE) for details.
