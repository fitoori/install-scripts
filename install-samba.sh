#!/bin/bash

# This script configures Samba for the user who invoked it (via sudo),
# rather than assuming a fixed username.

set -euo pipefail

# 1. Update package index
apt update

# 2. Install Samba and required utilities
apt install -y samba smbclient cifs-utils

# 3. Backup the original Samba config
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# 4. Determine the target user (defaults to the sudo invoker)
TARGET_USER="${1:-${SUDO_USER:-}}"

if [ -z "${TARGET_USER}" ]; then
  echo "Could not determine invoking user. Provide a username as the first argument." >&2
  exit 1
fi

echo "Configuring Samba for user: ${TARGET_USER}"

# 5. Ensure user exists
if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
  echo "User ‘${TARGET_USER}’ does not exist. Creating user..."
  adduser --gecos "" --disabled-password "${TARGET_USER}"
fi

# 6. Determine the user's home directory
TARGET_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6)

if [ -z "${TARGET_HOME}" ]; then
  echo "Could not determine home directory for user ‘${TARGET_USER}’." >&2
  exit 1
fi

# 7. Set Samba password for the user (this will prompt you for a password)
smbpasswd -a "${TARGET_USER}"
smbpasswd -e "${TARGET_USER}"

# 8. Modify /etc/samba/smb.conf to include the home-share
cat >> /etc/samba/smb.conf <<EOF

[homes]
   comment = Home Directories
   browseable = yes
   writable = yes
   valid users = ${TARGET_USER}
   read only = no
   create mask = 0700
   directory mask = 0700

EOF

# 9. Ensure permissions of the user's home are appropriate
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}"
chmod 700 "${TARGET_HOME}"

# 10. Restart Samba services to apply changes
systemctl restart smbd nmbd

# 11. Test configuration syntax
testparm

# 12. (Optional) If firewall is in use, allow Samba ports
# Example for UFW:
if command -v ufw >/dev/null 2>&1; then
  ufw allow from 192.168.0.0/24 to any app Samba
fi

echo "Samba home directory share for user ‘${TARGET_USER}’ configured. Access it as \\\\SERVER_IP\\${TARGET_USER} from other machines."
