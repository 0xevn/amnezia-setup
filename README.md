# AmneziaWG Setup

Automated installer for **AmneziaWG** — a DPI-resistant WireGuard VPN with protocol obfuscation.

One script. One command. Full VPN server with obfuscation.

## Why AmneziaWG?

Standard WireGuard is fast and secure, but has a recognizable packet signature that makes it easy for Deep Packet Inspection (DPI) to detect and block.

**AmneziaWG** is a modified WireGuard protocol that adds obfuscation:

| Feature | Description |
|---------|-------------|
| **Same security** | x25519 + ChaCha20-Poly1305 (identical to WireGuard) |
| **Magic headers** (H1-H4) | Random 32-bit values that disguise packet signatures |
| **Packet padding** (S1-S2) | Obscures handshake patterns |
| **Junk packets** (Jc, Jmin, Jmax) | Adds noise to traffic flow |

The result: your VPN traffic looks like random noise, defeating DPI systems.

---

## Quick Start

```bash
# On a fresh VPS (Debian/Ubuntu or Alpine Linux):
# Install git if not present: apt install git (Debian/Ubuntu) or apk add git (Alpine)
git clone https://github.com/0xevn/amnezia-setup.git

# Run as root
chmod +x amnezia-setup.sh
sh amnezia-setup.sh
```

> The script starts with `#!/bin/sh` and auto-installs `bash` if missing (e.g., on Alpine), then re-executes itself in bash.

### Supported Distributions

| Distro | Package Manager | Init System | Installation Method |
|--------|-----------------|-------------|---------------------|
| Debian 11/12 | apt | systemd | PPA + kernel module |
| Ubuntu 22.04/24.04 | apt | systemd | PPA + kernel module |
| Alpine 3.18+ | apk | OpenRC | Compiled from source (userspace) |

The script auto-detects your distro, init system, and package manager, then adapts accordingly.

---

## What the Script Does

On launch, the script asks two preliminary questions before making any changes:

1. **Security check** — asks if you're in a secure environment (no shared screens, cameras, or bystanders). This determines whether credentials are shown during setup or hidden entirely.

2. **Overwrite confirmation** — warns that existing AmneziaWG config, firewall rules, and sysctl settings will be overwritten (firewall rules are backed up first).

Then the setup proceeds:

1. Detect distro & init system, update packages & install dependencies
2. Install AmneziaWG (PPA + kernel module on Debian/Ubuntu, compiled from source on Alpine)
3. Choose a custom SSH port (auto-detects OpenSSH or Dropbear)
4. Choose a custom AmneziaWG port (default: 51820/UDP)
5. Choose a DNS provider for client config
6. Choose logging preference (disabled by default)
7. Generate server and client keypairs + preshared key
8. Generate unique obfuscation parameters (H1-H4 random, Jc/S1/S2 fixed)
9. Write server config to `/etc/amnezia/amneziawg/awg0.conf`
10. Enable IP forwarding
11. Configure iptables firewall with NAT (backs up existing rules)
12. Enable BBR congestion control and TCP optimizations
13. Create and start AmneziaWG service
14. Interactive summary with credential display, QR code, and save options

### Secure Mode vs Safe Mode

| Behavior | Secure (answered Y) | Safe (answered N / Enter) |
|----------|---------------------|---------------------------|
| Credentials in terminal | Shown | Hidden |
| Show credentials? | Asked, default **Y** | Auto-skipped |
| Show client config? | Asked, default **Y** | Auto-skipped |
| Show QR code? | Asked, default **Y** | Auto-skipped |
| Save to file? | Asked, default **N** | Asked, default **Y** (recommended) |

> In safe mode, saving to `/root/amneziawg-credentials.txt` is the recommended way to retrieve your credentials later from a private session.

---

## Client Apps

Connect using the official **AmneziaVPN** app:

