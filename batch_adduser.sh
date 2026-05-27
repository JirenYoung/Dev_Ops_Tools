#!/bin/bash

# Filename: batch_adduser.sh
# Author: JirenYoung
# Date: 2026
# Copyright (c) 2026 JirenYoung. All rights reserved.
# Licensed under the MIT License.



# Add new users to the system

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "########################################################"
  echo "#                                                      #"
  echo "# Permissions denied. Please run as root or with sudo. #"
  echo "#                                                      #"
  echo "########################################################"
  echo -e "\n\n"
  exit 1
fi

## check the Linux distribution to determine the appropriate sudo group
echo "Checking Linux distribution..."

if [ -f /etc/debian_version ]; then
  echo "#####################################################################"
  echo "#                                                                   #"
  echo "#                 Debian-based system detected.                     #"
  echo "#                                                                   #"
  SUDO_GROUP="sudo"
  echo "#####################################################################"
  echo "#                                                                   #"
  echo "#     The sudo group is set to '$SUDO_GROUP' for Debian-based systems      #"
  echo "#                                                                   #"
  echo "#####################################################################"
  echo -e "\n\n"
elif [ -f /etc/redhat-release ]; then
  echo "#####################################################################"
  echo "#                 Red Hat-based system detected.                    #"
  echo "#                                                                   #"
  SUDO_GROUP="wheel"
  echo "#####################################################################"
  echo "#                                                                   #"
  echo "#     The sudo group is set to '$SUDO_GROUP' for Red Hat-based systems     #"
  echo "#                                                                   #"
  echo "#####################################################################"
  echo -e "\n\n"
else
  echo "#######################################################################"
  echo "#                                                                     #"
  echo "#                   Unsupported Linux distribution!                   #"
  echo "#                                                                     #"
  echo "#     This script ONLY supports Debian/Ubuntu and RHEL/CentOS/Rocky.  #"
  echo "#                                                                     #"
  echo "#######################################################################"
  echo "#                                                                     #"
  echo "#    Detected system is likely Arch-based or other rolling release.   #"
  echo "#                                                                     #"
  echo "#       Arch is NOT supported in production environments.             #"
  echo "#                                                                     #"
  echo "# If you insist on using it, manually modify the SUDO_GROUP variable. #"
  echo "#                                                                     #"
  echo "#######################################################################"
  echo -e "\n\n"
  exit 1
fi

######################################################################################################
adduser_group=()

# Add new users to the system 
echo "#####################################################################"
echo "#                                                                   #"
echo "#              Starting to add new users to the system              #"
echo "#                                                                   #"
echo "#####################################################################"
echo -e "\n"

while true; do
  read -p "Enter the username to add (or 'exit' to quit): " username
  if [ "$username" = "exit" ]; then
    echo "########################################################"
    echo "#                                                      #"
    echo "#            Exiting the user addition process         #"
    echo "#                                                      #"
    echo "########################################################"
    echo -e "\n\n"
    break
  fi
  
  if [[ -z "$username"  ]]; then
    echo "###################################################################"
    echo "#                                                                 #"
    echo "# Error! Username cannot be empty. Please enter a valid username. #"
    echo "#                                                                 #"
    echo "###################################################################"
    echo -e "\n"
    continue
  fi

  # Check if the user already exists
  if id "$username" &>/dev/null; then
    echo "################################################################################"
    echo "#                                                                              #"
    echo "# Error! User '$username' already exists. Please choose a different username.  #"
    echo "#                                                                              #"
    echo "################################################################################"
    echo -e "\n"
    continue
  fi

######################################################################################################
  # Add the user to the system
  echo -e "\n"
  echo "Creating user '$username'..."
  echo -e "\n"
  
  useradd -m -s /bin/bash "$username"
  if [ $? -eq 0 ]; then
    echo "✅ User '$username' has been added successfully."
  else
    echo "❌ Failed to add user '$username'. Please try again."
    echo "########################################################"
    echo -e "\n"
    continue
  fi
  echo -e "\n"

  # set user password
  echo "########################################################"
  echo -e "\n"
  echo "        Please set a password for user '$username'       "
  echo -e "\n"
  echo "########################################################"
  passwd "$username"

  if [ $? -eq 0 ]; then
    echo -e "\n"  
    echo "✅ User $username created and password set successfully!"
    echo -e "\n"
  else
    echo -e "\n"  
    echo "⚠️  Failed to set password for user '$username', but user was created."
    echo "⚠️  Please use 'passwd $username' to set the password manually."
    echo -e "\n"
  fi
  echo "########################################################"
  echo -e "\n"

########################################################################################################
  ##### Add the user to the sudo group
  echo "#########################################################"
  echo -e "\n"
  echo "      Adding user '$username' to the '$SUDO_GROUP' group...      "
  echo -e "\n"
  echo "#########################################################"
  echo -e "\n"
  
  usermod -aG "$SUDO_GROUP" "$username"
  if [ $? -eq 0 ]; then
    echo "✅ User '$username' has been added to the '$SUDO_GROUP' group successfully."
  else
    echo "⚠️  Failed to add user '$username' to the '$SUDO_GROUP' group."
    echo "⚠️  Please check the user and group settings."
  fi
  echo -e "\n"

  ##### set passwordless sudo for the user
  echo "########################################################"
  echo -e "\n"
  echo "    Configuring passwordless sudo for user '$username'    "
  echo -e "\n"
  echo "########################################################"
  
  SUDO_FILE="/etc/sudoers.d/$username"
  echo "$username  ALL=(ALL)  NOPASSWD:ALL" | tee "$SUDO_FILE"
  
  if [ $? -ne 0 ]; then
    echo "❌ Failed to create sudoers file for user '$username'."
    echo "########################################################"
    echo -e "\n"
    continue
  fi

  chmod 0440 "$SUDO_FILE"
  if [ $? -ne 0 ]; then
    echo "❌ Failed to set permissions for the sudoers file."
    echo "❌ Removing invalid file to prevent sudo system failure."
    rm -f "$SUDO_FILE"
    echo "########################################################"
    echo -e "\n"
    continue
  fi

  visudo -c -f "$SUDO_FILE" &>/dev/null
  if [ $? -ne 0 ]; then
    echo "❌ FATAL ERROR: Sudoers file syntax error!"
    echo "❌ Removing invalid file to prevent sudo system failure."
    rm -f "$SUDO_FILE"
    echo "########################################################"
    echo -e "\n"
    continue
  fi

  echo "✅ User '$username' set to passwordless sudo successfully."
  echo "✅ User '$username' has full passwordless sudo privileges."
  echo "########################################################"
  echo -e "\n"

  echo "########################################################"
  echo " ✅ All operations completed for user '$username'! "
  echo "########################################################"

  adduser_group+=("$username")

  echo -e "\n"
  read -p "Do you want to create another user? (y/n): " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo -e "\n"
    echo "########################################################"
    echo "#            Exiting the user addition process         #"
    echo "########################################################"
    break
  fi
  echo -e "\n=======================================\n"
done

######################################################################################################
# 脚本结束统计总结
echo -e "\n\n"
echo "#####################################################################"
echo "#                      Script execution completed!                  #"
echo "#####################################################################"
echo -e "\n"

if [ ${#adduser_group[@]} -eq 0 ]; then
  echo " ❌ No users were added during this session.                      "
else
  echo "# ✅ Successfully added ${#adduser_group[@]} user(s):"
  for user in "${adduser_group[@]}"; do
    echo "#   - $user"
  done
fi
echo -e "\n"