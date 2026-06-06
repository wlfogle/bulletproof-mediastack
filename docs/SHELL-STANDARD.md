# Shell Standard
Fish is the default interactive shell for Linux systems in this stack.

## Current standard
- Laptop user `loufogle`: `/usr/bin/fish`
- Laptop `root`: `/usr/bin/fish`
- Tiamat `root`: `/usr/bin/fish`
- CT-300 `root`: `/usr/bin/fish`
- CT-501 `root`: `/usr/bin/fish`
- Bahamut `root`: `/usr/bin/fish`

Do not change OpenWrt, Home Assistant OS, or the Windows gaming VM to fish. OpenWrt uses BusyBox/ash, Home Assistant OS is appliance-managed, and the Windows VM is gaming-only.

## Script standard
Use bash for automation scripts unless the script is explicitly interactive fish configuration:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
```

Use fish for operator convenience, not for portable provisioning scripts.
