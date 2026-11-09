#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1.0 — Instalador Automático, Seguro e Idempotente
# Soporta Ubuntu 22.04 / 24.04 / 26.04 (AMD64 y ARM64) y Python 3.10 - 3.14+
# Respeta instalaciones existentes de 3X-UI, Xray, V2Ray y Nginx
# ==============================================================================
set -euo pipefail
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

C_RESET='\033[0m'
C_BLUE='\033[1;34m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_WHITE='\033[1;37m'

INSTALL_DIR="/opt/blue-company"
CONF_DIR="/etc/bluecompany"
SSL_DIR="/etc/bluecompany/ssl"
LOG_DIR="/var/log/bluecompany"
DB_FILE="/etc/bluecompany/bluecompany.db"
CERT_FILE="${SSL_DIR}/cert.pem"
KEY_FILE="${SSL_DIR}/key.pem"
PANEL_PORT=8443

die() {
    echo -e "\n${C_RED}[✖] ERROR CRÍTICO:${C_RESET} $1" >&2
    exit 1
}

info() {
    echo -e "${C_CYAN}[*]${C_RESET} $1"
}

ok() {
    echo -e "${C_GREEN}[✓]${C_RESET} $1"
}

warn() {
    echo -e "${C_YELLOW}[!]${C_RESET} $1"
}

if [ "$EUID" -ne 0 ]; then
    die "Ejecuta este instalador como root: sudo bash install.sh"
fi

SCRIPT_SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

echo -e "${C_BLUE}══════════════════════════════════════════════════════════════════${C_RESET}"
echo -e "${C_WHITE}          BLUE COMPANY WEB v10.1.0 • INSTALADOR ENTERPRISE        ${C_RESET}"
echo -e "${C_BLUE}══════════════════════════════════════════════════════════════════${C_RESET}"

# ------------------------------------------------------------------------------
# 1. DETECCIÓN DE SISTEMA OPERATIVO, ARQUITECTURA Y PYTHON
# ------------------------------------------------------------------------------
[ -f /etc/os-release ] || die "No se encontró /etc/os-release en este sistema."
. /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    die "Sistema operativo no compatible (${ID:-desconocido}). Se requiere Ubuntu Server."
fi

RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
    x86_64|amd64) ARCH_LABEL="AMD64 (x86_64)" ;;
    aarch64|arm64) ARCH_LABEL="ARM64 (aarch64)" ;;
    *) die "Arquitectura de procesador no soportada: ${RAW_ARCH}. Solo se admite AMD64 y ARM64." ;;
esac

ok "Sistema detectado: Ubuntu ${VERSION_ID:-desconocido} (${PRETTY_NAME}) | Arquitectura: ${ARCH_LABEL}"

# Detectar servicios externos existentes para protegerlos
EXTERNAL_DETECTED=()
for ext_srv in x-ui xray v2ray nginx caddy hysteria-server; do
    if systemctl is-active --quiet "$ext_srv" 2>/dev/null || pgrep -x "${ext_srv%%-*}" &>/dev/null; then
        EXTERNAL_DETECTED+=("$ext_srv")
    fi
done
if [ "${#EXTERNAL_DETECTED[@]}" -gt 0 ]; then
    warn "Servicios externos detectados y protegidos (Modo No-Intrusivo): ${EXTERNAL_DETECTED[*]}"
fi

# Verificar disponibilidad del puerto 8443 antes de continuar
PROC_8443=$(ss -tlnp 2>/dev/null | awk -v p=":${PANEL_PORT}$" '$4 ~ p {print $6}' || true)
if [ -n "$PROC_8443" ] && ! echo "$PROC_8443" | grep -q "uvicorn\|python"; then
    die "El puerto ${PANEL_PORT} está ocupado por otro proceso (${PROC_8443}). Libera el puerto antes de continuar."
fi

# Limpiar gancho antiguo de terminal interactiva (si existiera de v9.x) sin tocar SSH
if [ -f /root/.bashrc ] && grep -q "BLUECOMPANY_RUNNING" /root/.bashrc 2>/dev/null; then
    info "Limpiando auto-arranque antiguo de terminal en /root/.bashrc..."
    sed -i '/BLUECOMPANY_RUNNING/,+4d' /root/.bashrc 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# 2. INSTALACIÓN DE PAQUETES DEL SISTEMA Y DETECCIÓN REAL DE PYTHON
