# CLAUDE.md

## Project Overview

AmneziaWG automated installer for VPS servers. Single-file bash script (~1390 lines) that sets up a DPI-resistant WireGuard VPN server with obfuscation support.

**License:** MIT

## Files

- `amnezia-setup.sh` — the installer script (the only code file)
- `README.md` — user documentation
- `LICENSE` — MIT license

## Supported Platforms

| Distro | Init System | Package Manager |
|--------|-------------|-----------------|
| Debian / Ubuntu | systemd | apt |
| Alpine Linux | OpenRC | apk |

## What is AmneziaWG?

AmneziaWG is a modified WireGuard protocol with DPI-evasion features:
- Same cryptographic security as WireGuard (x25519 + ChaCha20-Poly1305)
- Random header ranges (H1-H4) to disguise packet signatures (2.0: ranges instead of fixed values)
- Packet padding (S1-S4) to obscure handshake and transport patterns (S3-S4 new in 2.0)
- Junk packets (Jc, Jmin, Jmax) to add noise

**AmneziaWG 2.0 additions:**
- `S3`: Cookie message padding (0-32 bytes)
- `S4`: Transport data padding (0-64 bytes) — most important, affects every packet
- `H1-H4`: Now specified as ranges (e.g., `H1 = 100000-200000`) for per-packet randomization

## Script Architecture

The script starts with a `#!/bin/sh` POSIX bootstrap that installs bash if missing (Alpine), then re-execs itself in bash. All code after the bootstrap uses bash features (arrays, `[[ ]]`, `${var,,}`, regex).

### Global Variables

Key globals set during execution (defined at top of file):

- `DISTRO` — `debian` | `alpine`
- `INIT_SYSTEM` — `systemd` | `openrc`
- `PKG_MANAGER` — `apt` | `apk`
- `SECURE_ENV` — `y` | `n` (controls credential display)
- `ENABLE_LOGS` — `y` | `n` (controls WireGuard debug logging)
- `SSH_DAEMON` — `openssh` | `dropbear`
- `AWG_MODE` — `kernel` | `userspace`
- `SSH_PORT`, `AWG_PORT`
- `SERVER_PRIVATE_KEY`, `SERVER_PUBLIC_KEY`
- `CLIENT_PRIVATE_KEY`, `CLIENT_PUBLIC_KEY`, `PRESHARED_KEY`
- `AWG_JC`, `AWG_JMIN`, `AWG_JMAX`, `AWG_S1`, `AWG_S2`, `AWG_S3`, `AWG_S4`, `AWG_H1-H4`
- `DNS_NAME`, `DNS_IP`
- `SERVER_IP`, `CLIENT_CONFIG`

### Function Map

```
main()
├── print_header()
├── check_root()
├── check_secure_environment()       # Security awareness prompt
├── confirm_proceed()                 # Overwrite warning prompt
├── detect_environment()              # Distro, init system, pkg manager
├── prepare_system()                  # Update packages, install deps
├── install_amneziawg()               # Dispatches to distro-specific install
│   ├── install_amneziawg_debian()    # PPA + kernel module
│   ├── install_amneziawg_alpine()    # Compile from source
│   └── install_amneziawg_userspace() # Fallback: amneziawg-go
├── choose_ssh_port()                 # Detects and configures SSH
│   ├── detect_ssh_daemon()           # OpenSSH vs Dropbear
│   ├── get_openssh_port()            # Parses sshd_config
│   ├── get_dropbear_port()           # Parses /etc/conf.d/dropbear
│   ├── apply_openssh_port()          # Writes sshd_config + drop-ins
│   └── apply_dropbear_port()         # Writes DROPBEAR_OPTS
├── choose_awg_port()                 # Default 51820/UDP
├── choose_dns()                      # 6 DNS providers (for client config)
├── choose_logging()                  # Debug logging preference
├── generate_credentials()            # Server/client keypairs + PSK
├── generate_obfuscation_params()     # User choice: optimized defaults or random params
├── write_server_config()             # Generates /etc/amnezia/amneziawg/awg0.conf
├── enable_ip_forwarding()            # sysctl net.ipv4.ip_forward
├── configure_firewall()              # iptables + NAT + persistence
├── optimize_sysctl()                 # BBR, TCP buffers
├── create_service()                  # Dispatches to init-specific service
│   ├── create_systemd_service()      # awg-quick@awg0 or custom unit
│   └── create_openrc_service()       # /etc/init.d/amneziawg
├── start_amneziawg()                 # Enable + start service
└── print_summary()                   # Interactive credential display + save
```

### Service Abstraction Layer

All init system differences are handled through wrapper functions:

- `svc_enable()`, `svc_start()`, `svc_stop()`, `svc_restart()`, `svc_is_active()`, `svc_disable()`
- Each dispatches on `$INIT_SYSTEM` (systemd/openrc)

### UI Frames

Interactive prompts use Unicode box-drawing frames. All framed content lines must be exactly **58 visual columns** between the `║` bars. Special character widths:

- Emoji with `east_asian_width` W/F (e.g., 🔒, 🚫) = 2 visual columns
- Emoji with `east_asian_width` N (e.g., ⚠) = 1 visual column
- Bullet `•` = 1 visual column
- ANSI color codes (`${CYAN}`, `${BOLD}`, etc.) = 0 visual columns

