#!/usr/bin/env bash
# =============================================================================
#  fixed.sh — Repair xRDP + Complete Remaining Setup Steps
#  Run this after setup.sh failed at "systemctl enable xrdp"
#
#  Usage:
#    wget -O fixed.sh <RAW_GITHUB_URL> && chmod +x fixed.sh && sudo bash fixed.sh
# =============================================================================

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
set_cfg() {
  local file="$1" key="$2" val="$3"
  if grep -qE "^[#;]?\s*${key}\s*=" "$file" 2>/dev/null; then
    sed -i "s|^[#;]\?\s*${key}\s*=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >> "$file"
  fi
}

# ─── PRE-FLIGHT ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo bash fixed.sh${RESET}"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo ""
echo -e "${BOLD}${YELLOW}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║        fixed.sh — xRDP Repair + Remaining Steps     ║"
echo "  ║  Port: ${RDP_PORT}  |  User: ${RDP_USER}                       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "fixed.sh started at $(date)"

# =============================================================================
section "FIX 1 — Stop & Purge Broken xRDP State"
# =============================================================================
log "Stopping xRDP if running..."
systemctl stop xrdp xrdp-sesman 2>/dev/null || true

log "Reinstalling xRDP to get a clean default config..."
DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y xrdp
ok "xRDP reinstalled with fresh default config."

# =============================================================================
section "FIX 2 — Restore & Patch xrdp.ini Correctly"
# =============================================================================
# ROOT CAUSE OF PREVIOUS FAILURE:
#   The old setup.sh replaced the entire xrdp.ini with a custom version that
#   had an invalid [channels] section and missing required entries.
#   FIX: Always patch the default config with sed — never overwrite it.

XRDP_INI=/etc/xrdp/xrdp.ini

log "Backing up fresh xrdp.ini..."
cp "$XRDP_INI" "${XRDP_INI}.fresh" 2>/dev/null || true

log "Patching xrdp.ini (port, TLS, performance)..."
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
ok "xrdp.ini patched — port ${RDP_PORT}, TLS 1.2/1.3, performance tuned."

# =============================================================================
section "FIX 3 — Fix startwm.sh for XFCE4"
# =============================================================================
log "Writing correct startwm.sh..."
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
ok "startwm.sh fixed."

# =============================================================================
section "FIX 4 — Regenerate TLS Certificate"
# =============================================================================
log "Regenerating TLS certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /etc/xrdp/key.pem \
  -out    /etc/xrdp/cert.pem \
  -days   "$CERT_DAYS" \
  -subj   "/CN=${HOSTNAME_NEW}/O=Pixxie/C=TH" 2>/dev/null
chown xrdp:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem
chmod 600 /etc/xrdp/key.pem
chmod 644 /etc/xrdp/cert.pem
ok "TLS certificate regenerated."

# =============================================================================
section "FIX 5 — Fix .xsession and User Groups"
# =============================================================================
log "Setting up .xsession for $RDP_USER..."
cat > "/home/${RDP_USER}/.xsession" << 'XSEOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
startxfce4
XSEOF
chown "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.xsession"
chmod 755 "/home/${RDP_USER}/.xsession"

usermod -aG xrdp     "$RDP_USER" 2>/dev/null || true
usermod -aG ssl-cert "$RDP_USER" 2>/dev/null || true
ok ".xsession and groups fixed."

# =============================================================================
section "FIX 6 — Fix X11 Wrapper"
# =============================================================================
if [[ -f /etc/X11/Xwrapper.config ]]; then
  sed -i 's/allowed_users=console/allowed_users=anybody/' /etc/X11/Xwrapper.config
  grep -q 'needs_root_rights' /etc/X11/Xwrapper.config \
    || echo 'needs_root_rights=yes' >> /etc/X11/Xwrapper.config
else
  printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
fi
ok "X11 wrapper → allowed_users=anybody."

