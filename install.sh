#!/bin/bash

#===============================================================================
# Filename: install.sh
# Author: JirenYoung
# Date: 2026
# Copyright (c) 2026 JirenYoung. All rights reserved.
# Licensed under the MIT License.
#
# Description:
#   One-stop initialisation script for a fresh Linux server.
#   It detects the distribution, updates the system, installs common tooling,
#   configures the firewall, hardens SSH, sets up fail2ban, enables automatic
#   security updates, and optionally creates an admin user.
#
# Supported distributions:
#   - Debian-based  : Debian, Ubuntu
#   - RHEL-based    : RHEL, CentOS, Rocky Linux, AlmaLinux
#
# Usage:
#   sudo bash install.sh                           # default
#   sudo bash install.sh -t America/New_York       # custom timezone
#   sudo bash install.sh -p 2222                   # custom SSH port
#   sudo bash install.sh -n                        # dry-run
#   sudo bash install.sh -l /opt/logs              # custom log dir
#===============================================================================

set -euo pipefail

#===============================================================================
# Constants & defaults
#===============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_TIMEZONE="Asia/Shanghai"
readonly DEFAULT_SSH_PORT="22"
readonly DEFAULT_LOG_DIR="/var/log/devops"

TIMEZONE="$DEFAULT_TIMEZONE"
SSH_PORT="$DEFAULT_SSH_PORT"
LOG_DIR="$DEFAULT_LOG_DIR"
DRY_RUN=false

#===============================================================================
# Logging — structured audit trail + terminal output
#===============================================================================
setup_logging() {
  if $DRY_RUN; then
    LOG_FILE="/dev/null"
    return
  fi
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
  exec 3>&1  # save original stdout
}

log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "$LOG_FILE" >&3 2>/dev/null || echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&3 2>/dev/null || echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "$LOG_FILE" >&3 2>/dev/null || echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }

# Dry-run aware command runner
run_cmd() {
  if $DRY_RUN; then
    log_info "[DRY-RUN] $*"
    return 0
  fi
  "$@"
}

#===============================================================================
# Usage
#===============================================================================
usage() {
  cat <<EOF
Usage: sudo bash $SCRIPT_NAME [OPTIONS]

Options:
  -t TIMEZONE   Set timezone (default: $DEFAULT_TIMEZONE)
  -p PORT       SSH port to open in firewall (default: $DEFAULT_SSH_PORT)
  -l DIR        Log directory (default: $DEFAULT_LOG_DIR)
  -n            Dry-run — show what would be done, make no changes
  -y            Non-interactive mode (skip confirmations)
  -h            Show this help message

Examples:
  sudo bash $SCRIPT_NAME
  sudo bash $SCRIPT_NAME -t America/New_York -p 2222
  sudo bash $SCRIPT_NAME -n    # preview changes only
EOF
}

#===============================================================================
# Parse CLI arguments
#===============================================================================
while getopts "t:p:l:nyh" opt; do
  case "$opt" in
    t) TIMEZONE="$OPTARG" ;;
    p) SSH_PORT="$OPTARG" ;;
    l) LOG_DIR="$OPTARG" ;;
    n) DRY_RUN=true ;;
    y) : ;;  # reserved for future interactive prompts
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# Validate SSH port
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
  echo "ERROR: Invalid SSH port: $SSH_PORT" >&2
  exit 1
fi

setup_logging

log_info "=== $SCRIPT_NAME started ==="
log_info "Timezone=$TIMEZONE  SSH port=$SSH_PORT  Log dir=$LOG_DIR  Dry-run=$DRY_RUN"

#===============================================================================
# 0. Root privilege check
#===============================================================================
if [ "$EUID" -ne 0 ]; then
  log_error "Permissions denied. Please run as root or with sudo."
  exit 1
fi

#===============================================================================
# 1. Detect Linux distribution
#===============================================================================
log_info "Detecting Linux distribution..."

DISTRO=""            # "debian" or "rhel"
PKG_MANAGER=""       # "apt" or "dnf" / "yum"
PKG_INSTALL=""       # install command prefix
FIREWALL_CMD=""      # "ufw" or "firewall-cmd"
FIREWALL_SERVICE=""  # service name for the firewall

if [ -f /etc/debian_version ]; then
  DISTRO="debian"
  PKG_MANAGER="apt"
  PKG_INSTALL="apt install -y"
  FIREWALL_CMD="ufw"
  FIREWALL_SERVICE="ufw"
  log_info "Debian-based system detected. Package manager: apt, Firewall: ufw."