# ------------------------------------------------------------------------------
info "Instalando paquetes base del sistema..."
apt-get update -y
apt-get install -y python3 python3-venv python3-pip python3-dev build-essential sqlite3 openssl curl iptables iproute2 psmisc sudo ca-certificates

command -v python3 &>/dev/null || die "Python 3 no está instalado tras ejecutar apt-get."
PY_REAL_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')
PY_MAJOR_MINOR=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')

python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' || \
    die "Se requiere Python 3.10 o superior (Detectado: Python ${PY_REAL_VER})."

ok "Versión real de Python detectada: Python ${PY_REAL_VER}"

# ------------------------------------------------------------------------------
# 3. USUARIOS, GRUPOS Y PERMISOS GRANULARES (IDEMPOTENTE)
# ------------------------------------------------------------------------------
info "Configurando usuario 'bluepanel', grupo 'bluecompany' y directorios..."
getent group bluecompany >/dev/null || groupadd --system bluecompany
if ! id -u bluepanel &>/dev/null; then
    useradd --system --gid bluecompany --home-dir "$INSTALL_DIR" --no-create-home --shell /usr/sbin/nologin bluepanel
else
    usermod -g bluecompany -d "$INSTALL_DIR" -s /usr/sbin/nologin bluepanel
fi

IS_REINSTALL=0
[ -f "$DB_FILE" ] && IS_REINSTALL=1
if [ "$IS_REINSTALL" -eq 1 ]; then
    info "Instalación previa detectada: se conservará la base de datos SQLite y las credenciales existentes."
fi

mkdir -p "${INSTALL_DIR}/backend/app" "${INSTALL_DIR}/frontend/dist" "${INSTALL_DIR}/scripts" "${INSTALL_DIR}/services"
mkdir -p "$CONF_DIR" "$SSL_DIR" "$LOG_DIR"

# Copiar código solo si el instalador se ejecuta desde un directorio distinto a /opt/blue-company
if [ "$SCRIPT_SRC_DIR" != "$INSTALL_DIR" ]; then
    cp -f "${SCRIPT_SRC_DIR}/VERSION" "${INSTALL_DIR}/VERSION"
    cp -f "${SCRIPT_SRC_DIR}/update.sh" "${INSTALL_DIR}/update.sh"
    cp -f "${SCRIPT_SRC_DIR}/backend/requirements.txt" "${INSTALL_DIR}/backend/requirements.txt"
    cp -f "${SCRIPT_SRC_DIR}/backend/app/main.py" "${INSTALL_DIR}/backend/app/main.py"
    cp -rf "${SCRIPT_SRC_DIR}/frontend/dist/"* "${INSTALL_DIR}/frontend/dist/"
    cp -rf "${SCRIPT_SRC_DIR}/scripts/"* "${INSTALL_DIR}/scripts/"
    cp -f "${SCRIPT_SRC_DIR}/services/blue-company.service" "${INSTALL_DIR}/services/blue-company.service"
fi

# Permisos estrictos sobre /opt/blue-company (Propiedad de root, lectura para grupo bluecompany)
chown -R root:bluecompany "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 0755 {} +
find "$INSTALL_DIR" -type f -exec chmod 0644 {} +
chmod 0750 "${INSTALL_DIR}/scripts/"*.sh "${INSTALL_DIR}/update.sh"

# Wrapper privilegiado y sudoers
install -m 0750 -o root -g bluecompany "${INSTALL_DIR}/scripts/blue-priv-helper.sh" /usr/local/sbin/blue-priv-helper
cat << 'SUDOEOF' > /etc/sudoers.d/bluecompany
Defaults:bluepanel !requiretty
bluepanel ALL=(root) NOPASSWD: /usr/local/sbin/blue-priv-helper
SUDOEOF
chmod 0440 /etc/sudoers.d/bluecompany
visudo -cf /etc/sudoers.d/bluecompany >/dev/null || die "Error de sintaxis en /etc/sudoers.d/bluecompany"

# ------------------------------------------------------------------------------
# 4. ENTORNO VIRTUAL PYTHON Y DEPENDENCIAS (SIN OCULTAR ERRORES)
# ------------------------------------------------------------------------------
info "Configurando entorno virtual Python (${PY_MAJOR_MINOR}) e instalando dependencias con wheels compatibles..."
if [ ! -x "${INSTALL_DIR}/venv/bin/python3" ]; then
    python3 -m venv "${INSTALL_DIR}/venv"