# =============================================================================
section "FIX 7 — Enable & Start xRDP"
# =============================================================================
systemctl daemon-reload
systemctl enable xrdp

log "Starting xRDP..."
if systemctl restart xrdp; then
  sleep 2
  if systemctl is-active --quiet xrdp; then
    ok "xRDP is running successfully on port ${RDP_PORT}."
  else
    err "xRDP started but then stopped. Journal:"
    journalctl -u xrdp --no-pager -n 40 | tee -a "$LOG_FILE"
    exit 1
  fi
else
  err "xRDP failed to start. Journal:"
  journalctl -u xrdp --no-pager -n 40 | tee -a "$LOG_FILE"
  exit 1
fi

# =============================================================================
section "STEP 6 — Firewall (UFW)"
# =============================================================================
log "Configuring UFW..."
ufw --force reset > /dev/null 2>&1

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp            comment 'SSH'
ufw allow "${RDP_PORT}/tcp" comment 'xRDP'
ufw --force enable

ok "UFW enabled. Ports open: SSH(22), xRDP(${RDP_PORT})."
ufw status verbose | tee -a "$LOG_FILE"

# =============================================================================
section "STEP 7 — Fail2Ban (Brute Force Protection)"
# =============================================================================
log "Installing and configuring Fail2Ban..."
DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
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
cp "$SSHD" "${SSHD}.backup.fixed" 2>/dev/null || true

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
ok "Password policy applied."

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
log "Restarting all services for final check..."
systemctl daemon-reload
systemctl restart xrdp      && ok "xRDP      ✓" || err "xRDP      ✗"
systemctl restart fail2ban  && ok "Fail2Ban  ✓" || err "Fail2Ban  ✗"
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
ok "SSH       ✓"

sleep 2
echo ""
log "Service status:"
systemctl is-active xrdp     | xargs -I{} log "  xRDP      → {}"
systemctl is-active fail2ban | xargs -I{} log "  Fail2Ban  → {}"
systemctl is-active ssh      | xargs -I{} log "  SSH       → {}"
systemctl is-active ufw      | xargs -I{} log "  UFW       → {}"

echo ""
log "Listening port check:"
ss -tlnp 2>/dev/null | grep -E "(:${RDP_PORT}|:22)" | tee -a "$LOG_FILE" \
  || warn "No matching ports found yet — services may still be starting."

if ss -tlnp 2>/dev/null | grep -q ":${RDP_PORT}"; then
  ok "Port ${RDP_PORT} confirmed OPEN and listening."
else
  warn "Port ${RDP_PORT} not yet visible. Try: sudo ss -tlnp | grep ${RDP_PORT}"
fi

# =============================================================================
section "ALL DONE"
# =============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║       ALL STEPS COMPLETED SUCCESSFULLY              ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf "  ║  Server IP  : ${CYAN}%-38s${GREEN}║\n" "$SERVER_IP"
printf "  ║  RDP Port   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PORT"
printf "  ║  Username   : ${CYAN}%-38s${GREEN}║\n" "$RDP_USER"
printf "  ║  Password   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PASS"
printf "  ║  Connect    : ${CYAN}%-38s${GREEN}║\n" "${SERVER_IP}:${RDP_PORT}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Windows: Win+R → mstsc                            ║"
echo "  ║    Computer: YOUR_SERVER_IP:10443                  ║"
echo "  ║  Log: /var/log/xrdp_setup.log                      ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Diagnostic commands:                              ║"
echo "  ║    sudo systemctl status xrdp                      ║"
echo "  ║    sudo tail -f /var/log/xrdp.log                  ║"
echo "  ║    sudo ss -tlnp | grep 10443                      ║"
echo "  ║    sudo ufw status verbose                         ║"
echo "  ║    sudo fail2ban-client status                     ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
warn "Important: Change password after login → passwd ${RDP_USER}"
log "fixed.sh completed at $(date)"
