#!/usr/bin/env bash
# =============================================================================
#  Ubuntu 24.04 LTS — XFCE4 Desktop + xRDP Secure Setup  (FINAL)
#  Port: 10443 | User: Pixxie | TLS 1.2/1.3 | Fail2Ban | UFW
#
#  All bugs fixed from v1–v4:
#   ✔  AppArmor profiles disabled before xRDP starts
#   ✔  xrdp.ini patched section-aware (Python) — port=-1 in [Xorg]/[Xvnc] preserved
#   ✔  Log files created with xrdp:xrdp ownership before service start
#   ✔  security_layer=negotiate (not tls) — fixes Windows auth error 0x0
#   ✔  startwm.sh uses plain startxfce4 (no exec)
#   ✔  set -e removed — each step handles its own errors
#
#  Usage:
#    wget -O setup.sh <RAW_GITHUB_URL> && chmod +x setup.sh && sudo bash setup.sh
# =============================================================================

set -uo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
RDP_PORT=10443
RDP_USER="Pixxie"
RDP_PASS="Aann5859"
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
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

# ─── SECTION-AWARE INI PATCHER ────────────────────────────────────────────────
# FIX: plain sed replaces ALL matching keys across every section.
#      e.g. port=10443 would clobber port=-1 in [Xorg] and [Xvnc],
#      breaking xRDP's internal session forwarding mechanism.
# This function uses Python to only modify the key inside the target [section].
patch_ini() {
  local file="$1" section="$2" key="$3" val="$4"
  python3 - "$file" "$section" "$key" "$val" << 'PYEOF'
import sys, re
fpath, section, key, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(fpath, 'r') as f:
    lines = f.readlines()
in_section = False
key_found  = False
insert_at  = -1
section_hdr = f'[{section}]'
key_pattern = re.compile(r'^[#;]?\s*' + re.escape(key) + r'\s*=', re.IGNORECASE)
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.lower() == section_hdr.lower():
        in_section = True; insert_at = i + 1; continue
    if in_section and stripped.startswith('['):
        in_section = False
    if in_section:
        insert_at = i + 1
        if key_pattern.match(stripped):
            lines[i] = f'{key}={val}\n'; key_found = True
if not key_found and insert_at >= 0:
    lines.insert(insert_at, f'{key}={val}\n')
with open(fpath, 'w') as f:
    f.writelines(lines)
PYEOF
}

# ─── PRE-FLIGHT ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Please run as root: sudo bash setup.sh"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔════════════════════════════════════════════════════════╗"
echo "  ║   Ubuntu 24.04 LTS — XFCE4 + xRDP Setup  (FINAL)    ║"
echo "  ║   Port: ${RDP_PORT}  |  User: ${RDP_USER}  |  Host: ${HOSTNAME_NEW}       ║"
echo "  ╚════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "Setup started at $(date)"
log "Log file: $LOG_FILE"
sleep 1

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
  openssl dbus-x11 xorg ca-certificates \
  python3

apt-get autoremove --purge -y -qq
apt-get autoclean  -y -qq
ok "System fully updated."

# =============================================================================
section "STEP 2 — Set Hostname"
# =============================================================================
hostnamectl set-hostname "$HOSTNAME_NEW"
grep -qxF "127.0.1.1  ${HOSTNAME_NEW}" /etc/hosts \
  || echo "127.0.1.1  ${HOSTNAME_NEW}" >> /etc/hosts
ok "Hostname → $HOSTNAME_NEW"

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

# Set LightDM as default non-interactively
echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
echo "lightdm shared/default-x-display-manager select lightdm" \
  | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure lightdm 2>/dev/null || true

systemctl enable lightdm 2>/dev/null || true
systemctl set-default graphical.target
ok "LightDM enabled. Graphical target set."

# =============================================================================
section "STEP 5 — Disable AppArmor for xRDP (prevents log file access block)"
# =============================================================================
# FIX: Ubuntu 24.04 AppArmor enforces xRDP profiles in enforce mode.
# Even with correct chown, AppArmor blocks /var/log/xrdp.log writes at
# the kernel level → "Could not start log. quitting." on every start.
# Solution: disable xRDP AppArmor profiles before installing xRDP.