Use this Python snippet to verify:

```python
import re, unicodedata

def vis_width(s):
    return sum(2 if unicodedata.east_asian_width(ch) in ('W','F') else 1 for ch in s)

# Extract content between ║${NC} and ${COLOR}║${NC}"
# Remove ${BOLD}, ${NC}, etc. before measuring
# Target: vis_width == 58 for every line
```

Frame colors by section:
- **Header**: cyan
- **Security Check** (🔒): yellow
- **Overwrite Warning** (⚠): red
- **Logging Preference** (📋): cyan
- **Obfuscation Parameters** (🔧): cyan
- **Server Credentials**: cyan

### AmneziaWG Config Format

Uses WireGuard INI format with additional obfuscation parameters (AmneziaWG 2.0):

```ini
[Interface]
PrivateKey = <server_private_key>
Address = 10.10.8.1/24
ListenPort = 51820
Jc = 8
Jmin = 50
Jmax = 1000
S1 = 60
S2 = 85
S3 = 45
S4 = 50
H1 = <min>-<max>
H2 = <min>-<max>
H3 = <min>-<max>
H4 = <min>-<max>

[Peer]
PublicKey = <client_public_key>
PresharedKey = <psk>
AllowedIPs = 10.10.8.2/32
```

**Obfuscation parameter options:**
- **Optimized defaults** (recommended): Jc=8, Jmin=50, Jmax=1000, S1=60, S2=85, S3=45, S4=50
- **Random**: User can choose to generate random Jc/Jmin/Jmax/S1-S4 values
- **H1-H4**: Always randomly generated as ranges (e.g., `H1 = 100000-500000`)
- Constraint: `S1 + 56 ≠ S2` (prevents pattern detection)

### Installation Strategy

| Platform | Method | Service |
|----------|--------|---------|
| Debian/Ubuntu | PPA `ppa:amnezia/ppa` + kernel module | `awg-quick@awg0` |
| Debian/Ubuntu (fallback) | amneziawg-go userspace | custom systemd unit |
| Alpine | amneziawg-go compiled from source | custom OpenRC script |

### Init Script Generation

OpenRC init scripts are generated dynamically. Key details:

- Shebang (`#!/sbin/openrc-run` vs `#!/usr/sbin/openrc-run`) is detected dynamically
- Log paths (`output_log`, `error_log`) are set to `/dev/null` when logging disabled
- PATH is set locally inside `start_post()`/`stop_pre()` functions to avoid breaking OpenRC initialization

## Key Design Decisions

- **Default-safe prompts**: Security-sensitive options default to N (don't show, don't log, don't save)
- **No sudo**: Script requires root directly — Alpine doesn't ship sudo
- **POSIX bootstrap**: `#!/bin/sh` ensures the script can self-install bash on minimal Alpine
- **No grep -P**: BusyBox grep doesn't support Perl regex; use `awk` instead
- **No ss -p**: BusyBox ss doesn't show process names; SSH port read from config files
- **Firewall backup**: Existing rules backed up with timestamp before overwrite
- **Userspace fallback**: If kernel module fails (containerized VPS), automatically falls back to amneziawg-go
- **Single client**: Generates one client during setup; provides instructions to add more

## File Locations

| File | Path |
|------|------|
| Server config | `/etc/amnezia/amneziawg/awg0.conf` |
| Credentials backup | `/root/amneziawg-credentials.txt` |
| Firewall rules (v4) | `/etc/iptables/rules.v4` |
| Firewall rules (v6) | `/etc/iptables/rules.v6` |
| Sysctl config | `/etc/sysctl.d/99-awg-optimize.conf` |
| OpenRC init script | `/etc/init.d/amneziawg` (Alpine) |
| Firewall init script | `/etc/init.d/iptables-awg` (Alpine) |

## Testing

The script is designed for fresh VPS instances. To test:

1. Spin up a Debian/Ubuntu or Alpine VPS
2. `scp amnezia-setup.sh root@vps:/root/`
3. `ssh root@vps 'sh /root/amnezia-setup.sh'`

For Alpine specifically, also test with Dropbear as the SSH daemon (default on some Alpine images).

### Verification Commands

```bash
# Check interface status
awg show awg0

# Service status (systemd)
systemctl status awg-quick@awg0

# Service status (OpenRC)
rc-service amneziawg status

# Test from client after connecting
ping 10.10.8.1
curl https://ifconfig.me
```

### Test Matrix

- Fresh Debian 12 VPS
- Fresh Ubuntu 22.04/24.04 VPS
- Fresh Alpine 3.18+ VPS (with OpenSSH)
- Fresh Alpine 3.18+ VPS (with Dropbear)

## Common Modifications

- **Adding a new framed prompt**: Copy an existing frame section, adjust content, verify all lines are 58 visual columns
- **Adding a new distro**: Add case to `detect_environment()`, update `prepare_system()` for its package manager
- **Adding a new init system**: Add cases to all `svc_*()` functions, plus init script generation
- **Changing obfuscation defaults**: Modify values in `generate_obfuscation_params()`
- **Adding more clients**: Script provides instructions; manually add `[Peer]` sections to config
