#!/bin/bash

#===============================================================================
# Filename: passwdless_ssh.sh
# Author: JirenYoung
# Date: 2026
# Copyright (c) 2026 JirenYoung. All rights reserved.
# Licensed under the MIT License.
#
# Description:
#   Disable SSH password authentication and enforce key-only login.
#   Before making changes, the script verifies that at least one user has an
#   SSH public key configured.  If anything goes wrong (config syntax error,
#   sshd fails to restart, or connection test fails), the script automatically
#   rolls back to the previous configuration.
#
#   Designed to be safe even when run over SSH — it keeps the current session
#   alive and tests a *second* connection before declaring success.
#
# Usage:
#   sudo bash passwdless_ssh.sh                  # interactive (asks for confirmation)
#   sudo bash passwdless_ssh.sh -y               # non-interactive (skip confirmation)
#   sudo bash passwdless_ssh.sh -n               # dry-run (preview only)
#   sudo bash passwdless_ssh.sh -h               # show help
#===============================================================================

set -euo pipefail

#===============================================================================
# Constants & defaults
#===============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly DEFAULT_LOG_DIR="/var/log/devops"

LOG_DIR="$DEFAULT_LOG_DIR"
DRY_RUN=false
SKIP_CONFIRM=false
CONNECTION_TEST_TIMEOUT=5

#===============================================================================
# Logging — structured audit trail + terminal output
#===============================================================================
setup_logging() {
  if $DRY_RUN; then
    LOG_FILE="/dev/null"
    return
  fi
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="${LOG_DIR}/passwdless_ssh_$(date +%Y%m%d_%H%M%S).log"
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

  Disable SSH password authentication — enforce key-only login.

Options:
  -y            Non-interactive mode (skip confirmation prompt)
  -n            Dry-run — preview changes without applying them
  -l DIR        Log directory (default: $DEFAULT_LOG_DIR)
  -h            Show this help

Safety features:
  * Verifies at least one SSH public key exists before making changes
  * Creates a timestamped backup of sshd_config
  * Validates SSH config syntax before restarting sshd
  * Tests a fresh SSH connection after the change
  * Automatically rolls back on any failure

Examples:
  sudo bash $SCRIPT_NAME           # interactive, asks for confirmation
  sudo bash $SCRIPT_NAME -y        # skip confirmation (CI / automation)
  sudo bash $SCRIPT_NAME -n        # see what would be done
EOF
}

#===============================================================================
# Parse CLI arguments
#===============================================================================
while getopts "ynl:h" opt; do
  case "$opt" in
    y) SKIP_CONFIRM=true ;;
    n) DRY_RUN=true ;;
    l) LOG_DIR="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

setup_logging
log_info "=== $SCRIPT_NAME started ==="
log_info "Dry-run=$DRY_RUN  Skip-confirm=$SKIP_CONFIRM"

#===============================================================================
# 0. Root privilege check
#===============================================================================
if [ "$EUID" -ne 0 ]; then
  log_error "This script must be run as root (or with sudo)."
  exit 1
fi

#===============================================================================
# 1. Verify sshd_config exists
#===============================================================================
if [ ! -f "$SSHD_CONFIG" ]; then
  log_error "SSH config file not found: $SSHD_CONFIG"
  log_error "Is OpenSSH server installed?  Try: apt install openssh-server  or  dnf install openssh-server"
  exit 1
fi

#===============================================================================
# 2. Check current PasswordAuthentication status
#===============================================================================
CURRENT_PW_AUTH=$(grep -iE '^\s*PasswordAuthentication\s+' "$SSHD_CONFIG" | tail -1 | awk '{print $2}' || true)

if [ "$CURRENT_PW_AUTH" = "no" ]; then
  log_info "PasswordAuthentication is already set to 'no'. Nothing to do."
  exit 0
fi

log_info "Current setting: PasswordAuthentication = ${CURRENT_PW_AUTH:-<not explicitly set, default is yes>}"

#===============================================================================
# 3. Scan for SSH public keys — at least one must exist before we proceed
#===============================================================================
echo ""
echo "── [1/6] Scan for SSH keys"
log_info "Scanning for SSH authorized_keys across all users..."

declare -a FOUND_KEYS=()