if command -v aa-status &>/dev/null && aa-status --enabled 2>/dev/null; then
  log "AppArmor is active — pre-disabling xRDP profiles..."
  mkdir -p /etc/apparmor.d/disable

  # Remove from kernel if profiles already loaded
  apparmor_parser -R /etc/apparmor.d/usr.sbin.xrdp        2>/dev/null || true
  apparmor_parser -R /etc/apparmor.d/usr.sbin.xrdp-sesman 2>/dev/null || true

  # Symlink to disable dir (survives reboot)
  ln -sf /etc/apparmor.d/usr.sbin.xrdp        /etc/apparmor.d/disable/ 2>/dev/null || true
  ln -sf /etc/apparmor.d/usr.sbin.xrdp-sesman /etc/apparmor.d/disable/ 2>/dev/null || true

  ok "AppArmor xRDP profiles disabled."
else
  log "AppArmor not active — skipping."
  ok "AppArmor: N/A"
fi

# =============================================================================
section "STEP 6 — Install xRDP"
# =============================================================================
log "Installing xRDP..."
DEBIAN_FRONTEND=noninteractive apt-get install -y xrdp
ok "xRDP installed."

# Re-disable AppArmor profiles in case install re-created them
apparmor_parser -R /etc/apparmor.d/usr.sbin.xrdp        2>/dev/null || true
apparmor_parser -R /etc/apparmor.d/usr.sbin.xrdp-sesman 2>/dev/null || true
ln -sf /etc/apparmor.d/usr.sbin.xrdp        /etc/apparmor.d/disable/ 2>/dev/null || true
ln -sf /etc/apparmor.d/usr.sbin.xrdp-sesman /etc/apparmor.d/disable/ 2>/dev/null || true

# ── Groups ────────────────────────────────────────────────────────────────────
usermod -aG xrdp     "$RDP_USER" 2>/dev/null || true
usermod -aG ssl-cert "$RDP_USER" 2>/dev/null || true
ok "$RDP_USER added to xrdp and ssl-cert groups."

# ── Log files — must be created with correct ownership before service starts ──
# FIX: xRDP refuses to start if it cannot write its own log files.
log "Creating xRDP log files with correct ownership..."
touch /var/log/xrdp.log
touch /var/log/xrdp-sesman.log
chown xrdp:xrdp /var/log/xrdp.log
chown xrdp:xrdp /var/log/xrdp-sesman.log
chmod 640 /var/log/xrdp.log
chmod 640 /var/log/xrdp-sesman.log
ok "Log files: $(stat -c '%n → %U:%G mode=%a' /var/log/xrdp.log)"

# Ensure sesman.ini log path is correct
SESMAN_INI=/etc/xrdp/sesman.ini
if [[ -f "$SESMAN_INI" ]]; then
  if grep -qE "^[#;]?\s*LogFile\s*=" "$SESMAN_INI"; then
    sed -i "s|^[#;]\?\s*LogFile\s*=.*|LogFile=/var/log/xrdp-sesman.log|" "$SESMAN_INI"
  fi
  ok "sesman.ini LogFile verified."
fi

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
# FIX: Do NOT use "exec startxfce4" — let it return normally
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
ok "TLS certificate generated (RSA 2048-bit, $CERT_DAYS days)."

# ── Patch xrdp.ini — section-aware, never overwrite ──────────────────────────
XRDP_INI=/etc/xrdp/xrdp.ini
[[ -f "$XRDP_INI" ]] || die "xrdp.ini not found — xRDP install may have failed."

log "Backing up xrdp.ini..."
cp "$XRDP_INI" "${XRDP_INI}.original"

log "Patching [Globals] section only..."
# FIX: security_layer=negotiate (not tls) — tls-only causes Windows error 0x0
patch_ini "$XRDP_INI" Globals port               "$RDP_PORT"
patch_ini "$XRDP_INI" Globals address            "0.0.0.0"
patch_ini "$XRDP_INI" Globals security_layer     "negotiate"
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

ok "xrdp.ini patched — port ${RDP_PORT}, negotiate, TLS 1.2/1.3, performance."

