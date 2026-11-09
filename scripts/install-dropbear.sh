#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1 — Instalador Configurable de Dropbear (Puerto 2222)
# Respeta servicios externos y comprueba conflictos de puerto antes de actuar
# ==============================================================================
set -euo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

NON_INTERACTIVE=0
[[ "${1:-}" == "--non-interactive" ]] && NON_INTERACTIVE=1

PORT_OCCUPIED=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:2222$/ {print $6}' || true)
if [ -n "$PORT_OCCUPIED" ] && ! echo "$PORT_OCCUPIED" | grep -qi "dropbear"; then
    echo "[!] CONFLICTO DE PUERTO: El puerto 2222 está ocupado por un proceso externo (${PORT_OCCUPIED})."
    echo "[!] Se omite la instalación de Dropbear para no afectar servicios existentes."
    exit 1
fi

if [ -f /etc/default/dropbear ] && ! grep -q "BLUE COMPANY" /etc/systemd/system/dropbear.service 2>/dev/null; then
    if [ "$NON_INTERACTIVE" -eq 0 ] && [ -e /dev/tty ]; then
        read -r -p "  [?] Se detectó una configuración previa de Dropbear. ¿Deseas adaptarla para BLUE COMPANY en puerto 2222? (s/N): " resp </dev/tty
        if [[ ! "$resp" =~ ^[sS]$ ]]; then
            echo "  [*] Conservando configuración original de Dropbear sin cambios."
            exit 0
        fi
    fi
fi

if ! command -v dropbear &>/dev/null; then
    apt-get update -y
    apt-get install -y dropbear-bin psmisc
fi

mkdir -p /etc/dropbear
cat << 'DBCONF' > /etc/default/dropbear
NO_START=0
DROPBEAR_PORT=2222
DROPBEAR_EXTRA_ARGS="-W 65536 -K 15 -I 60"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=65536
DBCONF

for sh_path in "/bin/false" "/usr/sbin/nologin"; do
    [ -f "$sh_path" ] && ! grep -qxF "$sh_path" /etc/shells 2>/dev/null && echo "$sh_path" >> /etc/shells
done
sed -i '\|/bin/expired|d' /etc/shells 2>/dev/null || true

[ ! -s /etc/dropbear/dropbear_rsa_host_key ] && dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null
[ ! -s /etc/dropbear/dropbear_ecdsa_host_key ] && dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null
[ ! -s /etc/dropbear/dropbear_ed25519_host_key ] && dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null
[ -f /etc/init.d/dropbear ] && chmod -x /etc/init.d/dropbear 2>/dev/null || true

DROPBEAR_BIN=$(command -v dropbear || echo "/usr/sbin/dropbear")
cat << DBSRV > /etc/systemd/system/dropbear.service
[Unit]
Description=Dropbear SSH Server (Puerto 2222 - BLUE COMPANY v10.1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${DROPBEAR_BIN} -EF -R -p 2222 -W 65536 -K 15 -I 60
KillMode=process
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
DBSRV

systemctl daemon-reload
systemctl enable dropbear >/dev/null
systemctl restart dropbear

if ! systemctl is-active --quiet dropbear; then
    echo "ERROR: Dropbear no pudo iniciar en el puerto 2222."
    exit 1
fi
echo "OK: Dropbear activo en puerto 2222"
