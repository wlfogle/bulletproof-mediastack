#!/bin/bash
# =============================================================================
# setup-openwrt-vm.sh — Self-healing OpenWrt VM provisioner for Proxmox
# =============================================================================
# Verified upstream sources (2026-05-31):
#   Image : https://downloads.openwrt.org/releases/25.12.2/targets/x86/64/
#           openwrt-25.12.2-x86-64-generic-ext4-combined-efi.img.gz
#   SHA256: 50aa03e073d48dd9a206f04503a481c6d0f84ff0b36a241d93b391269ca93f49
#   Size  : ~13.5 MB compressed / ~126 MB expanded
#
# Network topology after this script:
#   KVD21 (192.168.12.1 DHCP)
#     └── vmbr0 (Proxmox bridge, 192.168.12.242)
#           └── VM-100 WAN (eth0) ← DHCP from KVD21, gets 192.168.12.x
#                 └── VM-100 LAN (eth1) → vmbr1 (virtual, no physical port)
#                       └── 10.10.0.0/24 internal subnet for CTs/VMs
#
# CTs stay on vmbr0 until TP-Link UE300 USB NIC arrives (see docs/HARDWARE.md).
# When NIC arrives: add vmbr2 (physical), add 3rd NIC to VM-100, migrate CTs.
#
# Usage:
#   bash setup-openwrt-vm.sh          # normal run (resumes from state)
#   bash setup-openwrt-vm.sh --reset  # wipe state, start fresh
#
# Run ON TIAMAT (Proxmox host), not on laptop.
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
VMID=100
VMNAME="openwrt"
STORAGE="local-ssd"
OPENWRT_VER="25.12.2"
IMG_GZ="openwrt-${OPENWRT_VER}-x86-64-generic-ext4-combined-efi.img.gz"
IMG="openwrt-${OPENWRT_VER}-x86-64-generic-ext4-combined-efi.img"
IMG_URL="https://downloads.openwrt.org/releases/${OPENWRT_VER}/targets/x86/64/${IMG_GZ}"
IMG_SHA256="50aa03e073d48dd9a206f04503a481c6d0f84ff0b36a241d93b391269ca93f49"
WORKDIR="/var/tmp/openwrt-vm-setup"
STATE_DIR="/var/lib/openwrt-vm-setup"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOGFILE="/var/log/openwrt-vm-setup-${TIMESTAMP}.txt"

# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
bash -n "$0" || { echo "FATAL: script syntax error"; exit 1; }
if command -v shellcheck &>/dev/null; then
    shellcheck -S warning "$0" || echo "[WARN] shellcheck warnings above (non-fatal)"
fi

# ---------------------------------------------------------------------------
# ERR trap — full diagnostic dump
# ---------------------------------------------------------------------------
trap '_err_handler $LINENO "$BASH_COMMAND" $?' ERR
_err_handler() {
    local line="$1" cmd="$2" code="$3"
    {
        echo "============================================================"
        echo "ERROR at line ${line}: ${cmd} (exit ${code})"
        echo "FUNCNAME stack: ${FUNCNAME[*]:-main}"
        echo "--- df -h ---"; df -h
        echo "--- free -m ---"; free -m
        echo "--- pvesm status ---"; pvesm status 2>/dev/null || true
        echo "--- qm list ---"; qm list 2>/dev/null || true
        echo "--- last 50 lines of journal ---"
        journalctl -n 50 --no-pager 2>/dev/null || true
        echo "============================================================"
    } | tee -a "$LOGFILE"
    echo "Failure log: $LOGFILE"
}

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
[[ "$*" == *--reset* ]] && rm -rf "$STATE_DIR"
mkdir -p "$WORKDIR" "$STATE_DIR"

step_done()  { [[ -f "${STATE_DIR}/${1}.done" ]]; }
mark_done()  { touch "${STATE_DIR}/${1}.done"; }

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
log "=== PREFLIGHT ==="

# Must run as root on Proxmox host
[[ $EUID -eq 0 ]] || { log "FATAL: must run as root"; exit 1; }
command -v qm      &>/dev/null || { log "FATAL: qm not found — run on Proxmox host"; exit 1; }
command -v pvesm   &>/dev/null || { log "FATAL: pvesm not found"; exit 1; }
command -v wget    &>/dev/null || { log "FATAL: wget not found"; exit 1; }

# Disk space: need at least 2GB free in /var/tmp and storage pool
TMPFREE=$(df -k "$WORKDIR" | awk 'NR==2{print $4}')
(( TMPFREE >= 2097152 )) || { log "FATAL: less than 2GB free in /var/tmp (${TMPFREE}k)"; exit 1; }

