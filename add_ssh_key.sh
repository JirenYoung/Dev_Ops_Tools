#!/bin/bash

#===============================================================================
# Filename: add_ssh_key.sh
# Author: JirenYoung
# Date: 2026
# Copyright (c) 2026 JirenYoung. All rights reserved.
# Licensed under the MIT License.
#
# Description:
#   Add an SSH public key to a user's authorized_keys with safety checks.
#   Supports key input from stdin, file, or command-line argument.
#
# Usage:
#   bash add_ssh_key.sh                          # current user, paste key
#   bash add_ssh_key.sh -u alice                 # specific user
#   bash add_ssh_key.sh -f ~/.ssh/id_ed25519.pub # from file
#   bash add_ssh_key.sh -k "ssh-ed25519 AAA..."  # inline key
#===============================================================================

set -euo pipefail         #Use strict mode for better safety
#===============================================================================
# Logging — structured audit trail
#===============================================================================
readonly DEFAULT_LOG_DIR="/var/log/ssh_add_keys"
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"

setup_logging() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="${LOG_DIR}/add_ssh_key_$(date +%Y%m%d_%H%M%S).log"
  exec 3>&1
}

log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "$LOG_FILE" >&3 2>/dev/null || echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&3 2>/dev/null || echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "$LOG_FILE" >&3 2>/dev/null || echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }

#===============================================================================
# Constants
#===============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly ALLOWED_KEY_TYPES=(
  ssh-rsa ssh-ed25519 ssh-ecdsa
  sk-ssh-ed25519@openssh.com sk-ecdsa-sha2-nistp256@openssh.com
  ecdsa-sha2-nistp256 ecdsa-sha2-nistp384 ecdsa-sha2-nistp521
  ssh-rsa-cert-v01@openssh.com ssh-ed25519-cert-v01@openssh.com
  ssh-ecdsa-cert-v01@openssh.com
)
readonly DEPRECATED_KEY_TYPES=(
  ssh-dsa ssh-dss
)

#===============================================================================
# Usage
#===============================================================================
usage() {
  cat <<EOF
Usage: bash $SCRIPT_NAME [OPTIONS]

Options:
  -u USER     Target user (default: current user)
  -f FILE     Read public key from FILE
  -k KEY      Provide public key as a string
  -l DIR      Log directory (default: /var/log/ssh_add_keys)
  -h          Show this help

Examples:
  bash $SCRIPT_NAME                           # paste key interactively
  bash $SCRIPT_NAME -u alice                  # for user 'alice'
  bash $SCRIPT_NAME -f ~/.ssh/id_ed25519.pub  # from key file
  bash $SCRIPT_NAME -u bob -f bob_key.pub     # combine options
EOF
}

#===============================================================================
# Validate SSH public key
# Returns 0 if valid, 1 if rejected, 2 if deprecated (but still accepted with warning)
#===============================================================================
validate_key() {
  local key="$1"
  local key_type key_data key_comment

  # Split into type + base64 + optional comment
  read -r key_type key_data key_comment <<< "$key"

  if [ -z "$key_type" ] || [ -z "$key_data" ]; then
    echo "ERROR: Key appears to be empty or malformed (missing type or data)." >&2
    return 1
  fi

  # Check deprecated types
  for dt in "${DEPRECATED_KEY_TYPES[@]}"; do
    if [ "$key_type" = "$dt" ]; then
      echo "WARNING: Key type '$key_type' is DEPRECATED and insecure." >&2
      echo "         OpenSSH 7.0+ disables DSA by default." >&2
      echo "         Consider generating a new ed25519 key instead." >&2
      return 2
    fi
  done

  # Check allowed types
  local type_ok=false
  for at in "${ALLOWED_KEY_TYPES[@]}"; do
    if [ "$key_type" = "$at" ]; then
      type_ok=true
      break
    fi
  done

  if ! $type_ok; then
    echo "ERROR: Unrecognized key type '$key_type'." >&2
    echo "       Supported: ${ALLOWED_KEY_TYPES[*]}" >&2
    return 1
  fi

  # Validate base64 data (must decode successfully)
  if ! echo "$key_data" | base64 -d &>/dev/null; then
    echo "ERROR: Key data is not valid base64." >&2
    return 1
  fi

  return 0
}

#===============================================================================
# Sanity check: ensure trailing newline in authorized_keys
#===============================================================================
ensure_trailing_newline() {
  local file="$1"
  if [ -s "$file" ] && [ "$(tail -c1 "$file" | wc -l)" -eq 0 ]; then
    echo >> "$file"
    echo "NOTE: Added missing trailing newline to authorized_keys." >&2
  fi
}

