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

if ! command -v nmcli >/dev/null 2>&1; then
    echo "E: NetworkManager (nmcli) is required to configure bridge br0. Exiting."
    exit 1
fi

# Prefer an onboard/USB/PCIe physical Ethernet interface that currently has carrier (LOWER_UP)
ETH_IF=$(ip -br link | awk '$1 ~ /^(eth|end)[0-9]+$/ && $0 ~ /LOWER_UP/ {print $1; exit}')
if [ -z "$ETH_IF" ]; then
    ETH_IF=$(ip -br link | awk '$1 ~ /^(en[opxs]|eth|end)[a-zA-Z0-9_-]*$/ && $0 ~ /LOWER_UP/ {print $1; exit}')
fi
if [ -z "$ETH_IF" ]; then
    ETH_IF=$(ip -br link | awk '$1 ~ /^(eth|end)[0-9]+$/ {print $1; exit}')
fi
if [ -z "$ETH_IF" ]; then
    ETH_IF=$(ip -br link | awk '$1 ~ /^(en[opxs]|eth|end)[a-zA-Z0-9_-]*$/ {print $1; exit}')
fi

if [ -z "$ETH_IF" ]; then
    echo "E: Could not detect a physical Ethernet interface."
    echo "E: Home Assistant requires a wired network bridge for proper Layer 2 device discovery. Exiting."
    exit 1
fi

if [ "$(cat "/sys/class/net/$ETH_IF/carrier" 2>/dev/null || echo 0)" != "1" ]; then
    ip link set dev "$ETH_IF" up 2>/dev/null || true
    sleep 2
fi
if [ "$(cat "/sys/class/net/$ETH_IF/carrier" 2>/dev/null || echo 0)" != "1" ]; then
    echo "E: Physical Ethernet interface $ETH_IF has no link carrier (cable unplugged)."
    echo "E: Wi-Fi client interfaces cannot be added to a Layer 2 bridge (br0). Please connect an Ethernet cable and retry."
    exit 1
fi

bridge_healthy() {
    ip link show br0 >/dev/null 2>&1 \
        && ip link show dev "$ETH_IF" 2>/dev/null | grep -q "master br0" \
        && ip -4 -br addr show dev br0 2>/dev/null | grep -v '169\.254\.' | grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}'
}

if bridge_healthy; then
    echo "I: Healthy bridge br0 with $ETH_IF enslaved detected. Using br0."
