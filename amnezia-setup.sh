#!/bin/sh
# ============================================================
#  AmneziaWG — Automated Setup Script
#
#  DPI-resistant WireGuard VPN with obfuscation support.
#
#  Supported distros:
#    • Debian / Ubuntu       (systemd, apt)
#    • Alpine Linux          (OpenRC, apk)
#
#  Run as root on a fresh VPS:
#    chmod +x amnezia-setup.sh && sh amnezia-setup.sh
#
#  License: MIT
# ============================================================

# ── Bootstrap: ensure bash is available, then re-exec ──
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        echo "[*] bash not found — installing..."
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash
        elif command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y bash
        else
            echo "[ERROR] Cannot install bash. Install it manually and re-run."
            exit 1
        fi
    fi
    exec bash "$0" "$@"
fi

# ── From here on, we are running in bash ──

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

AWG_CONFIG_DIR="/etc/amnezia/amneziawg"
AWG_CONFIG="${AWG_CONFIG_DIR}/awg0.conf"
AWG_LOG_DIR="/var/log/amneziawg"

# Populated by detect_environment()
DISTRO=""        # debian | alpine
INIT_SYSTEM=""   # systemd | openrc
PKG_MANAGER=""   # apt | apk
SECURE_ENV=""    # y | n — controls sensitive output visibility
ENABLE_LOGS=""   # y | n — controls WireGuard debug logging
SSH_DAEMON=""    # openssh | dropbear — detected automatically
AWG_MODE=""      # kernel | userspace — determined during install

# Network configuration
VPN_SUBNET="10.10.8"
VPN_INTERFACE="awg0"

# iptables commands (may be overridden to use legacy on Alpine)
IPTABLES="iptables"
IPTABLES_RESTORE="iptables-restore"
IP6TABLES="ip6tables"
IP6TABLES_RESTORE="ip6tables-restore"

# ────────────────────────────────────────────────────────────
#  Helper functions
# ────────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}AmneziaWG — DPI-Resistant WireGuard Setup${NC}              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Obfuscated VPN server installer                         ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

log_info()    { echo -e "${GREEN}[INFO]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}▶ Step $1: $2${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Use: su -c 'sh $0' or doas sh $0"
        exit 1
    fi
}

check_secure_environment() {
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${NC}  ${BOLD}🔒 Security Check${NC}                                       ${YELLOW}║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  This script generates sensitive cryptographic keys.     ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  Before proceeding, make sure:                           ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}    • You are ${BOLD}not${NC} in a public place                       ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}    • No cameras can see your screen                      ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}    • No one is standing behind you                       ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}    • You are ${BOLD}not${NC} sharing your screen                     ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Are you in a secure environment? [y/N]: " SEC_INPUT

    if [[ "${SEC_INPUT,,}" == "y" || "${SEC_INPUT,,}" == "yes" ]]; then
        SECURE_ENV="y"
        log_info "Secure mode: credentials will be shown during setup."
    else
        SECURE_ENV="n"
        log_info "Safe mode: sensitive data will be hidden. Save to file at the end to retrieve later."
    fi
}

confirm_proceed() {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}  ${BOLD}⚠  Overwrite Warning${NC}                                    ${RED}║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC}                                                          ${RED}║${NC}"
    echo -e "${RED}║${NC}  This script will overwrite the following if they        ${RED}║${NC}"
    echo -e "${RED}║${NC}  already exist:                                          ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                          ${RED}║${NC}"
    echo -e "${RED}║${NC}    • AmneziaWG server configuration and keys             ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Firewall (iptables) rules                           ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Sysctl network optimizations                        ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                          ${RED}║${NC}"
    echo -e "${RED}║${NC}  Existing firewall rules will be backed up first.        ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                          ${RED}║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Continue with installation? [y/N]: " CONFIRM

    if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
        log_info "Installation cancelled."
        exit 0
    fi
}

# ────────────────────────────────────────────────────────────
#  Environment detection & service abstraction
# ────────────────────────────────────────────────────────────
detect_environment() {
    # Detect distro
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID,,}" in
            alpine)               DISTRO="alpine" ;;
            debian|ubuntu|linuxmint|pop|kali|raspbian)
                                  DISTRO="debian" ;;
            *)
                log_error "Unsupported distro: ${ID}. Supported: Debian/Ubuntu, Alpine."
                exit 1
                ;;
        esac
    elif [[ -f /etc/alpine-release ]]; then
        DISTRO="alpine"
    else
        log_error "Cannot detect distribution. /etc/os-release not found."
        exit 1
    fi

    # Detect init system
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        log_error "Cannot detect init system. Supported: systemd, OpenRC."
        exit 1
    fi

    # Detect package manager
    if command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
    elif command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
    else
        log_error "No supported package manager found. Need apt or apk."
        exit 1
    fi

    log_info "Detected: ${BOLD}${DISTRO}${NC} / ${BOLD}${INIT_SYSTEM}${NC} / ${BOLD}${PKG_MANAGER}${NC}"
}

# ── Service management abstraction ──
svc_enable() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl enable "$name" 2>/dev/null ;;
        openrc)   rc-update add "$name" default 2>/dev/null ;;
    esac
}

svc_start() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl start "$name" ;;
        openrc)   rc-service "$name" start ;;
    esac
}

svc_stop() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl stop "$name" 2>/dev/null || true ;;
        openrc)   rc-service "$name" stop 2>/dev/null || true ;;
    esac
}

svc_restart() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl daemon-reload; systemctl restart "$name" ;;
        openrc)   rc-service "$name" restart ;;
    esac
}

svc_is_active() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl is-active --quiet "$name" ;;
        openrc)   rc-service "$name" status 2>/dev/null | grep -qi "started" ;;
    esac
}