fi

"${INSTALL_DIR}/venv/bin/pip" install --upgrade pip wheel
if ! "${INSTALL_DIR}/venv/bin/pip" install --prefer-binary -r "${INSTALL_DIR}/backend/requirements.txt"; then
    die "Fallo al instalar las dependencias de Python desde requirements.txt. Revisa la salida de pip superior."
fi

# Comprobar importación real de todas las librerías críticas en el Python del venv
"${INSTALL_DIR}/venv/bin/python3" -c "import fastapi, uvicorn, pydantic, psutil, httpx, multipart" || \
    die "Las dependencias de Python se instalaron pero falló la validación de importación."
chown -R root:bluecompany "${INSTALL_DIR}/venv"
ok "Dependencias Python verificadas correctamente en Python ${PY_REAL_VER}."

# ------------------------------------------------------------------------------
# 5. FUNCIÓN DE VALIDACIÓN Y CONFIGURACIÓN DE CERTIFICADOS SSL
# ------------------------------------------------------------------------------
CERT_DOMAIN=""

validar_par_ssl() {
    local c_file="$1" k_file="$2"
    [ -s "$c_file" ] || { warn "El archivo de certificado '$c_file' no existe o está vacío."; return 1; }
    [ -s "$k_file" ] || { warn "El archivo de clave privada '$k_file' no existe o está vacío."; return 1; }

    # Validar formato y vigencia del certificado
    if ! openssl x509 -in "$c_file" -noout -checkend 0 >/dev/null 2>&1; then
        warn "El certificado '$c_file' es inválido o ha expirado."
        return 1
    fi

    # Validar correspondencia criptográfica entre certificado y clave privada (Soporta RSA, ECDSA y Ed25519)
    local pub_cert pub_key
    pub_cert=$(openssl x509 -in "$c_file" -pubkey -noout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    pub_key=$(openssl pkey -in "$k_file" -pubout 2>/dev/null | sha256sum | awk '{print $1}') || return 1

    if [ -z "$pub_cert" ] || [ "$pub_cert" != "$pub_key" ]; then
        warn "El certificado y la clave privada NO corresponden al mismo par criptográfico."
        return 1
    fi

    CERT_DOMAIN=$(openssl x509 -in "$c_file" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*\([^,/]*\).*/\1/p' | head -n 1)
    [ -z "$CERT_DOMAIN" ] && CERT_DOMAIN="certificado-valido"
    return 0
}

instalar_archivos_ssl_seguros() {
    local src_cert="$1" src_key="$2"
    chown root:bluecompany "$SSL_DIR"
    chmod 0750 "$SSL_DIR"
    if [ "$src_cert" != "$CERT_FILE" ]; then
        install -m 0640 -o root -g bluecompany "$src_cert" "$CERT_FILE"
    else
        chown root:bluecompany "$CERT_FILE"
        chmod 0640 "$CERT_FILE"
    fi
    if [ "$src_key" != "$KEY_FILE" ]; then
        install -m 0640 -o root -g bluecompany "$src_key" "$KEY_FILE"
    else
        chown root:bluecompany "$KEY_FILE"
        chmod 0640 "$KEY_FILE"
    fi
}

instalar_hook_letsencrypt() {
    local dom="$1"
    echo "$dom" > "${SSL_DIR}/letsencrypt_domain.conf"
    chown root:bluecompany "${SSL_DIR}/letsencrypt_domain.conf"
    chmod 0640 "${SSL_DIR}/letsencrypt_domain.conf"
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    install -m 0755 -o root -g root "${INSTALL_DIR}/scripts/letsencrypt-deploy-hook.sh" /etc/letsencrypt/renewal-hooks/deploy/blue-company-ssl.sh
    ok "Deploy hook de renovación automática Let's Encrypt instalado en /etc/letsencrypt/renewal-hooks/deploy/blue-company-ssl.sh"
}

configurar_ssl_interactivo() {
    chown root:bluecompany "$SSL_DIR"
    chmod 0750 "$SSL_DIR"

    # Si ya existen certificados válidos en una reinstalación, ofrecer conservarlos
    if validar_par_ssl "$CERT_FILE" "$KEY_FILE"; then
        instalar_archivos_ssl_seguros "$CERT_FILE" "$KEY_FILE"
        ok "Certificado SSL existente y válido detectado en ${SSL_DIR} (CN: ${CERT_DOMAIN})."
        if [ -e /dev/tty ]; then
            read -r -p "  [?] ¿Deseas conservar el certificado actual sin modificarlo? (S/n): " keep_ssl </dev/tty
            if [[ ! "$keep_ssl" =~ ^[nN]$ ]]; then
                return 0
            fi
        else
            return 0
        fi
    fi

    echo -e "\n${C_CYAN}━━ CONFIGURACIÓN DE CERTIFICADO HTTPS (PUERTO ${PANEL_PORT}) ━━${C_RESET}"
    echo -e "  [1] Reutilizar un certificado Let's Encrypt existente (/etc/letsencrypt/live/...)"
    echo -e "  [2] Introducir rutas de un certificado y clave privada existentes (ej. 3X-UI / acme.sh)"
    echo -e "  [3] Generar certificado autofirmado para pruebas locales/IP"

    local op_ssl="3"
    if [ -e /dev/tty ]; then
        read -r -p "  ► Selecciona una opción [1-3]: " op_ssl </dev/tty
    fi

    case "$op_ssl" in
        1)
            local dom_list=()
            if [ -d /etc/letsencrypt/live ]; then
                while IFS= read -r d; do
                    [ -f "/etc/letsencrypt/live/${d}/fullchain.pem" ] && dom_list+=("$d")
                done < <(ls -1 /etc/letsencrypt/live 2>/dev/null)
            fi
            if [ "${#dom_list[@]}" -eq 0 ]; then
                die "No se encontraron certificados activos en /etc/letsencrypt/live/. Usa la opción 2 o 3."
            fi
            echo -e "  Dominios Let's Encrypt detectados:"
            local idx=1
            for d in "${dom_list[@]}"; do
                echo -e "    [$idx] $d"
                idx=$((idx + 1))
            done
            local sel_idx=1
            read -r -p "  ► Número de dominio a reutilizar [1]: " sel_idx </dev/tty
            sel_idx="${sel_idx:-1}"
            local chosen_dom="${dom_list[$((sel_idx - 1))]:-}"
            [ -n "$chosen_dom" ] || die "Selección de dominio inválida."
            local le_cert="/etc/letsencrypt/live/${chosen_dom}/fullchain.pem"
            local le_key="/etc/letsencrypt/live/${chosen_dom}/privkey.pem"
            validar_par_ssl "$le_cert" "$le_key" || die "El certificado Let's Encrypt seleccionado no superó la validación."
            instalar_archivos_ssl_seguros "$le_cert" "$le_key"
            instalar_hook_letsencrypt "$chosen_dom"
            ;;
        2)
            local custom_cert="" custom_key=""
            read -r -p "  ► Ruta completa del certificado (fullchain.pem / cert.pem): " custom_cert </dev/tty
            read -r -p "  ► Ruta completa de la clave privada (privkey.pem / key.pem): " custom_key </dev/tty
            validar_par_ssl "$custom_cert" "$custom_key" || die "Los archivos indicados no existen, expiraron o no coinciden."
            # Copiar de forma segura sin alterar ni mover los archivos originales (ej. 3X-UI intacto)
            instalar_archivos_ssl_seguros "$custom_cert" "$custom_key"
            ok "Certificado externo copiado de forma segura a ${SSL_DIR} sin alterar los archivos originales."
            ;;
        3)
            local pub_ip
            pub_ip=$(curl -s --max-time 3 https://api.ipify.org || hostname -I | awk '{print $1}')
            info "Generando certificado autofirmado para pruebas (CN=${pub_ip})..."
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout "$KEY_FILE" \
                -out "$CERT_FILE" \
                -subj "/CN=${pub_ip}/O=BLUE COMPANY WEB v10.1" >/dev/null 2>&1
            instalar_archivos_ssl_seguros "$CERT_FILE" "$KEY_FILE"
            validar_par_ssl "$CERT_FILE" "$KEY_FILE" || die "Error al validar el certificado autofirmado generado."
            ;;
        *)
            die "Opción SSL inválida. Instalación detenida."
            ;;
    esac
}

