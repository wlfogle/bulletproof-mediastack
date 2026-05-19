Follow these steps to enable SPICE on Proxmox VE 9 and use a SPICE client to connect to VMs.

Prerequisites

Proxmox VE 9 installed and updated.
Root (or sudo) access to the Proxmox host.
VM using QEMU/KVM (not LXC).
Update host packages Run on the Proxmox host:


apt update && apt full-upgrade -y
Install spice-server components (host-side) Proxmox includes SPICE support in qemu; ensure spice-server and related packages are installed:


apt install -y spice-vdagent spice-client-gtk
Notes:

spice-vdagent runs inside the guest (see step 4).
spice-client-gtk is a local SPICE viewer package (optional on the host).
Configure the VM to use SPICE (Proxmox web UI)
In the Proxmox web UI, select the VM → Hardware.
Remove or change the Display device to "SPICE".
Click "Add" → "Display" (or edit existing) → choose "SPICE".
Add a QXL or virtio-gpu video device if needed:
Hardware → Add → "Video Card" → choose "QXL" (or "virtio" if using newer drivers).
Add a serial/USB or tablet input device if you want better mouse integration (optional).
Or configure via qm CLI:



qm set <vmid> --vga qxl
qm set <vmid> --display spice
Install SPICE guest agent and drivers inside the VM
For Linux guests (Debian/Ubuntu):


apt update
apt install -y spice-vdagent qemu-guest-agent
systemctl enable --now spice-vdagent qemu-guest-agent
Install QXL/virtio video drivers if the distro needs them (most modern kernels include them).
For Windows guests:
Install the SPICE guest tools and QXL/virtio drivers via the virtio ISO or Spice guest tools ISO:
Attach the virtio ISO / Spice tools ISO to the VM (Hardware → CD/DVD Drive → use ISO).
Inside Windows, run the drivers installer (look for qxl, virtio, and spice-guest-tools).
Install spice-guest-tools (includes spice-vdagent) and reboot.
Open VNC/SPICE port (if necessary)
Proxmox’s built-in SPICE proxy handles connections via the web UI; you usually do NOT need to open extra firewall ports on the host.
If you plan to connect directly with an external SPICE client, ensure the appropriate ports are allowed and configure TLS if exposing remotely (generally not recommended).
Connect with the Proxmox web UI
With the VM running, click "Console" → choose "SPICE" (if available). The browser will open the SPICE session via the built-in proxy.
Or use "SPICE" → "Download Spice file" and open it with a local spice client (virt-viewer or remote-viewer).
Connect with a local SPICE client
Install virt-viewer/remote-viewer:
On Linux: apt install -y virt-viewer
On Windows: download virt-viewer or use remote-viewer from the virt-viewer package.
Use the downloaded .vv or .spice file from Proxmox or connect directly:


remote-viewer /path/to/file.spice
Troubleshooting
Black screen: ensure guest has QXL/virtio video driver installed and spice-vdagent running.
Mouse pointer issues: add a USB tablet device or install spice-vdagent in the guest.
No SPICE option: confirm VM uses qemu/KVM (not LXC) and that display is set to spice (qm config shows display: spice).
Check guest agent status inside guest: systemctl status spice-vdagent qemu-guest-agent.
Check VM config: qm config <vmid> — look for vga: qxl and display: spice.
Quick CLI summary



apt update && apt full-upgrade -y
apt install -y spice-client-gtk spice-vdagent
qm set <vmid> --vga qxl
qm set <vmid> --display spice
# In Linux guest:
apt install -y spice-vdagent qemu-guest-agent
systemctl enable --now spice-vdagent qemu-guest-agent
If you want, tell me your VM OS and I’ll give specific guest installation steps.

Steps for each VM
Proxmox host (common)
Update host:


apt update && apt full-upgrade -y
Set VM display and video (replace ):


qm set <vmid> --display spice
qm set <vmid> --vga qxl
(If qxl not supported for a VM, use virtio if available.)

Home Assistant OS VM
Home Assistant OS is appliance-like and usually does NOT include spice guest agents or QXL drivers; SPICE will likely show only a framebuffer and limited input support. Recommended approach:
Try setting display to SPICE and vga to qxl as above.
Start VM and open SPICE console from Proxmox web UI; expect limited integration (no spice-vdagent features).
If you need full GUI access to Home Assistant, use its web UI (http(s) to HA) rather than SPICE. For troubleshooting console, use SPICE/VNC only for kernel/boot access.
Windows 11 VM
Attach virtio and Spice guest tools ISOs (from Proxmox node ISO store or download virtio drivers and spice guest tools).
Set display/video:


