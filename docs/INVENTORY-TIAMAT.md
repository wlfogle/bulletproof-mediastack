# Tiamat Inventory

> **Historical/reference note:** This document may describe an older pre-NexusOS or pre-Riven architecture. Current live source of truth is `docs/NETWORKING.md`, `docs/NEXUSOS-COMPONENT.md`, and `README.md`. WireGuard, wg-easy, CT-100/CT-101, Traefik, Authentik, zurg, rclone, Docker-first Bahamut, and old multi-CT *arr flows are not active unless a current doc explicitly says otherwise.

Generated 2026-05-01T17:43:34Z by `bulletproof-mediastack/scripts` snapshot of `pct config` / `qm config` / `pvesm status`.

Bahamut (Pi 4) is not included; it's separately managed and unaffected by this stack.

## Storage pools
```
Name             Type     Status     Total (KiB)      Used (KiB) Available (KiB)        %
hdd-ct            dir     active      1547051236      1186621864       281769788   76.70%
local             dir     active        98497780        30098324        63349908   30.56%
local-lvm     lvmthin     active      1793392640      1460718305       332674334   81.45%
```

## LXC containers — overview
```
VMID       Status     Lock         Name                
100        running                 wireguard           
101        running                 wg-proxy            
102        stopped                 flaresolverr        
103        running                 traefik             
104        running                 vaultwarden         
105        running                 valkey              
106        running                 postgresql          
107        running                 authentik           
108        running                 flaresolverr        
109        stopped                 byparr              
110        running                 pulse               
111        running                 pulse               
112        running                 byparr              
200        running                 alexa-media-bridge  
210        running                 prowlarr            
211        stopped                 jackett             
212        running                 qbittorrent         
213        running                 rdtclient           
214        running                 sonarr              
215        running                 radarr              
216        running                 decluttarr          
217        stopped                 readarr             
218        stopped                 lidarr              
221        stopped                 mylar3              
230        stopped                 plex                
231        running                 jellyfin            
232        stopped                 audiobookshelf      
233        stopped                 calibre-web         
234        running                 threadfin           
235        running                 dispatcharr         
240        stopped                 bazarr              
241        stopped                 overseerr           
242        running                 jellyseerr          
244        stopped                 tautulli            
245        running                 recyclarr           
247        running                 jellystat           
248        running                 uptime-kuma         
275        running                 homarr              
278        stopped                 crowdsec            
279        running                 tailscale           
280        stopped                 retroarch-web       
300        running                 mediastack          
900        stopped                 ziggy
```

## QEMU VMs — overview
```
VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID       
       901 windows-gaming       stopped    4096             300.00 0         
       990 haos17-1             running    2048              32.00 34817
```

## LXC containers — full configs
### CT-100 `wireguard` — running
- **IP**: `192.168.12.100/24`
- **Resources**: 1 cores, 768 MB RAM, 256 MB swap
- **Rootfs**: `local-lvm:vm-100-disk-0,size=4G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: wireguard
memory: 768
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:C1:B5:F4,ip=192.168.12.100/24,type=veth
onboot: 1
ostype: alpine
rootfs: local-lvm:vm-100-disk-0,size=4G
startup: order=1,up=30,down=60
swap: 256
lxc.cgroup.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net dev/net none bind,create=dir
```
</details>

### CT-101 `wg-proxy` — running
- **IP**: `192.168.12.101/24`
- **Resources**: 1 cores, 768 MB RAM, 256 MB swap
- **Rootfs**: `local-lvm:vm-101-disk-0,size=4G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1,keyctl=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1,keyctl=1
hostname: wg-proxy
memory: 768
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:C3:34:8B,ip=192.168.12.101/24,type=veth
onboot: 1
ostype: alpine
rootfs: local-lvm:vm-101-disk-0,size=4G
startup: order=2,up=30,down=60
swap: 256
lxc.cgroup.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net dev/net none bind,create=dir
lxc.apparmor.profile: unconfined
lxc.mount.auto: proc:rw sys:rw
```
</details>

