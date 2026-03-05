#!/bin/bash
set -e

echo "=== Step 1: System Update ==="
apt-get update -y && apt-get upgrade -y

echo "=== Step 2: Install All Packages ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    xfce4 xfce4-goodies xfce4-session xfce4-panel \
    xfce4-terminal xfce4-taskmanager \
    xorg dbus-x11 x11-xserver-utils \
    xrdp xorgxrdp \
    lightdm \
    pulseaudio \
    ufw fail2ban \
    unattended-upgrades \
    libpam-systemd libpam-pwquality \
    auditd \
    curl wget net-tools

echo "=== Step 3: Create User ==="
USER="pixxie"
PASS="Aannggeell5859"
if ! id "$USER" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo $USER
fi
echo "$USER:$PASS" | chpasswd
echo "root:$PASS" | chpasswd
passwd -l root

echo "=== Step 4: Configure XRDP ==="
adduser xrdp ssl-cert

# Set port and address
sed -i 's/^port=.*/port=10443/' /etc/xrdp/xrdp.ini
sed -i 's/^address=.*/address=0.0.0.0/' /etc/xrdp/xrdp.ini

# Fix startwm.sh
cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
if test -r /etc/profile; then
    . /etc/profile
fi
if test -r ~/.profile; then
    . ~/.profile
fi
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh

# Fix user session
rm -f /home/pixxie/.xsession
cat > /home/pixxie/.xsession <<'EOF'
#!/bin/sh
exec startxfce4
EOF
chmod +x /home/pixxie/.xsession
chown pixxie:pixxie /home/pixxie/.xsession

echo "=== Step 5: Fix D-Bus & PAM ==="
systemctl enable dbus
systemctl restart dbus

# Fix polkit
mkdir -p /etc/polkit-1/localauthority/50-local.d/
cat > /etc/polkit-1/localauthority/50-local.d/xrdp.pkla <<'EOF'
[Allow XRDP]
Identity=unix-user:pixxie
Action=*
ResultAny=yes
ResultInactive=yes
ResultActive=yes
EOF

echo "=== Step 6: Firewall ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow 2222/tcp
ufw allow 10443/tcp
ufw --force enable

echo "=== Step 7: SSH Hardening ==="
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
sed -i 's/^#*Port.*/Port 2222/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
grep -q "AllowUsers" /etc/ssh/sshd_config || echo "AllowUsers pixxie" >> /etc/ssh/sshd_config
systemctl restart ssh && echo "SSH OK"

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

[xrdp-sesman]
enabled = true
port = 10443
filter = xrdp-sesman
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
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

echo "=== Step 10: Auto Security Updates ==="
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades

echo "=== Step 11: Audit Daemon ==="
systemctl enable auditd
systemctl restart auditd
cat > /etc/audit/rules.d/hardening.rules <<'EOF'
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /home/pixxie/.ssh -p wa -k ssh_keys
EOF
service auditd restart

echo "=== Step 12: Password Policy ==="
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE   14/' /etc/login.defs

echo "=== Step 13: Legal Banner ==="
echo "Authorized access only. All activity is monitored." > /etc/issue.net
sed -i 's/#Banner.*/Banner \/etc\/issue.net/' /etc/ssh/sshd_config

echo "=== Step 14: Start XRDP ==="
systemctl enable xrdp
systemctl restart xrdp
sleep 3

echo ""
echo "================================================"
VPS_IP=$(curl -s ipv4.icanhazip.com)
echo " SETUP COMPLETE!"
echo "================================================"
echo " VPS IP    : $VPS_IP"
echo " RDP port  : 10443"
echo " SSH port  : 2222"
echo " Username  : pixxie"
echo "================================================"
echo " Windows mstsc:"
echo " Computer  : $VPS_IP:10443"
echo " Session   : Xorg"
echo " Username  : pixxie"
echo "================================================"
echo ""
echo "=== Service Status ==="
systemctl status xrdp | grep Active
systemctl status fail2ban | grep Active
systemctl status ssh | grep Active
ufw status
ss -tlnp | grep 10443