svc_disable() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl disable "$name" 2>/dev/null; systemctl stop "$name" 2>/dev/null ;;
        openrc)   rc-update del "$name" default 2>/dev/null; rc-service "$name" stop 2>/dev/null ;;
    esac
}

# ────────────────────────────────────────────────────────────
#  Step 1: System preparation
# ────────────────────────────────────────────────────────────
prepare_system() {
    log_step "1" "Updating system and installing dependencies"

    case "$PKG_MANAGER" in
        apt)
            apt update -y && apt upgrade -y
            # Pre-seed iptables-persistent to avoid interactive prompts
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
            apt install -y curl wget openssl iptables iptables-persistent qrencode software-properties-common
            ;;
        apk)
            # Enable community repo (needed for libqrencode-tools)
            if ! grep -q '^\s*[^#].*community' /etc/apk/repositories 2>/dev/null; then
                ALPINE_VER=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2)
                echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories
                log_info "Enabled Alpine community repository."
            fi
            apk update && apk upgrade
            apk add curl wget openssl iptables ip6tables libqrencode-tools bash
            ;;
    esac

    # Disable UFW if present to avoid conflicts with iptables
    if command -v ufw &>/dev/null; then
        svc_disable ufw || true
        log_info "UFW disabled to avoid conflicts with iptables."
    fi

    log_info "System updated and dependencies installed."
}

# ────────────────────────────────────────────────────────────
#  Step 2: Install AmneziaWG
# ────────────────────────────────────────────────────────────
install_amneziawg() {
    log_step "2" "Installing AmneziaWG"

    case "$DISTRO" in
        debian)
            install_amneziawg_debian
            ;;
        alpine)
            install_amneziawg_alpine
            ;;
    esac

    # Verify installation
    if command -v awg &>/dev/null; then
        log_info "AmneziaWG tools installed: $(which awg)"
    else
        log_error "AmneziaWG installation failed!"
        exit 1
    fi
}

install_amneziawg_debian() {
    log_info "Installing AmneziaWG via PPA..."

    # Add Amnezia PPA
    add-apt-repository -y ppa:amnezia/ppa
    apt update

    # Install kernel module + tools
    apt install -y amneziawg amneziawg-tools

    # Try to load kernel module
    if modprobe amneziawg 2>/dev/null; then
        AWG_MODE="kernel"
        log_info "AmneziaWG kernel module loaded successfully."
    else
        log_warn "Kernel module failed to load. Trying userspace fallback..."
        install_amneziawg_userspace
    fi
}

install_amneziawg_userspace() {
    log_info "Installing amneziawg-go (userspace implementation)..."

    # Install Go if needed
    if ! command -v go &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) apt install -y golang-go ;;
            apk) apk add go ;;
        esac
    fi

    # Install git, make, and build dependencies
    case "$PKG_MANAGER" in
        apt) apt install -y git make build-essential ;;
        apk) apk add git make linux-headers ;;
    esac

    # Create temp directory
    local TMPDIR
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"

    # Clone and build amneziawg-go
    log_info "Cloning amneziawg-go..."
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go.git
    cd amneziawg-go

    log_info "Building amneziawg-go..."
    go build -o amneziawg-go
    install -m 755 amneziawg-go /usr/local/bin/
    log_info "Installed: /usr/local/bin/amneziawg-go"

    cd "$TMPDIR"

    # Clone and build amneziawg-tools
    log_info "Cloning amneziawg-tools..."
    git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-tools.git
    cd amneziawg-tools/src

    log_info "Building amneziawg-tools..."
    make
    install -m 755 wg /usr/local/bin/awg
    install -m 755 wg-quick/linux.bash /usr/local/bin/awg-quick
    log_info "Installed: /usr/local/bin/awg, /usr/local/bin/awg-quick"

    # Cleanup
    cd /
    rm -rf "$TMPDIR"

    AWG_MODE="userspace"
    log_info "AmneziaWG userspace mode ready."
}

install_amneziawg_alpine() {
    log_info "Alpine detected — using userspace amneziawg-go..."

    # Alpine always uses userspace (no DKMS support)
    install_amneziawg_userspace
}

# ────────────────────────────────────────────────────────────
#  Step 3: Choose custom SSH port
# ────────────────────────────────────────────────────────────

# Detect which SSH daemon is running
detect_ssh_daemon() {
    if rc-service dropbear status &>/dev/null 2>&1 || [[ -f /etc/init.d/dropbear ]]; then
        SSH_DAEMON="dropbear"
    elif rc-service sshd status &>/dev/null 2>&1 || [[ -f /etc/init.d/sshd ]] \
         || systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null \
         || [[ -f /etc/ssh/sshd_config ]]; then
        SSH_DAEMON="openssh"
    elif command -v dropbear &>/dev/null; then
        SSH_DAEMON="dropbear"
    elif command -v sshd &>/dev/null; then
        SSH_DAEMON="openssh"
    else
        log_warn "No SSH daemon detected. Assuming OpenSSH."
        SSH_DAEMON="openssh"
    fi
    log_info "SSH daemon: ${BOLD}${SSH_DAEMON}${NC}"
}

# Get current SSH port for dropbear
get_dropbear_port() {
    local CONF="/etc/conf.d/dropbear"
    if [[ -f "$CONF" ]]; then
        local OPTS
        OPTS=$(grep -E '^DROPBEAR_OPTS=' "$CONF" 2>/dev/null | sed 's/^DROPBEAR_OPTS=//' | tr -d '"' | tr -d "'") || true
        if [[ -n "$OPTS" ]]; then
            local PORT
            PORT=$(echo "$OPTS" | grep -oE '\-p\s*[0-9]+' | grep -oE '[0-9]+' | tail -1) || true
            if [[ -n "$PORT" ]]; then
                echo "$PORT"
                return
            fi
        fi
    fi
    echo ""
}