### CT-102 `flaresolverr` — stopped
- **IP**: `192.168.12.102/24`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-102-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1,keyctl=1,mknod=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1,keyctl=1,mknod=1
hostname: flaresolverr
memory: 2048
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:73:19:23,ip=192.168.12.102/24,type=veth
onboot: 0
ostype: debian
parent: vzdump
rootfs: local-lvm:vm-102-disk-0,size=8G
startup: order=0,up=20,down=30
swap: 512
lxc.apparmor.profile: unconfined
lxc.cap.drop: 
lxc.cgroup2.devices.allow: a
lxc.mount.auto: proc:rw sys:rw cgroup:rw
```
</details>

### CT-103 `traefik` — running
- **IP**: `192.168.12.103/24`
- **Resources**: 2 cores, 1024 MB RAM, 256 MB swap
- **Rootfs**: `local-lvm:vm-103-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/opt/traefik-logs,mp=/var/log/traefik`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: traefik
memory: 1024
mp0: /opt/traefik-logs,mp=/var/log/traefik
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:D8:4A:7F,ip=192.168.12.103/24,type=veth
onboot: 1
ostype: alpine
rootfs: local-lvm:vm-103-disk-0,size=8G
startup: order=5,up=15,down=30
swap: 256
unprivileged: 1
```
</details>

### CT-104 `vaultwarden` — running
- **IP**: `192.168.12.104/24`
- **Resources**: 2 cores, 512 MB RAM, 2048 MB swap
- **Rootfs**: `local-lvm:vm-104-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: vaultwarden
memory: 512
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:93:4D:63,ip=192.168.12.104/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-104-disk-0,size=8G
startup: order=5,up=15,down=30
swap: 2048
unprivileged: 1
```
</details>

### CT-105 `valkey` — running
- **IP**: `192.168.12.105/24`
- **Resources**: 2 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-105-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: valkey
memory: 1024
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:56:63:82,ip=192.168.12.105/24,type=veth
onboot: 1
ostype: alpine
rootfs: local-lvm:vm-105-disk-0,size=8G
startup: order=4,up=15,down=30
swap: 512
unprivileged: 1
```
</details>

### CT-106 `postgresql` — running
- **IP**: `192.168.12.106/24`
- **Resources**: 2 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-106-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: postgresql
memory: 1024
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:4C:A3:AF,ip=192.168.12.106/24,type=veth
onboot: 1
ostype: alpine
rootfs: local-lvm:vm-106-disk-0,size=8G
startup: order=4,up=15,down=30
swap: 512
unprivileged: 1
```
</details>

### CT-107 `authentik` — running
- **IP**: `192.168.12.107/24`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-107-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: authentik
memory: 2048
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:D8:55:A8,ip=192.168.12.107/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-107-disk-0,size=8G
startup: order=5,up=20,down=30
swap: 512
unprivileged: 1
```
</details>

### CT-108 `flaresolverr` — running
- **IP**: `192.168.12.108/24`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-108-disk-0,size=8G`
- **Privileged**: yes
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: flaresolverr
memory: 2048
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:7D:8B:81,ip=192.168.12.108/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-108-disk-0,size=8G
swap: 512
unprivileged: 0
```
</details>

### CT-109 `byparr` — stopped
- **IP**: `192.168.12.109/24`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-109-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1,keyctl=1,fuse=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
description: <div align='center'>%0A  <a href='https%3A//community-scripts.org' target='_blank' rel='noopener noreferrer'>%0A    <img src='https%3A//raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo-81x112.png' alt='Logo' style='width%3A81px;height%3A112px;'/>%0A  </a>%0A%0A  <h2 style='font-size%3A 24px; margin%3A 20px 0;'>Byparr LXC</h2>%0A%0A  <p style='margin%3A 16px 0;'>%0A    <a href='https%3A//community-scripts.org/donate' target='_blank' rel='noopener noreferrer'>%0A      <img src='https%3A//img.shields.io/badge/%E2%9D%A4%EF%B8%8F-Sponsoring%2520%2526%2520Donations-FF5E5B' alt='Sponsoring and donations' />%0A    </a>%0A  </p>%0A%0A  <p style='margin%3A 12px 0;'>%0A    <a href='https%3A//community-scripts.org/scripts/byparr' target='_blank' rel='noopener noreferrer'>%0A      <img src='https%3A//img.shields.io/badge/%F0%9F%93%A6-Open%2520Script%2520Page-00617f' alt='Open script page' />%0A    </a>%0A  </p>%0A%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-github fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>GitHub</a>%0A  </span>%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-comments fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>Discussions</a>%0A  </span>%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-exclamation-circle fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE/issues' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>Issues</a>%0A  </span>%0A</div>%0A
features: nesting=1,keyctl=1,fuse=1
hostname: byparr
memory: 2048
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:6C:B6:97,ip=192.168.12.109/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-109-disk-0,size=8G
swap: 512
tags: community-script;proxy
timezone: America/New_York
unprivileged: 1
```
</details>

