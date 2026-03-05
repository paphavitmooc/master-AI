#!/bin/bash
echo "=== Complete XRDP Fix ==="

# Stop xrdp
systemctl stop xrdp

# Backup and rewrite xrdp.ini completely
cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.bak

cat > /etc/xrdp/xrdp.ini <<'EOF'
[Globals]
ini_version=1
fork=true
port=10443
use_vsock=false
tcp_nodelay=true
tcp_keepalive=true
security_layer=rdp
crypt_level=none
certificate=
key_file=
ssl_protocols=TLSv1.2
autorun=
allow_channels=true
allow_multimon=false
bitmap_cache=true
bitmap_compression=true
bulk_compression=true
max_bpp=32
new_cursors=true
use_fastpath=both

[Xorg]
name=Xorg
lib=libxup.so
username=ask
password=ask
ip=127.0.0.1
port=-1
code=20

[Xvnc]
name=Xvnc
lib=libvnc.so
username=ask
password=ask
ip=127.0.0.1
port=-1
EOF

# Fix sesman.ini
cat > /etc/xrdp/sesman.ini <<'EOF'
[Globals]
ListenAddress=127.0.0.1
ListenPort=3350
EnableUserWindowManager=true
UserWindowManager=startwm.sh
DefaultWindowManager=startwm.sh

[Security]
AllowRootLogin=false
MaxLoginRetry=3
TerminalServerUsers=tsusers
TerminalServerAdmins=tsadmins
AlwaysGroupCheck=false

[Sessions]
MaxSessions=50
KillDisconnected=false
DisconnectedTimeLimit=0
IdleTimeLimit=0
SessionType=Xorg

[Logging]
LogFile=/var/log/xrdp-sesman.log
LogLevel=DEBUG
EnableSyslog=true
SyslogLevel=DEBUG

[Xorg]
param=Xorg
param=-config
param=xrdp/xorg.conf
param=-noreset
param=-nolisten
param=tcp
param=-logfile
param=/var/log/xrdp/xorg-sesman.log
EOF

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

# Create xrdp log directory
mkdir -p /var/log/xrdp
chown xrdp:xrdp /var/log/xrdp 2>/dev/null || true

# Fix permissions
chown root:root /etc/xrdp/xrdp.ini
chown root:root /etc/xrdp/sesman.ini

# Restart services
systemctl restart dbus
sleep 1
systemctl start xrdp
sleep 3

echo ""
echo "=== Results ==="
systemctl status xrdp | grep Active
ss -tlnp | grep 10443
echo ""
echo "Connect: 217.216.73.71:10443"
echo "Session: Xorg"
echo "User: pixxie"
