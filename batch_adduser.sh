#!/bin/bash

#===============================================================================
# Filename: batch_adduser.sh
# Author: JirenYoung
# Date: 2026
# Copyright (c) 2026 JirenYoung. All rights reserved.
# Licensed under the MIT License.
#
# Description:
#   Batch create Linux users with passwordless sudo.
#   Supports interactive mode and batch import from file.
#
# Usage:
#   sudo bash batch_adduser.sh                  # interactive mode
#   sudo bash batch_adduser.sh -f users.txt     # batch from file (one username per line)
#   sudo bash batch_adduser.sh -l /var/log/ops  # custom log directory
#===============================================================================

set -euo pipefail  # strict mode for better error handling, and safer variable usage
# Note: 'set -e' is used to exit immediately if a command exits with a non-zero status.
#===============================================================================
# Constants
#===============================================================================
readonly SCRIPT_NAME="$(basename "$0")"
readonly RESERVED_USERS=(
  root bin daemon adm lp sync shutdown halt mail operator
  nobody systemd-network systemd-resolve systemd-timesync
  sshd postfix ntp www-data mysql redis docker
)
readonly USERNAME_REGEX='^[a-z_][a-z0-9_-]{0,31}$' # check POSIX username rules: start with letter/underscore, then letters/digits/underscore/dash, max 32 chars

#===============================================================================
# Defaults (overridable via CLI)
#===============================================================================
LOG_DIR="${LOG_DIR:-/var/log/devops}"
BATCH_FILE=""

#===============================================================================
# Logging
#===============================================================================
setup_logging() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="${LOG_DIR}/batch_adduser_$(date +%Y%m%d_%H%M%S).log"
  exec 3>&1  # save original stdout
}

log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*" | tee -a "$LOG_FILE" >&3; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" | tee -a "$LOG_FILE" >&3; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*" | tee -a "$LOG_FILE" >&3; }

#===============================================================================
# Usage
#===============================================================================
usage() {
  cat <<EOF
Usage: sudo bash $SCRIPT_NAME [OPTIONS]

Options:
  -f FILE     Read usernames from FILE (one per line)
  -l DIR      Log directory (default: /var/log/devops)
  -h          Show this help

Examples:
  sudo bash $SCRIPT_NAME                    # interactive
  sudo bash $SCRIPT_NAME -f new_users.txt   # batch from file
EOF
}

#===============================================================================
# Validate username against POSIX rules and reserved list
#===============================================================================
validate_username() {
  local username="$1"
# Check POSIX username rules: start with letter/underscore, then letters/digits/underscore/dash, max 32 chars
  if [[ ! "$username" =~ $USERNAME_REGEX ]]; then
    log_error "Invalid username '$username'."
    log_error "Must start with a lowercase letter or underscore,"
    log_error "contain only [a-z0-9_-], and be ≤ 32 characters."
    return 1
  fi
# Check against reserved system usernames
  for reserved in "${RESERVED_USERS[@]}"; do
    if [ "$username" = "$reserved" ]; then
      log_error "'$username' is a reserved system username. Choose another."
      return 1
    fi
  done

  return 0
}

#===============================================================================
# Set password using chpasswd (reliable exit code)
#===============================================================================
set_password() {
  local username="$1"
  local password password2

  while true; do
    read -s -p "Enter password for $username: " password
    echo >&2
    read -s -p "Confirm password for $username: " password2
    echo >&2

    if [ "$password" != "$password2" ]; then
      log_warn "Passwords do not match. Try again."
      continue
    fi
    if [ -z "$password" ]; then
      log_warn "Password cannot be empty. Try again."
      continue
    fi
    break
  done

  printf '%s:%s' "$username" "$password" | chpasswd 2>/dev/null
}

