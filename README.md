# Homeassistant-OS-on-Raspberry-Pi-5-KVM

Run genuine, officially supported **Home Assistant OS (HAOS)** inside a lightweight KVM virtual machine on your **Raspberry Pi 5** running **Raspberry Pi OS 64-bit**.

---

## Contents
- [Introduction](#introduction)
   - [Why HAOS in KVM?](#why-haos-in-kvm)
   - [Requirements](#requirements)
- [Installation](#installation)
   - [Automatic Installation (Script)](#automatic-installation)
   - [Manual Installation](#manual-installation)
      - [Step 1: Install KVM and Virtualization Tools](#step-1-install-kvm-and-virtualization-tools)
      - [Step 2: Configure Bridged Networking](#step-2-configure-bridged-networking)
      - [Step 3: Download and Prepare the Generic aarch64 Image](#step-3-download-and-prepare-the-generic-aarch64-image)
      - [Step 4: Create and Launch the HAOS VM](#step-4-create-and-launch-the-haos-vm)
- [Accessing Home Assistant](#accessing-home-assistant)
- [Troubleshooting](#troubleshooting)
   - [UEFI Secure Boot Error (Access Denied / Security Violation)](#uefi-secure-boot-error)

---

# Introduction

## Why HAOS in KVM?
With the deprecation of Home Assistant Supervised in 2025.12, running Home Assistant OS inside a KVM virtual machine is the recommended modern solution for Raspberry Pi 5 users who want the best of both worlds:

- **100% Officially Supported:** Runs genuine Home Assistant OS with official update streams, supervisor health checks, and the complete Add-on Store.
- **Full Host OS Control:** Your Raspberry Pi continues running Raspberry Pi OS on bare metal for your own Docker containers, NAS storage, or native services.
- **Hardware Virtualization on Pi 5:** The Broadcom BCM2712 CPU on the Raspberry Pi 5 features ARMv8.2-A hardware virtualization extensions with near-zero performance overhead.
- **Dedicated LAN IP:** Using a network bridge (`br0`), Home Assistant has full Layer 2 access to your local network for local IoT discovery (mDNS, HomeKit, Matter/Thread).

## Requirements
- **Hardware:** Raspberry Pi 5 (4GB, 8GB, or 16GB RAM)
- **Host OS:** Raspberry Pi OS 64-bit (Debian Bookworm or Trixie)
- **Network:** Physical Ethernet connection recommended (required for bridging `br0`)
- **Privileges:** Root / sudo access

---

# Installation

## Automatic Installation
You can install and deploy Home Assistant OS in KVM with a single command using the automated installer script:

```bash
sudo wget https://raw.githubusercontent.com/HuckleberryLovesYou/Homeassistant-OS-on-Raspberry-Pi-5-KVM/main/installHomeassistant.sh -O installHomeassistant.sh && sudo chmod +x installHomeassistant.sh && sudo ./installHomeassistant.sh
```

The script will:
1. Verify system and architecture compatibility.
2. Install QEMU, KVM, libvirt, and UEFI firmware tools.
3. Automatically configure the network bridge `br0` on your physical Ethernet interface using NetworkManager.
4. Download the latest official generic-aarch64 HAOS UEFI image, expand its disk by +32GB, and place it in libvirt storage.
5. Create and launch the VM with appropriate RAM allocation (4GB for 8GB/16GB models, 2GB for 4GB models) and enable automatic startup on boot.

---

## Manual Installation

### Step 1: Install KVM and Virtualization Tools
Install the virtualization stack and UEFI ARM firmware:
```bash
sudo apt update
sudo apt install -y qemu-system-arm qemu-efi-aarch64 libvirt-daemon-system libvirt-clients bridge-utils virtinst qemu-utils xz-utils curl jq

# Add your user to the virtualization groups
sudo usermod -aG libvirt,kvm $USER
```

### Step 2: Configure Bridged Networking
Home Assistant requires Layer 2 network access to your local subnet for device discovery (mDNS, HomeKit, Matter). Configure a network bridge (`br0`) attached to your physical Ethernet interface:

```bash
# Identify your active ethernet interface (e.g. eth0 or end0)
ETH_IF=$(ip -br link | awk '$1 ~ /^(eth|end)/ {print $1}' | head -n 1)

# Create the bridge connection
sudo nmcli connection add type bridge con-name br0 ifname br0
sudo nmcli connection add type bridge-slave con-name br0-slave ifname "$ETH_IF" master br0
sudo nmcli connection up br0
```

### Step 3: Download and Prepare the Generic aarch64 Image
> [!NOTE]  
> Use the **`generic-aarch64`** image (not `haos_rpi5-64`). In a virtual machine, QEMU exposes a standard UEFI `virt` machine type, which uses the generic ARM64 Linux kernel and drivers.

Download the latest image from [Home Assistant OS Releases](https://github.com/home-assistant/operating-system/releases) and expand its virtual disk:
```bash
# Fetch latest release URL
HAOS_URL=$(curl -s https://api.github.com/repos/home-assistant/operating-system/releases/latest | grep "browser_download_url.*haos_generic-aarch64-.*\.qcow2\.xz" | cut -d '"' -f 4 | head -n 1)

wget -O haos_generic-aarch64.qcow2.xz "$HAOS_URL"
unxz haos_generic-aarch64.qcow2.xz

# Expand virtual disk by +32GB
qemu-img resize haos_generic-aarch64.qcow2 +32G

# Move into libvirt storage directory
sudo mkdir -p /var/lib/libvirt/images
sudo mv haos_generic-aarch64.qcow2 /var/lib/libvirt/images/haos.qcow2
```

### Step 4: Create and Launch the HAOS VM
> [!IMPORTANT]  
> Home Assistant OS does not support Secure Boot. Disable Secure Boot explicitly in the UEFI parameters as shown below.

Run `virt-install` to create and launch the VM (allocate 4096MB RAM if you have an 8GB/16GB Pi 5, or 2048MB for a 4GB model):
```bash
sudo virt-install \
  --name haos \
  --description "Home Assistant OS" \
  --os-variant generic \
  --ram 4096 \
  --vcpus 2 \
  --cpu host-passthrough \
  --disk /var/lib/libvirt/images/haos.qcow2,bus=virtio \
  --import \
  --graphics none \
  --noautoconsole \
  --network bridge=br0,model=virtio \
  --boot uefi,firmware.feature0.name=enrolled-keys,firmware.feature0.enabled=no,firmware.feature1.name=secure-boot,firmware.feature1.enabled=no
```

Set the VM to automatically start when your Raspberry Pi boots:
```bash
sudo virsh autostart haos
```

---

# Accessing Home Assistant

> [!NOTE]  
> New Home Assistant installations (2026.8+) use port **80** by default (standard HTTP), so no port suffix is required in your browser.

Access the Home Assistant Web GUI using:
- **By Hostname:**
  ```
  http://homeassistant.local
  ```
- **By Assigned IP Address (e.g. `http://192.168.0.6`):**
  Because the VM is bridged directly to your LAN via `br0`, it gets its IP address directly from your home router.
  To find the assigned IP address, run:
  ```bash
  sudo virsh domifaddr haos
  ```
  Or check your router's DHCP client list for a device named `homeassistant`.

---

# Troubleshooting

## UEFI Secure Boot Error
If the virtual machine halts with `Access Denied` or `Security Violation`:
- Home Assistant OS does not use Microsoft-signed Secure Boot keys. Secure Boot must be disabled.
- If using `virt-install`, ensure you passed:
  ```bash
  --boot uefi,firmware.feature0.name=enrolled-keys,firmware.feature0.enabled=no,firmware.feature1.name=secure-boot,firmware.feature1.enabled=no
  ```
- If editing the virtual machine configuration manually with `sudo virsh edit haos`, verify that the `<firmware>` block includes:
  ```xml
  <firmware>
    <feature enabled='no' name='enrolled-keys'/>
    <feature enabled='no' name='secure-boot'/>
  </firmware>
  ```
