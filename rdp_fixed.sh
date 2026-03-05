#!/usr/bin/env bash
# =============================================================================
#  rdp-fix.sh — Fix Windows RDP "authentication is not enabled" error
#
#  Cause:  xrdp.ini had security_layer=tls which forces TLS-only mode.
#          Windows RDP client expects NLA negotiation, causing auth mismatch.
#  Fix:    Set security_layer=negotiate so Windows and xRDP auto-agree.
#
#  Usage:  wget -O rdp-fix.sh <RAW_URL> && chmod +x rdp-fix.sh && sudo bash rdp-fix.sh
# =============================================================================

set -uo pipefail

RDP_PORT=10443
RDP_USER="Pixxie"
LOG_FILE="/var/log/xrdp_setup.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
ok()   { echo -e "${GREEN}[ OK ]${RESET}  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[FAIL]${RESET}  $*" | tee -a "$LOG_FILE"; }
section() {
  echo "" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
  echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root: sudo bash rdp-fix.sh${RESET}"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   rdp-fix.sh — Fix Windows Auth Error 0x0          ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "rdp-fix.sh started at $(date)"

XRDP_INI=/etc/xrdp/xrdp.ini
[[ -f "$XRDP_INI" ]] || { err "xrdp.ini not found!"; exit 1; }

# =============================================================================
section "FIX 1 — security_layer: tls → negotiate"
# =============================================================================
log "Current security settings in xrdp.ini:"
grep -E "security_layer|crypt_level|ssl_protocols|tls_ciphers|certificate|key_file" \
  "$XRDP_INI" | tee -a "$LOG_FILE"

log "Backing up xrdp.ini..."
cp "$XRDP_INI" "${XRDP_INI}.backup.rdpfix"

log "Applying fix..."

# Use section-aware Python patcher (same as fixed.sh v4)
patch_ini() {
  local file="$1" section="$2" key="$3" val="$4"
  python3 - "$file" "$section" "$key" "$val" << 'PYEOF'
import sys, re
fpath, section, key, val = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(fpath, 'r') as f:
    lines = f.readlines()
in_section = False; key_found = False; insert_at = -1
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

# KEY FIX: negotiate lets Windows and xRDP agree on best available method
# tls = forces TLS only (Windows NLA fails), negotiate = auto-agree (works)
patch_ini "$XRDP_INI" Globals security_layer   "negotiate"
patch_ini "$XRDP_INI" Globals crypt_level      "high"

# Keep TLS 1.2/1.3 — just allow negotiation of the auth method
patch_ini "$XRDP_INI" Globals ssl_protocols    "TLSv1.2, TLSv1.3"
patch_ini "$XRDP_INI" Globals tls_ciphers      "HIGH:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5"
patch_ini "$XRDP_INI" Globals certificate      "/etc/xrdp/cert.pem"
patch_ini "$XRDP_INI" Globals key_file         "/etc/xrdp/key.pem"

ok "security_layer set to: negotiate"

log "Updated security settings:"
grep -E "security_layer|crypt_level|ssl_protocols|tls_ciphers|certificate|key_file" \
  "$XRDP_INI" | tee -a "$LOG_FILE"

# =============================================================================
section "FIX 2 — Verify xRDP Cert & Key Permissions"
# =============================================================================
log "Checking certificate and key..."

if [[ ! -f /etc/xrdp/cert.pem ]] || [[ ! -f /etc/xrdp/key.pem ]]; then
  warn "Certificate missing — regenerating..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/xrdp/key.pem \
    -out    /etc/xrdp/cert.pem \
    -days   3650 \
    -subj   "/CN=pixxiestudio/O=Pixxie/C=TH" 2>/dev/null
fi

chown xrdp:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem
chmod 600 /etc/xrdp/key.pem
chmod 644 /etc/xrdp/cert.pem
ok "Certificate: $(stat -c '%n  owner=%U:%G  mode=%a' /etc/xrdp/cert.pem)"
ok "Key:         $(stat -c '%n  owner=%U:%G  mode=%a' /etc/xrdp/key.pem)"

# =============================================================================
section "FIX 3 — Restart xRDP"
# =============================================================================
log "Restarting xRDP with new settings..."
systemctl daemon-reload
systemctl restart xrdp

sleep 3
if systemctl is-active --quiet xrdp; then
  ok "xRDP restarted successfully."
  log "Port ${RDP_PORT} listening:"
  ss -tlnp 2>/dev/null | grep ":${RDP_PORT}" | tee -a "$LOG_FILE" \
    && ok "Port ${RDP_PORT} is OPEN ✓" \
    || warn "Port ${RDP_PORT} not visible yet."
  log ""
  log "Last 5 lines of /var/log/xrdp.log:"
  tail -5 /var/log/xrdp.log 2>/dev/null | tee -a "$LOG_FILE" || true
else
  err "xRDP failed to restart!"
  journalctl -u xrdp --no-pager -n 40 | tee -a "$LOG_FILE"
  exit 1
fi

# =============================================================================
section "WINDOWS — Save this as Ubuntu-RDP.rdp on your desktop"
# =============================================================================
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${YELLOW}  ┌─ Copy this content to a file called Ubuntu-RDP.rdp on Windows ─┐${RESET}"
echo ""
cat << RDPEOF
full address:s:${SERVER_IP}:${RDP_PORT}
username:s:${RDP_USER}
screen mode id:i:2
desktopwidth:i:1920
desktopheight:i:1080
session bpp:i:32
compression:i:1
keyboardhook:i:2
audiocapturemode:i:0
videoplaybackmode:i:1
connection type:i:7
networkautodetect:i:1
bandwidthautodetect:i:1
displayconnectionbar:i:1
enableworkspacereconnect:i:0
disable wallpaper:i:0
allow font smoothing:i:1
allow desktop composition:i:0
disable full window drag:i:1
disable menu anims:i:1
disable themes:i:0
bitmapcachepersistenable:i:1
audiomode:i:0
redirectclipboard:i:1
autoreconnection enabled:i:1
authentication level:i:2
prompt for credentials:i:0
negotiate security layer:i:1
enablecredsspsupport:i:0
RDPEOF
echo ""
echo -e "${BOLD}${YELLOW}  └──────────────────────────────────────────────────────────────────┘${RESET}"
echo ""
warn "Key setting: enablecredsspsupport:i:0  — disables NLA on the Windows client"
warn "This matches security_layer=negotiate on the xRDP side."

# =============================================================================
section "DONE"
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║              RDP AUTH FIX APPLIED                   ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf "  ║  Server IP  : ${CYAN}%-38s${GREEN}║\n" "$SERVER_IP"
printf "  ║  RDP Port   : ${CYAN}%-38s${GREEN}║\n" "$RDP_PORT"
printf "  ║  Username   : ${CYAN}%-38s${GREEN}║\n" "$RDP_USER"
printf "  ║  Security   : ${CYAN}%-38s${GREEN}║\n" "negotiate (TLS 1.2/1.3)"
echo "  ╠══════════════════════════════════════════════════════╣"
echo "  ║  On Windows:                                       ║"
echo "  ║  1. Save the .rdp content above to Ubuntu-RDP.rdp ║"
echo "  ║  2. Double-click to connect                        ║"
echo "  ║  3. Accept the certificate warning (self-signed)   ║"
echo "  ║  4. Login: Pixxie / Aannggeell5859                 ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
log "rdp-fix.sh completed at $(date)"
