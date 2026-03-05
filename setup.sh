#!/bin/bash
# Fix stunnel and complete setup

# Fix stunnel config
cat > /etc/stunnel/stunnel.conf << 'EOF'
pid = /var/run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4
output = /var/log/stunnel4/stunnel.log

[rdp]
accept = 10443
connect = 127.0.0.1:3389
cert = /etc/stunnel/stunnel.pem
EOF

# Fix permissions
chmod 600 /etc/stunnel/stunnel.pem
chown stunnel4:stunnel4 /etc/stunnel/stunnel.pem

# Create pid directory
mkdir -p /var/run/stunnel4
chown stunnel4:stunnel4 /var/run/stunnel4

# Restart stunnel
systemctl restart stunnel4
sleep 2
systemctl status stunnel4 | grep Active
ss -tlnp | grep 10443

# Kernel hardening
echo "net.ipv4.tcp_syncookies = 1" >> /etc/sysctl.d/99-security.conf
echo "kernel.randomize_va_space = 2" >> /etc/sysctl.d/99-security.conf
sysctl --system > /dev/null

# Auto security updates
echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades

# Password policy
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs

# Legal banner
echo "Authorized access only. All activity is monitored." > /etc/issue.net

# Audit daemon
systemctl enable --now auditd
echo "-w /etc/passwd -p wa -k identity" >> /etc/audit/rules.d/hardening.rules
echo "-w /etc/sudoers -p wa -k sudoers" >> /etc/audit/rules.d/hardening.rules
echo "-w /home/pixxie/.ssh -p wa -k ssh_keys" >> /etc/audit/rules.d/hardening.rules
service auditd restart

echo ""
echo "================================================"
echo " SETUP COMPLETE!"
echo " SSH port  : 2222"
echo " RDP port  : 10443"
echo " Desktop   : XFCE4"
echo " User      : pixxie"
echo "================================================"
echo ""
echo "WINDOWS CONNECTION:"
echo " 1. Open mstsc (Remote Desktop)"
echo " 2. Computer: $(curl -s ifconfig.me):10443"
echo " 3. Username: pixxie"
echo "================================================"