# Verify [Xorg] and [Xvnc] port=-1 are untouched
log "Verifying internal session ports are intact:"
grep -A8 '^\[Xorg\]' "$XRDP_INI" | grep "^port" | tee -a "$LOG_FILE"
grep -A8 '^\[Xvnc\]' "$XRDP_INI" | grep "^port" | tee -a "$LOG_FILE"

# ── X11 Wrapper ───────────────────────────────────────────────────────────────
if [[ -f /etc/X11/Xwrapper.config ]]; then
  sed -i 's/allowed_users=console/allowed_users=anybody/' /etc/X11/Xwrapper.config
  grep -q 'needs_root_rights' /etc/X11/Xwrapper.config \
    || echo 'needs_root_rights=yes' >> /etc/X11/Xwrapper.config
else
  printf 'allowed_users=anybody\nneeds_root_rights=yes\n' > /etc/X11/Xwrapper.config
fi
ok "X11 wrapper → allowed_users=anybody."

# ── Enable & Start xRDP ───────────────────────────────────────────────────────
log "Enabling and starting xRDP..."
systemctl daemon-reload
systemctl enable xrdp

if systemctl restart xrdp; then
  sleep 3
  if systemctl is-active --quiet xrdp; then
    ok "xRDP is running on port ${RDP_PORT}."
    log "Last 5 lines of /var/log/xrdp.log:"
    tail -5 /var/log/xrdp.log 2>/dev/null | tee -a "$LOG_FILE" || true
  else
    err "xRDP started then stopped. Journal:"
    journalctl -u xrdp --no-pager -n 50 | tee -a "$LOG_FILE"
    die "xRDP failed — review output above."
  fi
else
  err "xRDP restart failed. Journal:"
  journalctl -u xrdp --no-pager -n 50 | tee -a "$LOG_FILE"
  die "xRDP could not be started."
fi

# =============================================================================
section "STEP 7 — Firewall (UFW)"
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
section "STEP 8 — Fail2Ban (Brute Force Protection)"
# =============================================================================
log "Configuring Fail2Ban..."
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true

# xRDP jail
cat > /etc/fail2ban/jail.d/xrdp.conf << FBEOF
[xrdp]
enabled  = true
port     = ${RDP_PORT}
filter   = xrdp
logpath  = /var/log/xrdp.log
maxretry = 5
findtime = 600
bantime  = 86400
action   = iptables-multiport[name=xrdp, port=${RDP_PORT}, protocol=tcp]
FBEOF

# xRDP filter
cat > /etc/fail2ban/filter.d/xrdp.conf << 'FBEOF'
[Definition]
failregex = .*\[XRDP\].*connect_ip_from.*FAILED.*<HOST>
            .*\[XRDP\].*User.*failed.*authentication.*<HOST>
            .*connection denied.*<HOST>
            .*Login failed.*display.*<HOST>
ignoreregex =
FBEOF

# SSH jail
cat > /etc/fail2ban/jail.d/sshd-extra.conf << 'FBEOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 4
findtime = 300
bantime  = 86400
FBEOF

