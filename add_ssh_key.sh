#! /bin/bash

# Filename: add_ssh_key.sh
# Author: JirenYoung
# Date: 2026
# Copyright (c) 2026 JirenYoung. All rights reserved.
# Licensed under the MIT License.

# This script is used to generate SSH keys for the user and link them to the appropriate location.



LoginUser=$(whoami)

echo "Welcome, $LoginUser! This script will help you add public SSH keys to this server."
echo "Please follow the prompts to complete the process."
read -p "Add Public Key to this Server (y/n)? " answer
if [[ "$answer" != "y" && "$answer" != "Y" || -z "$answer" ]]; then
    echo "Exiting the script. No changes have been made."
    exit 0
fi
echo "This script will add your SSH public key to this server"
echo 
read -p "Enter the public key for the SSH key: " SSH_KEY

if [[ ! "$SSH_KEY" =~ ^ssh-(rsa|ed25519|ecdsa|dsa) ]]; then
    echo "Invalid public key format. Please ensure it starts with 'ssh-rsa|ssh-ed25519|ssh-ecdsa|ssh-dsa'. Exiting the script."
    exit 1
fi


SSH_DIR="$HOME/.ssh"
AUTH_FILE="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if grep -qxF "$SSH_KEY" "$AUTH_FILE" 2>/dev/null; then
    echo "The SSH key is already present in the authorized_keys file. No changes have been made."
    exit 0
fi

echo "$SSH_KEY" >> "$AUTH_FILE"
chmod 600 "$AUTH_FILE"

echo "SSH key has been added to the authorized_keys file. You can now use this key to access the server."
echo "please check login with the new SSH key to ensure it works correctly."





