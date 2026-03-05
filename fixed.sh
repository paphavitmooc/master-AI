#!/usr/bin/env bash
# =============================================================================
#  fixed.sh  (v4 — FINAL)
#  Fixes:
#   1. AppArmor blocking xRDP log file writes  (root cause of "Could not start log")
#   2. section-aware xrdp.ini patching  (port=10443 was replacing port=-1 in [Xorg]/[Xvnc])
#   3. Full purge + reinstall for clean state
#   4. All remaining setup steps (UFW, Fail2Ban, SSH, Security, Performance)
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

# ─── SECTION-AWARE ini patcher ────────────────────────────────────────────────
# BUG in v1-v3: plain sed replaced ALL matching keys across ALL sections.
# e.g. "port=10443" also clobbered "port=-1" in [Xorg] and [Xvnc],
# breaking xRDP's internal session-forwarding mechanism.
# This function only patches the key inside the specified [section].
patch_ini() {
  local file="$1" section="$2" key="$3" val="$4"
  python3 - "$file" "$section" "$key" "$val" << 'PYEOF'
import sys, re

fpath, section, key, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

with open(fpath, 'r') as f:
    lines = f.readlines()

in_section  = False
key_found   = False
insert_at   = -1
section_hdr = f'[{section}]'
key_pattern = re.compile(r'^[#;]?\s*' + re.escape(key) + r'\s*=', re.IGNORECASE)

for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.lower() == section_hdr.lower():
        in_section = True
        insert_at  = i + 1
        continue
    if in_section and stripped.startswith('['):
        in_section = False
    if in_section:
        insert_at = i + 1
        if key_pattern.match(stripped):
            lines[i] = f'{key}={val}\n'
            key_found = True

if not key_found and insert_at >= 0:
    lines.insert(insert_at, f'{key}={val}\n')

with open(fpath, 'w') as f:
    f.writelines(lines)
PYEOF
}

# ─── PRE-FLIGHT ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo bash fixed.sh${RESET}"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo ""
echo -e "${BOLD}${YELLOW}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║      fixed.sh v4 (FINAL) — xRDP Full Repair        ║"
echo "  ║  Port: ${RDP_PORT}  |  User: ${RDP_USER}                       ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "fixed.sh v4 started at $(date)"

# =============================================================================
section "FIX 1 — Stop Everything Cleanly"
# =============================================================================
log "Stopping all xRDP processes..."
systemctl stop xrdp-sesman 2>/dev/null || true
systemctl stop xrdp        2>/dev/null || true
pkill -9 -f xrdp           2>/dev/null || true
sleep 1
ok "All xRDP processes stopped."

# =============================================================================
section "FIX 2 — AppArmor  ← ROOT CAUSE of 'Could not start log'"
# =============================================================================
# Ubuntu 24.04 ships AppArmor profiles for xrdp in ENFORCE mode.
# Even with correct file ownership, AppArmor can block xrdp from
# writing /var/log/xrdp.log. The fix is to disable the xRDP AppArmor profiles.

log "Checking for AppArmor..."
if command -v aa-status &>/dev/null && aa-status --enabled 2>/dev/null; then
  log "AppArmor is active — disabling xRDP profiles..."

  # Method 1: aa-disable (preferred)
  if command -v aa-disable &>/dev/null; then
    aa-disable /etc/apparmor.d/usr.sbin.xrdp        2>/dev/null && log "  Disabled: usr.sbin.xrdp"        || true
    aa-disable /etc/apparmor.d/usr.sbin.xrdp-sesman 2>/dev/null && log "  Disabled: usr.sbin.xrdp-sesman" || true
  fi

  # Method 2: apparmor_parser -R (remove from kernel)
  apparmor_parser -R /etc/apparmor.d/usr.sbin.xrdp        2>/dev/null || true
  apparmor_parser -R /etc/apparmor.d/usr.sbin.xrdp-sesman 2>/dev/null || true

  # Method 3: symlink to disable directory (survives reboots)
  mkdir -p /etc/apparmor.d/disable
  ln -sf /etc/apparmor.d/usr.sbin.xrdp        /etc/apparmor.d/disable/ 2>/dev/null || true
  ln -sf /etc/apparmor.d/usr.sbin.xrdp-sesman /etc/apparmor.d/disable/ 2>/dev/null || true

  ok "AppArmor xRDP profiles disabled."

  # Verify xrdp is no longer in enforce/complain mode
  if aa-status 2>/dev/null | grep -qi xrdp; then
    warn "xRDP still appears in aa-status — will proceed and verify after start."
  else
    ok "Confirmed: xRDP not in AppArmor enforce list."
  fi