# Get current SSH port for openssh
get_openssh_port() {
    local PORT=""

    if [[ -f /etc/ssh/sshd_config ]]; then
        PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1) || true
    fi

    if [[ -z "$PORT" && -d /etc/ssh/sshd_config.d ]]; then
        PORT=$(grep -rE "^Port " /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | head -1) || true
    fi

    echo "$PORT"
}

# Apply new port for dropbear
apply_dropbear_port() {
    local NEW_PORT="$1"
    local CONF="/etc/conf.d/dropbear"

    if [[ ! -f "$CONF" ]]; then
        mkdir -p /etc/conf.d
        echo 'DROPBEAR_OPTS=""' > "$CONF"
    fi

    local OPTS
    OPTS=$(grep -E '^DROPBEAR_OPTS=' "$CONF" | sed 's/^DROPBEAR_OPTS=//' | tr -d '"' | tr -d "'") || true

    OPTS=$(echo "$OPTS" | sed 's/-p\s*[0-9]*//g; s/  */ /g; s/^ //; s/ $//')

    if [[ -n "$OPTS" ]]; then
        OPTS="${OPTS} -p ${NEW_PORT}"
    else
        OPTS="-p ${NEW_PORT}"
    fi

    if grep -qE '^DROPBEAR_OPTS=' "$CONF"; then
        sed -i "s|^DROPBEAR_OPTS=.*|DROPBEAR_OPTS=\"${OPTS}\"|" "$CONF"
    else
        echo "DROPBEAR_OPTS=\"${OPTS}\"" >> "$CONF"
    fi

    svc_restart dropbear 2>/dev/null || true
}

# Apply new port for openssh
apply_openssh_port() {
    local NEW_PORT="$1"
    local SSHD_CONFIG="/etc/ssh/sshd_config"

    if grep -qE "^#?Port " "$SSHD_CONFIG"; then
        sed -i "s/^#*Port .*/Port ${NEW_PORT}/" "$SSHD_CONFIG"
    else
        echo "Port ${NEW_PORT}" >> "$SSHD_CONFIG"
    fi

    if [[ -d /etc/ssh/sshd_config.d ]]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$f" ]] && sed -i "s/^Port .*/Port ${NEW_PORT}/" "$f" 2>/dev/null || true
        done
    fi

    svc_restart sshd 2>/dev/null || svc_restart ssh 2>/dev/null || true
}

choose_ssh_port() {
    log_step "3" "Configuring SSH port"

    detect_ssh_daemon

    CURRENT_SSH_PORT=""
    case "$SSH_DAEMON" in
        dropbear) CURRENT_SSH_PORT=$(get_dropbear_port) ;;
        openssh)  CURRENT_SSH_PORT=$(get_openssh_port) ;;
    esac

    if [[ -z "$CURRENT_SSH_PORT" && -n "${SSH_CONNECTION:-}" ]]; then
        CURRENT_SSH_PORT=$(echo "$SSH_CONNECTION" | awk '{print $4}') || true
    fi

    CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"

    echo ""
    echo -e "  SSH daemon:       ${BOLD}${SSH_DAEMON}${NC}"
    echo -e "  Current SSH port: ${BOLD}${CURRENT_SSH_PORT}${NC}"
    echo -e "  Using a non-standard port reduces brute-force noise."
    echo -e "  ${YELLOW}⚠ Make sure you can reconnect on the new port before closing this session!${NC}"
    echo ""
    read -rp "  Enter SSH port [default=${CURRENT_SSH_PORT}]: " INPUT_SSH_PORT

    SSH_PORT="${INPUT_SSH_PORT:-$CURRENT_SSH_PORT}"

    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        log_warn "Invalid port. Falling back to ${CURRENT_SSH_PORT}."
        SSH_PORT="$CURRENT_SSH_PORT"
    fi

    if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
        case "$SSH_DAEMON" in
            dropbear) apply_dropbear_port "$SSH_PORT" ;;
            openssh)  apply_openssh_port "$SSH_PORT" ;;
        esac
        log_info "SSH port changed to ${SSH_PORT}. Update your SSH client!"
    else
        log_info "SSH port kept at ${SSH_PORT}."
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 4: Choose AmneziaWG port
# ────────────────────────────────────────────────────────────
choose_awg_port() {
    log_step "4" "Configuring AmneziaWG port"

    echo ""
    echo -e "  Port ${BOLD}51820${NC} is the standard WireGuard port."
    echo -e "  You can use a different port if needed."
    echo ""
    read -rp "  Enter AmneziaWG port [default=51820]: " INPUT_AWG_PORT

    AWG_PORT="${INPUT_AWG_PORT:-51820}"

    if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] || (( AWG_PORT < 1 || AWG_PORT > 65535 )); then
        log_warn "Invalid port. Falling back to 51820."
        AWG_PORT="51820"
    fi

    if [[ "$AWG_PORT" == "$SSH_PORT" ]]; then
        log_error "AmneziaWG port cannot be the same as SSH port (${SSH_PORT})!"
        read -rp "  Enter a different AmneziaWG port: " AWG_PORT
    fi

    log_info "AmneziaWG will listen on UDP port ${AWG_PORT}."
}

# ────────────────────────────────────────────────────────────
#  Step 5: Choose DNS provider
# ────────────────────────────────────────────────────────────