POOLFREE=$(pvesm status | awk -v p="$STORAGE" '$1==p{print $6}')
(( POOLFREE >= 1048576 )) || { log "FATAL: less than 1GB free in ${STORAGE} pool"; exit 1; }
log "Storage: ${STORAGE} has $((POOLFREE/1024))MB free — OK"

# Reachability probe: OpenWrt download server
log "Probing downloads.openwrt.org..."
wget -q --spider --timeout=10 "https://downloads.openwrt.org/" \
    || { log "FATAL: cannot reach downloads.openwrt.org"; exit 1; }

# RAM: warn if < 512MB free
FREEMB=$(free -m | awk '/^Mem/{print $7}')
(( FREEMB >= 512 )) || log "[WARN] only ${FREEMB}MB RAM available — OpenWrt VM may start slowly"

log "Preflight OK"

# ---------------------------------------------------------------------------
# STEP 1: Add vmbr1 internal bridge
# ---------------------------------------------------------------------------
do_step_vmbr1() {
    local name="vmbr1"
    log "--- STEP 1: vmbr1 internal bridge ---"

    # verify
    if ip link show "$name" &>/dev/null; then
        log "vmbr1 already exists — skip"
        return 0
    fi

    # check interfaces file
    if grep -q "^auto vmbr1" /etc/network/interfaces; then
        log "vmbr1 in interfaces but not up — bringing up"
    else
        # execute: append vmbr1 stanza
        log "Adding vmbr1 to /etc/network/interfaces"
        cp /etc/network/interfaces "/etc/network/interfaces.bak.${TIMESTAMP}"
        cat >> /etc/network/interfaces <<'VMBR1'

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-multicast-snooping 0
    # OpenWrt VM internal LAN — no physical port, virtual only
    # CTs/VMs on this bridge get DHCP from OpenWrt (10.10.0.0/24)
VMBR1
    fi

    # bring up — try ifreload first, fall back to direct ip link
    # (ifreload may warn on orphaned post-up lines in interfaces but still works)
    local attempt
    for attempt in 1 2 3; do
        ifreload -a 2>/dev/null && break || {
            log "[WARN] ifreload attempt ${attempt} failed, retrying..."
            sleep 3
        }
    done

    # Direct fallback: create bridge without ifreload
    if ! ip link show vmbr1 &>/dev/null; then
        log "ifreload could not bring up vmbr1 — using ip link directly"
        ip link add name vmbr1 type bridge
        ip link set vmbr1 type bridge forward_delay 0
        ip link set vmbr1 type bridge stp_state 0
        ip link set vmbr1 up
    fi

    # verify
    ip link show vmbr1 &>/dev/null || { log "FATAL: vmbr1 still not up"; exit 1; }
    log "vmbr1 up OK"
}

if ! step_done "vmbr1"; then
    do_step_vmbr1
    mark_done "vmbr1"
fi

# ---------------------------------------------------------------------------
# STEP 2: Download and verify OpenWrt image
# ---------------------------------------------------------------------------
do_step_download() {
    log "--- STEP 2: Download OpenWrt ${OPENWRT_VER} ---"
    local dest="${WORKDIR}/${IMG_GZ}"

    if [[ -f "${WORKDIR}/${IMG}" ]]; then
        log "Extracted image already present — skip download"
        return 0
    fi

    if [[ ! -f "$dest" ]]; then
        log "Downloading ${IMG_URL}..."
        local attempt
        for attempt in 1 2 3; do
            wget -O "$dest" --tries=3 --timeout=60 --progress=dot:giga \
                "$IMG_URL" 2>&1 | tee -a "$LOGFILE" && break || {
                log "[WARN] Download attempt ${attempt} failed"
                rm -f "$dest"
                sleep $((attempt * 5))
                [[ $attempt -eq 3 ]] && { log "FATAL: download failed after 3 attempts"; exit 1; }
            }
        done
    else
        log "Compressed image already downloaded — verifying checksum"
    fi

    # Verify checksum
    log "Verifying SHA256..."
    local actual
    actual=$(sha256sum "$dest" | awk '{print $1}')
    if [[ "$actual" != "$IMG_SHA256" ]]; then
        log "FATAL: SHA256 mismatch! Expected: ${IMG_SHA256} Got: ${actual}"
        rm -f "$dest"
        exit 1
    fi
    log "SHA256 OK"

    # Extract
    log "Extracting ${IMG_GZ}..."
    gunzip -k "$dest"
    [[ -f "${WORKDIR}/${IMG}" ]] || { log "FATAL: extraction failed"; exit 1; }
    log "Extraction OK: ${WORKDIR}/${IMG}"
}

