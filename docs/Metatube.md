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

and 

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