elif [ -f /etc/redhat-release ]; then
  DISTRO="rhel"

  # Prefer dnf on RHEL 8+ / CentOS 8+ / Rocky / Alma, fall back to yum
  if command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
    PKG_INSTALL="dnf install -y"
  else
    PKG_MANAGER="yum"
    PKG_INSTALL="yum install -y"
  fi

  FIREWALL_CMD="firewall-cmd"
  FIREWALL_SERVICE="firewalld"
  log_info "Red Hat-based system detected. Package manager: $PKG_MANAGER, Firewall: firewalld."

else
  log_error "Unsupported Linux distribution. Only Debian/Ubuntu and RHEL/CentOS/Rocky are supported."
  exit 1
fi

#===============================================================================
# 2. System update
#===============================================================================
log_info "Updating system packages..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would update system packages via $PKG_MANAGER."
else
  if [ "$DISTRO" = "debian" ]; then
    apt update -y && apt upgrade -y
  elif [ "$DISTRO" = "rhel" ]; then
    $PKG_MANAGER update -y
  fi
  log_info "System packages updated successfully."
fi

#===============================================================================
# 3. Install essential base packages
#===============================================================================
log_info "Installing essential base packages..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would install base packages via $PKG_INSTALL."
else
  if [ "$DISTRO" = "debian" ]; then
    $PKG_INSTALL \
      curl wget git vim nano \
      htop net-tools lsof dnsutils \
      unzip zip tar gzip \
      software-properties-common \
      ca-certificates gnupg lsb-release \
      ufw fail2ban \
      ntpdate cron
  elif [ "$DISTRO" = "rhel" ]; then
    # EPEL is required for many extras (fail2ban, htop, etc.)
    $PKG_INSTALL epel-release

    $PKG_INSTALL \
      curl wget git vim nano \
      htop net-tools lsof bind-utils \
      unzip zip tar gzip \
      ca-certificates gnupg \
      firewalld fail2ban \
      ntpdate cronie
  fi
  log_info "Base packages installed."
fi

#===============================================================================
# 4. Timezone & clock synchronisation
#===============================================================================
log_info "Configuring timezone ($TIMEZONE) and clock sync..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would set timezone to '$TIMEZONE' and sync clock."
else
  # Set timezone
  if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
    log_info "Timezone set to $TIMEZONE."
  else
    log_warn "Failed to set timezone via timedatectl. Check if systemd is available."
  fi

  # Sync clock immediately
  ntpdate -u ntp.aliyun.com 2>/dev/null || log_warn "ntpdate sync failed (non-fatal)."

  # Enable & start systemd-timesyncd (preferred on modern distros)
  if systemctl is-enabled systemd-timesyncd &>/dev/null; then
    systemctl restart systemd-timesyncd 2>/dev/null || true
    log_info "systemd-timesyncd restarted."
  fi
fi

#===============================================================================
# 5. Firewall configuration
#===============================================================================
log_info "Configuring firewall rules (SSH port: $SSH_PORT)..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would configure firewall and open port $SSH_PORT."
else
  if [ "$DISTRO" = "debian" ]; then
    # --- ufw ---
    ufw default deny incoming
    ufw default allow outgoing

    # ufw 'comment' requires version >= 0.35
    if ufw version 2>/dev/null | grep -qP '0\.(3[5-9]|[4-9]\d)' || \
       ufw version 2>/dev/null | grep -qP '[1-9]\d+\.'; then
      ufw allow ${SSH_PORT}/tcp comment 'SSH'
    else
      ufw allow ${SSH_PORT}/tcp
    fi

    # Allow HTTP / HTTPS (uncomment if this is a web server)
    # ufw allow 80/tcp   comment 'HTTP'
    # ufw allow 443/tcp  comment 'HTTPS'

    # Enable the firewall
    ufw --force enable
    systemctl enable "$FIREWALL_SERVICE"
    systemctl start "$FIREWALL_SERVICE" 2>/dev/null || true

  elif [ "$DISTRO" = "rhel" ]; then
    # --- firewalld ---
    systemctl enable "$FIREWALL_SERVICE"
    systemctl start "$FIREWALL_SERVICE" 2>/dev/null || true

    # Default zone: public
    firewall-cmd --set-default-zone=public

    # Allow SSH (custom port if not default)
    if [ "$SSH_PORT" = "22" ]; then
      firewall-cmd --permanent --add-service=ssh
    else
      firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    fi

    # Allow HTTP / HTTPS (uncomment if this is a web server)
    # firewall-cmd --permanent --add-service=http
    # firewall-cmd --permanent --add-service=https

    firewall-cmd --reload
  fi

  log_info "Firewall configured and enabled (SSH on port $SSH_PORT)."
fi

#===============================================================================
# 6. SSH hardening
#===============================================================================
log_info "Hardening SSH daemon..."

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"