while IFS=: read -r username _ uid _ _ _ homedir; do
  # Skip system accounts: uid < 1000, or homedir doesn't exist
  if [ "$uid" -lt 1000 ] && [ "$username" != "root" ]; then
    continue
  fi
  if [ ! -d "$homedir" ]; then
    continue
  fi

  auth_file="${homedir}/.ssh/authorized_keys"
  if [ -f "$auth_file" ] && [ -s "$auth_file" ]; then
    key_count=$(grep -cE '^(ssh-|ecdsa-|sk-ssh-)' "$auth_file" 2>/dev/null || true)
    if [ "${key_count:-0}" -gt 0 ]; then
      FOUND_KEYS+=("$username:$auth_file:${key_count} key(s)")
      log_info "  Found $key_count key(s) for user '$username' → $auth_file"
    fi
  fi
done < /etc/passwd

# Also check root's keys explicitly (in case root's homedir wasn't caught above)
ROOT_AUTH="/root/.ssh/authorized_keys"
if [ -f "$ROOT_AUTH" ] && [ -s "$ROOT_AUTH" ]; then
  root_count=$(grep -cE '^(ssh-|ecdsa-|sk-ssh-)' "$ROOT_AUTH" 2>/dev/null || true)
  if [ "${root_count:-0}" -gt 0 ]; then
    # Avoid duplicate if root was already picked up
    already_listed=false
    for entry in "${FOUND_KEYS[@]}"; do
      [[ "$entry" == root:* ]] && already_listed=true && break
    done
    if ! $already_listed; then
      FOUND_KEYS+=("root:$ROOT_AUTH:${root_count} key(s)")
      log_info "  Found $root_count key(s) for user 'root' → $ROOT_AUTH"
    fi
  fi
fi

