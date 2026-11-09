#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.0 — Instalador Automático para Ubuntu Server
# ==============================================================================
set -euo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

if [ "$EUID" -ne 0 ]; then
    echo "[!] Ejecuta este instalador como root (sudo bash install.sh)"
    exit 1
fi

# 1. Detectar versión de Ubuntu
if [ ! -f /etc/os-release ]; then
    echo "[✖] No se detectó /etc/os-release."
    exit 1
fi
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "[✖] Este instalador requiere Ubuntu Server (Detectado: ${ID:-desconocido})."
    exit 1
fi
echo "[1/10] Sistema detectado: Ubuntu ${VERSION_ID} (${PRETTY_NAME})"

# 2. Comprobar requisitos y limpiar auto-arranque antiguo en .bashrc sin tocar SSH
echo "[2/10] Comprobando requisitos y limpiando ganchos interactivos antiguos..."
if [ -f /root/.bashrc ]; then
    sed -i '/BLUECOMPANY_RUNNING/,+4d' /root/.bashrc 2>/dev/null || true
fi

# 3. Instalar dependencias base
echo "[3/10] Instalando paquetes y dependencias del sistema..."
apt-get update -y &>/dev/null
apt-get install -y python3 python3-venv python3-pip sqlite3 openssl curl iptables psmisc dropbear-bin &>/dev/null

# 4. Crear usuario de sistema sin privilegios y directorios
echo "[4/10] Creando usuario 'bluepanel' y estructura de directorios..."
groupadd -f bluecompany
id -u bluepanel &>/dev/null || useradd -r -g bluecompany -d /opt/blue-company -s /usr/sbin/nologin bluepanel

mkdir -p /opt/blue-company/{backend/app,frontend/dist,scripts,services}
mkdir -p /etc/bluecompany/ssl /var/log/bluecompany

# 5. Instalar archivos del proyecto
echo "[5/10] Copiando backend, frontend y módulos..."
SCRIPT_SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cp -rf "${SCRIPT_SRC_DIR}/VERSION" /opt/blue-company/VERSION
cp -rf "${SCRIPT_SRC_DIR}/update.sh" /opt/blue-company/update.sh
cp -rf "${SCRIPT_SRC_DIR}/backend/"* /opt/blue-company/backend/
cp -rf "${SCRIPT_SRC_DIR}/frontend/dist/"* /opt/blue-company/frontend/dist/
cp -rf "${SCRIPT_SRC_DIR}/scripts/"* /opt/blue-company/scripts/
cp -rf "${SCRIPT_SRC_DIR}/services/blue-company.service" /etc/systemd/system/blue-company.service
chmod +x /opt/blue-company/scripts/*.sh /opt/blue-company/update.sh

# Entorno virtual Python
python3 -m venv /opt/blue-company/venv
/opt/blue-company/venv/bin/pip install --upgrade pip &>/dev/null
/opt/blue-company/venv/bin/pip install -r /opt/blue-company/backend/requirements.txt &>/dev/null

# 6. Configurar certificado HTTPS y permisos mínimos (sudoers)
echo "[6/10] Configurando TLS (HTTPS) y wrapper de privilegios..."
if [ ! -f /etc/bluecompany/ssl/cert.pem ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/bluecompany/ssl/key.pem \
        -out /etc/bluecompany/ssl/cert.pem \
        -subj "/CN=bluecompany.local/O=BLUE COMPANY v10" &>/dev/null
fi

cp -f /opt/blue-company/scripts/blue-priv-helper.sh /usr/local/sbin/blue-priv-helper
chown root:bluecompany /usr/local/sbin/blue-priv-helper
chmod 750 /usr/local/sbin/blue-priv-helper

cat << 'SUDOEOF' > /etc/sudoers.d/bluecompany
Defaults:bluepanel !requiretty
bluepanel ALL=(root) NOPASSWD: /usr/local/sbin/blue-priv-helper
SUDOEOF
chmod 440 /etc/sudoers.d/bluecompany

# 7. Inicializar base de datos SQLite y migrar usuarios previos si existen
echo "[7/10] Inicializando base de datos SQLite y credenciales de acceso..."
ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
/opt/blue-company/venv/bin/python3 - "$ADMIN_PASS" << 'PYINIT'
import sys, time, sqlite3
sys.path.insert(0, "/opt/blue-company/backend")
from app.main import init_db, hash_password, DB_PATH

init_db()
admin_pass = sys.argv[1]
conn = sqlite3.connect(DB_PATH)
cur = conn.cursor()
cur.execute("SELECT COUNT(*) FROM admins")
if cur.fetchone()[0] == 0:
    cur.execute("INSERT INTO admins (username, password_hash, created_at) VALUES (?, ?, ?)",
                ("admin", hash_password(admin_pass), int(time.time())))
    conn.commit()
conn.close()
PYINIT

chown -R bluepanel:bluecompany /opt/blue-company /etc/bluecompany /var/log/bluecompany
chmod 750 /etc/bluecompany /etc/bluecompany/ssl
chmod 640 /etc/bluecompany/ssl/key.pem /etc/bluecompany/bluecompany.db 2>/dev/null || true

# 8. Desplegar servicios base de red (Dropbear, Despachador WS, Auto-Limitador, BadVPN)
echo "[8/10] Configurando módulos Dropbear, Despachador WS y Auto-Limitador..."
bash /opt/blue-company/scripts/install-dropbear.sh
bash /opt/blue-company/scripts/install-despachador.sh
bash /opt/blue-company/scripts/install-limiter.sh
bash /opt/blue-company/scripts/install-badvpn.sh || true

# 9. Iniciar el servicio systemd del panel web
echo "[9/10] Iniciando servicio systemd blue-company.service..."
systemctl daemon-reload
systemctl enable blue-company &>/dev/null
systemctl restart blue-company

# 10. Mostrar dirección y credenciales de acceso
PUBLIC_IP=$(curl -s --max-time 3 https://api.ipify.org || hostname -I | awk '{print $1}')
echo "=================================================================="
echo "   ✅ BLUE COMPANY WEB v10.0 INSTALADO CORRECTAMENTE"
echo "=================================================================="
echo "   🌐 URL del Panel : https://${PUBLIC_IP}:8443"
echo "   👤 Usuario Admin : admin"
echo "   🔑 Contraseña    : ${ADMIN_PASS} (Si es primera instalación)"
echo "   🔒 Servidor SSH  : Activo e intacto (Puerto 22)"
echo "=================================================================="
