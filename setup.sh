#!/bin/bash
set -e

# Variables
USER="pixxie"
PASS="Aannggeell5859"
RDP_PORT="10443"

echo "=== Step 1: System Update ==="
apt-get update -y && apt-get upgrade -y

echo "=== Step 2: Install Dependencies ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    xfce4 xfce4-goodies xorg dbus-x11 x11-xserver-utils \
    xrdp xorgxrdp \
    ufw fail2ban \
    curl wget net-tools

echo "=== Step 3: Create User ==="
if ! id "$USER" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo $USER
fi
echo "$USER:$PASS" | chpasswd
echo "root:$PASS" | chpasswd
passwd -l root

echo "=== Step 4: Configure XRDP ==="
adduser xrdp ssl-cert
sed -i 's/^port=.*/port='$RDP_PORT'/' /etc/xrdp/xrdp.ini
sed -i 's/^address=.*/address=0.0.0.0/' /etc/xrdp/xrdp.ini

# Fix session
cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
if test -r /etc/profile; then
    . /etc/profile
fi
if test -r ~/.profile; then
    . ~/.profile
fi
startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh

# Fix .xsession for user
echo "xfce4-session" > /home/$USER/.xsession
chmod +x /home/$USER/.xsession
chown $USER:$USER /home/$USER/.xsession

echo "=== Step 5: Fix D-Bus & PAM ==="
apt-get install -y dbus-x11 libpam-systemd
systemctl enable dbus
systemctl restart dbus

echo "=== Step 6: Firewall ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow 2222/tcp
ufw allow $RDP_PORT/tcp
ufw --force enable

echo "=== Step 7: SSH Hardening ==="
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config
sed -i 's/^Port 22/Port 2222/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
echo "AllowUsers $USER" >> /etc/ssh/sshd_config
systemctl restart ssh

echo "=== Step 8: Fail2Ban ==="
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = 2222
maxretry = 3
bantime = 7200
EOF
systemctl enable fail2ban
systemctl restart fail2ban

echo "=== Step 9: Kernel Hardening ==="
cat > /etc/sysctl.d/99-security.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
fs.suid_dumpable = 0
EOF
sysctl --system > /dev/null

echo "=== Step 10: Start XRDP ==="
systemctl enable xrdp
systemctl restart xrdp
sleep 3

echo ""
echo "================================================"
echo " SETUP COMPLETE!"
echo "================================================"
VPS_IP=$(curl -s ipv4.icanhazip.com)
echo " VPS IP    : $VPS_IP"
echo " RDP port  : $RDP_PORT"
echo " SSH port  : 2222"
echo " Username  : $USER"
echo "================================================"
echo " Connect from Windows mstsc:"
echo " Computer  : $VPS_IP:$RDP_PORT"
echo " Username  : $USER"
echo "================================================"
systemctl status xrdp | grep Active
ss -tlnp | grep $RDP_PORT