else
    echo "I: Configuring bridge br0 with physical interface $ETH_IF..."
    ETH_MAC=$(cat "/sys/class/net/$ETH_IF/address")

    # Capture existing active profile IPv4 settings on $ETH_IF (to preserve static IPs if configured)
    ACTIVE_ETH_UUID=$(nmcli -t -f UUID,DEVICE connection show --active | awk -F: -v dev="$ETH_IF" '$2 == dev {print $1; exit}')
    IPV4_METHOD="auto"
    IPV4_ADDRS=""
    IPV4_GW=""
    IPV4_DNS=""
    IPV4_SEARCH=""
    if [ -n "$ACTIVE_ETH_UUID" ]; then
        ACTIVE_TYPE=$(nmcli -g connection.type connection show uuid "$ACTIVE_ETH_UUID" 2>/dev/null || true)
        if [ "$ACTIVE_TYPE" = "802-3-ethernet" ]; then
            IPV4_METHOD=$(nmcli -g ipv4.method connection show uuid "$ACTIVE_ETH_UUID" 2>/dev/null || echo "auto")
            if [ "$IPV4_METHOD" = "manual" ]; then
                IPV4_ADDRS=$(nmcli -g ipv4.addresses connection show uuid "$ACTIVE_ETH_UUID" 2>/dev/null | tr -d '\\' || true)
                IPV4_GW=$(nmcli -g ipv4.gateway connection show uuid "$ACTIVE_ETH_UUID" 2>/dev/null | tr -d '\\' || true)
                IPV4_DNS=$(nmcli -g ipv4.dns connection show uuid "$ACTIVE_ETH_UUID" 2>/dev/null | tr -d '\\' || true)
                IPV4_SEARCH=$(nmcli -g ipv4.dns-search connection show uuid "$ACTIVE_ETH_UUID" 2>/dev/null | tr -d '\\' || true)
            fi
        fi
    fi

    # Delete pre-existing/broken br0 or br0-slave profiles to avoid duplicate UUIDs
    nmcli -t -f UUID,NAME connection show | awk -F: '$2 == "br0" || $2 == "br0-slave" {print $1}' | xargs -r -n1 nmcli connection delete uuid 2>/dev/null || true

    # Disable autoconnect on competing Ethernet profiles (including unbound profiles like "Wired connection 1")
    while IFS=: read -r uuid type dev; do
        [ -z "$uuid" ] && continue
        if [ "$type" = "802-3-ethernet" ]; then
            ifname=$(nmcli -g connection.interface-name connection show uuid "$uuid" 2>/dev/null || true)
            if [ "$dev" = "$ETH_IF" ] || [ "$ifname" = "$ETH_IF" ] || [ -z "$ifname" ]; then
                nmcli connection modify uuid "$uuid" connection.autoconnect no 2>/dev/null || true
            fi
        fi
    done < <(nmcli -t -f UUID,TYPE,DEVICE connection show)

    # Create br0 (STP disabled to avoid 30s forwarding delay; preserve physical MAC)
    if [ "$IPV4_METHOD" = "manual" ] && [ -n "$IPV4_ADDRS" ]; then
        BR0_ARGS=(
            ipv4.method manual
            ipv4.addresses "$IPV4_ADDRS"
        )
        [ -n "$IPV4_GW" ] && BR0_ARGS+=(ipv4.gateway "$IPV4_GW")
        [ -n "$IPV4_DNS" ] && BR0_ARGS+=(ipv4.dns "$IPV4_DNS")
        [ -n "$IPV4_SEARCH" ] && BR0_ARGS+=(ipv4.dns-search "$IPV4_SEARCH")
    else
        BR0_ARGS=(
            ipv4.method auto
            ipv4.dhcp-client-id mac
        )
    fi

    nmcli connection add type bridge con-name br0 ifname br0 \
        bridge.stp no \
        connection.autoconnect yes \
        connection.autoconnect-slaves 1 \
        ethernet.cloned-mac-address "$ETH_MAC" \
        "${BR0_ARGS[@]}"

    nmcli connection add type bridge-slave con-name br0-slave ifname "$ETH_IF" master br0 \
        connection.autoconnect yes

    # Start br0 non-blocking so it doesn't stall waiting for DHCP before br0-slave attaches,
    # then activate br0-slave (which hands over $ETH_IF from any old profile).
    nmcli --wait 0 connection up br0
    nmcli connection up br0-slave

    # Wait up to 30s for br0 to obtain a non-APIPA IPv4 address and confirm $ETH_IF is enslaved
    BR_WAIT=0
    while [ "$BR_WAIT" -lt 30 ]; do
        if bridge_healthy; then
            break
        fi
        sleep 1
        BR_WAIT=$((BR_WAIT + 1))
    done

    if ! bridge_healthy; then
        echo "E: Bridge br0 failed to come up with $ETH_IF enslaved and an IPv4 address."
        echo "E: Run 'nmcli device status' and 'ip -br addr' to inspect the network state."
        exit 1
    fi
    echo "I: Bridge br0 is active with $ETH_IF enslaved."
fi

# Step 3: Download and prepare HAOS Generic aarch64 image
if [ -f /var/lib/libvirt/images/haos.qcow2 ] || virsh dominfo haos >/dev/null 2>&1; then
    echo "I: Step 3: Existing HAOS disk/VM detected. Skipping image download and resize."
else
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
fi

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
    virsh start haos >/dev/null 2>&1 || true
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
      --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
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
MAX_WAIT_SECONDS=120
START_TIME=$(date +%s)
SPIN_CHARS='|/-\'
SPIN_INDEX=0

# Ensure cursor is restored if interrupted
trap 'tput cnorm 2>/dev/null || true' EXIT INT TERM
tput civis 2>/dev/null || true

while true; do
    HA_IP=$(virsh domifaddr haos --source agent 2>/dev/null \
        | awk '{
            if ($1 != "-" && $1 != "") iface = $1
            if (iface ~ /^(en|eth)/ && $3 == "ipv4") print $4
        }' \
        | cut -d'/' -f1 \
        | grep -vE '^(127\.|169\.254\.|172\.30\.)' \
        | head -n 1 || true)
    if [ -z "$HA_IP" ]; then
        HA_IP=$(virsh domifaddr haos --source arp 2>/dev/null \
            | awk '$3 == "ipv4" {print $4}' \
            | cut -d'/' -f1 \
            | grep -vE '^(127\.|169\.254\.)' \
            | head -n 1 || true)
    fi
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
    echo "   (The VM is still initializing. Check your router's DHCP list or run: 'sudo virsh domifaddr haos --source agent')"
fi
echo ""
echo "I: Keep in mind that first boot can take several minutes to complete initial setup."
echo "I: Script finished successfully!"