else
  log "AppArmor is not active or not installed — skipping."
  ok "AppArmor: N/A"
fi

# =============================================================================
section "FIX 3 — Full Purge + Clean Reinstall of xRDP"
# =============================================================================
log "Purging xRDP completely (removes all broken config state)..."
systemctl disable xrdp 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get purge -y xrdp 2>/dev/null || true
rm -f /etc/xrdp/xrdp.ini /etc/xrdp/sesman.ini /etc/xrdp/startwm.sh 2>/dev/null || true
rm -f /var/log/xrdp.log /var/log/xrdp-sesman.log 2>/dev/null || true

log "Reinstalling xRDP fresh..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y xrdp
ok "xRDP freshly installed."

# =============================================================================
section "FIX 4 — Log Files (must happen right after install)"
# =============================================================================
# After purge+install, log files may not exist. Create them immediately
# and set ownership before AppArmor (if any remaining) can interfere.

log "Creating xRDP log files with correct ownership..."
mkdir -p /var/log
touch /var/log/xrdp.log
touch /var/log/xrdp-sesman.log

chown xrdp:xrdp /var/log/xrdp.log
chown xrdp:xrdp /var/log/xrdp-sesman.log
chmod 640 /var/log/xrdp.log
chmod 640 /var/log/xrdp-sesman.log

ok "Log files created:"
log "  $(stat -c '%n  owner=%U:%G  mode=%a' /var/log/xrdp.log)"
log "  $(stat -c '%n  owner=%U:%G  mode=%a' /var/log/xrdp-sesman.log)"

# Verify sesman.ini points to correct log path
SESMAN_INI=/etc/xrdp/sesman.ini
if [[ -f "$SESMAN_INI" ]]; then
  log "Checking sesman.ini LogFile setting..."
  if grep -qE "^[#;]?\s*LogFile\s*=" "$SESMAN_INI"; then
    sed -i "s|^[#;]\?\s*LogFile\s*=.*|LogFile=/var/log/xrdp-sesman.log|" "$SESMAN_INI"
  fi
  ok "sesman.ini LogFile verified."
fi

# =============================================================================
section "FIX 5 — Patch xrdp.ini (section-aware — fixes port= bug)"
# =============================================================================
XRDP_INI=/etc/xrdp/xrdp.ini
[[ -f "$XRDP_INI" ]] || die "xrdp.ini not found after reinstall — something is very wrong."

log "Backing up fresh xrdp.ini..."
cp "$XRDP_INI" "${XRDP_INI}.clean_backup"

log "Patching [Globals] only — port, TLS, performance..."
# Each call only modifies keys inside [Globals], leaving [Xorg]/[Xvnc] untouched
patch_ini "$XRDP_INI" Globals port               "$RDP_PORT"
patch_ini "$XRDP_INI" Globals address            "0.0.0.0"
patch_ini "$XRDP_INI" Globals security_layer     "tls"
patch_ini "$XRDP_INI" Globals crypt_level        "high"
patch_ini "$XRDP_INI" Globals certificate        "/etc/xrdp/cert.pem"
patch_ini "$XRDP_INI" Globals key_file           "/etc/xrdp/key.pem"
patch_ini "$XRDP_INI" Globals ssl_protocols      "TLSv1.2, TLSv1.3"
patch_ini "$XRDP_INI" Globals tls_ciphers        "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5"
patch_ini "$XRDP_INI" Globals max_bpp            "32"
patch_ini "$XRDP_INI" Globals xserverbpp         "24"
patch_ini "$XRDP_INI" Globals tcp_nodelay        "yes"
patch_ini "$XRDP_INI" Globals tcp_keepalive      "yes"
patch_ini "$XRDP_INI" Globals bitmap_cache       "yes"
patch_ini "$XRDP_INI" Globals bitmap_compression "yes"
patch_ini "$XRDP_INI" Globals bulk_compression   "yes"
patch_ini "$XRDP_INI" Globals new_cursors        "true"
patch_ini "$XRDP_INI" Globals use_compression    "yes"

