#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

command -v dropbear &>/dev/null || { apt-get update -y &>/dev/null; apt-get install -y dropbear-bin psmisc &>/dev/null; }
mkdir -p /etc/dropbear

cat << 'DBCONF' > /etc/default/dropbear
NO_START=0
DROPBEAR_PORT=2222
DROPBEAR_EXTRA_ARGS="-W 65536 -K 15 -I 60"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
DBCONF

for sh_path in "/bin/false" "/usr/sbin/nologin"; do
    grep -qxF "$sh_path" /etc/shells 2>/dev/null || echo "$sh_path" >> /etc/shells
done
sed -i '\|/bin/expired|d' /etc/shells 2>/dev/null || true

[ ! -s /etc/dropbear/dropbear_rsa_host_key ] && dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key &>/dev/null
[ ! -s /etc/dropbear/dropbear_ecdsa_host_key ] && dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key &>/dev/null
[ ! -s /etc/dropbear/dropbear_ed25519_host_key ] && dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key &>/dev/null
[ -f /etc/init.d/dropbear ] && chmod -x /etc/init.d/dropbear 2>/dev/null || true

DROPBEAR_BIN=$(command -v dropbear || echo "/usr/sbin/dropbear")
cat << DBSRV > /etc/systemd/system/dropbear.service
[Unit]
Description=Dropbear SSH Server (Puerto 2222 - BLUE COMPANY v10.0)
After=network.target

[Service]
Type=simple
ExecStart=${DROPBEAR_BIN} -EF -R -p 2222 -W 65536 -K 15 -I 60
KillMode=process
Restart=always
RestartSec=1
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
DBSRV

systemctl daemon-reload
systemctl enable dropbear &>/dev/null
systemctl restart dropbear &>/dev/null
echo "OK: Dropbear instalado en puerto 2222"