### CT-110 `pulse` — running
- **IP**: `192.168.12.251/24`
- **Resources**: 1 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-110-disk-0,size=4G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1,keyctl=1,fuse=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
description: FileBrowser is reachable at%3A http%3A//192.168.12.251%3A8183%0A
features: nesting=1,keyctl=1,fuse=1
hostname: pulse
memory: 1024
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:E0:78:C6,ip=192.168.12.251/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-110-disk-0,size=4G
swap: 512
tags: community-script;monitoring;proxmox
timezone: America/New_York
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```
</details>

### CT-111 `pulse` — running
- **IP**: `192.168.12.251/24`
- **Resources**: 1 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-111-disk-0,size=4G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1,keyctl=1,fuse=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1,keyctl=1,fuse=1
hostname: pulse
memory: 1024
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:E0:78:C6,ip=192.168.12.251/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-111-disk-0,size=4G
swap: 512
tags: community-script;monitoring;proxmox
timezone: America/New_York
unprivileged: 1
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```
</details>

### CT-112 `byparr` — running
- **IP**: `192.168.12.109/24`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-112-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1,keyctl=1,fuse=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
description: <div align='center'>%0A  <a href='https%3A//community-scripts.org' target='_blank' rel='noopener noreferrer'>%0A    <img src='https%3A//raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo-81x112.png' alt='Logo' style='width%3A81px;height%3A112px;'/>%0A  </a>%0A%0A  <h2 style='font-size%3A 24px; margin%3A 20px 0;'>Byparr LXC</h2>%0A%0A  <p style='margin%3A 16px 0;'>%0A    <a href='https%3A//community-scripts.org/donate' target='_blank' rel='noopener noreferrer'>%0A      <img src='https%3A//img.shields.io/badge/%E2%9D%A4%EF%B8%8F-Sponsoring%2520%2526%2520Donations-FF5E5B' alt='Sponsoring and donations' />%0A    </a>%0A  </p>%0A%0A  <p style='margin%3A 12px 0;'>%0A    <a href='https%3A//community-scripts.org/scripts/byparr' target='_blank' rel='noopener noreferrer'>%0A      <img src='https%3A//img.shields.io/badge/%F0%9F%93%A6-Open%2520Script%2520Page-00617f' alt='Open script page' />%0A    </a>%0A  </p>%0A%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-github fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>GitHub</a>%0A  </span>%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-comments fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>Discussions</a>%0A  </span>%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-exclamation-circle fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE/issues' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>Issues</a>%0A  </span>%0A</div>%0A
features: nesting=1,keyctl=1,fuse=1
hostname: byparr
memory: 2048
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:6C:B6:97,ip=192.168.12.109/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-112-disk-0,size=8G
swap: 512
tags: community-script;proxy
timezone: America/New_York
```
</details>

### CT-200 `alexa-media-bridge` — running
- **IP**: `192.168.12.200/24`
- **Resources**: 2 cores, 512 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-200-disk-0,size=16G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1,keyctl=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1,keyctl=1
hostname: alexa-media-bridge
memory: 512
nameserver: 192.168.12.244
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:30:1C:C2,ip=192.168.12.200/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-200-disk-0,size=16G
startup: order=10,up=5,down=10
swap: 512
```
</details>

### CT-210 `prowlarr` — running
- **IP**: `192.168.12.210/24`
- **Resources**: 2 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-210-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: prowlarr
memory: 1024
mp0: /mnt/hdd,mp=/data
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:56:9F:78,ip=192.168.12.210/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-210-disk-0,size=8G
startup: order=6,up=20,down=30
swap: 512
unprivileged: 1
```
</details>

### CT-211 `jackett` — stopped
- **IP**: `192.168.12.211/24`
- **Resources**: 1 cores, 512 MB RAM, 512 MB swap
- **Rootfs**: `hdd-ct:211/vm-211-disk-0.raw,size=2G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1,keyctl=1,fuse=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1,keyctl=1,fuse=1
hostname: jackett
memory: 512
mp0: /mnt/hdd,mp=/data
nameserver: 192.168.12.244
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=bc:24:11:c1:bf:d1,ip=192.168.12.211/24,type=veth
onboot: 0
ostype: debian
rootfs: hdd-ct:211/vm-211-disk-0.raw,size=2G
startup: order=6,up=20,down=20
swap: 512
tags: community-script;torrent
timezone: America/New_York
unprivileged: 1
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```
</details>

### CT-212 `qbittorrent` — running
- **IP**: `192.168.12.212/24`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-212-disk-0,size=16G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: qbittorrent
memory: 2048
mp0: /mnt/hdd,mp=/data
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:96:06:E2,ip=192.168.12.212/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-212-disk-0,size=16G
startup: order=6,up=20,down=30
swap: 512
unprivileged: 1
```
</details>

