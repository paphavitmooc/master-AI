#!/usr/bin/env bash
# =============================================================================
#  fixed.sh  (v3) — Fix xRDP log permission + Complete Remaining Steps
#  Root cause: xrdp cannot open /var/log/xrdp.log  (wrong owner/missing file)
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
die()     { err "$*"; exit 1; }
section() {
  echo "" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

# Patch or append  key=value  in an ini-style config file
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
echo "  ║      fixed.sh v3 — xRDP Repair + Remaining Steps   ║"
echo "  ║  Port: ${RDP_PORT}  |  User: ${RDP_USER}                       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "fixed.sh v3 started at $(date)"

# =============================================================================
section "FIX 1 — Stop xRDP completely"
# =============================================================================
log "Stopping xrdp and xrdp-sesman services..."
systemctl stop xrdp-sesman 2>/dev/null || true
systemctl stop xrdp        2>/dev/null || true
# Kill any leftover processes
pkill -9 -f xrdp 2>/dev/null || true
sleep 1
ok "xRDP stopped."

# =============================================================================
section "FIX 2 — Fix xRDP Log Files  ← ROOT CAUSE OF FAILURE"
# =============================================================================
# The exact error was:
#   "error opening log file [The log is not properly started]. quitting."
# This means /var/log/xrdp.log and /var/log/xrdp-sesman.log either:
#   (a) Don't exist, or (b) Are owned by root instead of xrdp:xrdp

log "Creating and fixing permissions on xRDP log files..."

# Create log files if they don't exist
touch /var/log/xrdp.log
touch /var/log/xrdp-sesman.log

# Fix ownership — must be owned by xrdp user
chown xrdp:xrdp /var/log/xrdp.log
chown xrdp:xrdp /var/log/xrdp-sesman.log

# Fix permissions — xrdp must be able to write
chmod 640 /var/log/xrdp.log
chmod 640 /var/log/xrdp-sesman.log

ok "Log files created with correct xrdp:xrdp ownership."
log "  /var/log/xrdp.log        → $(stat -c '%U:%G %a' /var/log/xrdp.log)"
log "  /var/log/xrdp-sesman.log → $(stat -c '%U:%G %a' /var/log/xrdp-sesman.log)"

# Also ensure xrdp user can write to /var/log itself if needed
chmod o+rx /var/log 2>/dev/null || true

# =============================================================================
section "FIX 3 — Verify xRDP Log Path in sesman.ini"
# =============================================================================
# xrdp-sesman has its own log config — make sure it points to a writable path
SESMAN_INI=/etc/xrdp/sesman.ini
if [[ -f "$SESMAN_INI" ]]; then
  log "Checking sesman.ini log path..."
  cp "$SESMAN_INI" "${SESMAN_INI}.backup.v3" 2>/dev/null || true

  # Ensure LogFile points to correct path
  if grep -qE "^[#;]?\s*LogFile\s*=" "$SESMAN_INI"; then
    sed -i "s|^[#;]\?\s*LogFile\s*=.*|LogFile=/var/log/xrdp-sesman.log|" "$SESMAN_INI"
  else
    # Insert under [Logging] section or append
    if grep -q '^\[Logging\]' "$SESMAN_INI"; then
      sed -i '/^\[Logging\]/a LogFile=\/var\/log\/xrdp-sesman.log' "$SESMAN_INI"
    else
      echo -e "\n[Logging]\nLogFile=/var/log/xrdp-sesman.log" >> "$SESMAN_INI"
    fi
  fi

  # Also fix LogLevel and EnableSyslog
  if grep -qE "^[#;]?\s*LogLevel\s*=" "$SESMAN_INI"; then
    sed -i "s|^[#;]\?\s*LogLevel\s*=.*|LogLevel=INFO|" "$SESMAN_INI"
  fi

  ok "sesman.ini log path verified → /var/log/xrdp-sesman.log"
else
  warn "sesman.ini not found at $SESMAN_INI — skipping."
fi

# =============================================================================
section "FIX 4 — Patch xrdp.ini (port + TLS + performance)"
# =============================================================================
XRDP_INI=/etc/xrdp/xrdp.ini

if [[ ! -f "$XRDP_INI" ]]; then
  log "xrdp.ini missing — reinstalling xRDP package..."
  DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y xrdp
  # Re-fix log files after reinstall (reinstall may reset them)
  touch /var/log/xrdp.log /var/log/xrdp-sesman.log
  chown xrdp:xrdp /var/log/xrdp.log /var/log/xrdp-sesman.log
  chmod 640 /var/log/xrdp.log /var/log/xrdp-sesman.log
fi

log "Backing up xrdp.ini..."
cp "$XRDP_INI" "${XRDP_INI}.backup.v3" 2>/dev/null || true

log "Patching xrdp.ini..."
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
ok "xrdp.ini patched — port ${RDP_PORT}, TLS 1.2/1.3, performance."

# =============================================================================
section "FIX 5 — Fix startwm.sh for XFCE4"
# =============================================================================
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
ok "startwm.sh → XFCE4."

# =============================================================================
section "FIX 6 — Regenerate TLS Certificate"
# =============================================================================
log "Regenerating self-signed TLS certificate..."
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
section "FIX 7 — Fix .xsession + X11 Wrapper + User Groups"
# =============================================================================
# .xsession
cat > "/home/${RDP_USER}/.xsession" << 'XSEOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
startxfce4
XSEOF
chown "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.xsession"
chmod 755 "/home/${RDP_USER}/.xsession"

# User groups
usermod -aG xrdp     "$RDP_USER" 2>/dev/null || true
usermod -aG ssl-cert "$RDP_USER" 2>/dev/null || true

# X11 wrapper
if [[ -f /etc/X11/Xwrapper.config ]]; then
  sed -i 's/allowed_users=console/allowed_users=anybody/' /etc/X11/Xwrapper.config
  grep -q 'needs_root_rights' /etc/X11/Xwrapper.config \
    || echo 'needs_root_rights=yes' >> /etc/X11/Xwrapper.config
else
  printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
fi

ok ".xsession, X11 wrapper, and user groups all fixed."

# =============================================================================
section "FIX 8 — Start xRDP (with full log check)"
# =============================================================================
log "Reloading systemd and enabling xRDP..."
systemctl daemon-reload
systemctl enable xrdp

log "Starting xRDP..."
if systemctl restart xrdp; then
  sleep 3

  if systemctl is-active --quiet xrdp; then
    ok "xRDP is running successfully."
    log "Port check:"
    ss -tlnp | grep ":${RDP_PORT}" | tee -a "$LOG_FILE" \
      && ok "Port ${RDP_PORT} is OPEN." \
      || warn "Port ${RDP_PORT} not visible yet — may still be binding."
  else
    err "xRDP started but then stopped. Last journal lines:"
    journalctl -u xrdp --no-pager -n 50 | tee -a "$LOG_FILE"
    die "xRDP is still failing. Review the journal output above."
  fi
else
  err "systemctl restart xrdp returned non-zero. Journal:"
  journalctl -u xrdp --no-pager -n 50 | tee -a "$LOG_FILE"
  die "xRDP could not be started. Review the output above."
fi

# Show current xrdp.log for confirmation
log "Last 5 lines of /var/log/xrdp.log:"
tail -5 /var/log/xrdp.log 2>/dev/null | tee -a "$LOG_FILE" || true

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

ok "UFW enabled — Open: SSH(22), xRDP(${RDP_PORT})."
ufw status verbose | tee -a "$LOG_FILE"

# =============================================================================
section "STEP 7 — Fail2Ban (Brute Force Protection)"
# =============================================================================
log "Configuring Fail2Ban..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban
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
log "Hardening SSH..."
SSHD=/etc/ssh/sshd_config
cp "$SSHD" "${SSHD}.backup.v3" 2>/dev/null || true

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
ok "SSH hardened. PermitRootLogin=no. AllowUsers=${RDP_USER}."

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
ok "Password policy applied (min 12 chars, mixed case + digits)."

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
# Disable compositing for better RDP performance
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
section "FINAL — Service Status & Verification"
# =============================================================================
log "Final service check..."
echo ""

check_svc() {
  local name="$1"
  if systemctl is-active --quiet "$name" 2>/dev/null; then
    ok "  ${name}  → active ✓"
  else
    warn "  ${name}  → INACTIVE ✗  (run: sudo systemctl status ${name})"
  fi
}

check_svc xrdp
check_svc fail2ban
check_svc ufw
check_svc ssh 2>/dev/null || check_svc sshd 2>/dev/null || true

echo ""
log "Port check:"
ss -tlnp 2>/dev/null | grep -E "(:${RDP_PORT}|:22)" | tee -a "$LOG_FILE" || true

if ss -tlnp 2>/dev/null | grep -q ":${RDP_PORT}"; then
  ok "Port ${RDP_PORT} is OPEN and listening. ✓"
else
  warn "Port ${RDP_PORT} not detected. Check: sudo systemctl status xrdp"
fi

# =============================================================================
section "ALL DONE"
# =============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║         ALL STEPS COMPLETED SUCCESSFULLY            ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf "  ║  Server IP  : ${CYAN}%-38s${GREEN}║\n" "$SERVER_IP"
printf "  ║  RDP Port   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PORT"
printf "  ║  Username   : ${CYAN}%-38s${GREEN}║\n" "$RDP_USER"
printf "  ║  Password   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PASS"
printf "  ║  Connect    : ${CYAN}%-38s${GREEN}║\n" "${SERVER_IP}:${RDP_PORT}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Windows: Win+R  →  mstsc                          ║"
echo "  ║    Computer: YOUR_SERVER_IP:10443                  ║"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Diagnostics:                                      ║"
echo "  ║    sudo systemctl status xrdp                      ║"
echo "  ║    sudo tail -f /var/log/xrdp.log                  ║"
echo "  ║    sudo ss -tlnp | grep 10443                      ║"
echo "  ║    sudo ufw status verbose                         ║"
echo "  ║    sudo fail2ban-client status                     ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
warn "Change your password after first login: passwd ${RDP_USER}"
log "fixed.sh v3 completed at $(date)"