configurar_ssl_interactivo

# ------------------------------------------------------------------------------
# 6. BASE DE DATOS SQLITE Y PERMISOS DE DIRECTORIOS DE CONFIGURACIÓN
# ------------------------------------------------------------------------------
info "Verificando base de datos SQLite y permisos de servicio..."
chown root:bluecompany "$CONF_DIR"
chmod 2770 "$CONF_DIR"
chown bluepanel:bluecompany "$LOG_DIR"
chmod 0750 "$LOG_DIR"

NEW_ADMIN_CREATED=0
INITIAL_ADMIN_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)

DB_INIT_OUT=$("${INSTALL_DIR}/venv/bin/python3" - "$INITIAL_ADMIN_PASS" << 'PYINIT'
import sys, time, sqlite3
sys.path.insert(0, "/opt/blue-company/backend")
from app.main import init_db, hash_password, DB_PATH

init_db()
admin_pass = sys.argv[1]
conn = sqlite3.connect(DB_PATH)
cur = conn.cursor()
cur.execute("SELECT COUNT(*) FROM admins")
count = cur.fetchone()[0]
if count == 0:
    cur.execute(
        "INSERT INTO admins (username, password_hash, created_at) VALUES (?, ?, ?)",
        ("admin", hash_password(admin_pass), int(time.time()))
    )
    conn.commit()
    print("CREATED")
else:
    print("EXISTING")
conn.close()
PYINIT
)

