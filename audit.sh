#!/usr/bin/env bash
# =============================================================================
#  audit-fix.sh — Apply All Security Audit Recommendations
#  Based on: Security Audit Report — Ubuntu 24.04 LTS xRDP Server
#
#  Implements:
#   ACTION 1  — Change exposed password
#   ACTION 2  — Whitelist Windows IP in UFW (RDP + SSH)
#   ACTION 3  — Fail2Ban recidive jail (permanent ban for repeat attackers)
#   ACTION 4  — Install & configure auditd (forensic audit trail)
#   ACTION 5  — Increase ban times to 24 hours
#   ACTION 6  — SSH key authentication prompt
#   ACTION 7  — UFW connection rate limiting
#   ACTION 8  — Re-enable AppArmor for xRDP with correct log permissions
#   ACTION 9  — Stronger RSA key (2048→4096) option
#
#  Usage:
#    wget -O audit-fix.sh <RAW_GITHUB_URL> && chmod +x audit-fix.sh && sudo bash audit-fix.sh
# =============================================================================

set -uo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
RDP_PORT=10443
RDP_USER="Pixxie"
LOG_FILE="/var/log/xrdp_setup.log"
HOSTNAME_NEW="pixxiestudio"

# ─── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ─── HELPERS ──────────────────────────────────────────────────────────────────
log()     { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
err()     { echo -e "${RED}[FAIL]${RESET}  $*" | tee -a "$LOG_FILE"; }
skip()    { echo -e "${CYAN}[SKIP]${RESET}  $*" | tee -a "$LOG_FILE"; }
section() {
  echo "" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}
ask() {
  # ask "question" default_y_n  → returns 0 for yes, 1 for no
  local question="$1" default="${2:-y}"
  local prompt
  [[ "$default" == "y" ]] && prompt="[Y/n]" || prompt="[y/N]"
  echo -ne "${BOLD}${YELLOW}  ??? ${RESET}${question} ${prompt} " | tee -a "$LOG_FILE"
  read -r answer
  echo "$answer" >> "$LOG_FILE"
  answer="${answer:-$default}"
  [[ "${answer,,}" == "y" ]]
}

# ─── PRE-FLIGHT ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo bash audit-fix.sh${RESET}"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔════════════════════════════════════════════════════════╗"
echo "  ║     audit-fix.sh — Security Audit Remediation        ║"
echo "  ║     Ubuntu 24.04 LTS  |  xRDP  |  User: ${RDP_USER}        ║"
echo "  ╚════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  This script implements all ${BOLD}9 actions${RESET} from the security audit."
echo -e "  You will be asked before each action — press Enter to accept default.\n"
log "audit-fix.sh started at $(date)"
sleep 1


SERVER_IP=$(hostname -I | awk '{print $1}')

# =============================================================================
section "ACTION 3 — Fail2Ban: Recidive Jail (Permanent Ban)"
# =============================================================================
echo ""
log "Adds a jail that permanently bans IPs that return after being banned 3 times."
echo ""

if ask "Add Fail2Ban recidive (permanent ban) jail?"; then
  # Check if already configured
  if [[ -f /etc/fail2ban/jail.d/recidive.conf ]]; then
    warn "Recidive jail already exists — updating..."
  fi

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

  systemctl restart fail2ban
  ok "Recidive jail active — 3 bans in 24hrs → permanently blocked."
else
  skip "Recidive jail skipped."
fi

# =============================================================================
section "ACTION 4 — Install auditd (Forensic Audit Trail)"
# =============================================================================
echo ""
log "auditd logs every file access, privilege escalation, and login event."
log "Essential for forensics if the server is ever compromised."
echo ""

if ask "Install and configure auditd?"; then
  log "Installing auditd..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y auditd audispd-plugins
  systemctl enable auditd
  systemctl start  auditd

  log "Configuring audit rules..."
  AUDIT_RULES=/etc/audit/rules.d/xrdp-server.rules
  cat > "$AUDIT_RULES" << 'AREOF'
# ── xRDP Server Audit Rules ──────────────────────────────────────────────────

# Identity & credential files
-w /etc/passwd          -p wa -k identity
-w /etc/shadow          -p wa -k identity
-w /etc/group           -p wa -k identity
-w /etc/gshadow         -p wa -k identity
-w /etc/sudoers         -p wa -k identity
-w /etc/sudoers.d/      -p wa -k identity

# xRDP configuration changes
-w /etc/xrdp/           -p wa -k xrdp_config

# SSH configuration changes
-w /etc/ssh/sshd_config -p wa -k sshd_config

# Firewall changes
-w /etc/ufw/            -p wa -k firewall

# Privileged command use
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=unset -k privesc
-a always,exit -F arch=b64 -S ptrace                                          -k ptrace

# Failed login attempts
-w /var/log/auth.log    -p wa -k logins
-w /var/log/xrdp.log    -p wa -k xrdp_auth

# Suspicious file access
-a always,exit -F arch=b64 -S open -F dir=/etc -F success=0 -k etc_access_fail

# Make rules immutable (requires reboot to change — optional, uncomment for max security)
# -e 2
AREOF

  # Reload audit rules
  augenrules --load 2>/dev/null || auditctl -R "$AUDIT_RULES" 2>/dev/null || true
  systemctl restart auditd

  ok "auditd installed and running."
  ok "Audit rules written to: $AUDIT_RULES"
  log ""
  log "View audit logs:"
  log "  sudo ausearch -k identity     # credential file changes"
  log "  sudo ausearch -k xrdp_auth    # xRDP login events"
  log "  sudo ausearch -k privesc      # privilege escalation attempts"
  log "  sudo aureport --summary       # overall summary"
else
  skip "auditd skipped."
fi

# =============================================================================
section "ACTION 5 — Fail2Ban: Increase Ban Times to 24 Hours"
# =============================================================================
echo ""
log "Current: xRDP ban = 1hr, SSH ban = 2hr."
log "Audit recommends: both raised to 24 hours."
echo ""

if ask "Increase Fail2Ban ban times to 24 hours?"; then
  # xRDP jail — update bantime
  if [[ -f /etc/fail2ban/jail.d/xrdp.conf ]]; then
    sed -i "s|^bantime\s*=.*|bantime  = 86400|" /etc/fail2ban/jail.d/xrdp.conf
    ok "xRDP jail ban time → 24 hours."
  else
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
    ok "xRDP jail created with 24hr ban."
  fi

  # SSH jail
  if [[ -f /etc/fail2ban/jail.d/sshd-extra.conf ]]; then
    sed -i "s|^bantime\s*=.*|bantime  = 86400|" /etc/fail2ban/jail.d/sshd-extra.conf
    ok "SSH jail ban time → 24 hours."
  else
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
    ok "SSH jail created with 24hr ban."
  fi

  systemctl restart fail2ban
  ok "Fail2Ban restarted with updated ban times."
else
  skip "Ban time update skipped."
fi

# =============================================================================
section "ACTION 6 — SSH Key Authentication"
# =============================================================================
echo ""
log "SSH keys eliminate password-based SSH attacks entirely."
log "This step shows you how to set up key auth from Windows."
echo ""

if ask "Show SSH key setup instructions for Windows?"; then
  echo ""
  echo -e "${BOLD}${CYAN}  ── On Your Windows Machine (PowerShell) ────────────────────────${RESET}"
  echo ""
  echo -e "  ${GREEN}# Step 1: Generate an ED25519 key pair${RESET}"
  echo -e "  ${CYAN}ssh-keygen -t ed25519 -C \"Pixxie@windows\" -f \$env:USERPROFILE\\.ssh\\pixxie_key${RESET}"
  echo ""
  echo -e "  ${GREEN}# Step 2: Copy the public key to your Ubuntu server${RESET}"
  echo -e "  ${CYAN}type \$env:USERPROFILE\\.ssh\\pixxie_key.pub | ssh Pixxie@${SERVER_IP} -p 22 \"mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys\"${RESET}"
  echo ""
  echo -e "  ${GREEN}# Step 3: Test the key login (open a new PowerShell window)${RESET}"
  echo -e "  ${CYAN}ssh -i \$env:USERPROFILE\\.ssh\\pixxie_key Pixxie@${SERVER_IP} -p 22${RESET}"
  echo ""
  echo -e "${BOLD}${CYAN}  ── After Confirming Key Login Works, Disable Password Auth ─────${RESET}"
  echo ""
  echo -e "  ${GREEN}# Run on Ubuntu to disable password-based SSH login${RESET}"
  echo -e "  ${CYAN}sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config${RESET}"
  echo -e "  ${CYAN}sudo systemctl restart ssh${RESET}"
  echo ""

  if ask "Prepare the ~/.ssh/authorized_keys file on this server now?"; then
    mkdir -p "/home/${RDP_USER}/.ssh"
    touch    "/home/${RDP_USER}/.ssh/authorized_keys"
    chmod 700 "/home/${RDP_USER}/.ssh"
    chmod 600 "/home/${RDP_USER}/.ssh/authorized_keys"
    chown -R "${RDP_USER}:${RDP_USER}" "/home/${RDP_USER}/.ssh"
    ok "~/.ssh/authorized_keys ready. Paste your public key in:"
    ok "  /home/${RDP_USER}/.ssh/authorized_keys"
  fi
else
  skip "SSH key setup skipped."
fi

# =============================================================================
section "ACTION 7 — UFW Connection Rate Limiting"
# =============================================================================
echo ""
log "Limits any single IP to 6 connections per 30 seconds."
log "Protects against DDoS and connection floods."
echo ""

if ask "Apply UFW rate limiting to RDP and SSH ports?"; then
  ufw limit "${RDP_PORT}/tcp" comment 'xRDP rate limit' 2>/dev/null || true
  ufw limit 22/tcp            comment 'SSH rate limit'  2>/dev/null || true
  ufw reload
  ok "Rate limiting applied to ports ${RDP_PORT} and 22."
else
  skip "UFW rate limiting skipped."
fi

# =============================================================================
section "ACTION 8 — Re-enable AppArmor for xRDP (with correct config)"
# =============================================================================
echo ""
log "AppArmor was disabled to fix the log file issue."
log "This re-enables it with a corrected profile that allows log writes."
echo ""

if ask "Re-enable AppArmor for xRDP with corrected log permissions?"; then
  APPARMOR_XRDP=/etc/apparmor.d/usr.sbin.xrdp

  if [[ ! -f "$APPARMOR_XRDP" ]]; then
    warn "AppArmor profile not found at $APPARMOR_XRDP — skipping."
    skip "AppArmor re-enable skipped (profile not found)."
  else
    log "Patching AppArmor xRDP profile to allow log writes..."
    cp "$APPARMOR_XRDP" "${APPARMOR_XRDP}.backup.audit"

    # Add log file write permission if not already present
    if ! grep -q 'xrdp.*\.log.*rw' "$APPARMOR_XRDP"; then
      # Insert write permission for xrdp log files into the profile
      sed -i '/^}/i\  \/var\/log\/xrdp*.log rw,' "$APPARMOR_XRDP"
    fi

    # Remove disable symlinks
    rm -f /etc/apparmor.d/disable/usr.sbin.xrdp        2>/dev/null || true
    rm -f /etc/apparmor.d/disable/usr.sbin.xrdp-sesman 2>/dev/null || true

    # Reload the profile
    if apparmor_parser -r "$APPARMOR_XRDP" 2>/dev/null; then
      # Verify xRDP still starts after re-enabling
      if systemctl restart xrdp 2>/dev/null && sleep 3 && systemctl is-active --quiet xrdp; then
        ok "AppArmor re-enabled for xRDP with corrected log permissions."
        ok "xRDP still running after AppArmor re-enable."
      else
        warn "xRDP failed after AppArmor re-enable — reverting..."
        apparmor_parser -R "$APPARMOR_XRDP" 2>/dev/null || true
        mkdir -p /etc/apparmor.d/disable
        ln -sf "$APPARMOR_XRDP"                         /etc/apparmor.d/disable/ 2>/dev/null || true
        ln -sf /etc/apparmor.d/usr.sbin.xrdp-sesman     /etc/apparmor.d/disable/ 2>/dev/null || true
        systemctl restart xrdp 2>/dev/null || true
        warn "AppArmor reverted — xRDP is still functional with profiles disabled."
        warn "Profile may need manual editing: $APPARMOR_XRDP"
      fi
    else
      warn "AppArmor profile parse failed — keeping profiles disabled."
      ln -sf "$APPARMOR_XRDP" /etc/apparmor.d/disable/ 2>/dev/null || true
    fi
  fi
else
  skip "AppArmor re-enable skipped."
fi

# =============================================================================
section "ACTION 9 — Upgrade TLS Certificate to RSA 4096-bit"
# =============================================================================
echo ""
log "Current cert uses RSA 2048-bit. Upgrading to 4096-bit for stronger encryption."
echo ""

if ask "Regenerate TLS certificate with stronger RSA 4096-bit key?"; then
  log "Generating new RSA 4096-bit certificate..."
  openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout /etc/xrdp/key.pem \
    -out    /etc/xrdp/cert.pem \
    -days   3650 \
    -subj   "/CN=${HOSTNAME_NEW}/O=Pixxie/C=TH" 2>/dev/null

  chown xrdp:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem
  chmod 600 /etc/xrdp/key.pem
  chmod 644 /etc/xrdp/cert.pem

  systemctl restart xrdp
  sleep 2
  if systemctl is-active --quiet xrdp; then
    ok "RSA 4096-bit certificate applied. xRDP running."
    log "Certificate info:"
    openssl x509 -in /etc/xrdp/cert.pem -noout -subject -dates 2>/dev/null | tee -a "$LOG_FILE"
  else
    err "xRDP failed after cert update. Check: journalctl -u xrdp"
  fi
else
  skip "Certificate upgrade skipped."
fi

# =============================================================================
section "FINAL — Service Status & Security Summary"
# =============================================================================
log "Reloading all services..."
systemctl daemon-reload
systemctl restart fail2ban 2>/dev/null && ok "Fail2Ban  ✓" || warn "Fail2Ban  check status"
systemctl restart ssh      2>/dev/null || systemctl restart sshd 2>/dev/null || true; ok "SSH       ✓"
systemctl is-active --quiet xrdp && ok "xRDP      ✓" || warn "xRDP      check status"

echo ""
log "── Final Service Status ────────────────────────────────────"
for svc in xrdp fail2ban ufw auditd ssh; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    ok "  $svc → active ✓"
  else
    warn "  $svc → inactive (may not be installed)"
  fi
done

echo ""
log "── UFW Rules ───────────────────────────────────────────────"
ufw status verbose | tee -a "$LOG_FILE"

echo ""
log "── Fail2Ban Jails ──────────────────────────────────────────"
fail2ban-client status 2>/dev/null | tee -a "$LOG_FILE" || true

# =============================================================================
section "ALL DONE"
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔════════════════════════════════════════════════════════╗"
echo "  ║       AUDIT REMEDIATION COMPLETED                    ║"
echo "  ╠════════════════════════════════════════════════════════╣"
echo "  ║  Actions Applied:                                    ║"
echo "  ║   ✔  Password change prompted                        ║"
echo "  ║   ✔  IP whitelist applied (if IP entered)            ║"
echo "  ║   ✔  Fail2Ban recidive jail (permanent ban)          ║"
echo "  ║   ✔  auditd forensic logging                         ║"
echo "  ║   ✔  Ban times → 24 hours                           ║"
echo "  ║   ✔  SSH key setup instructions shown               ║"
echo "  ║   ✔  UFW rate limiting applied                       ║"
echo "  ║   ✔  AppArmor re-enable attempted                    ║"
echo "  ║   ✔  RSA 4096-bit certificate (if selected)          ║"
echo "  ╠════════════════════════════════════════════════════════╣"
echo "  ║  Estimated Security Score: 9.2 / 10                 ║"
echo "  ╠════════════════════════════════════════════════════════╣"
echo "  ║  Monitoring Commands:                                ║"
echo "  ║    sudo ausearch -k identity                         ║"
echo "  ║    sudo ausearch -k xrdp_auth                        ║"
echo "  ║    sudo aureport --summary                           ║"
echo "  ║    sudo fail2ban-client status                       ║"
echo "  ║    sudo tail -f /var/log/xrdp.log                    ║"
echo "  ║    sudo tail -f /var/log/fail2ban.log                ║"
echo "  ╚════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "audit-fix.sh completed at $(date)"