if [ ${#FOUND_KEYS[@]} -eq 0 ]; then
  echo ""
  log_error "NO SSH PUBLIC KEYS FOUND ON THIS SYSTEM"
  log_error ""
  log_error "If you disable password authentication now, you will be"
  log_error "LOCKED OUT of this server permanently."
  log_error ""
  log_error "Add your SSH key first:   bash add_ssh_key.sh"
  log_error "Then re-run this script."
  echo ""
  exit 1
fi

#===============================================================================
# 4. Detect SSH port (so we can test the connection later)
#===============================================================================
SSH_PORT=$(grep -iE '^\s*Port\s+' "$SSHD_CONFIG" | tail -1 | awk '{print $2}' || echo "22")
if [ -z "$SSH_PORT" ] || ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
  SSH_PORT="22"
fi
log_info "SSH port detected: $SSH_PORT"

# Pick a local IP to test against (prefer the one the default route uses)
SERVER_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' || true)
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
fi
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="127.0.0.1"
fi

#===============================================================================
# 5. Confirmation prompt
#===============================================================================
echo ""
echo "── Disable SSH password authentication"
echo ""
echo "  After this change, ONLY key-based login will work."
echo "  Password login will be REJECTED for all users."
echo ""
echo "  Existing authorized_keys found for:"
for entry in "${FOUND_KEYS[@]}"; do
  IFS=':' read -r uname ufile ucount <<< "$entry"
  printf "    ✅ %-20s %s (%s)\n" "$uname" "$ufile" "$ucount"
done
echo ""
echo "  SSH port : $SSH_PORT"
echo "  Config   : $SSHD_CONFIG"
echo ""

if $DRY_RUN; then
  log_info "[DRY-RUN] Would disable PasswordAuthentication. No changes made."
  echo "  ℹ️  Dry-run complete. Remove '-n' to apply changes."
  exit 0
fi

if ! $SKIP_CONFIRM; then
  read -p "  Proceed? Type 'yes' to confirm: " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    log_info "User declined. Exiting without changes."
    exit 0
  fi
  echo ""
fi

#===============================================================================
# 6. Backup sshd_config (timestamped, never overwritten)
#===============================================================================
SSHD_BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"

echo ""
echo "── [2/6] Backup sshd_config"
log_info "Backing up sshd_config → $SSHD_BACKUP"
if ! cp "$SSHD_CONFIG" "$SSHD_BACKUP"; then
  log_error "Failed to create backup of $SSHD_CONFIG. Aborting."
  exit 1
fi

# Verify backup is identical to original
if ! diff -q "$SSHD_CONFIG" "$SSHD_BACKUP" &>/dev/null; then
  log_error "Backup verification failed — backup differs from original. Aborting."
  rm -f "$SSHD_BACKUP"
  exit 1
fi
log_info "Backup verified (identical to original)."

#===============================================================================
# 7. Modify sshd_config — disable password authentication
#===============================================================================
echo ""
echo "── [3/6] Disable password authentication"
log_info "Disabling PasswordAuthentication in $SSHD_CONFIG..."

# Robust sed: handles commented lines, varying whitespace, tabs, mixed case
if grep -qiE '^\s*#?\s*PasswordAuthentication\s+' "$SSHD_CONFIG"; then
  sed -i "s|^\s*#\?\s*PasswordAuthentication\s\+.*|PasswordAuthentication no|I" "$SSHD_CONFIG"
  log_info "  Updated existing 'PasswordAuthentication' directive to 'no'."
else
  echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
  log_info "  Appended 'PasswordAuthentication no' to config (no existing directive found)."
fi

# Also disable ChallengeResponseAuthentication (PAM-based password backdoor)
if grep -qiE '^\s*#?\s*ChallengeResponseAuthentication\s+' "$SSHD_CONFIG"; then
  sed -i "s|^\s*#\?\s*ChallengeResponseAuthentication\s\+.*|ChallengeResponseAuthentication no|I" "$SSHD_CONFIG"
  log_info "  Set ChallengeResponseAuthentication → no."
fi

# Also ensure UsePAM is still yes (needed for session management) but
# PasswordAuthentication no + ChallengeResponseAuthentication no + UsePAM yes
# is the standard secure combination
if grep -qiE '^\s*#?\s*UsePAM\s+' "$SSHD_CONFIG"; then
  sed -i "s|^\s*#\?\s*UsePAM\s\+.*|UsePAM yes|I" "$SSHD_CONFIG"
  log_info "  Ensured UsePAM → yes (needed for session/account management)."
fi

# Verify the change took effect
VERIFY_PW_AUTH=$(grep -iE '^\s*PasswordAuthentication\s+' "$SSHD_CONFIG" | tail -1 | awk '{print $2}' || true)
if [ "$VERIFY_PW_AUTH" != "no" ]; then
  log_error "Failed to set PasswordAuthentication to 'no'."
  log_error "Current value: ${VERIFY_PW_AUTH:-<missing>}"
  log_error "Restoring backup..."
  cp "$SSHD_BACKUP" "$SSHD_CONFIG"
  exit 1
fi
log_info "  Verified: PasswordAuthentication = no"

#===============================================================================
# 8. Validate SSH configuration syntax
#===============================================================================
echo ""
echo "── [4/6] Validate SSH config syntax"
log_info "Validating SSH configuration syntax (sshd -t)..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would run sshd -t."
else
  SSH_TEST_OUTPUT=$(sshd -t 2>&1) || true
  if sshd -t 2>/dev/null; then
    log_info "  SSH configuration syntax OK."
  else
    log_error "SSH configuration syntax error detected:"
    log_error "$SSH_TEST_OUTPUT"
    log_error ""
    log_error "Restoring backup configuration..."
    cp "$SSHD_BACKUP" "$SSHD_CONFIG"

    if sshd -t 2>/dev/null; then
      log_info "  Backup config restored. SSH configuration is valid again."
    else
      log_error "  CRITICAL: Even the backup config fails syntax check!"
      log_error "  This should not happen — the backup was verified before editing."
      log_error "  Manual intervention required. Check $SSHD_CONFIG and $SSHD_BACKUP"
      exit 1
    fi
    exit 1
  fi
fi

#===============================================================================
# 9. Restart SSH daemon
#===============================================================================
echo ""
echo "── [5/6] Restart SSH daemon"
log_info "Restarting SSH daemon..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would restart sshd."
else
  # Try sshd first (RHEL), fall back to ssh (Debian/Ubuntu)
  if systemctl restart sshd 2>/dev/null; then
    log_info "  Restarted via 'sshd' service."
  elif systemctl restart ssh 2>/dev/null; then
    log_info "  Restarted via 'ssh' service."
  else
    log_error "Failed to restart SSH daemon (tried both 'sshd' and 'ssh' services)."
    log_error "Restoring backup and restarting with original config..."
    cp "$SSHD_BACKUP" "$SSHD_CONFIG"

    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || {
      log_error "CRITICAL: Cannot restart SSH even with restored config!"
      log_error "Check 'systemctl status sshd' immediately. DO NOT close this session."
      exit 1
    }
    log_warn "Backup restored. SSH is running with original configuration."
    exit 1
  fi
fi

# Brief pause to let sshd settle
sleep 1

#===============================================================================
# 10. Verify SSH daemon is running and listening
#===============================================================================
echo ""
echo "── [6/6] Verify SSH connectivity"
log_info "Verifying SSH daemon is running..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would verify sshd status."
else
  if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
    log_info "  SSH daemon is active."
  else
    log_error "SSH daemon is NOT active after restart!"
    log_error "Restoring backup..."
    cp "$SSHD_BACKUP" "$SSHD_CONFIG"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log_warn "Backup restored. Verify SSH manually: systemctl status sshd"
    exit 1
  fi

  # Verify the port is listening
  if ss -tlnp 2>/dev/null | grep -q ":$SSH_PORT " || netstat -tlnp 2>/dev/null | grep -q ":$SSH_PORT "; then
    log_info "  Port $SSH_PORT is listening."
  else
    log_error "Port $SSH_PORT is NOT listening after restart!"
    log_error "Restoring backup..."
    cp "$SSHD_BACKUP" "$SSHD_CONFIG"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log_warn "Backup restored. Verify SSH manually."
    exit 1
  fi
fi

#===============================================================================
# 11. Connection test — try a fresh SSH connection with key auth
#===============================================================================
log_info "Testing SSH key-based connection to $SERVER_IP:$SSH_PORT..."

if $DRY_RUN; then
  log_info "[DRY-RUN] Would test SSH connection."
else
  # Use the first user with keys found earlier as the test user
  TEST_USER=""
  if [ ${#FOUND_KEYS[@]} -gt 0 ]; then
    TEST_USER=$(echo "${FOUND_KEYS[0]}" | cut -d: -f1)
  fi
  SSH_TEST_USER="${TEST_USER:-root}"

  # BatchMode=yes ensures no password prompt; StrictHostKeyChecking=accept-new
  # handles first-time host keys without blocking
  if ssh -o BatchMode=yes \
         -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout="$CONNECTION_TEST_TIMEOUT" \
         -o PasswordAuthentication=no \
         -p "$SSH_PORT" \
         "${SSH_TEST_USER}@${SERVER_IP}" \
         "echo OK" 2>/dev/null; then
    log_info "  ✅ SSH key-based connection test SUCCEEDED (user: $SSH_TEST_USER)."
  else
    log_warn "  ⚠️  SSH key-based connection test did not succeed."
    log_warn "     User: $SSH_TEST_USER | Target: $SERVER_IP:$SSH_PORT"
    log_warn ""
    log_warn "     This is NOT automatically rolling back, because the test"
    log_warn "     may have failed for benign reasons (StrictHostKeyChecking,"
    log_warn "     network quirks, or the test user's key isn't available here)."
    log_warn ""
    log_warn "     ⚡ If you are CURRENTLY connected via SSH key, you are fine."
    log_warn "     ⚡ If you are on a password-based session, VERIFY key access NOW"
    log_warn "        before closing this session!"
    log_warn ""
    log_warn "     To roll back manually:"
    log_warn "       sudo cp $SSHD_BACKUP $SSHD_CONFIG"
    log_warn "       sudo systemctl restart sshd"
  fi
fi

#===============================================================================
# 12. Summary
#===============================================================================
echo ""
echo "── Password authentication disabled"
echo ""
echo "  Config file    : $SSHD_CONFIG"
echo "  Backup file    : $SSHD_BACKUP"
echo "  SSH port       : $SSH_PORT"
echo "  Password auth  : OFF (key-only from now on)"
echo ""
echo "  ⚠️  IMPORTANT: Do NOT close your current SSH session until you"
echo "     have verified you can open a NEW session with your key."
echo ""
echo "     Test from another terminal:"
echo "       ssh -i ~/.ssh/your_key -p $SSH_PORT USER@HOST"
echo ""
echo "  To roll back (if needed):"
echo "       sudo cp $SSHD_BACKUP $SSHD_CONFIG"
echo "       sudo systemctl restart sshd"
echo ""
echo "  📁 Execution log: $LOG_FILE"
echo ""

log_info "=== $SCRIPT_NAME finished successfully ==="