### CT-213 `rdtclient` — running
- **IP**: `192.168.12.213/24`
- **Resources**: 2 cores, 1024 MB RAM, 1024 MB swap
- **Rootfs**: `local-lvm:vm-213-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1,keyctl=1,fuse=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1,keyctl=1,fuse=1
hostname: rdtclient
memory: 1024
mp0: /mnt/hdd,mp=/data
nameserver: 192.168.12.1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:8B:4C:8B,ip=192.168.12.213/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-213-disk-0,size=8G
startup: order=4,up=20
swap: 1024
tags: community-script;debrid
timezone: America/New_York
unprivileged: 1
```
</details>

### CT-214 `sonarr` — running
- **IP**: `192.168.12.214/24`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-214-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: sonarr
memory: 2048
mp0: /mnt/hdd,mp=/data
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:94:D9:FE,ip=192.168.12.214/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-214-disk-0,size=8G
startup: order=7,up=15,down=20
swap: 512
unprivileged: 1
```
</details>

### CT-215 `radarr` — running
- **IP**: `192.168.12.225/24`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-215-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`
  - `mp1=/mnt/realdebrid,mp=/mnt/remote/realdebrid`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: radarr
memory: 2048
mp0: /mnt/hdd,mp=/data
mp1: /mnt/realdebrid,mp=/mnt/remote/realdebrid
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:2A:83:BB,ip=192.168.12.225/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-215-disk-0,size=8G
startup: order=7,up=15,down=20
swap: 512
unprivileged: 1
```
</details>

### CT-216 `decluttarr` — running
- **IP**: `192.168.12.216/24`
- **Resources**: 1 cores, 256 MB RAM, 256 MB swap
- **Rootfs**: `local-lvm:vm-216-disk-0,size=2G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: decluttarr
memory: 256
nameserver: 8.8.8.8 1.1.1.1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:B2:DF:C7,ip=192.168.12.216/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-216-disk-0,size=2G
swap: 256
unprivileged: 1
```
</details>

### CT-217 `readarr` — stopped
- **IP**: `192.168.12.217/24`
- **Resources**: 2 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-217-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: readarr
memory: 1024
mp0: /mnt/hdd,mp=/data
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:F7:6F:18,ip=192.168.12.217/24,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-217-disk-0,size=8G
startup: order=7,up=15,down=20
swap: 512
unprivileged: 1
```
</details>

### CT-218 `lidarr` — stopped
- **IP**: `192.168.12.218/24`
- **Resources**: 2 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-218-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: lidarr
memory: 1024
mp0: /mnt/hdd,mp=/data
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:DE:FD:A9,ip=192.168.12.218/24,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-218-disk-0,size=8G
startup: order=7,up=15,down=20
swap: 512
unprivileged: 1
```
</details>

### CT-221 `mylar3` — stopped
- **IP**: `192.168.12.221/24`
- **Resources**: 2 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-221-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: mylar3
memory: 1024
mp0: /mnt/hdd,mp=/data
nameserver: 192.168.12.244
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:43:6D:09,ip=192.168.12.221/24,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-221-disk-0,size=8G
startup: order=7,up=15,down=15
swap: 512
unprivileged: 1
```
</details>

### CT-230 `plex` — stopped
- **IP**: `192.168.12.230/24`
- **Resources**: 2 cores, 8192 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-230-disk-0,size=32G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: plex
memory: 8192
mp0: /mnt/hdd,mp=/data
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:CE:A1:AA,ip=192.168.12.230/24,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-230-disk-0,size=32G
startup: order=8,up=15,down=20
swap: 512
unprivileged: 1
```
</details>

### CT-231 `jellyfin` — running
- **IP**: `192.168.12.231/24`
- **Resources**: 4 cores, 8192 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-231-disk-0,size=16G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd,mp=/data`
  - `mp1=/mnt/realdebrid,mp=/mnt/remote/realdebrid`

