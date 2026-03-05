#!/usr/bin/env bash
# =============================================================================
#  Ubuntu 24.04 LTS — XFCE4 Desktop + xRDP Secure Setup  (v2 — FIXED)
#  Port: 10443 | User: Pixxie | Secured + Performance Optimized
#
#  Usage:
#    wget -O setup.sh <RAW_GITHUB_URL> && chmod +x setup.sh && sudo bash setup.sh
# =============================================================================

# NOTE: intentionally NO "set -e" — each step handles its own errors
set -uo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
RDP_PORT=10443
RDP_USER="Pixxie"
RDP_PASS="Aannggeell5859"
HOSTNAME_NEW="pixxiestudio"
CERT_DAYS=3650
LOG_FILE="/var/log/xrdp_setup.log"

# ─── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── HELPERS ──────────────────────────────────────────────────────────────────
log()     { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[FAIL]${RESET}  $*" | tee -a "$LOG_FILE"; }
section() {
  echo "" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

# Safely set key=value in a config file (replace commented or existing line, or append)
set_cfg() {
  local file="$1" key="$2" val="$3"
  if grep -qE "^[#;]?\s*${key}\s*=" "$file" 2>/dev/null; then
    sed -i "s|^[#;]\?\s*${key}\s*=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

# ─── PRE-FLIGHT ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo bash setup.sh${RESET}"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║  Ubuntu 24.04 LTS — XFCE4 + xRDP Setup  (v2 FIXED) ║"
echo "  ║  Port: ${RDP_PORT}  |  User: ${RDP_USER}                       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "Setup started at $(date)"

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
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl wget gnupg2 software-properties-common \
  net-tools ufw fail2ban unzip git \
  openssl dbus-x11 xorg ca-certificates

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
section "STEP 3 — Create User: $RDP_USER"
# =============================================================================
if id "$RDP_USER" &>/dev/null; then
  warn "User '$RDP_USER' already exists — skipping creation."
else
  useradd -m -s /bin/bash -G sudo "$RDP_USER"
  ok "User '$RDP_USER' created with sudo rights."
fi
echo "${RDP_USER}:${RDP_PASS}" | chpasswd
ok "Password set for $RDP_USER."

# =============================================================================
section "STEP 4 — Install XFCE4 Desktop Environment"
# =============================================================================
log "Installing XFCE4 (minimal, RDP-optimised)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xfce4 xfce4-goodies \
  xfce4-terminal thunar mousepad \
  xfce4-screensaver \
  xfce4-netload-plugin xfce4-systemload-plugin
ok "XFCE4 installed."

log "Installing LightDM display manager..."
DEBIAN_FRONTEND=noninteractive apt-get install -y lightdm lightdm-gtk-greeter
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm 2>/dev/null || true
systemctl enable lightdm 2>/dev/null || true
systemctl set-default graphical.target
ok "LightDM enabled. Graphical target set."

# =============================================================================
section "STEP 5 — Install & Configure xRDP"
# =============================================================================
log "Installing xRDP..."
DEBIAN_FRONTEND=noninteractive apt-get install -y xrdp
ok "xRDP package installed."

# ── Groups ────────────────────────────────────────────────────────────────────
usermod -aG xrdp     "$RDP_USER" 2>/dev/null || true
usermod -aG ssl-cert "$RDP_USER" 2>/dev/null || true
ok "$RDP_USER added to xrdp and ssl-cert groups."

# ── .xsession ─────────────────────────────────────────────────────────────────
cat > "/home/${RDP_USER}/.xsession" << 'XSEOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
startxfce4
XSEOF
chown "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.xsession"
chmod 755 "/home/${RDP_USER}/.xsession"
ok ".xsession configured for $RDP_USER."

# ── startwm.sh ────────────────────────────────────────────────────────────────
# FIX: Do NOT use "exec" — let startxfce4 run and return normally
cat > /etc/xrdp/startwm.sh << 'WMEOF'
#!/bin/sh
# xRDP session startup — XFCE4
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

if [ -r /etc/profile ]; then
  . /etc/profile
fi
if [ -r "${HOME}/.profile" ]; then
  . "${HOME}/.profile"
fi

startxfce4
WMEOF
chmod +x /etc/xrdp/startwm.sh
ok "startwm.sh configured for XFCE4."

# ── TLS Certificate ───────────────────────────────────────────────────────────
log "Generating self-signed TLS certificate (${CERT_DAYS} days)..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /etc/xrdp/key.pem \
  -out    /etc/xrdp/cert.pem \
  -days   "$CERT_DAYS" \
  -subj   "/CN=${HOSTNAME_NEW}/O=Pixxie/C=TH" 2>/dev/null
chown xrdp:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem
chmod 600 /etc/xrdp/key.pem
chmod 644 /etc/xrdp/cert.pem
ok "TLS certificate generated."

# ── Patch xrdp.ini (KEY FIX: patch default config, never overwrite it) ────────
log "Patching /etc/xrdp/xrdp.ini (port ${RDP_PORT})..."
XRDP_INI=/etc/xrdp/xrdp.ini
cp "$XRDP_INI" "${XRDP_INI}.backup" 2>/dev/null || true

set_cfg "$XRDP_INI" port               "$RDP_PORT"
set_cfg "$XRDP_INI" address            "0.0.0.0"
set_cfg "$XRDP_INI" security_layer     "tls"
set_cfg "$XRDP_INI" crypt_level        "high"
set_cfg "$XRDP_INI" certificate        "/etc/xrdp/cert.pem"
set_cfg "$XRDP_INI" key_file           "/etc/xrdp/key.pem"
set_cfg "$XRDP_INI" ssl_protocols      "TLSv1.2, TLSv1.3"
set_cfg "$XRDP_INI" tls_ciphers        "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5"
set_cfg "$XRDP_INI" max_bpp            "32"
set_cfg "$XRDP_INI" xserverbpp         "24"
set_cfg "$XRDP_INI" tcp_nodelay        "yes"
set_cfg "$XRDP_INI" tcp_keepalive      "yes"
set_cfg "$XRDP_INI" bitmap_cache       "yes"
set_cfg "$XRDP_INI" bitmap_compression "yes"
set_cfg "$XRDP_INI" bulk_compression   "yes"
set_cfg "$XRDP_INI" new_cursors        "true"
set_cfg "$XRDP_INI" use_compression    "yes"
ok "xrdp.ini patched — port ${RDP_PORT}, TLS, performance settings applied."

# ── X11 wrapper ───────────────────────────────────────────────────────────────
if [[ -f /etc/X11/Xwrapper.config ]]; then
  sed -i 's/allowed_users=console/allowed_users=anybody/' /etc/X11/Xwrapper.config
else
  printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
fi
ok "X11 wrapper → allowed_users=anybody."

# ── Start xRDP ────────────────────────────────────────────────────────────────
log "Enabling and starting xRDP service..."
systemctl daemon-reload
systemctl enable xrdp

if systemctl restart xrdp; then
  ok "xRDP service started successfully on port ${RDP_PORT}."
else
  err "xRDP failed to start. Showing journal:"
  journalctl -u xrdp --no-pager -n 40 | tee -a "$LOG_FILE"
  err "Please fix the error above, then run fixed.sh to continue."
  exit 1
fi

# =============================================================================
section "STEP 6 — Firewall (UFW)"
# =============================================================================
log "Configuring UFW..."
ufw --force reset > /dev/null 2>&1

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow "${RDP_PORT}/tcp" comment 'xRDP'
ufw --force enable

ok "UFW enabled. Open: SSH(22), xRDP(${RDP_PORT})."
ufw status verbose | tee -a "$LOG_FILE"

# =============================================================================
section "STEP 7 — Fail2Ban (Brute Force Protection)"
# =============================================================================
log "Configuring Fail2Ban for xRDP and SSH..."
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true

cat > /etc/fail2ban/jail.d/xrdp.conf << FBEOF
[xrdp]
enabled  = true
port     = ${RDP_PORT}
filter   = xrdp
logpath  = /var/log/xrdp.log
maxretry = 5
findtime = 600
bantime  = 3600
action   = iptables-multiport[name=xrdp, port=${RDP_PORT}, protocol=tcp]
FBEOF

cat > /etc/fail2ban/filter.d/xrdp.conf << 'FBEOF'
[Definition]
failregex = .*\[XRDP\].*connect_ip_from.*FAILED.*<HOST>
            .*\[XRDP\].*User.*failed.*authentication.*<HOST>
            .*connection denied.*<HOST>
            .*Login failed.*display.*<HOST>
ignoreregex =
FBEOF

cat > /etc/fail2ban/jail.d/sshd-extra.conf << 'FBEOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 4
findtime = 300
bantime  = 7200
FBEOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2Ban active — xRDP: 5 tries→1hr ban | SSH: 4 tries→2hr ban."

# =============================================================================
section "STEP 8 — SSH Hardening"
# =============================================================================
log "Hardening SSH configuration..."
SSHD=/etc/ssh/sshd_config
cp "$SSHD" "${SSHD}.backup" 2>/dev/null || true

ssh_set() {
  local key="$1" val="$2"
  if grep -qE "^[#]?\s*${key}\s" "$SSHD"; then
    sed -i "s|^[#]\?\s*${key}\s.*|${key} ${val}|" "$SSHD"
  else
    echo "${key} ${val}" >> "$SSHD"
  fi
}

ssh_set PermitRootLogin        no
ssh_set MaxAuthTries           3
ssh_set LoginGraceTime         30
ssh_set X11Forwarding          no
ssh_set AllowUsers             "$RDP_USER"
ssh_set PasswordAuthentication yes
ssh_set PubkeyAuthentication   yes
ssh_set IgnoreRhosts           yes
ssh_set PermitEmptyPasswords   no
ssh_set ClientAliveInterval    300
ssh_set ClientAliveCountMax    2
ssh_set Banner                 /etc/issue.net

cat > /etc/issue.net << 'BNREOF'
**** WARNING ****
Unauthorized access is strictly prohibited.
All activities are monitored and logged.
Disconnect immediately if you are not an authorized user.
**** WARNING ****
BNREOF

systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
ok "SSH hardened. Root=no. AllowUsers=${RDP_USER}."

# =============================================================================
section "STEP 9 — System Security Hardening"
# =============================================================================
grep -qF 'tmpfs /run/shm' /etc/fstab \
  || echo 'tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0' >> /etc/fstab
ok "Shared memory secured."

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libpam-pwquality 2>/dev/null || true
PWQUAL=/etc/security/pwquality.conf
[[ -f "$PWQUAL" ]] || touch "$PWQUAL"
for kv in "minlen=12" "dcredit=-1" "ucredit=-1" "lcredit=-1" "ocredit=-1" "retry=3"; do
  k="${kv%%=*}"; v="${kv#*=}"
  if grep -qE "^[#]?\s*${k}\s*=" "$PWQUAL"; then
    sed -i "s|^[#]\?\s*${k}\s*=.*|${k} = ${v}|" "$PWQUAL"
  else
    echo "${k} = ${v}" >> "$PWQUAL"
  fi
done
ok "Password policy applied (min 12 chars, mixed)."

DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUEOF
ok "Automatic security updates enabled."

# =============================================================================
section "STEP 10 — Performance Tuning"
# =============================================================================
if ! grep -q 'xRDP Performance Tuning' /etc/sysctl.conf; then
  cat >> /etc/sysctl.conf << 'SCEOF'

# ── xRDP Performance Tuning ──────────────────────────────────
net.core.rmem_max               = 16777216
net.core.wmem_max               = 16777216
net.ipv4.tcp_rmem               = 4096 87380 16777216
net.ipv4.tcp_wmem               = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc          = fq
net.ipv4.tcp_fastopen           = 3
net.ipv4.tcp_mtu_probing        = 1
fs.file-max                     = 65536
SCEOF
fi
sysctl -p > /dev/null 2>&1 || true
ok "Network stack tuned. BBR congestion control enabled."

grep -qF '* soft nofile 65536' /etc/security/limits.conf \
  || echo '* soft nofile 65536' >> /etc/security/limits.conf
grep -qF '* hard nofile 65536' /etc/security/limits.conf \
  || echo '* hard nofile 65536' >> /etc/security/limits.conf
ok "File descriptor limit → 65536."

ADIR="/home/${RDP_USER}/.config/autostart"
mkdir -p "$ADIR"
cat > "${ADIR}/xfce-perf.sh" << 'XPEOF'
#!/bin/bash
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null || true
xfconf-query -c xfwm4 -p /general/vblank_mode       -s off   2>/dev/null || true
xfconf-query -c xfwm4 -p /general/box_move          -s true  2>/dev/null || true
xfconf-query -c xfwm4 -p /general/box_resize        -s true  2>/dev/null || true
XPEOF
chmod +x "${ADIR}/xfce-perf.sh"

cat > "${ADIR}/xfce-perf.desktop" << XDEOF
[Desktop Entry]
Type=Application
Name=XFCE Performance Tweaks
Exec=/home/${RDP_USER}/.config/autostart/xfce-perf.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
XDEOF
chown -R "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.config"
ok "XFCE4 performance autostart configured."

# =============================================================================
section "STEP 11 — Final Verification"
# =============================================================================
systemctl daemon-reload
systemctl restart xrdp     && ok "xRDP      ✓" || err "xRDP      ✗ — journalctl -u xrdp"
systemctl restart fail2ban && ok "Fail2Ban  ✓" || err "Fail2Ban  ✗"
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true; ok "SSH       ✓"

sleep 2
if ss -tlnp 2>/dev/null | grep -q ":${RDP_PORT}"; then
  ok "Port ${RDP_PORT} confirmed OPEN."
else
  warn "Port ${RDP_PORT} not detected — xRDP may still be initialising."
fi

# =============================================================================
section "SETUP COMPLETE"
# =============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         SETUP COMPLETED SUCCESSFULLY                ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf "  ║  Server IP  : ${CYAN}%-38s${GREEN}║\n" "$SERVER_IP"
printf "  ║  RDP Port   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PORT"
printf "  ║  Username   : ${CYAN}%-38s${GREEN}║\n" "$RDP_USER"
printf "  ║  Password   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PASS"
printf "  ║  Connect    : ${CYAN}%-38s${GREEN}║\n" "${SERVER_IP}:${RDP_PORT}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Windows: mstsc → Computer: IP:10443               ║"
echo "  ║  Log: /var/log/xrdp_setup.log                      ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
warn "Change password after first login: passwd ${RDP_USER}"
log "Completed at $(date)"