[[ "$DB_INIT_OUT" == *"CREATED"* ]] && NEW_ADMIN_CREATED=1

chown bluepanel:bluecompany "$DB_FILE"
chmod 0660 "$DB_FILE"
if [ -f "${CONF_DIR}/secret.key" ]; then
    chown bluepanel:bluecompany "${CONF_DIR}/secret.key"
    chmod 0600 "${CONF_DIR}/secret.key"
fi

# ------------------------------------------------------------------------------
# 7. SELECCIÓN CONFIGURABLE DE MÓDULOS DE RED (CON DETECCIÓN DE CONFLICTOS)
# ------------------------------------------------------------------------------
echo -e "\n${C_CYAN}━━ SELECCIÓN DE MÓDULOS DE RED OPCIONALES ━━${C_RESET}"
MOD_DROPBEAR="s"
MOD_DESPACHADOR="s"
MOD_BADVPN="s"
MOD_LIMITER="s"

if [ -e /dev/tty ]; then
    read -r -p "  ► ¿Instalar/verificar Dropbear SSH (Puerto 2222)? (S/n): " r_db </dev/tty
    [[ "$r_db" =~ ^[nN]$ ]] && MOD_DROPBEAR="n"

    read -r -p "  ► ¿Instalar/verificar Despachador WS (Puerto 80 -> 2222/20001/20002/20003)? (S/n): " r_ws </dev/tty
    [[ "$r_ws" =~ ^[nN]$ ]] && MOD_DESPACHADOR="n"

    read -r -p "  ► ¿Instalar/verificar BadVPN UDPGW (Puerto 7300)? (S/n): " r_bv </dev/tty
    [[ "$r_bv" =~ ^[nN]$ ]] && MOD_BADVPN="n"

    read -r -p "  ► ¿Instalar/verificar Auto-Limitador 24/7 (Solo usuarios BLUE COMPANY)? (S/n): " r_lm </dev/tty
    [[ "$r_lm" =~ ^[nN]$ ]] && MOD_LIMITER="n"
fi

STATUS_DROPBEAR="OMITIDO"
STATUS_DESPACHADOR="OMITIDO"
STATUS_BADVPN="OMITIDO"
STATUS_LIMITER="OMITIDO"

if [ "$MOD_DROPBEAR" = "s" ]; then
    if bash "${INSTALL_DIR}/scripts/install-dropbear.sh"; then
        STATUS_DROPBEAR="ACTIVO (P:2222)"
    else
        STATUS_DROPBEAR="OMITIDO POR CONFLICTO"
    fi
fi

if [ "$MOD_DESPACHADOR" = "s" ]; then
    if bash "${INSTALL_DIR}/scripts/install-despachador.sh"; then
        STATUS_DESPACHADOR="ACTIVO (P:80 -> 20001/20002/20003)"
    else
        STATUS_DESPACHADOR="OMITIDO POR CONFLICTO"
    fi
fi

if [ "$MOD_BADVPN" = "s" ]; then
    if bash "${INSTALL_DIR}/scripts/install-badvpn.sh"; then
        STATUS_BADVPN="ACTIVO (P:7300)"
    else
        STATUS_BADVPN="OMITIDO POR CONFLICTO"
    fi
fi