<details><summary>full config</summary>

```
arch: amd64
cores: 4
features: nesting=1
hostname: jellyfin
memory: 8192
mp0: /mnt/hdd,mp=/data
mp1: /mnt/realdebrid,mp=/mnt/remote/realdebrid
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:2A:08:31,ip=192.168.12.231/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-231-disk-0,size=16G
startup: order=8,up=15,down=20
swap: 512
unprivileged: 1
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
```
</details>

### CT-232 `audiobookshelf` — stopped
- **IP**: `192.168.12.232/24`
- **Resources**: 2 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-232-disk-0,size=8G`
- **Privileged**: yes
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd/media/audiobooks,mp=/audiobooks`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: audiobookshelf
memory: 1024
mp0: /mnt/hdd/media/audiobooks,mp=/audiobooks
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:D9:20:90,ip=192.168.12.232/24,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-232-disk-0,size=8G
startup: order=8,up=10,down=20
swap: 512
unprivileged: 0
```
</details>

### CT-233 `calibre-web` — stopped
- **IP**: `192.168.12.233/24`
- **Resources**: 1 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-233-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd/media/books,mp=/books`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: calibre-web
memory: 1024
mp0: /mnt/hdd/media/books,mp=/books
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:8B:0F:33,ip=192.168.12.233/24,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-233-disk-0,size=8G
startup: order=8,up=10,down=20
swap: 512
unprivileged: 1
```
</details>

### CT-234 `threadfin` — running
- **IP**: `192.168.12.234/24`
- **Resources**: 1 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-234-disk-0,size=4G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: threadfin
memory: 1024
nameserver: 8.8.8.8 1.1.1.1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:A9:1B:AC,ip=192.168.12.234/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-234-disk-0,size=4G
swap: 512
unprivileged: 1
```
</details>

### CT-235 `dispatcharr` — running
- **IP**: `192.168.12.235/24`
- **Resources**: 2 cores, 512 MB RAM, 1024 MB swap
- **Rootfs**: `local-lvm:vm-235-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: dispatcharr
memory: 512
nameserver: 8.8.8.8 1.1.1.1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:22:62:46,ip=192.168.12.235/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-235-disk-0,size=8G
swap: 1024
unprivileged: 1
```
</details>

### CT-240 `bazarr` — stopped
- **IP**: `n/a`
- **Resources**: 1 cores, 512 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-240-disk-0,size=8G`
- **Privileged**: yes
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd/media,mp=/data/media`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: bazarr
memory: 512
mp0: /mnt/hdd/media,mp=/data/media
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:E1:A9:20,ip=dhcp,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-240-disk-0,size=8G
startup: order=9,up=10,down=20
swap: 512
unprivileged: 0
```
</details>

### CT-241 `overseerr` — stopped
- **IP**: `n/a`
- **Resources**: 1 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-241-disk-0,size=8G`
- **Privileged**: yes
- **Onboot**: no
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: overseerr
memory: 1024
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:F4:22:CF,ip=dhcp,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-241-disk-0,size=8G
startup: order=9,up=10,down=20
swap: 512
unprivileged: 0
```
</details>

### CT-242 `jellyseerr` — running
- **IP**: `192.168.12.151/24`
- **Resources**: 4 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-242-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 4
features: nesting=1
hostname: jellyseerr
memory: 1024
nameserver: 192.168.12.244
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:B3:6D:FF,ip=192.168.12.151/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-242-disk-0,size=8G
startup: order=9,up=10,down=20
swap: 512
```
</details>

### CT-244 `tautulli` — stopped
- **IP**: `n/a`
- **Resources**: 1 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-244-disk-0,size=8G`
- **Privileged**: yes
- **Onboot**: no
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: tautulli
memory: 1024
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:18:FC:DF,ip=dhcp,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-244-disk-0,size=8G
startup: order=9,up=10,down=20
swap: 512
unprivileged: 0
```
</details>

### CT-245 `recyclarr` — running
- **IP**: `192.168.12.245/24`
- **Resources**: 1 cores, 512 MB RAM, 256 MB swap
- **Rootfs**: `local-lvm:vm-245-disk-0,size=2G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: recyclarr
memory: 512
nameserver: 8.8.8.8 1.1.1.1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:24:F9:80,ip=192.168.12.245/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-245-disk-0,size=2G
searchdomain:  
swap: 256
unprivileged: 1
```
</details>