| Platform | Download |
|----------|----------|
| Android | [Google Play](https://play.google.com/store/apps/details?id=org.amnezia.vpn) / [GitHub](https://github.com/amnezia-vpn/amnezia-client/releases) |
| iOS | [App Store](https://apps.apple.com/app/amneziavpn/id1600529900) |
| Windows | [GitHub Releases](https://github.com/amnezia-vpn/amnezia-client/releases) |
| macOS | [GitHub Releases](https://github.com/amnezia-vpn/amnezia-client/releases) |
| Linux | [GitHub Releases](https://github.com/amnezia-vpn/amnezia-client/releases) |

### Connecting

**Option A: QR Code (fastest for mobile)**

During setup (secure mode), choose "Show QR code" and scan it with the AmneziaVPN app.

**Option B: Copy Config**

Copy the client configuration text and import it as a `.conf` file in the app.

**Option C: Manual Entry**

Enter the server details manually in the app settings.

---

## DNS Providers

During setup, you choose a DNS provider for the client config:

| # | Provider | Jurisdiction | Logging | IP Address |
|---|----------|--------------|---------|------------|
| 1 | **DNS.SB** | Germany | No logging | `45.11.45.11` |
| 2 | **Mullvad DNS** | Sweden | Zero logs, audited | `194.242.2.2` |
| 3 | **Quad9** | Switzerland | No IP logging, threat blocking | `9.9.9.9` |
| 4 | **Quad9 Unfiltered** | Switzerland | No IP logging, no filtering | `9.9.9.11` |
| 5 | **Cloudflare** | USA | Logs purged 24h, audited | `1.1.1.1` |
| 6 | **AdGuard DNS** | Cyprus | Aggregated anon stats, ad blocking | `94.140.14.14` |

Default: DNS.SB (Germany, no logging).

---

## Obfuscation Parameters

These parameters are generated during setup and must match between server and all clients:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `Jc` | Junk packet count | 4 |
| `Jmin` | Minimum junk size (bytes) | 40 |
| `Jmax` | Maximum junk size (bytes) | 70 |
| `S1` | Init packet padding | 30 |
| `S2` | Response packet padding | 40 |
| `H1-H4` | Magic headers (32-bit) | **Random per install** |

The H1-H4 values are unique to your installation. Keep them secret — they're part of what makes your traffic undetectable.

---

## Adding More Clients

1. Generate a new keypair:
   ```bash
   awg genkey | tee client2_private.key | awg pubkey > client2_public.key
   ```

2. Add peer to server config (`/etc/amnezia/amneziawg/awg0.conf`):
   ```ini
   [Peer]
   # Client 2
   PublicKey = <contents of client2_public.key>
   AllowedIPs = 10.10.8.3/32
   ```

3. Restart the service:
   ```bash
   systemctl restart awg-quick@awg0   # Debian/Ubuntu (kernel mode)
   systemctl restart amneziawg        # Debian/Ubuntu (userspace mode)
   rc-service amneziawg restart       # Alpine
   ```

4. Create client config (copy obfuscation params from server):
   ```ini
   [Interface]
   PrivateKey = <contents of client2_private.key>
   Address = 10.10.8.3/24
   DNS = 45.11.45.11
   Jc = 4
   Jmin = 40
   Jmax = 70
   S1 = 30
   S2 = 40
   H1 = <same as server>
   H2 = <same as server>
   H3 = <same as server>
   H4 = <same as server>

   [Peer]
   PublicKey = <server public key>
   Endpoint = <server_ip>:51820
   AllowedIPs = 0.0.0.0/0
   PersistentKeepalive = 25
   ```

---

## Management Commands

| Task | systemd (Debian/Ubuntu) | OpenRC (Alpine) |
|------|-------------------------|-----------------|
| Status | `systemctl status awg-quick@awg0` | `rc-service amneziawg status` |
| Restart | `systemctl restart awg-quick@awg0` | `rc-service amneziawg restart` |
| Stop | `systemctl stop awg-quick@awg0` | `rc-service amneziawg stop` |
| Logs | `journalctl -u awg-quick@awg0 -f` | `tail -f /var/log/amneziawg/amneziawg.log` |
| Show peers | `awg show awg0` | `awg show awg0` |
| Edit config | `nano /etc/amnezia/amneziawg/awg0.conf` | ← same |
| View firewall | `iptables -L -n --line-numbers` | ← same |
| View NAT | `iptables -t nat -L -n` | ← same |
| Reload firewall | `netfilter-persistent reload` | `rc-service iptables-awg restart` |

> **Note:** On Debian/Ubuntu, if the kernel module failed to load and userspace mode is used, the service name is `amneziawg` instead of `awg-quick@awg0`.

---

## Security Best Practices

1. **Use a non-standard SSH port** (the script offers this during setup)
2. **Disable password SSH** — use key-based auth only
3. **Don't share your obfuscation parameters** — H1-H4 values are unique to your server
4. **Keep logging disabled** (the default) for maximum privacy
5. **Use the preshared key** — it's generated automatically and adds post-quantum resistance
6. **Run the script in safe mode** if you're in a public place
7. **Protect the credentials file** — if saved, it's at `/root/amneziawg-credentials.txt` with mode 600

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Interface not coming up | Check service status with the commands above |
| Kernel module not loading | Script auto-falls back to userspace mode. Check with `lsmod \| grep amneziawg` |
| No internet after connecting | Check IP forwarding: `cat /proc/sys/net/ipv4/ip_forward` should be `1` |
| NAT not working | Check NAT rules: `iptables -t nat -L POSTROUTING -n` |
| Client can't connect | Verify obfuscation params match exactly (especially H1-H4) |
| Locked out of SSH | Connect via VPS console, check port in config |
| QR code not displayed | Install `qrencode`: `apt install qrencode` or `apk add libqrencode-tools` |

---

## File Locations

| File | Path |
|------|------|
| Server config | `/etc/amnezia/amneziawg/awg0.conf` |
| Credentials backup | `/root/amneziawg-credentials.txt` (optional) |
| Firewall rules (v4) | `/etc/iptables/rules.v4` |
| Firewall rules (v6) | `/etc/iptables/rules.v6` |
| Firewall backup | `/etc/iptables/rules.v4.bak.*` (timestamped) |
| Sysctl config | `/etc/sysctl.d/99-awg-optimize.conf` |
| Debug logs | `/var/log/amneziawg/amneziawg.log` (if enabled) |
| OpenRC init script | `/etc/init.d/amneziawg` (Alpine) |
| Firewall init script | `/etc/init.d/iptables-awg` (Alpine) |
| OpenSSH config | `/etc/ssh/sshd_config` |
| Dropbear config | `/etc/conf.d/dropbear` |

---

## Alpine Linux Notes

Alpine requires adaptations that the script handles automatically:

- **Bash**: Not installed by default — auto-installed and re-executed
- **AmneziaWG**: No official Alpine package — compiled from source using Go
- **QR codes**: Package is `libqrencode-tools`, requires `community` repository (auto-enabled)
- **Init scripts**: OpenRC `openrc-run` path varies by version — auto-detected
- **Firewall persistence**: Custom `/etc/init.d/iptables-awg` OpenRC service
- **SSH daemon**: Auto-detects OpenSSH or Dropbear
- **No sudo**: Run as root directly (`su`, `doas`, or root login)

---

## Uninstall

```bash
# Stop and disable service
systemctl stop awg-quick@awg0 && systemctl disable awg-quick@awg0   # Debian/Ubuntu
rc-service amneziawg stop && rc-update del amneziawg                 # Alpine

# Remove config
rm -rf /etc/amnezia

# Remove credentials (if saved)
rm -f /root/amneziawg-credentials.txt

# Remove firewall rules
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6

# Remove sysctl config
rm -f /etc/sysctl.d/99-awg-optimize.conf

# Debian/Ubuntu: Remove packages
apt remove --purge amneziawg amneziawg-tools

# Alpine: Remove binaries
rm -f /usr/local/bin/amneziawg-go /usr/local/bin/awg /usr/local/bin/awg-quick
rm -f /etc/init.d/amneziawg /etc/init.d/iptables-awg
```

---

## References

- [AmneziaVPN](https://amnezia.org/) — official project site
- [amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module) — kernel module
- [amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go) — userspace implementation
- [amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools) — CLI tools (awg, awg-quick)
- [amnezia-client](https://github.com/amnezia-vpn/amnezia-client) — official client apps
- [WireGuard](https://www.wireguard.com/) — underlying protocol

---

## License

This project is licensed under the [MIT License](LICENSE).