if [ "$MOD_LIMITER" = "s" ]; then
    if bash "${INSTALL_DIR}/scripts/install-limiter.sh"; then
        STATUS_LIMITER="ACTIVO (24/7 Aislado)"
    else
        STATUS_LIMITER="ERROR"
    fi
fi

# ------------------------------------------------------------------------------
# 8. CONFIGURACIÓN E INICIO DE SYSTEMD (blue-company.service)
# ------------------------------------------------------------------------------
info "Instalando e iniciando servicio systemd blue-company.service..."
install -m 0644 -o root -g root "${INSTALL_DIR}/services/blue-company.service" /etc/systemd/system/blue-company.service
systemctl daemon-reload
systemctl enable blue-company.service >/dev/null
systemctl restart blue-company.service

# ------------------------------------------------------------------------------
# 9. VERIFICACIÓN FINAL DE 8 PUNTOS ANTES DE DECLARAR ÉXITO
# ------------------------------------------------------------------------------
info "Ejecutando auditoría final de verificación (8 comprobaciones obligatorias)..."

# 1. Dependencias Python
"${INSTALL_DIR}/venv/bin/python3" -c "import fastapi, uvicorn, pydantic, psutil, httpx, multipart" || \
    die "Fallo en verificación 1/8: Dependencias Python incompletas."

# 2. Existencia de base de datos
[ -s "$DB_FILE" ] || die "Fallo en verificación 2/8: La base de datos SQLite no existe."

# 3. Existencia y validez del certificado
validar_par_ssl "$CERT_FILE" "$KEY_FILE" || die "Fallo en verificación 3/8: Certificado SSL o clave privada inválidos."

# 4. Permisos del usuario de servicio (bluepanel)
sudo -u bluepanel test -r "$CERT_FILE" || die "Fallo en verificación 4/8: El usuario 'bluepanel' no puede leer ${CERT_FILE}."
sudo -u bluepanel test -r "$KEY_FILE" || die "Fallo en verificación 4/8: El usuario 'bluepanel' no puede leer ${KEY_FILE}."
sudo -u bluepanel test -r "$DB_FILE" && sudo -u bluepanel test -w "$DB_FILE" || \
    die "Fallo en verificación 4/8: El usuario 'bluepanel' no tiene acceso R/W a ${DB_FILE}."

# 5 y 6. Estado de systemd y escucha en puerto 8443
sleep 2
if ! systemctl is-active --quiet blue-company.service; then
    journalctl -u blue-company.service --no-pager -n 25 >&2 || true
    die "Fallo en verificación 6/8: El servicio blue-company.service no se mantuvo activo."
fi

ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT} " || \
    die "Fallo en verificación 5/8: El puerto ${PANEL_PORT} no está en escucha."

# 7. Respuesta HTTPS real del panel (/api/health)
HTTP_HEALTH=$(curl -kfsS --max-time 5 "https://127.0.0.1:${PANEL_PORT}/api/health" || true)
if [[ "$HTTP_HEALTH" != *'"status":"ok"'* ]]; then
    die "Fallo en verificación 7/8: El panel HTTPS no respondió correctamente en https://127.0.0.1:${PANEL_PORT}/api/health (Respuesta: ${HTTP_HEALTH:-vacía})."
fi

ok "Las 8 comprobaciones de integridad y operación finalizaron sin errores."

# ------------------------------------------------------------------------------
# 10. RESUMEN FINAL DE INSTALACIÓN
# ------------------------------------------------------------------------------
PUBLIC_HOST=$(curl -s --max-time 3 https://api.ipify.org || hostname -I | awk '{print $1}')
DISPLAY_HOST="$PUBLIC_HOST"
if [[ -n "$CERT_DOMAIN" && "$CERT_DOMAIN" != "certificado-valido" && "$CERT_DOMAIN" != "bluecompany.local" ]]; then
    DISPLAY_HOST="$CERT_DOMAIN"
fi

echo -e "\n${C_BLUE}╔══════════════════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_BLUE}║${C_GREEN}       ✅ BLUE COMPANY WEB v10.1.0 INSTALADO Y VERIFICADO         ${C_BLUE}║${C_RESET}"
echo -e "${C_BLUE}╠══════════════════════════════════════════════════════════════════╣${C_RESET}"
echo -e "  ${C_CYAN}Dominio / IP        :${C_RESET} ${C_WHITE}${DISPLAY_HOST}${C_RESET}"
echo -e "  ${C_CYAN