#===============================================================================
# Main
#===============================================================================

# --- Parse arguments ---
TARGET_USER=""
KEY_FILE=""
KEY_STRING=""

while getopts "u:f:k:l:h" opt; do
  case "$opt" in
    u) TARGET_USER="$OPTARG" ;;
    f) KEY_FILE="$OPTARG" ;;
    k) KEY_STRING="$OPTARG" ;;
    h) usage; exit 0 ;;
    l) LOG_DIR="$OPTARG" ;;
    *) usage; exit 1 ;;
  esac
done

setup_logging
log_info "=== $SCRIPT_NAME started ==="

# --- Determine target user ---
if [ -n "$TARGET_USER" ]; then
  TARGET="$TARGET_USER"
else
  # Detect sudo: if running under sudo, default to SUDO_USER
  if [ -n "${SUDO_USER:-}" ]; then
    TARGET="$SUDO_USER"
  else
    TARGET="$(whoami)"
  fi
fi

# Idempotency check
if ! id "$TARGET" &>/dev/null; then
  echo "ERROR: User '$TARGET' does not exist on this system." >&2
  exit 1
fi

# --- Resolve home directory ---
HOME_DIR="$(getent passwd "$TARGET" | cut -d: -f6)"
if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  log_error "Cannot resolve home directory for user '$TARGET'."
  exit 1
fi
SSH_DIR="$HOME_DIR/.ssh"
AUTH_FILE="$SSH_DIR/authorized_keys"

# --- Get the key ---
if [ -n "$KEY_STRING" ]; then
  SSH_KEY="$KEY_STRING"
elif [ -n "$KEY_FILE" ]; then
  if [ ! -f "$KEY_FILE" ]; then
    echo "ERROR: Key file not found: $KEY_FILE" >&2
    exit 1
  fi
  SSH_KEY="$(cat "$KEY_FILE")"
  if [ -z "$SSH_KEY" ]; then
    echo "ERROR: Key file is empty: $KEY_FILE" >&2
    exit 1
  fi
else
  # Interactive mode
  echo "── SSH Key Installer"
  echo "  Target user: $TARGET  →  $AUTH_FILE"
  echo

  read -p "Paste the SSH public key: " SSH_KEY
  if [ -z "$SSH_KEY" ]; then
    echo "No key provided. Exiting."
    exit 0
  fi
fi

# --- Validate ---
validate_key "$SSH_KEY"
key_status=$?
if [ $key_status -eq 1 ]; then
  exit 1
elif [ $key_status -eq 2 ]; then
  echo "Do you still want to add this deprecated key? (y/N): "
  read -r answer
  if [[ ! "$answer" =~ ^[yY] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# --- Prepare .ssh directory ---
if ! mkdir -p "$SSH_DIR"; then
  echo "ERROR: Failed to create $SSH_DIR" >&2
  exit 1
fi
chmod 700 "$SSH_DIR" || true

# --- Check for duplicate ---
if [ -f "$AUTH_FILE" ] && grep -qxF "$SSH_KEY" "$AUTH_FILE" 2>/dev/null; then
  echo "INFO: Key already present in $AUTH_FILE — nothing to do."
  exit 0
fi

# --- Ensure trailing newline before appending ---
if [ -f "$AUTH_FILE" ]; then
  ensure_trailing_newline "$AUTH_FILE"
fi

# --- Append key ---
echo "$SSH_KEY" >> "$AUTH_FILE" || {
  echo "ERROR: Failed to write to $AUTH_FILE" >&2
  exit 1
}

# --- Fix permissions and ownership ---
chmod 600 "$AUTH_FILE" || true
if [ "$(whoami)" = "root" ]; then
  TARGET_GROUP="$(id -gn "$TARGET" 2>/dev/null || echo "$TARGET")"
  chown "${TARGET}:${TARGET_GROUP}" "$AUTH_FILE" 2>/dev/null || true
  chown "${TARGET}:${TARGET_GROUP}" "$SSH_DIR" 2>/dev/null || true
fi

log_info "SSH key added for user '$TARGET' to $AUTH_FILE."
echo
echo "SSH key added successfully."
echo "   User : $TARGET"
echo "   File : $AUTH_FILE"
echo
echo "   Test it before closing this session:"
echo "   ssh -i /path/to/private_key $TARGET@$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server>')"