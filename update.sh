#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.0 — Actualizador Oficial con Verificación SHA256
# ==============================================================================
set -euo pipefail
export LC_ALL=C

REPO_RAW="https://raw.githubusercontent.com/david-bluecompany/blue-company/web-v10"
INSTALL_DIR="/opt/blue-company"
LOCAL_VERSION=$(cat "${INSTALL_DIR}/VERSION" 2>/dev/null || echo "10.0.0")
TMP_DIR="/tmp/blue-company-update-$$"

mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[*] Consultando versión en GitHub (rama web-v10)..."
REMOTE_VERSION=$(curl -fsSL --max-time 10 "${REPO_RAW}/VERSION" | tr -d '[:space:]' || true)

if [[ ! "$REMOTE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: No se pudo obtener una versión válida desde GitHub."
    exit 1
fi

echo "[*] Versión instalada: ${LOCAL_VERSION} | Versión remota: ${REMOTE_VERSION}"

if ! curl -fsSL --max-time 10 "${REPO_RAW}/SHA256SUMS" -o "${TMP_DIR}/SHA256SUMS"; then
    echo "ERROR: Archivo SHA256SUMS no disponible en el repositorio."
    exit 1
fi

FILES=(
    "VERSION"
    "backend/app/main.py"
    "frontend/dist/index.html"
    "frontend/dist/styles.css"
    "frontend/dist/app.js"
    "scripts/blue-priv-helper.sh"
)

for f in "${FILES[@]}"; do
    mkdir -p "${TMP_DIR}/$(dirname "$f")"
    curl -fsSL --max-time 15 "${REPO_RAW}/${f}" -o "${TMP_DIR}/${f}"
done

echo "[*] Verificando sumas criptográficas SHA256..."
(cd "$TMP_DIR" && sha256sum -c SHA256SUMS --quiet)

echo "[*] Validando sintaxis de código antes de aplicar..."
python3 -m py_compile "${TMP_DIR}/backend/app/main.py"
bash -n "${TMP_DIR}/scripts/blue-priv-helper.sh"

cp -f "${TMP_DIR}/VERSION" "${INSTALL_DIR}/VERSION"
cp -f "${TMP_DIR}/backend/app/main.py" "${INSTALL_DIR}/backend/app/main.py"
cp -f "${TMP_DIR}/frontend/dist/"* "${INSTALL_DIR}/frontend/dist/"
cp -f "${TMP_DIR}/scripts/blue-priv-helper.sh" /usr/local/sbin/blue-priv-helper
chmod 750 /usr/local/sbin/blue-priv-helper
chown root:bluecompany /usr/local/sbin/blue-priv-helper

systemctl restart blue-company
echo "OK: Actualizado exitosamente a v${REMOTE_VERSION} (SHA256 verificado)"
