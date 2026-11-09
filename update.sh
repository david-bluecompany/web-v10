#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1.0 — Actualizador Inteligente desde GitHub
# Soporta actualización v10.0.0 -> v10.1.0 y migración de base de datos SQLite
# ==============================================================================
set -euo pipefail
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

BRANCH="web-v10"
GITHUB_RAW_URL="https://raw.githubusercontent.com/david-bluecompany/blue-company/${BRANCH}"
INSTALL_DIR="/opt/blue-company"
CONF_DIR="/etc/bluecompany"
VERSION_LOCAL_FILE="${INSTALL_DIR}/VERSION"
UPDATE_LOCK="/run/bluecompany-update.lock"
DB_SQLITE="${CONF_DIR}/bluecompany.db"
LEGACY_DB="/etc/ssh-limits.txt"

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

# 1. Bloqueo exclusivo de actualización
exec 7>"$UPDATE_LOCK"
if ! flock -n 7; then
    echo "ERROR: Ya hay una actualización de BLUE COMPANY en ejecución."
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

echo "[1/7] Consultando versión disponible en GitHub (rama: ${BRANCH})..."
VERSION_REMOTA=$(curl -fsSL --max-time 10 "${GITHUB_RAW_URL}/VERSION" 2>/dev/null | tr -d '[:space:]' || true)

