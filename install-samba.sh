#!/bin/bash

# this script assumes the user is "s". 
# a future update will fix this.

set -euo pipefail

# 1. Update package index
apt update

# 2. Install Samba and required utilities
apt install -y samba smbclient cifs-utils

# 3. Backup the original Samba config
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# 4. Ensure user “s” exists
if ! id -u s >/dev/null 2>&1; then
  echo "User ‘s’ does not exist. Creating user ‘s’..."
  adduser --gecos "" --disabled-password s
fi

# 5. Set Samba password for user “s”
# (this will prompt you for a password)
smbpasswd -a s
smbpasswd -e s

# 6. Modify /etc/samba/smb.conf to include the home-share
cat >> /etc/samba/smb.conf <<'EOF'

[homes]
   comment = Home Directories
   browseable = yes
   writable = yes
   valid users = s
   read only = no
   create mask = 0700
   directory mask = 0700

EOF

# 7. Ensure permissions of /home/s are appropriate
chown s:s /home/s
chmod 700 /home/s

# 8. Restart Samba services to apply changes
systemctl restart smbd nmbd

# 9. Test configuration syntax
testparm

# 10. (Optional) If firewall is in use, allow Samba ports
# Example for UFW:
if command -v ufw >/dev/null 2>&1; then
  ufw allow from 192.168.0.0/24 to any app Samba
fi

echo "Samba home directory share for user ‘s’ configured. Access it as \\\\SERVER_IP\\s from other machines."