DNS_NAMES=(
    "DNS.SB"
    "Mullvad DNS"
    "Quad9"
    "Quad9 Unfiltered"
    "Cloudflare"
    "AdGuard DNS"
)
DNS_IPS=(
    "45.11.45.11"
    "194.242.2.2"
    "9.9.9.9"
    "9.9.9.11"
    "1.1.1.1"
    "94.140.14.14"
)
DNS_INFO=(
    "Germany   | No logging"
    "Sweden    | Zero logs, audited"
    "Switzerland| No IP logging, threat blocking"
    "Switzerland| No IP logging, no filtering"
    "USA       | Logs purged 24h, KPMG-audited"
    "Cyprus    | Aggregated anon stats, ad blocking"
)

choose_dns() {
    log_step "5" "Choosing DNS provider (for client config)"

    echo ""
    echo -e "  DNS queries from connected clients will use this provider."
    echo ""
    echo -e "  ${BOLD}#   Provider            Jurisdiction     Logging${NC}"
    echo -e "  ─────────────────────────────────────────────────────────────"
    for i in "${!DNS_NAMES[@]}"; do
        printf "    %d)  %-20s %s\n" $((i+1)) "${DNS_NAMES[$i]}" "${DNS_INFO[$i]}"
    done
    echo ""

    read -rp "  Select DNS [1-${#DNS_NAMES[@]}, default=1 (DNS.SB)]: " INPUT_DNS
    DNS_IDX=$(( ${INPUT_DNS:-1} - 1 ))
    if (( DNS_IDX < 0 || DNS_IDX >= ${#DNS_NAMES[@]} )); then
        log_warn "Invalid choice. Falling back to DNS.SB."
        DNS_IDX=0
    fi

    DNS_NAME="${DNS_NAMES[$DNS_IDX]}"
    DNS_IP="${DNS_IPS[$DNS_IDX]}"

    echo ""
    log_info "Selected DNS: ${DNS_NAME} (${DNS_IP})"
}

# ────────────────────────────────────────────────────────────
#  Logging preference
# ────────────────────────────────────────────────────────────
choose_logging() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}📋 Logging Preference${NC}                                   ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  WireGuard debug logs can help with troubleshooting      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  but may record connection metadata.                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  For maximum privacy, disable logging entirely.          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  You can re-enable it later if needed.                   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Enable debug logging? [y/N]: " LOG_INPUT

    if [[ "${LOG_INPUT,,}" == "y" || "${LOG_INPUT,,}" == "yes" ]]; then
        ENABLE_LOGS="y"
        mkdir -p "$AWG_LOG_DIR"
        chmod 755 "$AWG_LOG_DIR"
        log_info "Logging enabled: debug logs in ${AWG_LOG_DIR}/"
    else
        ENABLE_LOGS="n"
        log_info "Logging disabled: no connection data will be stored."
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 6: Generate credentials
# ────────────────────────────────────────────────────────────
generate_credentials() {
    log_step "6" "Generating cryptographic credentials"

    # Generate server keypair
    SERVER_PRIVATE_KEY=$(awg genkey)
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | awg pubkey)

    # Generate client keypair
    CLIENT_PRIVATE_KEY=$(awg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | awg pubkey)

    # Generate preshared key for additional security
    PRESHARED_KEY=$(awg genpsk)

    if [[ "$SECURE_ENV" == "y" ]]; then
        log_info "Server Private Key: ${SERVER_PRIVATE_KEY:0:10}..."
        log_info "Server Public Key:  ${SERVER_PUBLIC_KEY:0:10}..."
        log_info "Client Private Key: ${CLIENT_PRIVATE_KEY:0:10}..."
        log_info "Client Public Key:  ${CLIENT_PUBLIC_KEY:0:10}..."
    else
        log_info "Credentials generated successfully (hidden — safe mode)."
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 7: Generate obfuscation parameters
# ────────────────────────────────────────────────────────────
generate_obfuscation_params() {
    log_step "7" "Generating obfuscation parameters"

    echo ""
    echo -e "  AmneziaWG uses protocol obfuscation to evade DPI detection."
    echo -e "  Generating unique parameters for this installation..."
    echo ""

    # Fixed parameters (reasonable defaults)
    AWG_JC=4        # Junk packet count
    AWG_JMIN=40     # Min junk size (bytes)
    AWG_JMAX=70     # Max junk size (bytes)
    AWG_S1=30       # Init packet padding
    AWG_S2=40       # Response packet padding

    # Generate random 32-bit magic headers (unique per installation)
    AWG_H1=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    AWG_H2=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    AWG_H3=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    AWG_H4=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')

    log_info "Obfuscation parameters generated:"
    echo -e "    Jc=${AWG_JC} (junk packets), Jmin=${AWG_JMIN}, Jmax=${AWG_JMAX}"
    echo -e "    S1=${AWG_S1} (init padding), S2=${AWG_S2} (response padding)"
    echo -e "    H1-H4: unique magic headers"
}

# ────────────────────────────────────────────────────────────
#  Step 8: Write server configuration
# ────────────────────────────────────────────────────────────
write_server_config() {
    log_step "8" "Writing server configuration"

    SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || echo "<SERVER_IP>")

    # Detect primary network interface
    PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$PRIMARY_IFACE" ]]; then
        PRIMARY_IFACE="eth0"
        log_warn "Could not detect primary interface, using eth0"
    fi

    mkdir -p "$AWG_CONFIG_DIR"

    # Create server config
    cat > "$AWG_CONFIG" <<AWG_SERVER_EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${VPN_SUBNET}.1/24
ListenPort = ${AWG_PORT}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

# NAT rules for routing client traffic
PostUp = iptables -t nat -A POSTROUTING -s ${VPN_SUBNET}.0/24 -o ${PRIMARY_IFACE} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${VPN_SUBNET}.0/24 -o ${PRIMARY_IFACE} -j MASQUERADE

[Peer]
# Client 1
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
AllowedIPs = ${VPN_SUBNET}.2/32
AWG_SERVER_EOF

    chmod 600 "$AWG_CONFIG"
    log_info "Server config written to $AWG_CONFIG"

    # Generate client config (for display later)
    CLIENT_CONFIG="[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${VPN_SUBNET}.2/24
DNS = ${DNS_IP}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
Endpoint = ${SERVER_IP}:${AWG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25"
}

# ────────────────────────────────────────────────────────────
#  Step 9: Enable IP forwarding and TUN module
# ────────────────────────────────────────────────────────────
enable_ip_forwarding() {
    log_step "9" "Enabling IP forwarding and TUN module"

    # Load TUN module (required for WireGuard/AmneziaWG)
    if ! lsmod | grep -q "^tun"; then
        modprobe tun 2>/dev/null || true
    fi

    # Persist TUN module across reboots
    if [[ -f /etc/modules ]]; then
        if ! grep -q "^tun$" /etc/modules 2>/dev/null; then
            echo "tun" >> /etc/modules
        fi
    fi
    if [[ -d /etc/modules-load.d ]]; then
        echo "tun" > /etc/modules-load.d/tun.conf
    fi

    # Verify TUN device exists
    if [[ ! -c /dev/net/tun ]]; then
        log_warn "TUN device not available. VPN may not work in this environment."
    else
        log_info "TUN module loaded."
    fi

    # Enable IP forwarding immediately
    sysctl -w net.ipv4.ip_forward=1 > /dev/null

    # Persist across reboots
    if [[ -f /etc/sysctl.conf ]]; then
        if grep -qE "^#?net.ipv4.ip_forward" /etc/sysctl.conf; then
            sed -i 's/^#*net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
        else
            echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        fi
    fi

    log_info "IP forwarding enabled."
}

# ────────────────────────────────────────────────────────────
#  Step 10: Configure firewall
# ────────────────────────────────────────────────────────────
configure_firewall() {
    log_step "10" "Configuring firewall (iptables)"

    RULES_V4="/etc/iptables/rules.v4"
    RULES_V6="/etc/iptables/rules.v6"

    # Backup existing rules if present
    mkdir -p /etc/iptables
    BACKUP_TS=$(date +%Y%m%d_%H%M%S)

    if [[ -f "$RULES_V4" ]]; then
        cp "$RULES_V4" "${RULES_V4}.bak.${BACKUP_TS}"
        log_info "Backed up ${RULES_V4} → ${RULES_V4}.bak.${BACKUP_TS}"
    fi
    if [[ -f "$RULES_V6" ]]; then
        cp "$RULES_V6" "${RULES_V6}.bak.${BACKUP_TS}"
        log_info "Backed up ${RULES_V6} → ${RULES_V6}.bak.${BACKUP_TS}"
    fi

    # Detect primary network interface
    PRIMARY_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    PRIMARY_IFACE="${PRIMARY_IFACE:-eth0}"

    # Write IPv4 rules
    cat > "$RULES_V4" <<RULES4_EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Loopback
-A INPUT -i lo -j ACCEPT

# Established & related connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Drop invalid packets early
-A INPUT -m conntrack --ctstate INVALID -j DROP

# SSH brute-force protection: max 6 new connections per 60s per IP
-A INPUT -p tcp --dport ${SSH_PORT} -m conntrack --ctstate NEW -m recent --set --name SSH --rsource
-A INPUT -p tcp --dport ${SSH_PORT} -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 6 --name SSH --rsource -j DROP

# Allow SSH
-A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT

# Allow AmneziaWG (UDP)
-A INPUT -p udp --dport ${AWG_PORT} -j ACCEPT

# Allow ICMP ping
-A INPUT -p icmp --icmp-type echo-request -j ACCEPT

# Allow VPN interface traffic
-A INPUT -i ${VPN_INTERFACE} -j ACCEPT

# Forward VPN traffic
-A FORWARD -i ${VPN_INTERFACE} -j ACCEPT
-A FORWARD -o ${VPN_INTERFACE} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]

# NAT for VPN clients
-A POSTROUTING -s ${VPN_SUBNET}.0/24 -o ${PRIMARY_IFACE} -j MASQUERADE

COMMIT
RULES4_EOF

    # Write IPv6 rules
    cat > "$RULES_V6" <<RULES6_EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Loopback
-A INPUT -i lo -j ACCEPT

# Established & related connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Drop invalid packets early
-A INPUT -m conntrack --ctstate INVALID -j DROP

# Allow SSH
-A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT

# Allow AmneziaWG (UDP)
-A INPUT -p udp --dport ${AWG_PORT} -j ACCEPT

# Allow ICMPv6 (required for IPv6 neighbor discovery, etc.)
-A INPUT -p icmpv6 -j ACCEPT

COMMIT
RULES6_EOF

    # Load rules atomically
    $IPTABLES_RESTORE < "$RULES_V4"
    log_info "IPv4 rules loaded: SSH ${SSH_PORT}/tcp, AmneziaWG ${AWG_PORT}/udp"

    $IP6TABLES_RESTORE < "$RULES_V6" 2>/dev/null || log_warn "IPv6 rules skipped (ip6tables not available)."

    # Persist rules across reboots (distro-specific)
    case "$INIT_SYSTEM" in
        systemd)
            systemctl enable netfilter-persistent 2>/dev/null || true
            ;;
        openrc)
            # Create a simple init script that restores rules on boot
            local OPENRC_RUN
            if [[ -x /sbin/openrc-run ]]; then
                OPENRC_RUN="/sbin/openrc-run"
            elif [[ -x /usr/sbin/openrc-run ]]; then
                OPENRC_RUN="/usr/sbin/openrc-run"
            else
                OPENRC_RUN="/sbin/openrc-run"
            fi

            cat > /etc/init.d/iptables-awg <<FWEOF