### CT-247 `jellystat` — running
- **IP**: `192.168.12.247/24`
- **Resources**: 2 cores, 512 MB RAM, 1024 MB swap
- **Rootfs**: `local-lvm:vm-247-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: jellystat
memory: 512
nameserver: 8.8.8.8 1.1.1.1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:D2:FD:0B,ip=192.168.12.247/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-247-disk-0,size=8G
swap: 1024
unprivileged: 1
```
</details>

### CT-248 `uptime-kuma` — running
- **IP**: `192.168.12.248/24`
- **Resources**: 1 cores, 1024 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-248-disk-0,size=4G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: uptime-kuma
memory: 1024
nameserver: 8.8.8.8 1.1.1.1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:ED:6F:F1,ip=192.168.12.248/24,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-248-disk-0,size=4G
swap: 512
unprivileged: 1
```
</details>

### CT-275 `homarr` — running
- **IP**: `n/a`
- **Resources**: 1 cores, 512 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-275-disk-0,size=8G`
- **Privileged**: yes
- **Onboot**: yes
- **Features**: `nesting=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: homarr
memory: 512
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:66:77:A9,ip=dhcp,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-275-disk-0,size=8G
startup: order=10,up=5,down=10
swap: 512
unprivileged: 0
```
</details>

### CT-278 `crowdsec` — stopped
- **IP**: `n/a`
- **Resources**: 1 cores, 512 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-278-disk-1,size=8G`
- **Privileged**: yes
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/opt/traefik-logs,mp=/traefik-logs,ro=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 1
features: nesting=1
hostname: crowdsec
memory: 512
mp0: /opt/traefik-logs,mp=/traefik-logs,ro=1
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:23:B7:D3,ip=dhcp,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-278-disk-1,size=8G
startup: order=10,up=5,down=10
swap: 512
unprivileged: 0
```
</details>

### CT-279 `tailscale` — running
- **IP**: `n/a`
- **Resources**: 1 cores, 128 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-279-disk-0,size=4G`
- **Privileged**: no
- **Onboot**: yes

<details><summary>full config</summary>

```
arch: amd64
cores: 1
hostname: tailscale
memory: 128
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:48:32:E3,ip=dhcp,type=veth
onboot: 1
ostype: debian
rootfs: local-lvm:vm-279-disk-0,size=4G
startup: order=10,up=5,down=10
swap: 512
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```
</details>

### CT-280 `retroarch-web` — stopped
- **IP**: `n/a`
- **Resources**: 2 cores, 2048 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-280-disk-0,size=8G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd/media/roms,mp=/roms`

<details><summary>full config</summary>

```
arch: amd64
cores: 2
features: nesting=1
hostname: retroarch-web
memory: 2048
mp0: /mnt/hdd/media/roms,mp=/roms
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:49:D9:8B,ip=dhcp,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-280-disk-0,size=8G
startup: order=10,up=5,down=10
swap: 512
unprivileged: 1
```
</details>

### CT-300 `mediastack` — running
- **IP**: `192.168.12.30/24`
- **Resources**: 4 cores, 4096 MB RAM, 2048 MB swap
- **Rootfs**: `hdd-ct:300/vm-300-disk-0.raw,size=16G`
- **Privileged**: no
- **Onboot**: yes
- **Features**: `nesting=1,keyctl=1,fuse=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 4
features: nesting=1,keyctl=1,fuse=1
hostname: mediastack
memory: 4096
nameserver: 8.8.8.8 1.1.1.1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:AB:99:E3,ip=192.168.12.30/24,type=veth
onboot: 1
ostype: debian
rootfs: hdd-ct:300/vm-300-disk-0.raw,size=16G
swap: 2048
lxc.cgroup2.devices.allow: c 226:0 rwm
lxc.cgroup2.devices.allow: c 226:128 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.cgroup2.devices.allow: c 10:229 rwm
lxc.mount.entry: /dev/fuse dev/fuse none bind,create=file
lxc.apparmor.profile: unconfined
```
</details>