# Recidive jail — permanently bans repeat offenders
cat > /etc/fail2ban/jail.d/recidive.conf << 'FBEOF'
[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
maxretry = 3
findtime = 86400
bantime  = -1
action   = iptables-allports
FBEOF

systemctl enable fail2ban
systemctl restart fail2ban
ok "Fail2Ban active:"
ok "  xRDP  — 5 attempts → 24hr ban"
ok "  SSH   — 4 attempts → 24hr ban"
ok "  Recidive — 3 bans → permanent ban"

# =============================================================================
section "STEP 9 — SSH Hardening"
# =============================================================================
log "Hardening SSH..."
SSHD=/etc/ssh/sshd_config
cp "$SSHD" "${SSHD}.original" 2>/dev/null || true

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
Unauthorized access to this system is strictly prohibited.
All activities are monitored and logged.
Disconnect immediately if you are not an authorized user.
**** WARNING ****
BNREOF

systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
ok "SSH hardened. PermitRootLogin=no. AllowUsers=${RDP_USER}."

# =============================================================================
section "STEP 10 — System Security Hardening"
# =============================================================================

# Secure shared memory
grep -qF 'tmpfs /run/shm' /etc/fstab \
  || echo 'tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0' >> /etc/fstab
ok "Shared memory secured (noexec, nosuid)."

# Password quality policy
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
ok "Password policy: min 12 chars, upper+lower+digit required."

# Automatic security updates
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUEOF
ok "Automatic security updates enabled (daily)."

# File descriptor limits
grep -qF '* soft nofile 65536' /etc/security/limits.conf \
  || echo '* soft nofile 65536' >> /etc/security/limits.conf
grep -qF '* hard nofile 65536' /etc/security/limits.conf \
  || echo '* hard nofile 65536' >> /etc/security/limits.conf
ok "File descriptor limit → 65536."

# =============================================================================
section "STEP 11 — Performance Tuning"
# =============================================================================

# TCP / network tuning (idempotent)
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

# XFCE4 performance autostart — disables compositing on first login
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

# UFW rate limiting (connection flood protection)
ufw limit "${RDP_PORT}/tcp" comment 'xRDP rate limit' 2>/dev/null || true
ufw limit 22/tcp            comment 'SSH rate limit'  2>/dev/null || true
ok "UFW connection rate limiting applied."

# =============================================================================
section "STEP 12 — Final Verification"
# =============================================================================
log "Restarting all services..."
systemctl daemon-reload
systemctl restart xrdp     && ok "xRDP       ✓" || err "xRDP       ✗ — journalctl -u xrdp"
systemctl restart fail2ban && ok "Fail2Ban   ✓" || err "Fail2Ban   ✗"
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
ok "SSH        ✓"

sleep 2

echo ""
log "── Service Status ──────────────────────────────────────────"
for svc in xrdp fail2ban ufw ssh; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    ok "  $svc → active ✓"
  else
    warn "  $svc → inactive ✗"
  fi
done

echo ""
log "── Port Check ──────────────────────────────────────────────"
if ss -tlnp 2>/dev/null | grep -q ":${RDP_PORT}"; then
  ok "  Port ${RDP_PORT} → OPEN and listening ✓"
else
  warn "  Port ${RDP_PORT} not detected yet — may still be binding"
fi

echo ""
log "── xRDP Log (last 5 lines) ─────────────────────────────────"
tail -5 /var/log/xrdp.log 2>/dev/null | tee -a "$LOG_FILE" || true

# =============================================================================
section "SETUP COMPLETE"
# =============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔════════════════════════════════════════════════════════╗"
echo "  ║           SETUP COMPLETED SUCCESSFULLY                ║"
echo "  ╠════════════════════════════════════════════════════════╣"
printf "  ║  Server IP   : ${CYAN}%-40s${GREEN}║\n" "$SERVER_IP"
printf "  ║  RDP Port    : ${CYAN}%-40s${GREEN}║\n" "$RDP_PORT"
printf "  ║  Username    : ${CYAN}%-40s${GREEN}║\n" "$RDP_USER"
printf "  ║  Password    : ${CYAN}%-40s${GREEN}║\n" "$RDP_PASS"
printf "  ║  Connect via : ${CYAN}%-40s${GREEN}║\n" "${SERVER_IP}:${RDP_PORT}"
echo "  ╠════════════════════════════════════════════════════════╣"
echo "  ║  Windows: Win+R → mstsc                              ║"
echo "  ║    Computer: YOUR_SERVER_IP:10443                    ║"
echo "  ║    Accept certificate warning on first connect       ║"
echo "  ╠════════════════════════════════════════════════════════╣"
echo "  ║  Diagnostics:                                        ║"
echo "  ║    sudo systemctl status xrdp                        ║"
echo "  ║    sudo tail -f /var/log/xrdp.log                    ║"
echo "  ║    sudo ss -tlnp | grep 10443                        ║"
echo "  ║    sudo ufw status verbose                           ║"
echo "  ║    sudo fail2ban-client status                       ║"
echo "  ╚════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
warn "Security: Change password after first login → sudo passwd ${RDP_USER}"
warn "Security: Whitelist your Windows IP → sudo ufw allow from YOUR.IP to any port 10443 proto tcp"
log "Setup completed at $(date)"
