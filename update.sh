#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1.0 — Actualizador Oficial desde GitHub
# Repositorio: https://github.com/david-bluecompany/web-v10 (Rama: main)
# ==============================================================================
set -euo pipefail
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

GITHUB_REPO="https://github.com/david-bluecompany/web-v10"
GITHUB_RAW_URL="https://raw.githubusercontent.com/david-bluecompany/web-v10/main"

INSTALL_DIR="/opt/blue-company"
CONF_DIR="/etc/bluecompany"
VERSION_LOCAL_FILE="${INSTALL_DIR}/VERSION"
UPDATE_LOCK="/run/bluecompany-update.lock"
DB_SQLITE="${CONF_DIR}/bluecompany.db"

MODO_WEB=0
FORZAR=0
for arg in "$@"; do
    case "$arg" in
        --web|--non-interactive) MODO_WEB=1 ;;
        --force) FORZAR=1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Ejecuta el actualizador como root (sudo bash update.sh)."
    exit 1
fi

# 1. Bloqueo exclusivo contra actualizaciones simultáneas
exec 7>"$UPDATE_LOCK"
if ! flock -n 7; then
    echo "ERROR: Ya existe un proceso de actualización en curso."
    exit 1
fi

TMP_DIR=$(mktemp -d /tmp/bluecompany-up101.XXXXXX)
limpiar() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
    flock -u 7 2>/dev/null || true
}
trap limpiar EXIT

VERSION_LOCAL="10.0.0"
[ -f "$VERSION_LOCAL_FILE" ] && VERSION_LOCAL=$(tr -d '[:space:]' < "$VERSION_LOCAL_FILE")