#!${OPENRC_RUN}
# Restore iptables rules on boot

name="iptables-awg"
description="Restore iptables rules for AmneziaWG"

depend() {
    before amneziawg
    need net
}

start() {
    local PATH="/usr/sbin:/sbin:/usr/bin:/bin:\${PATH}"
    ebegin "Restoring iptables rules"
    if [ -f /etc/iptables/rules.v4 ]; then
        ${IPTABLES_RESTORE} < /etc/iptables/rules.v4
    fi
    if [ -f /etc/iptables/rules.v6 ] && command -v ${IP6TABLES_RESTORE} >/dev/null 2>&1; then
        ${IP6TABLES_RESTORE} < /etc/iptables/rules.v6
    fi
    eend \$?
}

stop() {
    local PATH="/usr/sbin:/sbin:/usr/bin:/bin:\${PATH}"
    ebegin "Flushing iptables rules"
    ${IPTABLES} -F
    ${IPTABLES} -P INPUT ACCEPT
    eend \$?
}
FWEOF
            chmod +x /etc/init.d/iptables-awg
            svc_enable iptables-awg
            log_info "Created /etc/init.d/iptables-awg for boot persistence."
            ;;
    esac

    log_info "Firewall configured and will persist across reboots."
}

# ────────────────────────────────────────────────────────────
#  Step 11: Apply sysctl optimizations
# ────────────────────────────────────────────────────────────
optimize_sysctl() {
    log_step "11" "Applying network optimizations (BBR + buffers)"

    mkdir -p /etc/sysctl.d

    cat > /etc/sysctl.d/99-awg-optimize.conf <<'SYSCTL_EOF'
# === TCP BBR Congestion Control ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === TCP Buffer Tuning ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# === Connection Tuning ===
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# === IP Forwarding (VPN) ===
net.ipv4.ip_forward = 1

# === Security ===
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
SYSCTL_EOF

    sysctl --system > /dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-awg-optimize.conf > /dev/null 2>&1
    log_info "BBR congestion control and TCP optimizations applied."
}