qm set <vmid> --display spice
qm set <vmid> --vga qxl
In Windows:
Mount the virtio ISO and install QXL/virtio GPU driver, virtio drivers (if needed), and qemu-guest-agent.
Install Spice Guest Tools (spice-guest-tools) which includes spice-vdagent.
Reboot Windows.
Confirm services running (in Windows Services): spice agent / qemu-guest-agent.
Connect:
Use Proxmox web UI → Console → SPICE, or Download the .vv/.spice file and open with remote-viewer/virt-viewer.
Notes / Troubleshooting
Home Assistant OS likely won’t gain spice-vdagent functionality — use HA web UI for normal use.
For Windows black screen or resolution issues, ensure QXL/virtio driver installed, then reinstall Spice tools and reboot.
To use local client: install virt-viewer/remote-viewer and open downloaded .spice file.
Check VM config: qm config <vmid> — verify display: spice and vga: qxl.
If you want, give VM IDs and I’ll output the exact qm commands and the filenames/ISOs to attach for Windows.

windows is vm-901, haos is vm-990

Commands to run on Proxmox host
Replace placeholders as needed; run as root.

Set display and video:



qm set 901 --display spice
qm set 901 --vga qxl

qm set 990 --display spice
qm set 990 --vga qxl
(If qxl errors for HAOS, use --vga virtio instead:



qm set 990 --vga virtio
)

Windows 11 (vm-901) — install guests/tools
Attach ISOs (use your local ISO store path in Proxmox GUI or CLI). Example CLI if ISOs are in /var/lib/vz/template/iso/:


qm set 901 --cdrom /var/lib/vz/template/iso/virtio-win.iso
qm set 901 --ide2 local:iso/win11-install.iso,media=cdrom    # if installing OS from ISO
Boot VM, then inside Windows mount virtio ISO and install:
QXL/virtio GPU driver (from virtio ISO)
VirtIO storage/network drivers (if needed)
qemu-guest-agent (from virtio)
Download and install Spice Guest Tools for Windows (spice-guest-tools); if you have the spice tools ISO, attach and run installer.
Reboot Windows.
Verify services: QEMU Guest Agent and Spice Agent running.
Connect via Proxmox Console → SPICE or download .spice/.vv and open with remote-viewer.
Home Assistant OS (vm-990) — notes and minimal steps
HAOS is appliance-like and generally does not include spice-vdagent; SPICE will give basic framebuffer only.
Set to SPICE (done above) and start VM. Use SPICE only for kernel/boot console or troubleshooting.
For regular use, access Home Assistant via its web UI (http(s) to the HA IP).
Optional: install spice client on your machine
Linux: apt install virt-viewer then open downloaded .spice file:


remote-viewer /path/to/file.spice
Windows: install virt-viewer / remote-viewer and open the .vv/.spice file from Proxmox.
If you want, I can generate the exact qm set commands to attach a specific virtio or spice ISO file — tell me the ISO filenames or where they are stored.

fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso, fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-gt-x64.msi, and fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-guest-tools.exe


Run these on the Proxmox host (adjust ISO paths to where you saved them):

Upload or download the files to the Proxmox node ISO store (example path /var/lib/vz/template/iso/):
virtio ISO:


wget -O /var/lib/vz/template/iso/virtio-win-0.1.285.iso "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"
(Optional) copy the two Windows installers if you want them available on the host:


wget -O /var/lib/vz/template/iso/virtio-win-gt-x64.msi "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-gt-x64.msi"
wget -O /var/lib/vz/template/iso/virtio-win-guest-tools.exe "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-guest-tools.exe"
Configure VM display/video:


qm set 901 --vga qxl
qm set 990 --vga qxl
# if qxl errors for HAOS:
qm set 990 --vga virtio

Enable SPICE and configure listen/port (example minimal):



qm set 901 --spice 1
qm set 990 --spice 1

Optional: set SPICE TLS off (for LAN/testing) and request display params:



qm set 901 --spice 1 --spice_tls 0 --args "-vga qxl"
(If --spice_tls not accepted, skip it; use the defaults.)

Verify config:



qm config 901
qm config 990

Attach virtio ISO to Windows VM (vm-901) so you can install drivers/tools:


qm set 901 --cdrom local:iso/virtio-win-0.1.285.iso
(If you already have a Windows installer CD on cdrom, use --ide2 instead: qm set 901 --ide2 local:iso/virtio-win-0.1.285.iso,media=cdrom)

Inside Windows 11 VM:
Open the mounted virtio CD in Explorer.
Run virtio-win-gt-x64.msi (or run virtio-win-guest-tools.exe) to install QXL/virtio drivers and QEMU guest agent.
If you prefer installers from the host ISOs use the ones you downloaded; otherwise run the installer from the ISO path (it contains the installers under guest-tools/ or similar).
Reboot Windows.
Verify services in Windows: QEMU Guest Agent and Spice Guest Agent running. Then connect with Proxmox SPICE console or download .spice and open with remote-viewer.
Home Assistant OS (vm-990): after setting display to SPICE and vga, start VM — HAOS normally won’t have spice-vdagent, so expect basic framebuffer only and use HA web UI for regular access.