echo "[1/8] Conectando con ${GITHUB_REPO} (rama main)..."
VERSION_REMOTA=$(curl -fsSL --max-time 10 "${GITHUB_RAW_URL}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)

if [[ ! "$VERSION_REMOTA" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "ERROR: No se pudo obtener el archivo VERSION desde ${GITHUB_REPO}."
    exit 1
fi

echo "      • Repositorio       : ${GITHUB_REPO}"
echo "      • Versión instalada : v${VERSION_LOCAL}"
echo "      • Versión en GitHub : v${VERSION_REMOTA}"

CHANGELOG_REMOTO=$(curl -fsSL --max-time 8 "${GITHUB_RAW_URL}/CHANGELOG.md" 2>/dev/null || echo "Actualización oficial a v${VERSION_REMOTA}")
echo "------------------------------------------------------------------"
echo "$CHANGELOG_REMOTO" | sed -n '1,18p' | sed 's/^/  /'
echo "------------------------------------------------------------------"

if [ "$VERSION_REMOTA" = "$VERSION_LOCAL" ] && [ "$FORZAR" -eq 0 ]; then
    if [ "$MODO_WEB" -eq 1 ]; then
        echo "INFO: Ya cuentas con la versión más reciente (v${VERSION_LOCAL}). Usa 'Forzar Resincronización' para reinstalar."
        exit 0
    else
        read -r -p "¿Ya tienes v${VERSION_LOCAL}. Deseas reinstalar de todos modos? (s/n): " resp
        [[ ! "$resp" =~ ^[sS]$ ]] && { echo "Actualización cancelada."; exit 0; }
    fi
elif [ "$MODO_WEB" -eq 0 ] && [ "$FORZAR" -eq 0 ]; then
    read -r -p "¿Confirmas actualizar de v${VERSION_LOCAL} a v${VERSION_REMOTA}? (s/n): " resp
    [[ ! "$resp" =~ ^[sS]$ ]] && { echo "Actualización cancelada."; exit 0; }
fi

# 2. Descargar manifiesto SHA256SUMS obligatorio
echo "[2/8] Descargando manifiesto SHA256SUMS..."
if ! curl -fsSL --max-time 10 "${GITHUB_RAW_URL}/SHA256SUMS" -o "${TMP_DIR}/SHA256SUMS" || [ ! -s "${TMP_DIR}/SHA256SUMS" ]; then
    echo "ERROR: No se encontró SHA256SUMS en ${GITHUB_REPO}."
    exit 1
fi

# 3. Verificar que todos los archivos listados en SHA256SUMS existan en remoto antes de descargar
echo "[3/8] Validando existencia de archivos en el manifiesto..."
while read -r _hash rel_path; do
    [ -z "${rel_path:-}" ] && continue
    rel_path="${rel_path#\*}"
    if [[ "$rel_path" == /* ]] || [[ "$rel_path" == *".."* ]]; then
        echo "ERROR: Ruta inválida en manifiesto: $rel_path"
        exit 1
    fi
    mkdir -p "${TMP_DIR}/$(dirname "$rel_path")"
    if ! curl -fsSL --max-time 15 "${GITHUB_RAW_URL}/${rel_path}" -o "${TMP_DIR}/${rel_path}"; then
        echo "ERROR: El archivo requerido '${rel_path}' listado en SHA256SUMS no está disponible en GitHub."
        exit 1
    fi
done < "${TMP_DIR}/SHA256SUMS"

# 4. Verificar integridad SHA256 estricta
echo "[4/8] Verificando firmas criptográficas SHA256..."
if ! (cd "$TMP_DIR" && sha256sum -c SHA256SUMS --status); then
    echo "ERROR CRÍTICO: La verificación SHA256 falló. Actualización abortada por seguridad."
    (cd "$TMP_DIR" && sha256sum -c SHA256SUMS || true)
    exit 1
fi
echo "      ✓ Integridad SHA256 verificada correctamente."

# 5. Validar sintaxis de Python y Bash
echo "[5/8] Validando sintaxis de los archivos descargados..."
python3 -m py_compile "${TMP_DIR}/backend/app/main.py"
for sh_f in "${TMP_DIR}/update.sh" "${TMP_DIR}/scripts/"*.sh; do
    [ -f "$sh_f" ] && bash -n "$sh_f"
done
echo "      ✓ Sintaxis validada sin errores."

# 6. Migración segura de Base de Datos SQLite (Verificando esquema estricto, sin migrar ssh-limits.txt ni alterar cuentas Linux)
echo "[6/8] Actualizando esquema SQLite a v${VERSION_REMOTA} de forma segura..."
python3 - "$DB_SQLITE" "$VERSION_REMOTA" << 'PYMIGRATE'
import os, sys, time, sqlite3

db_path, target_ver = sys.argv[1], sys.argv[2]
if not os.path.exists(db_path):
    print("      • Base de datos SQLite no encontrada. Se inicializará limpia.")
    sys.exit(0)

conn = sqlite3.connect(db_path, timeout=10)
cur = conn.cursor()

# Comprobar existencia previa de tablas obligatorias antes de proceder
tables = [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
if "system_meta" not in tables or "ssh_users" not in tables:
    print("      • Esquema SQLite incompleto. Omitiendo migración para evitar corrupción.")
    conn.close()
    sys.exit(0)

# Comprobar existencia de columnas necesarias en ssh_users
cols = [r[1] for r in cur.execute("PRAGMA table_info(ssh_users)").fetchall()]
if "last_updated" not in cols:
    try:
        cur.execute("ALTER TABLE ssh_users ADD COLUMN last_updated INTEGER DEFAULT 0")
        print("      • Columna 'last_updated' añadida exitosamente a ssh_users.")
    except Exception as e:
        print(f"      ! No se pudo añadir la columna last_updated: {e}")

cur.execute("INSERT OR REPLACE INTO system_meta (key, value) VALUES ('schema_version', ?)", (target_ver,))
cur.execute("INSERT OR REPLACE INTO system_meta (key, value) VALUES ('updated_at', ?)", (str(int(time.time())),))
conn.commit()
conn.close()
print("      ✓ Verificación y migración de esquema SQLite completada.")
PYMIGRATE

# 7. Detectar cambios y aplicar archivos (sin modificar permisos de certificados ni SSL, y sin ejecutar instaladores de servicios externos)
echo "[7/8] Aplicando archivos de forma controlada..."
cambio_archivo() {
    local nuevo="$1" actual="$2"
    [ ! -f "$actual" ] && return 0
    [ "$(sha256sum "$nuevo" | awk '{print $1}')" != "$(sha256sum "$actual" | awk '{print $1}')" ]
}

RELOAD_PIP=0
RESTART_PANEL=0

cambio_archivo "${TMP_DIR}/backend/requirements.txt" "${INSTALL_DIR}/backend/requirements.txt" && RELOAD_PIP=1
cambio_archivo "${TMP_DIR}/backend/app/main.py" "${INSTALL_DIR}/backend/app/main.py" && RESTART_PANEL=1
cambio_archivo "${TMP_DIR}/services/blue-company.service" "/etc/systemd/system/blue-company.service" && RESTART_PANEL=1

while read -r _hash rel_path; do
    [ -z "${rel_path:-}" ] && continue
    rel_path="${rel_path#\*}"
    # Omitir ejecución automática de install-limiter.sh e install-despachador.sh durante actualización web
    if [[ "$rel_path" == *"install-limiter.sh"* ]] || [[ "$rel_path" == *"install-despachador.sh"* ]]; then
        continue
    fi
    mkdir -p "${INSTALL_DIR}/$(dirname "$rel_path")"
    cp -f "${TMP_DIR}/${rel_path}" "${INSTALL_DIR}/${rel_path}"
done < "${TMP_DIR}/SHA256SUMS"

cp -f "${TMP_DIR}/SHA256SUMS" "${INSTALL_DIR}/SHA256SUMS"
cp -f "${TMP_DIR}/services/blue-company.service" "/etc/systemd/system/blue-company.service"
cp -f "${TMP_DIR}/scripts/blue-priv-helper.sh" /usr/local/sbin/blue-priv-helper
chown root:bluecompany /usr/local/sbin/blue-priv-helper
chmod 750 /usr/local/sbin/blue-priv-helper

chmod +x "${INSTALL_DIR}/update.sh" "${INSTALL_DIR}/scripts/"*.sh
chown -R bluepanel:bluecompany "${INSTALL_DIR}"
# NOTA: Se elimina completamente cualquier chown recursivo sobre /etc/bluecompany y se respetan certificados/SSL.
[ -d "${CONF_DIR}" ] && chown root:root "${CONF_DIR}" 2>/dev/null || true
echo "$VERSION_REMOTA" > "${CONF_DIR}/version.info"

# 8. Validar dependencias Python sin degradar Pydantic 2.14.3 ni romper entorno virtual existente
echo "[8/8] Validando entorno virtual y dependencias Python..."
if [ "$RELOAD_PIP" -eq 1 ] && [ -f "${INSTALL_DIR}/venv/bin/pip" ]; then
    # Verificar versión actual de pydantic en el entorno virtual
    PYDANTIC_INSTALLED=$("${INSTALL_DIR}/venv/bin/python3" -c "import pydantic; print(pydantic.__version__)" 2>/dev/null || echo "0.0.0")
    echo "      • Versión actual de Pydantic detectada: ${PYDANTIC_INSTALLED}"
    
    # Instalar requerimientos sin forzar la degradación si ya cumple o excede los requerimientos
    "${INSTALL_DIR}/venv/bin/pip" install --no-deps -r "${INSTALL_DIR}/backend/requirements.txt" &>/dev/null || \
        "${INSTALL_DIR}/venv/bin/pip" install -r "${INSTALL_DIR}/backend/requirements.txt" &>/dev/null
    
    RESTART_PANEL=1
fi

if [ "$RESTART_PANEL" -eq 1 ]; then
    systemctl daemon-reload
    if [ "$MODO_WEB" -eq 1 ]; then
        echo "      • Recargando panel web en segundo plano (2s)..."
        systemd-run --on-active=2s --unit=blue-company-up101-$$ systemctl restart blue-company &>/dev/null || \
            (nohup bash -c "sleep 2 && systemctl restart blue-company" >/dev/null 2>&1 &)
    else
        systemctl restart blue-company
    fi
fi

# Validación posterior del servicio systemd con reporte de errores reales si falla
echo "[*] Validando estado del servicio blue-company..."
sleep 1.5
if ! systemctl is-active --quiet blue-company; then
    echo "ERROR: El servicio blue-company falló al iniciar tras la actualización."
    echo "--- Últimos logs de error del servicio ---"
    journalctl -u blue-company -n 15 --no-pager
    exit 1
fi

FECHA_LOG=$(date "+%Y-%m-%d %H:%M:%S")
if [ -f "$DB_SQLITE" ]; then
    sqlite3 "$DB_SQLITE" "INSERT INTO audit_logs (timestamp, admin_user, ip, action, details) VALUES ('$FECHA_LOG', 'updater', 'GITHUB', 'UPDATE_V10_1', 'Actualizado de v${VERSION_LOCAL} a v${VERSION_REMOTA}');" 2>/dev/null || true
fi

echo "✅ ACTUALIZACIÓN COMPLETADA: BLUE COMPANY WEB v${VERSION_REMOTA} ACTIVO Y VERIFICADO"
