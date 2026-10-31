#!/bin/bash

# By default, skip checks is set to 0. If you want to skip the OS and Architecture checks, set variable below to 1
SKIP_CHECKS=0  # Set variable to 1 to skip

set -e

# Check OS and architecture compatibility
if [ "$SKIP_CHECKS" -eq 0 ]; then
    os_info=$(hostnamectl status | grep "Operating System:" | cut -d: -f2 | xargs)
    if [ "$os_info" != "Debian GNU/Linux 12 (bookworm)" ] && [ "$os_info" != "Debian GNU/Linux 13 (trixie)" ]; then
        echo "E: OS does not match an OS where the script was tested on. Exiting."
        echo "I: If you still want to try the automatic installation, edit the script to ignore these checks ('SKIP_CHECKS=1')."
        exit 1
    fi
    echo "I: OS used is supported"
    
    if [ "$(uname -m)" != "aarch64" ]; then
        echo "E: Architecture is not 64-bit. Exiting."
        exit 1
    fi
    echo "I: Architecture used is supported"
else
    echo "I: The OS and Architecture checks were skipped because SKIP_CHECKS was equal to 1."
fi

echo "=========================================================="
echo "  Home Assistant OS in KVM on Raspberry Pi 5 Installer"
echo "=========================================================="
echo "I: This script installs official Home Assistant OS inside a KVM virtual machine."
echo "I: You get the full Supervisor, Add-on store, and automated updates without modifying your host OS."
echo "I: A network bridge (br0) will be configured on your physical Ethernet interface."
echo "Do you want to continue (y/n)"
read -r continue_install
if [[ $continue_install != "y" ]]; then
    echo "Aborting installation."
    exit 0
fi

# Step 1: Install virtualization stack
echo "I: Step 1: Installing QEMU, KVM, and Libvirt packages..."
apt update -y
apt install -y qemu-system-arm qemu-efi-aarch64 libvirt-daemon-system libvirt-clients bridge-utils virtinst qemu-utils xz-utils curl jq

# Add active user to libvirt and kvm groups
ACTUAL_USER="${SUDO_USER:-$USER}"
if [ -n "$ACTUAL_USER" ]; then
    usermod -aG libvirt,kvm "$ACTUAL_USER" 2>/dev/null || true
fi

# Step 2: Configure networking (bridge br0)
echo "I: Step 2: Setting up network bridge br0..."
systemctl enable --now libvirtd

if ip link show br0 >/dev/null 2>&1; then
    echo "I: Existing bridge br0 detected. Using br0."
else
    ETH_IF=$(ip -br link | awk '$1 ~ /^(eth|end)/ {print $1}' | head -n 1)
    if [ -n "$ETH_IF" ] && command -v nmcli >/dev/null 2>&1; then
        echo "I: Creating bridge br0 with physical interface $ETH_IF..."
        nmcli connection add type bridge con-name br0 ifname br0
        nmcli connection add type bridge-slave con-name br0-slave ifname "$ETH_IF" master br0
        nmcli connection up br0
    else
        echo "E: Could not detect a physical Ethernet interface or nmcli to create bridge br0."
        echo "E: Home Assistant requires a network bridge for proper Layer 2 device discovery. Exiting."
        exit 1
    fi
fi

# Step 3: Download and prepare HAOS Generic aarch64 image
echo "I: Step 3: Finding latest Home Assistant OS generic-aarch64 release..."
HAOS_URL=$(curl -s https://api.github.com/repos/home-assistant/operating-system/releases/latest | grep "browser_download_url.*haos_generic-aarch64-.*\.qcow2\.xz" | cut -d '"' -f 4 | head -n 1)
if [ -z "$HAOS_URL" ]; then
    HAOS_URL="https://github.com/home-assistant/operating-system/releases/download/18.4/haos_generic-aarch64-18.4.qcow2.xz"
fi

echo "I: Downloading HAOS image from $HAOS_URL..."
wget -O haos_generic-aarch64.qcow2.xz "$HAOS_URL"

echo "I: Decompressing HAOS image (this may take a minute)..."
unxz -f haos_generic-aarch64.qcow2.xz

echo "I: Expanding disk image by +32GB..."
qemu-img resize haos_generic-aarch64.qcow2 +32G

mkdir -p /var/lib/libvirt/images
mv -f haos_generic-aarch64.qcow2 /var/lib/libvirt/images/haos.qcow2

# Step 4: Create and launch the VM
echo "I: Step 4: Creating and launching virtual machine..."
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM_MB" -gt 6000 ]; then
    VM_RAM=4096
else
    VM_RAM=2048
fi

echo "I: Allocating ${VM_RAM}MB RAM and 2 vCPUs..."
if virsh dominfo haos >/dev/null 2>&1; then
    echo "W: Virtual machine 'haos' already exists. Skipping creation."
else
    virt-install \
      --name haos \
      --description "Home Assistant OS" \
      --os-variant generic \
      --ram "$VM_RAM" \
      --vcpus 2 \
      --cpu host-passthrough \
      --disk /var/lib/libvirt/images/haos.qcow2,bus=virtio \
      --import \
      --graphics none \
      --noautoconsole \
      --network bridge=br0,model=virtio \
      --boot uefi,firmware.feature0.name=enrolled-keys,firmware.feature0.enabled=no,firmware.feature1.name=secure-boot,firmware.feature1.enabled=no

    virsh autostart haos
fi

echo ""
echo "=========================================================="
echo " Home Assistant OS successfully installed in KVM!"
echo "=========================================================="
echo "I: HAOS is now starting in the background on bridge br0."
echo "I: Note: New Home Assistant installations (2026.8+) use port 80 (HTTP) by default."
echo ""

# Spinner while fetching the IP address
HA_IP=""
MAX_WAIT_SECONDS=60
START_TIME=$(date +%s)
SPIN_CHARS='|/-\'
SPIN_INDEX=0

# Ensure cursor is restored if interrupted
trap 'tput cnorm 2>/dev/null || true' EXIT INT TERM
tput civis 2>/dev/null || true

while true; do
    HA_IP=$(virsh domifaddr haos 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -n 1)
    if [ -n "$HA_IP" ]; then
        break
    fi

    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ "$ELAPSED" -ge "$MAX_WAIT_SECONDS" ]; then
        break
    fi

    CHAR="${SPIN_CHARS:$SPIN_INDEX:1}"
    printf "\rI: [%s] Waiting for VM to obtain IP address... (%ds / %ds, script is running)" "$CHAR" "$ELAPSED" "$MAX_WAIT_SECONDS"
    SPIN_INDEX=$(( (SPIN_INDEX + 1) % 4 ))
    sleep 1
done

# Clear spinner line and restore cursor
printf "\r\033[K"
tput cnorm 2>/dev/null || true
trap - EXIT INT TERM

echo "I: You can reach Home Assistant at:"
echo "   http://homeassistant.local"
if [ -n "$HA_IP" ]; then
    echo "   http://$HA_IP"
else
    echo "   http://<Your-Assigned-IP>"
    echo "   (The VM is still initializing. Check your router's DHCP list or run: 'virsh domifaddr haos')"
fi
echo ""
echo "I: Keep in mind that first boot can take several minutes to complete initial setup."
echo "I: Script finished successfully!"
