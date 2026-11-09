#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
    apt-get update -y &>/dev/null
    apt-get install -y cmake make gcc git curl psmisc &>/dev/null
    rm -rf /tmp/badvpn-build
    if git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn-build &>/dev/null; then
        sed -i 's/cmake_minimum_required.*/cmake_minimum_required(VERSION 3.5)/g' /tmp/badvpn-build/CMakeLists.txt 2>/dev/null || true
        mkdir -p /tmp/badvpn-build/build
        cd /tmp/badvpn-build/build
        cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 &>/dev/null
        make -j"$(nproc)" &>/dev/null
        if [ -f /tmp/badvpn-build/build/udpgw/badvpn-udpgw ]; then
            cp -f /tmp/badvpn-build/build/udpgw/badvpn-udpgw /usr/local/bin/badvpn-udpgw
            chmod 755 /usr/local/bin/badvpn-udpgw
        fi
        cd /
        rm -rf /tmp/badvpn-build
    fi
fi

cat << 'BVEOF' > /etc/systemd/system/badvpn.service
[Unit]
Description=BadVPN UDPGW Server Puerto 7300 (BLUE COMPANY v10.0)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 100 --client-socket-sndbuf 1048576
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
BVEOF

systemctl daemon-reload
systemctl enable badvpn &>/dev/null
systemctl restart badvpn &>/dev/null || true
echo "OK: BadVPN UDPGW configurado en puerto 7300"