#===============================================================================
# Core: create one user with full setup
#===============================================================================
create_user() {
  local username="$1"

  # --- Validate ---
  if ! validate_username "$username"; then
    return 1
  fi

  if id "$username" &>/dev/null; then
    log_warn "User '$username' already exists — skipping."
    return 1
  fi

  # --- Create ---
  log_info "Creating user '$username'..."
  if ! useradd -m -s /bin/bash "$username"; then
    log_error "useradd failed for '$username'."
    return 1
  fi

  # --- Set password (interactive only) ---
  if [ -z "$BATCH_FILE" ]; then
    echo "────────────────────────────────────────────"
    log_info "Setting password for '$username'..."
    if set_password "$username"; then
      log_info "Password set for '$username'."
    else
      log_error "chpasswd failed for '$username'. User created but NO password set."
      log_error "Run 'passwd $username' manually to set one."
      return 1
    fi
  else
    # Batch mode: create with locked password; admin must set manually
    passwd -l "$username" &>/dev/null || true
    log_warn "Batch mode: password locked for '$username'."
    log_warn "Admin must run 'passwd $username' to set a password."
  fi

  # --- Add to sudo group ---
  log_info "Adding '$username' to '$SUDO_GROUP' group..."
  if ! usermod -aG "$SUDO_GROUP" "$username"; then
    log_error "usermod failed for '$username'."
    return 1
  fi

  # --- Passwordless sudo ---
  local sudo_file="/etc/sudoers.d/$username"
  echo "$username  ALL=(ALL)  NOPASSWD:ALL" > "$sudo_file"
  if ! chmod 0440 "$sudo_file"; then
    log_error "chmod failed on sudoers file — removing it."
    rm -f "$sudo_file"
    return 1
  fi

  if ! visudo -c -f "$sudo_file" &>/dev/null; then
    log_error "Sudoers syntax error in '$sudo_file' — removing it."
    rm -f "$sudo_file"
    return 1
  fi

  log_info "Passwordless sudo configured for '$username'."
  return 0
}

#===============================================================================
# Main
#===============================================================================

# Parse arguments
while getopts "f:l:h" opt; do
  case "$opt" in
    f) BATCH_FILE="$OPTARG" ;;
    l) LOG_DIR="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# Root check
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root (or with sudo)." >&2
  exit 1
fi

setup_logging

#===============================================================================
# Detect Linux distribution → sudo group
#===============================================================================
log_info "Detecting Linux distribution..."

if [ -f /etc/debian_version ]; then
  SUDO_GROUP="sudo"
  log_info "Debian-based system detected. sudo group = '$SUDO_GROUP'."
elif [ -f /etc/redhat-release ]; then
  SUDO_GROUP="wheel"
  log_info "RHEL-based system detected. sudo group = '$SUDO_GROUP'."
else
  log_error "Unsupported distribution. Only Debian/Ubuntu and RHEL/CentOS/Rocky are supported."
  exit 1
fi

#===============================================================================
# Collect usernames
#===============================================================================
declare -a USERNAMES=()

if [ -n "$BATCH_FILE" ]; then
  # --- Batch mode ---
  if [ ! -f "$BATCH_FILE" ]; then
    log_error "File not found: $BATCH_FILE"
    exit 1
  fi
  log_info "Reading usernames from '$BATCH_FILE'..."
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"            # strip comments
    # Trim leading/trailing whitespace (bash built-in, no subprocess fork)
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    USERNAMES+=("$line")
  done < "$BATCH_FILE"
  log_info "Loaded ${#USERNAMES[@]} username(s) from file."
else
  # --- Interactive mode ---
  echo "============================================================"
  echo "  Batch Add User — Interactive Mode"
  echo "  Type 'exit' at the username prompt to finish."
  echo "============================================================"
  echo

  while true; do
    read -p "Enter username (or 'exit' to quit): " username
    if [ "$username" = "exit" ]; then
      break
    fi
    if [ -n "$username" ]; then
      USERNAMES+=("$username")
    fi
  done
fi

if [ ${#USERNAMES[@]} -eq 0 ]; then
  log_warn "No usernames provided. Nothing to do."
  exit 0
fi

#===============================================================================
# Process each user
#===============================================================================
declare -a SUCCESS=()
declare -a FAILED=()
# Batch add users and log successful / failed results
for username in "${USERNAMES[@]}"; do
  echo
  echo "━━━ Processing: $username ━━━"
  if create_user "$username"; then
    SUCCESS+=("$username")
    echo "✅ $username — complete."
  else
    FAILED+=("$username")
    echo "❌ $username — failed (see log for details)."
  fi
done

#===============================================================================
# Summary
#===============================================================================
echo
echo "============================================================"
echo "  Summary"
echo "============================================================"
echo "  ✅ Success: ${#SUCCESS[@]}"
echo "  ❌ Failed:  ${#FAILED[@]}"

if [ ${#SUCCESS[@]} -gt 0 ]; then
  echo
  echo "  Created users:"
  for u in "${SUCCESS[@]}"; do
    echo "    - $u"
  done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  echo
  echo "  Failed users:"
  for u in "${FAILED[@]}"; do
    echo "    - $u"
  done
fi

log_info "Script finished. ${#SUCCESS[@]} created, ${#FAILED[@]} failed."
echo
echo "Log: $LOG_FILE"