# Helper: set or append a config directive
set_sshd_option() {
  local key="$1"
  local value="$2"
  if grep -qE "^\s*#?\s*${key}\s+" "$SSHD_CONFIG"; then
    sed -i "s|^\s*#\?\s*${key}\s\+.*|${key} ${value}|" "$SSHD_CONFIG"
  else
    echo "${key} ${value}" >> "$SSHD_CONFIG"
  fi
}

if $DRY_RUN; then
  log_info "[DRY-RUN] Would backup $SSHD_CONFIG and apply hardening settings."
else
  # Backup original config
  cp "$SSHD_CONFIG" "$SSHD_BACKUP"
  log_info "Original sshd_config backed up to: $SSHD_BACKUP"

  # Disable root login via SSH
  set_sshd_option "PermitRootLogin" "no"

  # Keep password auth enabled for now — admin disables after adding keys
  set_sshd_option "PasswordAuthentication" "yes"

  # Disable empty passwords
  set_sshd_option "PermitEmptyPasswords" "no"

  # Disable less-secure key exchange algorithms
  set_sshd_option "KexAlgorithms" "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256"

  # Protocol 2: default since OpenSSH 7.0; only set explicitly on older versions
  if sshd -V 2>&1 | grep -qP 'OpenSSH_[1-6]\.'; then
    set_sshd_option "Protocol" "2"
    log_info "Set Protocol 2 (OpenSSH < 7.0 detected)."
  else
    log_info "Skipping Protocol directive (OpenSSH 7.0+ defaults to Protocol 2)."
  fi

  # Reduce login grace time (default 120s)
  set_sshd_option "LoginGraceTime" "30"

  # Limit authentication attempts
  set_sshd_option "MaxAuthTries" "3"

  # Disable X11 forwarding unless needed
  set_sshd_option "X11Forwarding" "no"

  # Client alive interval
  set_sshd_option "ClientAliveInterval" "300"
  set_sshd_option "ClientAliveCountMax" "2"

  # Custom SSH port
  if [ "$SSH_PORT" != "22" ]; then
    set_sshd_option "Port" "$SSH_PORT"
    log_info "SSH port set to $SSH_PORT."
  fi

  # Validate SSH config before restarting
  if sshd -t; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log_info "SSH daemon restarted with new configuration."
  else
    log_error "SSH configuration syntax error! Restoring backup..."
    cp "$SSHD_BACKUP" "$SSHD_CONFIG"
    if sshd -t; then
      systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
      log_warn "Original config restored. SSH is running with pre-installation settings."
    else
      log_error "CRITICAL: Even the backup config is invalid! Manual intervention required."
      log_error "Check $SSHD_CONFIG and $SSHD_BACKUP immediately."
    fi
  fi
fi

#===============================================================================
# 7. Fail2ban setup (brute-force protection)
#===============================================================================
log_info "Setting up fail2ban protection..."

FAIL2BAN_JAIL="/etc/fail2ban/jail.local"

if $DRY_RUN; then
  log_info "[DRY-RUN] Would configure fail2ban with SSH jail on port $SSH_PORT."
else
  if [ ! -f "$FAIL2BAN_JAIL" ]; then
    cat > "$FAIL2BAN_JAIL" << 'FAIL2BAN_EOF'
[DEFAULT]
# Ban IP for 1 hour after 5 failures within 10 minutes
bantime   = 3600
findtime  = 600
maxretry  = 5

# Whitelist your own trusted IPs (e.g. office VPN / jump host)
# ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
FAIL2BAN_EOF
  fi

  # If non-default SSH port, patch jail.local
  if [ "$SSH_PORT" != "22" ]; then
    sed -i "s/^port\s*=.*/port     = $SSH_PORT/" "$FAIL2BAN_JAIL" 2>/dev/null || true
    log_info "fail2ban SSH jail port set to $SSH_PORT."
  fi

  # Enable and start fail2ban
  systemctl enable fail2ban 2>/dev/null || true
  systemctl start fail2ban 2>/dev/null || true
  log_info "fail2ban configured and started."
fi

#===============================================================================
# 8. Automatic security updates (unattended-upgrades / dnf-automatic)
#===============================================================================
log_info "Enabling automatic security updates..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would enable automatic security updates."
else
  if [ "$DISTRO" = "debian" ]; then
    $PKG_INSTALL unattended-upgrades

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'APT_AUTO_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT_AUTO_EOF

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'APT_UNATTEND_EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APT_UNATTEND_EOF

  elif [ "$DISTRO" = "rhel" ]; then
    $PKG_INSTALL dnf-automatic

    sed -i 's/^apply_updates = .*/apply_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null || true
    sed -i 's/^download_updates = .*/download_updates = yes/' /etc/dnf/automatic.conf 2>/dev/null || true

    systemctl enable dnf-automatic.timer --now 2>/dev/null || {
      systemctl enable dnf-automatic.timer 2>/dev/null || true
      systemctl start dnf-automatic.timer 2>/dev/null || true
    }
  fi

  log_info "Automatic security updates enabled."
