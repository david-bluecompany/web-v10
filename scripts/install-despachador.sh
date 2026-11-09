#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1 — Instalador Configurable Despachador WS (Puerto 80)
# Rutas multiplexadas: /ws -> 20001 | /upgrade -> 20002 | /xhttp -> 20003 | SSH -> 2222
# Verifica que 3X-UI, Xray, Nginx o Apache no estén ocupando el puerto 80
# ==============================================================================
set -euo pipefail
export LC_ALL=C

PROC_80=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print $6}' || true)
if [ -n "$PROC_80" ] && ! echo "$PROC_80" | grep -q "despachador\|python3"; then
    echo "[!] CONFLICTO DE PUERTO 80: Ocupado por un servicio existente (${PROC_80})."
    echo "[!] Se omite la instalación del Despachador WS para no interrumpir 3X-UI / Nginx / Xray."
    exit 1
fi

cat << 'PY_EOF' > /usr/local/bin/despachador.py
#!/usr/bin/env python3
import socket, select, threading, random

LISTEN_HOST, LISTEN_PORT, SSH_PORT = "0.0.0.0", 80, 2222
PORT_WS, PORT_UPGRADE, PORT_XHTTP, BUF_SIZE = 20001, 20002, 20003, 32768

def optimizar_socket(sock, timeout=None):
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        if timeout is not None:
            sock.settimeout(timeout)
    except Exception:
        pass

def conectar_dropbear_aislado():
    ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    optimizar_socket(ssh, timeout=10)
    try:
        ssh.bind((f"127.{random.randint(0, 254)}.{random.randint(0, 254)}.{random.randint(2, 254)}", 0))
    except Exception:
        pass
    ssh.connect(("127.0.0.1", SSH_PORT))
    ssh.settimeout(None)
    return ssh

def cerrar_par(s1, s2):
    for s in (s1, s2):
        if s is None:
            continue
        try:
            s.shutdown(socket.SHUT_RDWR)
        except Exception:
            pass
        try:
            s.close()
        except Exception:
            pass

def pipe_directo(src, dst):
    try:
        while True:
            data = src.recv(BUF_SIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        cerrar_par(src, dst)

def pipe_cliente_a_ssh(client, ssh, ssh_iniciado=False):
    acumulado = b""
    try:
        if not ssh_iniciado:
            client.settimeout(12)
            while True:
                data = client.recv(BUF_SIZE)
                if not data:
                    break
                if ssh_iniciado:
                    ssh.sendall(data)
                else:
                    acumulado += data
                    if b"SSH-2.0-" in acumulado:
                        idx = acumulado.find(b"SSH-2.0-")
                        ssh_iniciado = True
                        client.settimeout(None)
                        ssh.sendall(acumulado[idx:])
                        acumulado = b""
                    elif len(acumulado) > 65536:
                        acumulado = b""
    except Exception:
        pass
    finally:
        cerrar_par(client, ssh)

def extraer_ruta_http(buffer):
    try:
        primera_linea = buffer.split(b"\r\n", 1)[0].decode("latin1", errors="ignore")
        partes = primera_linea.split(" ")
        if len(partes) >= 2:
            return partes[1].lower()
    except Exception:
        pass
    return ""

def procesar_conexion(client, addr):
    ssh = None
    try:
        optimizar_socket(client, timeout=12)
        buffer = client.recv(BUF_SIZE)
        if not buffer:
            client.close()
            return
        if buffer.startswith(b"SSH-"):
            ssh = conectar_dropbear_aislado()
            client.settimeout(None)
            ssh.sendall(buffer)
            threading.Thread(target=pipe_cliente_a_ssh, args=(client, ssh, True), daemon=True).start()
            pipe_directo(ssh, client)
            return
        ruta = extraer_ruta_http(buffer)
        target_port = None
        if ruta.startswith("/ws"):
            target_port = PORT_WS
        elif ruta.startswith("/upgrade"):
            target_port = PORT_UPGRADE
        elif ruta.startswith("/xhttp"):
            target_port = PORT_XHTTP
        if target_port:
            try:
                remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                optimizar_socket(remote, timeout=4)
                remote.connect(("127.0.0.1", target_port))
                remote.settimeout(None)
                client.settimeout(None)
                remote.sendall(buffer)
                threading.Thread(target=pipe_directo, args=(client, remote), daemon=True).start()
                pipe_directo(remote, client)
                return
            except Exception:
                try:
                    remote.close()
                except Exception:
                    pass
        for _ in range(5):
            if b"SSH-2.0-" in buffer:
                break
            espera = 0.08 if buffer.endswith(b"\r\n\r\n") else 0.45
            rlist, _, _ = select.select([client], [], [], espera)
            if not rlist:
                break
            extra = client.recv(BUF_SIZE)
            if not extra:
                break
            buffer += extra
        client.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        ssh = conectar_dropbear_aislado()
        ya_inicio_ssh = False
        if b"SSH-2.0-" in buffer:
            idx = buffer.find(b"SSH-2.0-")
            ya_inicio_ssh = True
            client.settimeout(None)
            ssh.sendall(buffer[idx:])
        threading.Thread(target=pipe_cliente_a_ssh, args=(client, ssh, ya_inicio_ssh), daemon=True).start()
        pipe_directo(ssh, client)
    except Exception:
        cerrar_par(client, ssh)

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    optimizar_socket(server)
    server.bind((LISTEN_HOST, LISTEN_PORT))
    server.listen(4096)
    while True:
        try:
            client, addr = server.accept()
            threading.Thread(target=procesar_conexion, args=(client, addr), daemon=True).start()
        except Exception:
            pass

if __name__ == "__main__":
    main()
PY_EOF

chmod 0755 /usr/local/bin/despachador.py

cat << 'SRV_EOF' > /etc/systemd/system/despachador.service
[Unit]
Description=Despachador Multiplexor Puerto 80 (WS:20001/Upgrade:20002/XHTTP:20003 - BLUE COMPANY v10.1)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="PYTHONUNBUFFERED=1"
ExecStart=/usr/bin/python3 /usr/local/bin/despachador.py
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SRV_EOF

# Añadir redirección NAT 8080/8880 -> 80 solo si 8080 y 8880 están libres y no hay reglas conflictivas
OCC_8080=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:(8080|8880)$/ {print $6}' || true)
if [ -z "$OCC_8080" ] && command -v iptables &>/dev/null; then
    iptables -t nat -C PREROUTING -p tcp -m multiport --dports 8080,8880 -j REDIRECT --to-ports 80 2>/dev/null || \
        iptables -t nat -A PREROUTING -p tcp -m multiport --dports 8080,8880 -j REDIRECT --to-ports 80 2>/dev/null || true
fi

systemctl daemon-reload
systemctl enable despachador >/dev/null
systemctl restart despachador

if ! systemctl is-active --quiet despachador; then
    echo "ERROR: El servicio despachador no pudo iniciar en el puerto 80."
    exit 1
fi
echo "OK: Despachador WS activo en puerto 80 (Rutas: /ws->20001, /upgrade->20002, /xhttp->20003, SSH->2222)"