# ────────────────────────────────────────────────────────────
#  Step 12: Create service and start AmneziaWG
# ────────────────────────────────────────────────────────────
create_service() {
    log_step "12" "Creating AmneziaWG service"

    case "$INIT_SYSTEM" in
        systemd)
            create_systemd_service
            ;;
        openrc)
            create_openrc_service
            ;;
    esac
}

create_systemd_service() {
    if [[ "$AWG_MODE" == "kernel" ]]; then
        # Use awg-quick for kernel module
        log_info "Using awg-quick@awg0 service (kernel mode)."
        # Service file is provided by amneziawg package
    else
        # Create custom service using awg-quick (handles both kernel and userspace)
        log_info "Creating custom systemd service."

        cat > /etc/systemd/system/amneziawg.service <<SVCEOF
[Unit]
Description=AmneziaWG VPN tunnel
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/awg-quick up ${AWG_CONFIG}
ExecStop=/usr/local/bin/awg-quick down ${AWG_CONFIG}

[Install]
WantedBy=multi-user.target
SVCEOF

        systemctl daemon-reload
    fi
}

create_openrc_service() {
    log_info "Creating OpenRC service."

    # Detect openrc-run path
    local OPENRC_RUN
    if [[ -x /sbin/openrc-run ]]; then
        OPENRC_RUN="/sbin/openrc-run"
    elif [[ -x /usr/sbin/openrc-run ]]; then
        OPENRC_RUN="/usr/sbin/openrc-run"
    else
        OPENRC_RUN="/sbin/openrc-run"
    fi

    # Use awg-quick which handles both kernel and userspace modes automatically
    cat > /etc/init.d/amneziawg <<INITEOF
#!${OPENRC_RUN}
# OpenRC init script for AmneziaWG

name="amneziawg"
description="AmneziaWG VPN tunnel"

depend() {
    need net
    after firewall iptables-awg
}

start() {
    local PATH="/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin:\${PATH}"
    ebegin "Starting AmneziaWG"
    awg-quick up ${AWG_CONFIG}
    eend \$?
}

stop() {
    local PATH="/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin:\${PATH}"
    ebegin "Stopping AmneziaWG"
    awg-quick down ${AWG_CONFIG}
    eend \$?
}
INITEOF

    chmod +x /etc/init.d/amneziawg
    log_info "Created /etc/init.d/amneziawg init script."
}

