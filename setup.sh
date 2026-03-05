#!/usr/bin/env bash
# =============================================================================
#  Ubuntu 24.04 LTS — XFCE4 Desktop + xRDP Secure Setup
#  Port: 10443 | User: Pixxie | Secured + Performance Optimized
#  Usage:  wget -O setup.sh <your-raw-github-url> && chmod +x setup.sh && sudo bash setup.sh
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
RDP_PORT=10443
RDP_USER="Pixxie"
RDP_PASS="Aannggeell5859"
HOSTNAME_NEW="pixxiestudio"
CERT_DAYS=3650
CERT_SUBJ="/CN=${HOSTNAME_NEW}/O=Pixxie/C=TH"
LOG_FILE="/var/log/xrdp_setup.log"

# ─── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── HELPERS ──────────────────────────────────────────────────────────────────
log()     { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }
section() {
  echo "" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

# ─── PRE-FLIGHT CHECKS ────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Please run as root: sudo bash setup.sh"
[[ "$(lsb_release -rs 2>/dev/null)" != "24.04" ]] && warn "Script designed for Ubuntu 24.04. Proceeding anyway..."

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   Ubuntu 24.04 LTS — XFCE4 + xRDP Setup Script     ║"
echo "  ║   Port: ${RDP_PORT}  |  User: ${RDP_USER}                      ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "Setup started at $(date)"
log "Logging to: $LOG_FILE"
sleep 2

# =============================================================================
section "STEP 1 — System Update & Essential Tools"
# =============================================================================
log "Updating package lists..."
apt-get update -qq

log "Upgrading all packages..."
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

log "Running dist-upgrade..."
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq

log "Installing essential tools..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl wget gnupg2 software-properties-common \
  net-tools ufw fail2ban unzip git \
  openssl dbus-x11 xorg

log "Cleaning up..."
apt-get autoremove --purge -y -qq
apt-get autoclean -y -qq

ok "System fully updated."

# =============================================================================
section "STEP 2 — Set Hostname"
# =============================================================================
hostnamectl set-hostname "$HOSTNAME_NEW"
grep -qxF "127.0.1.1  ${HOSTNAME_NEW}" /etc/hosts \
  || echo "127.0.1.1  ${HOSTNAME_NEW}" >> /etc/hosts
ok "Hostname set to: $HOSTNAME_NEW"

# =============================================================================
section "STEP 3 — Create User Pixxie (if not exists)"
# =============================================================================
if id "$RDP_USER" &>/dev/null; then
  warn "User '$RDP_USER' already exists. Skipping creation."
else
  log "Creating user: $RDP_USER ..."
  useradd -m -s /bin/bash -G sudo "$RDP_USER"
  ok "User '$RDP_USER' created and added to sudo group."
fi

log "Setting password for $RDP_USER ..."
echo "${RDP_USER}:${RDP_PASS}" | chpasswd
ok "Password set for $RDP_USER."

# =============================================================================
section "STEP 4 — Install XFCE4 Desktop Environment"
# =============================================================================
log "Installing XFCE4 (minimal, optimized for RDP)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  xfce4 xfce4-goodies \
  xfce4-terminal thunar mousepad \
  xfce4-screensaver \
  xfce4-netload-plugin xfce4-systemload-plugin

ok "XFCE4 installed."

log "Installing LightDM display manager..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  lightdm lightdm-gtk-greeter

log "Setting LightDM as default display manager..."
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm 2>/dev/null || true

systemctl enable lightdm 2>/dev/null || true
systemctl set-default graphical.target
ok "LightDM enabled. Graphical target set."

# =============================================================================
section "STEP 5 — Install & Configure xRDP"
# =============================================================================
log "Installing xRDP..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xrdp

log "Adding $RDP_USER to xrdp & ssl-cert groups..."
usermod -aG xrdp "$RDP_USER" 2>/dev/null || true
usermod -aG ssl-cert "$RDP_USER" 2>/dev/null || true

log "Configuring .xsession for $RDP_USER..."
echo 'startxfce4' > "/home/${RDP_USER}/.xsession"
chown "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.xsession"
chmod 755 "/home/${RDP_USER}/.xsession"

log "Configuring xRDP startwm.sh..."
cat > /etc/xrdp/startwm.sh << 'EOF'
#!/bin/sh
# xRDP session startup — XFCE4
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh
ok "xRDP session configured to launch XFCE4."

# ─── GENERATE TLS CERTIFICATE ─────────────────────────────────────────────────
log "Generating self-signed TLS certificate ($CERT_DAYS days)..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /etc/xrdp/key.pem \
  -out /etc/xrdp/cert.pem \
  -days "$CERT_DAYS" \
  -subj "$CERT_SUBJ" 2>/dev/null
chown xrdp:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem
chmod 600 /etc/xrdp/key.pem
chmod 644 /etc/xrdp/cert.pem
ok "TLS certificate generated."

# ─── WRITE FULL xrdp.ini ──────────────────────────────────────────────────────
log "Writing optimized /etc/xrdp/xrdp.ini (port ${RDP_PORT})..."
cp /etc/xrdp/xrdp.ini /etc/xrdp/xrdp.ini.backup 2>/dev/null || true

cat > /etc/xrdp/xrdp.ini << EOF
[Globals]
ini_version=1
fork=true
port=${RDP_PORT}
address=0.0.0.0
use_vsock=false
security_layer=tls
crypt_level=high
certificate=/etc/xrdp/cert.pem
key_file=/etc/xrdp/key.pem
ssl_protocols=TLSv1.2, TLSv1.3
tls_ciphers=HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5
autorun=
allow_channels=true
allow_multimon=true
bitmap_cache=true
bitmap_compression=true
bulk_compression=true
max_bpp=32
xserverbpp=24
tcp_nodelay=yes
tcp_keepalive=yes
new_cursors=true
use_compression=yes
hidelogwindow=yes
require_credentials=true
enabled_programs=

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
#xauthentication=1
#xauthentication_file=/etc/xrdp/keyfile
#xauthentication_time=3600
# sec_layer=rdp
code=2

[channels]
channel.rdpdr=true
channel.rdpsnd=true
channel.drdynvc=true
channel.cliprdr=true
channel.rail=true
channel.xrdpvr=true
channel.tcutils=true
EOF
ok "xrdp.ini written with port ${RDP_PORT} and TLS hardening."

# ─── FIX X11 WRAPPER ──────────────────────────────────────────────────────────
log "Fixing X11 wrapper config..."
if [[ -f /etc/X11/Xwrapper.config ]]; then
  sed -i 's/allowed_users=console/allowed_users=anybody/' /etc/X11/Xwrapper.config
else
  echo 'allowed_users=anybody' > /etc/X11/Xwrapper.config
  echo 'needs_root_rights=yes' >> /etc/X11/Xwrapper.config
fi
ok "X11 wrapper set to allow_users=anybody."

log "Enabling and starting xRDP..."
systemctl enable xrdp
systemctl restart xrdp
ok "xRDP running on port ${RDP_PORT}."

# =============================================================================
section "STEP 6 — Firewall (UFW)"
# =============================================================================
log "Configuring UFW..."
ufw --force reset > /dev/null

ufw default deny incoming
ufw default allow outgoing

# Allow SSH — IMPORTANT: do this before enabling UFW
ufw allow 22/tcp comment 'SSH'

# Allow xRDP on custom port
ufw allow "${RDP_PORT}/tcp" comment 'xRDP'

ufw --force enable
ok "UFW enabled. Ports open: SSH(22), xRDP(${RDP_PORT})."
ufw status verbose | tee -a "$LOG_FILE"

# =============================================================================
section "STEP 7 — Fail2Ban (Brute Force Protection)"
# =============================================================================
log "Configuring Fail2Ban..."
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true

# xRDP jail
cat > /etc/fail2ban/jail.d/xrdp.conf << EOF
[xrdp]
enabled  = true
port     = ${RDP_PORT}
filter   = xrdp
logpath  = /var/log/xrdp.log
maxretry = 5
findtime = 600
bantime  = 3600
action   = iptables-multiport[name=xrdp, port=${RDP_PORT}, protocol=tcp]
EOF

# xRDP filter
cat > /etc/fail2ban/filter.d/xrdp.conf << 'EOF'
[Definition]
failregex = .*\[XRDP\] .*connect_ip_from.*FAILED.* <HOST>
            .*\[XRDP\] .*User.*failed.*authentication.*<HOST>
            .*connection denied.*<HOST>
            .*Login failed for display .* from <HOST>
ignoreregex =
EOF

# SSH hardening jail
cat > /etc/fail2ban/jail.d/ssh-extra.conf << 'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 4
findtime = 300
bantime  = 7200
EOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2Ban active. Max 5 xRDP retries → 1hr ban. Max 4 SSH retries → 2hr ban."

# =============================================================================
section "STEP 8 — SSH Hardening"
# =============================================================================
log "Hardening SSH configuration..."
SSHD_CFG=/etc/ssh/sshd_config

# Backup original
cp "$SSHD_CFG" "${SSHD_CFG}.backup" 2>/dev/null || true

# Apply hardening settings safely (add if not set, replace if set)
declare -A SSH_SETTINGS=(
  [PermitRootLogin]="no"
  [MaxAuthTries]="3"
  [LoginGraceTime]="30"
  [X11Forwarding]="no"
  [AllowUsers]="${RDP_USER}"
  [PasswordAuthentication]="yes"
  [PubkeyAuthentication]="yes"
  [IgnoreRhosts]="yes"
  [PermitEmptyPasswords]="no"
  [ClientAliveInterval]="300"
  [ClientAliveCountMax]="2"
  [Banner]="/etc/issue.net"
)
for key in "${!SSH_SETTINGS[@]}"; do
  val="${SSH_SETTINGS[$key]}"
  if grep -qE "^#?${key}" "$SSHD_CFG"; then
    sed -i "s|^#\?${key}.*|${key} ${val}|" "$SSHD_CFG"
  else
    echo "${key} ${val}" >> "$SSHD_CFG"
  fi
done

# Login banner
cat > /etc/issue.net << 'EOF'
**** WARNING ****
Unauthorized access to this system is strictly prohibited.
All activities are monitored and logged.
Disconnect immediately if you are not an authorized user.
**** WARNING ****
EOF

systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
ok "SSH hardened. Root login disabled. AllowUsers=${RDP_USER}."

# =============================================================================
section "STEP 9 — System Security Hardening"
# =============================================================================

# Secure shared memory
log "Securing shared memory..."
grep -qF '/run/shm' /etc/fstab \
  || echo 'tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0' >> /etc/fstab
ok "Shared memory secured."

# Password quality
log "Setting password quality policy..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libpam-pwquality 2>/dev/null || true
PWQUAL=/etc/security/pwquality.conf
[[ -f "$PWQUAL" ]] || touch "$PWQUAL"
declare -A PW_SETTINGS=(
  [minlen]="12"
  [dcredit]="-1"
  [ucredit]="-1"
  [lcredit]="-1"
  [ocredit]="-1"
  [retry]="3"
)
for key in "${!PW_SETTINGS[@]}"; do
  val="${PW_SETTINGS[$key]}"
  if grep -qE "^#?\s*${key}" "$PWQUAL"; then
    sed -i "s|^#\?\s*${key}.*|${key} = ${val}|" "$PWQUAL"
  else
    echo "${key} = ${val}" >> "$PWQUAL"
  fi
done
ok "Password policy: min 12 chars, mixed case + digits required."

# Automatic security updates
log "Enabling automatic security updates..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
ok "Automatic security updates enabled (daily)."

# =============================================================================
section "STEP 10 — Performance Tuning"
# =============================================================================

# TCP/Network tuning
log "Tuning TCP/network for high-performance RDP..."
cat >> /etc/sysctl.conf << 'EOF'

# ── xRDP Performance Tuning ──────────────────────────
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
# File descriptor limit
fs.file-max = 65536
EOF
sysctl -p > /dev/null 2>&1 || true
ok "Network stack tuned. BBR congestion control enabled."

# File descriptor limits
log "Setting file descriptor limits..."
grep -qF '* soft nofile 65536' /etc/security/limits.conf \
  || echo '* soft nofile 65536' >> /etc/security/limits.conf
grep -qF '* hard nofile 65536' /etc/security/limits.conf \
  || echo '* hard nofile 65536' >> /etc/security/limits.conf
ok "File descriptor limit set to 65536."

# XFCE4 performance tweaks (run as user after login via autostart)
log "Creating XFCE4 performance autostart script..."
AUTOSTART_DIR="/home/${RDP_USER}/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
cat > "${AUTOSTART_DIR}/xfce-perf.sh" << 'EOF'
#!/bin/bash
# Disable compositing for better RDP performance
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null
xfconf-query -c xfwm4 -p /general/vblank_mode       -s off   2>/dev/null
xfconf-query -c xfwm4 -p /general/box_move          -s true  2>/dev/null
xfconf-query -c xfwm4 -p /general/box_resize        -s true  2>/dev/null
EOF
chmod +x "${AUTOSTART_DIR}/xfce-perf.sh"

# Create the .desktop autostart entry
cat > "${AUTOSTART_DIR}/xfce-perf.desktop" << EOF
[Desktop Entry]
Type=Application
Name=XFCE Performance Tweaks
Comment=Disable compositing for RDP performance
Exec=/home/${RDP_USER}/.config/autostart/xfce-perf.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
chown -R "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.config"
ok "XFCE4 performance tweaks will apply on next login."

# =============================================================================
section "STEP 11 — Final Service Restart & Verification"
# =============================================================================
log "Restarting all services..."
systemctl daemon-reload
systemctl restart xrdp       && ok "xRDP      → running"
systemctl restart fail2ban   && ok "Fail2Ban  → running"
systemctl restart lightdm 2>/dev/null && ok "LightDM   → running" || warn "LightDM restart skipped (no display)"
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null && ok "SSH       → running"

log "Verifying port ${RDP_PORT} is listening..."
sleep 2
if ss -tlnp 2>/dev/null | grep -q ":${RDP_PORT}"; then
  ok "Port ${RDP_PORT} is OPEN and listening."
else
  warn "Port ${RDP_PORT} not yet detected — xRDP may still be initializing."
fi

# =============================================================================
section "SETUP COMPLETE"
# =============================================================================

SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              SETUP COMPLETED SUCCESSFULLY!          ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo -e "  ║  Server IP    : ${CYAN}${SERVER_IP}${GREEN}"
printf   "  ║  RDP Port     : ${CYAN}%-36s${GREEN}║\n" "${RDP_PORT}"
printf   "  ║  Username     : ${CYAN}%-36s${GREEN}║\n" "${RDP_USER}"
printf   "  ║  Password     : ${CYAN}%-36s${GREEN}║\n" "${RDP_PASS}"
printf   "  ║  Connect via  : ${CYAN}%-36s${GREEN}║\n" "${SERVER_IP}:${RDP_PORT}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  WINDOWS: Open mstsc → Computer: IP:10443          ║"
echo "  ║  Log file: /var/log/xrdp_setup.log                 ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

log "Setup completed successfully at $(date)"
log ""
log "═══ Quick Diagnostic Commands ═══"
log "  sudo systemctl status xrdp"
log "  sudo ss -tlnp | grep ${RDP_PORT}"
log "  sudo ufw status verbose"
log "  sudo fail2ban-client status"
log "  sudo tail -f /var/log/xrdp.log"
log ""
warn "Security Reminder: Change password after first login → passwd ${RDP_USER}"
warn "Consider replacing the self-signed cert with a CA-signed one for production."
echo ""
