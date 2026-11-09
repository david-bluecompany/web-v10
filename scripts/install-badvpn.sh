#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1 — Instalador Configurable BadVPN UDPGW (Puerto 7300)
# Compatible con AMD64 y ARM64 (Compilación nativa limpia)
# ==============================================================================
set -euo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

PROC_7300=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:7300$/ {print $6}' || true)
if [ -n "$PROC_7300" ] && ! echo "$PROC_7300" | grep -q "badvpn-udpgw"; then
    echo "[!] CONFLICTO DE PUERTO 7300: Ocupado por un proceso externo (${PROC_7300})."
    echo "[!] Se omite la instalación de BadVPN UDPGW."
    exit 1
fi

if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
    echo "[*] Compilando BadVPN UDPGW para arquitectura $(uname -m)..."
    apt-get update -y
    apt-get install -y cmake make gcc git curl psmisc
    rm -rf /tmp/badvpn-build
    git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn-build
    sed -i 's/cmake_minimum_required.*/cmake_minimum_required(VERSION 3.5)/g' /tmp/badvpn-build/CMakeLists.txt 2>/dev/null || true
    mkdir -p /tmp/badvpn-build/build
    pushd /tmp/badvpn-build/build >/dev/null
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    make -j"$(nproc)"
    install -m 0755 /tmp/badvpn-build/build/udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
    popd >/dev/null
    rm -rf /tmp/badvpn-build
fi

cat << 'BVEOF' > /etc/systemd/system/badvpn.service
[Unit]
Description=BadVPN UDPGW Server Puerto 7300 (BLUE COMPANY v10.1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 100 --client-socket-sndbuf 1048576
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
BVEOF

systemctl daemon-reload
systemctl enable badvpn >/dev/null
systemctl restart badvpn

if ! systemctl is-active --quiet badvpn; then
    echo "ERROR: BadVPN UDPGW no pudo iniciar en el puerto 7300."
    exit 1
fi
echo "OK: BadVPN UDPGW activo en puerto 7300"