start_amneziawg() {
    log_step "12b" "Starting AmneziaWG service"

    local SVC_NAME
    if [[ "$INIT_SYSTEM" == "systemd" && "$AWG_MODE" == "kernel" ]]; then
        SVC_NAME="awg-quick@awg0"
    else
        SVC_NAME="amneziawg"
    fi

    svc_enable "$SVC_NAME"
    svc_stop "$SVC_NAME" 2>/dev/null || true
    sleep 1
    svc_start "$SVC_NAME"

    sleep 2
    # Check if interface is up (awg-quick is oneshot, so service status check doesn't work)
    if ip link show "$VPN_INTERFACE" &>/dev/null; then
        log_info "AmneziaWG is running successfully!"
        log_info "Interface ${VPN_INTERFACE} is up."
    else
        log_error "AmneziaWG failed to start. Check configuration."
        exit 1
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 13: Print summary & client connection info
# ────────────────────────────────────────────────────────────
print_summary() {
    log_step "13" "Setup complete!"

    # Build distro-appropriate management commands
    local SVC_NAME SVC_STATUS SVC_RESTART SVC_LOGS FW_RELOAD
    if [[ "$INIT_SYSTEM" == "systemd" && "$AWG_MODE" == "kernel" ]]; then
        SVC_NAME="awg-quick@awg0"
    else
        SVC_NAME="amneziawg"
    fi

    case "$INIT_SYSTEM" in
        systemd)
            SVC_STATUS="systemctl status ${SVC_NAME}"
            SVC_RESTART="systemctl restart ${SVC_NAME}"
            SVC_LOGS="journalctl -u ${SVC_NAME} -f"
            FW_RELOAD="netfilter-persistent reload"
            ;;
        openrc)
            SVC_STATUS="rc-service amneziawg status"
            SVC_RESTART="rc-service amneziawg restart"
            SVC_LOGS="tail -f ${AWG_LOG_DIR}/amneziawg.log"
            FW_RELOAD="rc-service iptables-awg restart"
            ;;
    esac

    echo ""
    echo -e "${GREEN}  ✔ AmneziaWG is running on UDP port ${AWG_PORT}${NC}"
    echo -e "${GREEN}  ✔ Firewall configured with NAT${NC}"
    echo -e "${GREEN}  ✔ IP forwarding enabled${NC}"
    echo -e "${GREEN}  ✔ BBR congestion control enabled${NC}"
    if [[ "$ENABLE_LOGS" == "y" ]]; then
        echo -e "${GREEN}  ✔ Debug logging enabled${NC}"
    else
        echo -e "${GREEN}  ✔ Logging disabled (no connection data stored)${NC}"
    fi
    echo -e "${GREEN}  ✔ Mode: ${AWG_MODE}${NC}"
    echo -e "${GREEN}  ✔ Distro: ${DISTRO} / Init: ${INIT_SYSTEM}${NC}"
    echo ""

    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "  ${RED}${BOLD}⚠ SSH PORT CHANGED to ${SSH_PORT}! (${SSH_DAEMON})${NC}"
        echo -e "  ${RED}  Reconnect with: ssh -p ${SSH_PORT} root@${SERVER_IP}${NC}"
        echo ""
    fi

    # ── Ask: Show credentials? ──
    if [[ "$SECURE_ENV" == "y" ]]; then
        echo -e "  ${BOLD}Display server credentials now?${NC}"
        echo -e "  ${YELLOW}⚠ Contains sensitive data (private keys).${NC}"
        echo ""
        read -rp "  Show credentials? [Y/n]: " SHOW_CREDS
        SHOW_CREDS="${SHOW_CREDS:-y}"
    else
        log_info "Credentials display skipped (safe mode)."
        SHOW_CREDS="n"
    fi

    if [[ "${SHOW_CREDS,,}" == "y" || "${SHOW_CREDS,,}" == "yes" ]]; then
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}  ${BOLD}SERVER CREDENTIALS${NC}                                      ${CYAN}║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  Server IP:      ${GREEN}${SERVER_IP}${NC}"
        echo -e "${CYAN}║${NC}  AWG Port:       ${GREEN}${AWG_PORT}/udp${NC}"
        echo -e "${CYAN}║${NC}  SSH Port:       ${GREEN}${SSH_PORT}/tcp${NC}"
        echo -e "${CYAN}║${NC}  VPN Subnet:     ${GREEN}${VPN_SUBNET}.0/24${NC}"
        echo -e "${CYAN}║${NC}  Server Address: ${GREEN}${VPN_SUBNET}.1${NC}"
        echo -e "${CYAN}║${NC}  Client Address: ${GREEN}${VPN_SUBNET}.2${NC}"
        echo -e "${CYAN}║${NC}  DNS:            ${GREEN}${DNS_NAME} (${DNS_IP})${NC}"
        echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  ${BOLD}Obfuscation Parameters:${NC}                                ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  Jc=${AWG_JC} Jmin=${AWG_JMIN} Jmax=${AWG_JMAX} S1=${AWG_S1} S2=${AWG_S2}"
        echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
    else
        log_info "Credentials hidden. You can view them later via the save file or config."
    fi

    # ── Ask: Show client config? ──
    if [[ "$SECURE_ENV" == "y" ]]; then
        echo -e "  ${BOLD}Display client configuration now?${NC}"
        echo -e "  ${YELLOW}⚠ This contains the client private key and obfuscation params.${NC}"
        echo ""
        read -rp "  Show client config? [Y/n]: " SHOW_CONFIG
        SHOW_CONFIG="${SHOW_CONFIG:-y}"
    else
        log_info "Client config display skipped (safe mode)."
        SHOW_CONFIG="n"
    fi

    if [[ "${SHOW_CONFIG,,}" == "y" || "${SHOW_CONFIG,,}" == "yes" ]]; then
        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}CLIENT CONFIGURATION (copy to AmneziaVPN app):${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "${GREEN}${CLIENT_CONFIG}${NC}"
        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo ""
    else
        log_info "Client config hidden. You can retrieve it later via the save file."
    fi

    # ── Ask: Show QR code? ──
    if [[ "$SECURE_ENV" == "y" ]]; then
        echo -e "  ${BOLD}Display QR code for client import?${NC}"
        echo -e "  ${YELLOW}⚠ The QR code contains the client config with all credentials.${NC}"
        echo ""
        read -rp "  Show QR code? [Y/n]: " SHOW_QR
        SHOW_QR="${SHOW_QR:-y}"
    else
        log_info "QR code display skipped (safe mode)."
        SHOW_QR="n"
    fi

    if [[ "${SHOW_QR,,}" == "y" || "${SHOW_QR,,}" == "yes" ]]; then
        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}Scan with AmneziaVPN app:${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo ""
        qrencode -t ANSIUTF8 "$CLIENT_CONFIG"
        echo ""
    else
        log_info "QR code hidden. You can generate it later with the save file."
    fi

    # ── Always show: non-sensitive management info ──
    echo -e "  ${BOLD}Recommended Client Apps:${NC}"
    echo -e "    • Android/iOS:  ${GREEN}AmneziaVPN${NC}"
    echo -e "    • Windows:      ${GREEN}AmneziaVPN${NC}"
    echo -e "    • macOS:        ${GREEN}AmneziaVPN${NC}"
    echo -e "    • Linux:        ${GREEN}AmneziaVPN / awg-quick${NC}"
    echo ""
    echo -e "  ${BOLD}Manage AmneziaWG:${NC}"
    echo -e "    Status:    ${YELLOW}${SVC_STATUS}${NC}"
    echo -e "    Restart:   ${YELLOW}${SVC_RESTART}${NC}"
    if [[ "$ENABLE_LOGS" == "y" ]]; then
        echo -e "    Logs:      ${YELLOW}${SVC_LOGS}${NC}"
    else
        echo -e "    Logs:      ${YELLOW}disabled${NC}"
    fi
    echo -e "    Config:    ${YELLOW}nano ${AWG_CONFIG}${NC}"
    echo -e "    Show peers:${YELLOW}awg show${NC}"
    echo ""
    echo -e "  ${BOLD}Firewall:${NC}"
    echo -e "    View rules:  ${YELLOW}iptables -L -n --line-numbers${NC}"
    echo -e "    Reload:      ${YELLOW}${FW_RELOAD}${NC}"
    echo ""
    echo -e "  ${BOLD}Add more clients:${NC}"
    echo -e "    1. Generate new keypair:  ${YELLOW}awg genkey | tee privatekey | awg pubkey > publickey${NC}"
    echo -e "    2. Add [Peer] section to: ${YELLOW}${AWG_CONFIG}${NC}"
    echo -e "    3. Restart service:       ${YELLOW}${SVC_RESTART}${NC}"
    echo ""

    # ── Ask: Save credentials to file? ──
    if [[ "$SECURE_ENV" == "y" ]]; then
        echo -e "  ${BOLD}Save credentials to /root/amneziawg-credentials.txt?${NC}"
        echo -e "  This file will contain your private keys and client config."
        echo -e "  ${YELLOW}⚠ Convenient but a security risk if the server is compromised.${NC}"
        echo ""
        read -rp "  Save credentials to file? [y/N]: " SAVE_CREDS
    else
        echo ""
        echo -e "  ${BOLD}Save credentials to /root/amneziawg-credentials.txt?${NC}"
        echo -e "  Since you're in safe mode, this is the recommended way to"
        echo -e "  retrieve your credentials later in a secure environment."
        echo ""
        read -rp "  Save credentials to file? [Y/n]: " SAVE_CREDS
        SAVE_CREDS="${SAVE_CREDS:-y}"
    fi

    if [[ "${SAVE_CREDS,,}" == "y" || "${SAVE_CREDS,,}" == "yes" ]]; then
        CREDS_FILE="/root/amneziawg-credentials.txt"

        cat > "$CREDS_FILE" <<CREDS_EOF
===== AMNEZIAWG SERVER CREDENTIALS =====
Generated: $(date)
Distro:       ${DISTRO} / ${INIT_SYSTEM}
Mode:         ${AWG_MODE}
SSH daemon:   ${SSH_DAEMON}
Logging:      $(if [[ "$ENABLE_LOGS" == "y" ]]; then echo "enabled"; else echo "disabled"; fi)

Server IP:    ${SERVER_IP}
AWG Port:     ${AWG_PORT}/udp
SSH Port:     ${SSH_PORT}/tcp
VPN Subnet:   ${VPN_SUBNET}.0/24
DNS:          ${DNS_NAME} (${DNS_IP})

=== SERVER KEYS ===
Server Private Key: ${SERVER_PRIVATE_KEY}
Server Public Key:  ${SERVER_PUBLIC_KEY}

=== CLIENT KEYS ===
Client Private Key: ${CLIENT_PRIVATE_KEY}
Client Public Key:  ${CLIENT_PUBLIC_KEY}
Preshared Key:      ${PRESHARED_KEY}

=== OBFUSCATION PARAMETERS ===
Jc   = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1   = ${AWG_S1}
S2   = ${AWG_S2}
H1   = ${AWG_H1}
H2   = ${AWG_H2}
H3   = ${AWG_H3}
H4   = ${AWG_H4}

=== CLIENT CONFIGURATION ===
(Copy this to AmneziaVPN app or save as .conf file)

${CLIENT_CONFIG}

=== MANAGEMENT ===
Config file:  ${AWG_CONFIG}
Status:       ${SVC_STATUS}
Restart:      ${SVC_RESTART}
Firewall:     ${FW_RELOAD}
SSH:          ssh -p ${SSH_PORT} root@${SERVER_IP}
CREDS_EOF
        chmod 600 "$CREDS_FILE"
        log_info "Credentials saved to ${CREDS_FILE}"
    else
        log_info "Credentials NOT saved to disk. Make sure you have them recorded."
    fi
}

# ────────────────────────────────────────────────────────────
#  Main
# ────────────────────────────────────────────────────────────
main() {
    print_header
    check_root
    check_secure_environment
    confirm_proceed
    detect_environment
    prepare_system
    install_amneziawg
    choose_ssh_port
    choose_awg_port
    choose_dns
    choose_logging
    generate_credentials
    generate_obfuscation_params
    write_server_config
    enable_ip_forwarding
    configure_firewall
    optimize_sysctl
    create_service
    start_amneziawg
    print_summary
}

main "$@"