if [[ ! "$VERSION_REMOTA" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: No se pudo verificar la versión remota en GitHub (${VERSION_REMOTA:-sin respuesta})."
    exit 1
fi

echo "      • Versión instalada : v${VERSION_LOCAL}"
echo "      • Versión disponible: v${VERSION_REMOTA}"

CHANGELOG_REMOTO=$(curl -fsSL --max-time 10 "${GITHUB_RAW_URL}/CHANGELOG.md" 2>/dev/null || echo "Actualización a v${VERSION_REMOTA}")
echo "------------------------------------------------------------------"
echo "$CHANGELOG_REMOTO" | sed -n '1,18p' | sed 's/^/  /'
echo "------------------------------------------------------------------"

if [ "$VERSION_REMOTA" = "$VERSION_LOCAL" ] && [ "$FORZAR" -eq 0 ]; then
    if [ "$MODO_WEB" -eq 1 ]; then
        echo "INFO: El servidor ya está en la versión v${VERSION_LOCAL}. Usa 'Forzar Resincronización' si deseas reinstalar los paquetes."
        exit 0
    else
        read -r -p "¿Ya cuentas con v${VERSION_LOCAL}. Deseas forzar la reinstalación? (s/n): " resp
        [[ ! "$resp" =~ ^[sS]$ ]] && { echo "Operación cancelada."; exit 0; }
    fi
elif [ "$MODO_WEB" -eq 0 ] && [ "$FORZAR" -eq 0 ]; then
    read -r -p "¿Deseas actualizar ahora de v${VERSION_LOCAL} a v${VERSION_REMOTA}? (s/n): " resp
    [[ ! "$resp" =~ ^[sS]$ ]] && { echo "Operación cancelada."; exit 0; }
fi

# 2. Descarga dinámica guiada por SHA256SUMS
echo "[2/7] Descargando manifiesto SHA256SUMS de v${VERSION_REMOTA}..."
if ! curl -fsSL --max-time 10 "${GITHUB_RAW_URL}/SHA256SUMS" -o "${TMP_DIR}/SHA256SUMS" || [ ! -s "${TMP_DIR}/SHA256SUMS" ]; then
    echo "ERROR: No se encontró el manifiesto SHA256SUMS en el repositorio."
    exit 1
fi

echo "[3/7] Descargando archivos del paquete v${VERSION_REMOTA}..."
while read -r _hash rel_path; do
    [ -z "${rel_path:-}" ] && continue
    rel_path="${rel_path#\*}"
    # Prevenir rutas inseguras
    if [[ "$rel_path" == /* ]] || [[ "$rel_path" == *".."* ]]; then
        echo "ERROR: Ruta no permitida en manifiesto: $rel_path"
        exit 1
    fi
    mkdir -p "${TMP_DIR}/$(dirname "$rel_path")"
    if ! curl -fsSL --max-time 15 "${GITHUB_RAW_URL}/${rel_path}" -o "${TMP_DIR}/${rel_path}"; then
        echo "ERROR: Falló la descarga del componente: ${rel_path}"
        exit 1
    fi
done < "${TMP_DIR}/SHA256SUMS"

# 3. Verificación criptográfica SHA256
echo "[4/7] Verificando integridad criptográfica SHA256..."
if ! (cd "$TMP_DIR" && sha256sum -c SHA256SUMS --status); then
    echo "ERROR CRÍTICO: Falló la validación SHA256. No se modificó ningún archivo del sistema."
    (cd "$TMP_DIR" && sha256sum -c SHA256SUMS || true)
    exit 1
fi
echo "      ✓ Integridad SHA256 verificada al 100%."

# 4. Validación de sintaxis previa a la aplicación
echo "[5/7] Comprobando sintaxis de Python y Bash..."
python3 -m py_compile "${TMP_DIR}/backend/app/main.py"
for sh_f in "${TMP_DIR}/update.sh" "${TMP_DIR}/scripts/"*.sh; do
    [ -f "$sh_f" ] && bash -n "$sh_f"
done
echo "      ✓ Validación de código superada."

# 5. Migración de Base de Datos SQLite a v10.1.0 e importación de cuentas previas
echo "[6/7] Ejecutando migración de base de datos para v${VERSION_REMOTA}..."
python3 - "$DB_SQLITE" "$LEGACY_DB" "$VERSION_REMOTA" << 'PYMIGRATE'
import os, sys, time, sqlite3, subprocess

db_path, legacy_path, target_ver = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(os.path.dirname(db_path), exist_ok=True)
conn = sqlite3.connect(db_path, timeout=10)
cur = conn.cursor()

# Asegurar tablas base y tabla de metadatos de versión v10.1.0
cur.execute("""
CREATE TABLE IF NOT EXISTS system_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
)
""")

# Añadir columna 'last_updated' en ssh_users si se actualiza desde v10.0.0
cols = [r[1] for r in cur.execute("PRAGMA table_info(ssh_users)").fetchall()]
if "ssh_users" in [r[0] for r in cur.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]:
    if "last_updated" not in cols:
        cur.execute("ALTER TABLE ssh_users ADD COLUMN last_updated INTEGER DEFAULT 0")

# Importar usuarios de /etc/ssh-limits.txt si existen y aún no están en SQLite
imported = 0
if os.path.exists(legacy_path):
    with open(legacy_path, "r", errors="ignore") as lf:
        for line in lf:
            line = line.strip()
            if not line or line.startswith("#") or ":" not in line:
                continue
            parts = line.split(":")
            u = parts[0].strip()
            if not u or u == "root":
                continue
            # Comprobar que el usuario exista en el sistema Linux
            if subprocess.call(["id", u], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
                continue
            exists = cur.execute("SELECT COUNT(*) FROM ssh_users WHERE username = ?", (u,)).fetchone()[0]
            if exists == 0:
                try:
                    lim = max(1, int(parts[1]))
                except Exception:
                    lim = 1
                exp = int(parts[3]) if (len(parts) >= 4 and parts[3].isdigit()) else int(time.time()) + 2592000
                st = parts[4].strip() if (len(parts) >= 5 and parts[4].strip()) else "ACTIVO"
                now = int(time.time())
                cur.execute(
                    "INSERT INTO ssh_users (username, max_connections, expires_at, status, created_at, notes, last_updated) "
                    "VALUES (?, ?, ?, ?, ?, 'Migrado a v10.1.0', ?)",
                    (u, lim, exp, st, now, now)
                )
                subprocess.call(["usermod", "-c", "BLUECOMPANY_MANAGED", u], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                imported += 1

cur.execute("INSERT OR REPLACE INTO system_meta (key, value) VALUES ('schema_version', ?)", (target_ver,))
cur.execute("INSERT OR REPLACE INTO system_meta (key, value) VALUES ('updated_at', ?)", (str(int(time.time())),))
conn.commit()
conn.close()
if imported > 0:
    print(f"      ✓ Se importaron {imported} cuentas existentes a SQLite (sin almacenar contraseñas en texto plano).")
PYMIGRATE

# 6. Comparar hashes para reiniciar solo servicios modificados
cambio_archivo() {
    local nuevo="$1" actual="$2"
    [ ! -f "$actual" ] && return 0
    [ "$(sha256sum "$nuevo" | awk '{print $1}')" != "$(sha256sum "$actual" | awk '{print $1}')" ]
}

RELOAD_PIP=0
RESTART_PANEL=0
RESTART_LIMITER=0
RESTART_WS=0

cambio_archivo "${TMP_DIR}/backend/requirements.txt" "${INSTALL_DIR}/backend/requirements.txt" && RELOAD_PIP=1
cambio_archivo "${TMP_DIR}/backend/app/main.py" "${INSTALL_DIR}/backend/app/main.py" && RESTART_PANEL=1
cambio_archivo "${TMP_DIR}/services/blue-company.service" "/etc/systemd/system/blue-company.service" && RESTART_PANEL=1
cambio_archivo "${TMP_DIR}/scripts/install-limiter.sh" "${INSTALL_DIR}/scripts/install-limiter.sh" && RESTART_LIMITER=1
cambio_archivo "${TMP_DIR}/scripts/install-despachador.sh" "${INSTALL_DIR}/scripts/install-despachador.sh" && RESTART_WS=1

# Copiar archivos verificados al directorio de producción
while read -r _hash rel_path; do
    [ -z "${rel_path:-}" ] && continue
    rel_path="${rel_path#\*}"
    mkdir -p "${INSTALL_DIR}/$(dirname "$rel_path")"
    cp -f "${TMP_DIR}/${rel_path}" "${INSTALL_DIR}/${rel_path}"
done < "${TMP_DIR}/SHA256SUMS"

cp -f "${TMP_DIR}/SHA256SUMS" "${INSTALL_DIR}/SHA256SUMS"
cp -f "${TMP_DIR}/services/blue-company.service" "/etc/systemd/system/blue-company.service"
cp -f "${TMP_DIR}/scripts/blue-priv-helper.sh" /usr/local/sbin/blue-priv-helper
chown root:bluecompany /usr/local/sbin/blue-priv-helper
chmod 750 /usr/local/sbin/blue-priv-helper

chmod +x "${INSTALL_DIR}/update.sh" "${INSTALL_DIR}/scripts/"*.sh
chown -R bluepanel:bluecompany "${INSTALL_DIR}" "${CONF_DIR}"
echo "$VERSION_REMOTA" > "${CONF_DIR}/version.info"

# 7. Reinicio controlado de servicios
echo "[7/7] Aplicando reinicio selectivo de servicios..."
if [ "$RELOAD_PIP" -eq 1 ]; then
    "${INSTALL_DIR}/venv/bin/pip" install -r "${INSTALL_DIR}/backend/requirements.txt" &>/dev/null
    RESTART_PANEL=1
fi

[ "$RESTART_LIMITER" -eq 1 ] && bash "${INSTALL_DIR}/scripts/install-limiter.sh" &>/dev/null
[ "$RESTART_WS" -eq 1 ] && bash "${INSTALL_DIR}/scripts/install-despachador.sh" &>/dev/null

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

FECHA_LOG=$(date "+%Y-%m-%d %H:%M:%S")
sqlite3 "$DB_SQLITE" "INSERT INTO audit_logs (timestamp, admin_user, ip, action, details) VALUES ('$FECHA_LOG', 'updater', 'GITHUB', 'UPDATE_V10_1', 'Actualizado de v${VERSION_LOCAL} a v${VERSION_REMOTA}');" 2>/dev/null || true

echo "✅ ACTUALIZACIÓN COMPLETADA: BLUE COMPANY WEB v${VERSION_REMOTA} ACTIVO"