if ! step_done "download"; then
    do_step_download
    mark_done "download"
fi

# ---------------------------------------------------------------------------
# STEP 3: Create VM
# ---------------------------------------------------------------------------
do_step_create_vm() {
    log "--- STEP 3: Create VM ${VMID} ---"

    # Destroy stale VM if it exists but has no running state
    if qm status "$VMID" &>/dev/null; then
        local vmstate
        vmstate=$(qm status "$VMID" | awk '{print $2}')
        if [[ "$vmstate" == "running" ]]; then
            log "FATAL: VMID ${VMID} already exists and is running — aborting"
            exit 1
        fi
        log "[WARN] VMID ${VMID} exists but is ${vmstate} — destroying and recreating"
        qm destroy "$VMID" --purge 1
    fi

    log "Creating VM ${VMID} (${VMNAME})..."
    qm create "$VMID" \
        --name "$VMNAME" \
        --memory 512 \
        --cores 1 \
        --sockets 1 \
        --machine q35 \
        --bios ovmf \
        --net0 virtio,bridge=vmbr0,firewall=0 \
        --net1 virtio,bridge=vmbr1,firewall=0 \
        --agent enabled=1 \
        --serial0 socket \
        --vga serial0 \
        --onboot 1 \
        --startup order=10

    log "VM ${VMID} created OK"
}

if ! step_done "create_vm"; then
    do_step_create_vm
    mark_done "create_vm"
fi

# ---------------------------------------------------------------------------
# STEP 4: Import and attach disk
# ---------------------------------------------------------------------------
do_step_disk() {
    log "--- STEP 4: Import disk ---"

    # Check if disk already imported
    if pvesm list "$STORAGE" | grep -q "vm-${VMID}-disk"; then
        log "Disk for VM ${VMID} already in ${STORAGE} — skip import"
    else
        log "Importing ${IMG} into ${STORAGE}..."
        qm importdisk "$VMID" "${WORKDIR}/${IMG}" "$STORAGE" 2>&1 | tee -a "$LOGFILE"
    fi

    # Find the imported disk volid
    local diskid
    diskid=$(pvesm list "$STORAGE" | awk -v v="$VMID" '$5==v && /disk/{print $1; exit}')
    [[ -n "$diskid" ]] || { log "FATAL: cannot find imported disk for VM ${VMID}"; exit 1; }
    log "Disk: ${diskid}"

    # Use full volid directly — pvesm list returns "storage:diskname" already
    # Attach disk to VM as virtio0
    log "Attaching disk as virtio0 (${diskid})..."
    qm set "$VMID" --virtio0 "${diskid},discard=on"

    # EFI vars disk (OVMF state store)
    log "Adding EFI vars disk..."
    qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0"

    # Set boot order
    log "Setting boot order: virtio0..."
    qm set "$VMID" --boot order=virtio0

    log "Disk setup OK"
}

if ! step_done "disk"; then
    do_step_disk
    mark_done "disk"
fi

# ---------------------------------------------------------------------------
# STEP 5: Configure OpenWrt rootfs before first boot
# ---------------------------------------------------------------------------
do_step_configure_openwrt() {
    log "--- STEP 5: Configure OpenWrt rootfs ---"

    local diskdev="/dev/mapper/pve--ssd-vm--${VMID}--disk--0"
    local loopdev="/dev/loop10"
    local mountdir="/mnt/openwrt"

    [[ -b "$diskdev" ]] || { log "FATAL: missing VM disk device ${diskdev}"; exit 1; }
    mkdir -p "$mountdir"
    umount "$mountdir" 2>/dev/null || true
    losetup -d "$loopdev" 2>/dev/null || true
    losetup -P "$loopdev" "$diskdev"
    mount "${loopdev}p2" "$mountdir"

    log "Writing OpenWrt network config: WAN=eth0/vmbr0, LAN=eth1/vmbr1, LAN IP=10.10.0.1/24"
    cat > "${mountdir}/etc/config/network" <<'OPENWRT_NETWORK'

config interface 'loopback'
	option device 'lo'
	option proto 'static'
	list ipaddr '127.0.0.1/8'

config globals 'globals'
	option ula_prefix 'fd7f:f3ed:d3aa::/48'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth1'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	list ipaddr '10.10.0.1/24'
	option ip6assign '60'

config interface 'wan'
	option device 'eth0'
	option proto 'dhcp'

config interface 'wan6'
	option device 'eth0'
	option proto 'dhcpv6'
OPENWRT_NETWORK

    if ! grep -q "option server '192.168.12.244'" "${mountdir}/etc/config/dhcp"; then
        sed -i "/config dnsmasq/a\\\toption server '192.168.12.244'" "${mountdir}/etc/config/dhcp"
    fi

    umask 077
    if [[ ! -f /root/openwrt-root-password ]]; then
        openssl rand -base64 24 > /root/openwrt-root-password
    fi
    chmod 600 /root/openwrt-root-password
    local pass hash
    pass=$(cat /root/openwrt-root-password)
    hash=$(openssl passwd -6 "$pass")
    awk -F: -v OFS=: -v h="$hash" '$1=="root"{$2=h} {print}' "${mountdir}/etc/shadow" > "${mountdir}/etc/shadow.new"
    mv "${mountdir}/etc/shadow.new" "${mountdir}/etc/shadow"
    chmod 600 "${mountdir}/etc/shadow"

    umount "$mountdir"
    losetup -d "$loopdev"
    log "OpenWrt rootfs configured; root password saved at /root/openwrt-root-password (0600)"
}

