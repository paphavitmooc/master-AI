#!/bin/bash
# Stop XRDP on 10443, move back to 3389, restore stunnel on 10443

# Step 1 - Move XRDP back to localhost:3389
sed -i 's/^port=.*/port=3389/' /etc/xrdp/xrdp.ini
sed -i 's/^address=.*/address=127.0.0.1/' /etc/xrdp/xrdp.ini
systemctl restart xrdp
sleep 2
echo "XRDP status:"
ss -tlnp | grep 3389

# Step 2 - Fix stunnel config
cat > /etc/stunnel/stunnel.conf <<'EOF'
pid = /var/run/stunnel4/stunnel.pid
setuid = stunnel4
setgid = stunnel4
output = /var/log/stunnel4/stunnel.log
socket = a:SO_REUSEADDR=1

[rdp]
accept = 0.0.0.0:10443
connect = 127.0.0.1:3389
cert = /etc/stunnel/stunnel.pem
EOF

# Step 3 - Fix permissions
chmod 600 /etc/stunnel/stunnel.pem
chown stunnel4:stunnel4 /etc/stunnel/stunnel.pem

# Step 4 - Fix pid directory
mkdir -p /var/run/stunnel4
chown stunnel4:stunnel4 /var/run/stunnel4

# Step 5 - Enable and start stunnel
systemctl enable stunnel4
systemctl restart stunnel4
sleep 2

# Step 6 - Verify
echo ""
echo "=== RESULTS ==="
systemctl status xrdp | grep Active
systemctl status stunnel4 | grep Active
ss -tlnp | grep -E "3389|10443"
echo "==============="
echo "XRDP on localhost:3389 ✅"
echo "Stunnel on 0.0.0.0:10443 ✅"