### CT-900 `ziggy` — stopped
- **IP**: `192.168.12.250/24`
- **Resources**: 8 cores, 32768 MB RAM, 512 MB swap
- **Rootfs**: `local-lvm:vm-900-disk-0,size=32G`
- **Privileged**: no
- **Onboot**: no
- **Features**: `nesting=1,keyctl=1`
- **Bind mounts**:
  - `mp0=/mnt/hdd/models,mp=/mnt/laptop-models,ro=1`

<details><summary>full config</summary>

```
arch: amd64
cores: 8
features: nesting=1,keyctl=1
hostname: ziggy
memory: 32768
mp0: /mnt/hdd/models,mp=/mnt/laptop-models,ro=1
net0: name=eth0,bridge=vmbr0,gw=192.168.12.1,hwaddr=BC:24:11:53:62:17,ip=192.168.12.250/24,type=veth
onboot: 0
ostype: debian
rootfs: local-lvm:vm-900-disk-0,size=32G
startup: order=10,up=5,down=10
swap: 512
```
</details>

## QEMU VMs — full configs
### VM-901 `windows-gaming`
<details><summary>full config</summary>

```
agent: 1
balloon: 0
bios: ovmf
boot: order=scsi0;ide2
cores: 4
cpu: x86-64-v2-AES
cpulimit: 2
efidisk0: local-lvm:vm-901-disk-efivars,efitype=4m,pre-enrolled-keys=1,size=4M
hostpci0: 09:00,pcie=1,x-vga=1
ide2: local:iso/28000.1_MULTI_X64_EN-US.ISO,media=cdrom
ide3: local:iso/virtio-win.iso,media=cdrom
kvm: 1
machine: pc-q35-10.1
memory: 4096
name: windows-gaming
net0: virtio=DE:AD:BE:EF:90:01,bridge=vmbr0,firewall=1
numa: 0
onboot: 0
ostype: win11
scsi0: local-lvm:vm-901-disk-1,cache=writeback,discard=on,iothread=1,size=300G,ssd=1
scsi1: /dev/sdb,cache=none,discard=on,iothread=1,ssd=1
scsihw: virtio-scsi-single
sockets: 1
tpmstate0: local-lvm:vm-901-tpmstate,size=4M,version=v2.0
vga: none
```
</details>

### VM-990 `haos17-1`
<details><summary>full config</summary>

```
agent: enabled=1
bios: ovmf
boot: order=scsi0
cores: 2
cpu: host
description: <div align='center'>%0A  <a href='https%3A//community-scripts.org' target='_blank' rel='noopener noreferrer'>%0A    <img src='https%3A//raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/images/logo-81x112.png' alt='Logo' style='width%3A81px;height%3A112px;'/>%0A  </a>%0A%0A  <h2 style='font-size%3A 24px; margin%3A 20px 0;'>Homeassistant OS VM</h2>%0A%0A  <p style='margin%3A 16px 0;'>%0A    <a href='https%3A//ko-fi.com/community_scripts' target='_blank' rel='noopener noreferrer'>%0A      <img src='https%3A//img.shields.io/badge/&#x2615;-Buy us a coffee-blue' alt='spend Coffee' />%0A    </a>%0A  </p>%0A%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-github fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>GitHub</a>%0A  </span>%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-comments fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE/discussions' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>Discussions</a>%0A  </span>%0A  <span style='margin%3A 0 10px;'>%0A    <i class="fa fa-exclamation-circle fa-fw" style="color%3A #f5f5f5;"></i>%0A    <a href='https%3A//github.com/community-scripts/ProxmoxVE/issues' target='_blank' rel='noopener noreferrer' style='text-decoration%3A none; color%3A #00617f;'>Issues</a>%0A  </span>%0A</div>%0A%0AHome Assistant URL http%3A//homeassistant.local%3A8123%0AObserver URL http%3A//homeassistant.local%3A4357
efidisk0: local-lvm:vm-990-disk-1,efitype=4m,size=4M
localtime: 1
machine: q35
memory: 2048
meta: creation-qemu=10.1.2,ctime=1775000436
name: haos17-1
net0: virtio=02:88:F9:77:28:E2,bridge=vmbr0
onboot: 1
ostype: l26
scsi0: local-lvm:vm-990-disk-0,discard=on,size=32G,ssd=1
scsihw: virtio-scsi-pci
serial0: socket
smbios1: uuid=112eafff-0605-43eb-a6bc-2da7b071280a
tablet: 0
tags: community-script
vga: std
vmgenid: 56a6d4aa-c3b6-4e8d-958f-952eef937bea
```
</details>