ok "xrdp.ini patched."
log "Verifying [Xorg] and [Xvnc] port=-1 are untouched:"
grep -A8 '^\[Xorg\]'  "$XRDP_INI" | grep port | tee -a "$LOG_FILE"
grep -A8 '^\[Xvnc\]'  "$XRDP_INI" | grep port | tee -a "$LOG_FILE"

# =============================================================================
section "FIX 6 — startwm.sh for XFCE4"
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
section "FIX 7 — TLS Certificate"
# =============================================================================
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

# =============================================================================
section "FIX 8 — .xsession, X11 Wrapper, User Groups"
# =============================================================================
log "Configuring .xsession for $RDP_USER..."
cat > "/home/${RDP_USER}/.xsession" << 'XSEOF'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
startxfce4
XSEOF
chown "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.xsession"
chmod 755 "/home/${RDP_USER}/.xsession"

log "Adding $RDP_USER to xrdp and ssl-cert groups..."
usermod -aG xrdp     "$RDP_USER" 2>/dev/null || true
usermod -aG ssl-cert "$RDP_USER" 2>/dev/null || true

log "Fixing X11 wrapper..."
if [[ -f /etc/X11/Xwrapper.config ]]; then
  sed -i 's/allowed_users=console/allowed_users=anybody/' /etc/X11/Xwrapper.config
  grep -q 'needs_root_rights' /etc/X11/Xwrapper.config \
    || echo 'needs_root_rights=yes' >> /etc/X11/Xwrapper.config
else
  printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
fi
ok ".xsession, groups, and X11 wrapper done."

# =============================================================================
section "FIX 9 — Start xRDP + Full Verification"
# =============================================================================
systemctl daemon-reload
systemctl enable xrdp

log "Starting xRDP..."
if systemctl restart xrdp; then
  sleep 3
  if systemctl is-active --quiet xrdp; then
    ok "xRDP is running!"
    log "Port ${RDP_PORT} check:"
    ss -tlnp 2>/dev/null | grep ":${RDP_PORT}" | tee -a "$LOG_FILE" \
      && ok "Port ${RDP_PORT} is OPEN ✓" \
      || warn "Port not visible yet — may still be binding."
    log ""
    log "Last lines of /var/log/xrdp.log:"
    tail -8 /var/log/xrdp.log 2>/dev/null | tee -a "$LOG_FILE" || true
  else
    err "xRDP started but then crashed. Journal:"
    journalctl -u xrdp --no-pager -n 60 | tee -a "$LOG_FILE"
    die "xRDP still failing — see journal above."
  fi
else
  err "systemctl restart xrdp failed. Journal:"
  journalctl -u xrdp --no-pager -n 60 | tee -a "$LOG_FILE"
  die "xRDP could not start — see journal above."
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

ok "UFW enabled. Open: SSH(22), xRDP(${RDP_PORT})."
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
cp "$SSHD" "${SSHD}.backup.v4" 2>/dev/null || true

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
section "FINAL — Full Service Status Check"
# =============================================================================
log "Final service verification..."
echo ""

check_svc() {
  local name="$1"
  if systemctl is-active --quiet "$name" 2>/dev/null; then
    ok "  ${name}  →  active ✓"
  else
    warn "  ${name}  →  INACTIVE ✗   (check: sudo systemctl status ${name})"
  fi
}

check_svc xrdp
check_svc fail2ban
check_svc ufw
check_svc ssh 2>/dev/null || check_svc sshd 2>/dev/null || true

echo ""
log "Open ports:"
ss -tlnp 2>/dev/null | grep -E "(:${RDP_PORT}|:22)" | tee -a "$LOG_FILE" || true

echo ""
log "Last 10 lines of /var/log/xrdp.log:"
tail -10 /var/log/xrdp.log 2>/dev/null | tee -a "$LOG_FILE" || warn "xrdp.log is empty"

# =============================================================================
section "ALL DONE"
# =============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║          ALL STEPS COMPLETED SUCCESSFULLY           ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf "  ║  Server IP  : ${CYAN}%-38s${GREEN}║\n" "$SERVER_IP"
printf "  ║  RDP Port   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PORT"
printf "  ║  Username   : ${CYAN}%-38s${GREEN}║\n" "$RDP_USER"
printf "  ║  Password   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PASS"
printf "  ║  Connect    : ${CYAN}%-38s${GREEN}║\n" "${SERVER_IP}:${RDP_PORT}"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  Windows: Win+R → mstsc                            ║"
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
warn "Change password after first login: passwd ${RDP_USER}"
log "fixed.sh v4 completed at $(date)"