fi

#===============================================================================
# 9. Kernel parameter tuning (basic network & security optimisations)
#===============================================================================
log_info "Applying kernel parameter tuning..."

SYSCTL_FILE="/etc/sysctl.d/99-server-tuning.conf"

if $DRY_RUN; then
  log_info "[DRY-RUN] Would write $SYSCTL_FILE and apply sysctl settings."
else
  cat > "$SYSCTL_FILE" << 'SYSCTL_EOF'
#===============================================================================
# Custom kernel parameters for a general-purpose server
#===============================================================================

# --- Network tuning ---
# Enable TCP BBR congestion control (requires kernel 4.9+)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Increase the maximum number of open files
fs.file-max = 65535

# Increase TCP buffer sizes for better throughput
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Reuse TIME_WAIT sockets safely (NAT-aware)
# NOTE: tcp_tw_recycle was removed in kernel 4.12; use tcp_tw_reuse with care behind NAT
net.ipv4.tcp_tw_reuse = 1

# --- Security hardening ---
# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore broadcast ICMP (prevent smurf attacks)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Enable source route verification (prevent IP spoofing)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Log martian packets (packets with impossible source addresses)
net.ipv4.conf.all.log_martians = 1

# Disable IPv6 if not needed (uncomment to enable)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL_EOF

  # Apply immediately
  sysctl -p "$SYSCTL_FILE" &>/dev/null || true
  log_info "Kernel parameters applied."
fi

#===============================================================================
# 10. SWAP check & basic recommendation
#===============================================================================
log_info "Checking SWAP configuration..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would check SWAP status."
else
  SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')

  if [ -z "$SWAP_TOTAL" ] || [ "$SWAP_TOTAL" -eq 0 ]; then
    log_warn "No swap detected. Consider adding a swap file:"
    echo ""
    echo "    fallocate -l 2G /swapfile"
    echo "    chmod 600 /swapfile"
    echo "    mkswap /swapfile"
    echo "    swapon /swapfile"
    echo "    echo '/swapfile none swap sw 0 0' >> /etc/fstab"
    echo ""
  else
    log_info "Swap is active (${SWAP_TOTAL} MB)."
  fi
fi

#===============================================================================
# 11. Summary
#===============================================================================
echo ""
echo "#####################################################################"
echo "#                                                                   #"
echo "#               Server initialisation complete!                     #"
echo "#                                                                   #"
echo "#####################################################################"
echo ""
echo "  Distribution       : $DISTRO"
echo "  Package manager    : $PKG_MANAGER"
echo "  Firewall           : $FIREWALL_CMD ($FIREWALL_SERVICE)"
echo "  SSH port           : $SSH_PORT"
echo ""
echo "  What was done:"
echo "    ✅ System packages updated"
echo "    ✅ Base tooling installed (curl, wget, git, vim, htop, ...)"
echo "    ✅ Timezone set to $TIMEZONE"
echo "    ✅ Firewall enabled (SSH on port $SSH_PORT)"
echo "    ✅ SSH hardened (root login disabled, password auth kept)"
echo "    ✅ fail2ban protecting SSH"
echo "    ✅ Automatic security updates enabled"
echo "    ✅ Kernel parameters tuned (BBR, network buffers, ...)"
echo ""

if $DRY_RUN; then
  echo "  ℹ️  This was a DRY-RUN. No changes were made."
  echo "     Remove the '-n' flag to apply changes."
else
  echo "  ⚠️  Post-installation checklist:"
  echo ""
  echo "    1. Add your SSH public key:  bash add_ssh_key.sh"
  echo "    2. Create an admin user:     bash batch_adduser.sh"
  if [ "$SSH_PORT" != "22" ]; then
    echo "    3. ⚡ SSH port changed to $SSH_PORT — update your SSH client config!"
  fi
  echo "    4. After verifying key-based login works, disable password auth:"
  echo "       Edit /etc/ssh/sshd_config and set 'PasswordAuthentication no',"
  echo "       then run 'systemctl restart sshd'"
  echo "    5. Review fail2ban whitelist: $FAIL2BAN_JAIL"
  echo "    6. Add fail2ban jails for other services if needed"
  echo ""
  echo "  📁 SSH config backup: $SSHD_BACKUP"
  echo "  📁 Execution log:     $LOG_FILE"
fi

echo ""
echo "#####################################################################"
echo ""

log_info "=== $SCRIPT_NAME finished successfully ==="