if ! step_done "configure_openwrt"; then
    do_step_configure_openwrt
    mark_done "configure_openwrt"
fi

# ---------------------------------------------------------------------------
# STEP 6: Start VM and verify it boots
# ---------------------------------------------------------------------------
do_step_start() {
    log "--- STEP 6: Start VM ---"

    local vmstate
    vmstate=$(qm status "$VMID" | awk '{print $2}')
    if [[ "$vmstate" == "running" ]]; then
        log "VM ${VMID} already running — OK"
        return 0
    fi

    log "Starting VM ${VMID}..."
    qm start "$VMID"

    # Wait up to 60s for VM to be running
    local i
    for i in $(seq 1 12); do
        sleep 5
        vmstate=$(qm status "$VMID" | awk '{print $2}')
        [[ "$vmstate" == "running" ]] && { log "VM ${VMID} is running"; return 0; }
        log "  [${i}/12] waiting for VM to start (state=${vmstate})..."
    done

    # Heal: collect diagnostics
    log "[WARN] VM not running after 60s — checking journal"
    journalctl -u qemu-server@${VMID} -n 30 --no-pager 2>/dev/null | tee -a "$LOGFILE" || true

    vmstate=$(qm status "$VMID" | awk '{print $2}')
    [[ "$vmstate" == "running" ]] || { log "FATAL: VM ${VMID} failed to start (state=${vmstate})"; exit 1; }
}

if ! step_done "start"; then
    do_step_start
    mark_done "start"
fi

# ---------------------------------------------------------------------------
# STEP 7: Install LuCI and qemu guest agent with OpenWrt apk
# ---------------------------------------------------------------------------
do_step_install_packages() {
    log "--- STEP 7: Install LuCI and qemu-ga ---"

    ip addr add 10.10.0.254/24 dev vmbr1 2>/dev/null || true
    local i
    for i in $(seq 1 12); do
        ping -c1 -W2 10.10.0.1 &>/dev/null && break
        sleep 5
    done
    ping -c1 -W2 10.10.0.1 &>/dev/null || { log "FATAL: OpenWrt LAN 10.10.0.1 not reachable"; exit 1; }

    ssh -o StrictHostKeyChecking=no root@10.10.0.1 \
        "apk update && apk add luci qemu-ga && /etc/init.d/qemu-ga enable && /etc/init.d/qemu-ga start && /etc/init.d/uhttpd enable && /etc/init.d/uhttpd start"

    wget -q --spider --timeout=10 http://10.10.0.1/ || { log "FATAL: LuCI HTTP probe failed"; exit 1; }
    qm agent "$VMID" ping || { log "FATAL: qemu guest agent did not respond"; exit 1; }
    log "LuCI and qemu guest agent verified"
}

if ! step_done "packages"; then
    do_step_install_packages
    mark_done "packages"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
log "============================================================"
log "SUCCESS: OpenWrt VM-${VMID} is running"
log ""
log "Access serial console:"
log "  qm terminal ${VMID}"
log ""
log "OpenWrt config:"
log "  WAN: eth0 on vmbr0, DHCP from KVD21 (192.168.12.x)"
log "  LAN: eth1 on vmbr1, static 10.10.0.1/24"
log "  DNS: dnsmasq forwards to Bahamut AdGuard at 192.168.12.244"
log "  LuCI: http://10.10.0.1/"
log "  SSH: ssh root@10.10.0.1"
log "  Root password: /root/openwrt-root-password on Tiamat (0600)"
log "  Package manager: apk (OpenWrt 25.12+), not opkg"
log ""
log "Tiamat vmbr1 bridge is up — attach CTs/VMs to vmbr1 when ready."
log "TP-Link UE300 USB NIC: plug in, add vmbr2, add 3rd NIC to this VM."
log "============================================================"
