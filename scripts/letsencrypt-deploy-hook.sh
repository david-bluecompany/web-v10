#!/bin/bash
# ==============================================================================
# BLUE COMPANY WEB v10.1 — Let's Encrypt Renewal Deploy Hook
# Ubicación de instalación: /etc/letsencrypt/renewal-hooks/deploy/blue-company-ssl.sh
# Actualiza los certificados del panel y reinicia SOLO blue-company.service
# ==============================================================================
set -euo pipefail
export LC_ALL=C

CONF_SSL_DIR="/etc/bluecompany/ssl"
DOMAIN_CONFIG="/etc/bluecompany/ssl/letsencrypt_domain.conf"

# Si no se configuró Let's Encrypt para BLUE COMPANY, salir silenciosamente
if [ ! -f "$DOMAIN_CONFIG" ]; then
    exit 0
fi

TARGET_DOMAIN=$(head -n 1 "$DOMAIN_CONFIG" | tr -d '[:space:]')
if [ -z "$TARGET_DOMAIN" ]; then
    exit 0
fi

LE_LIVE_DIR="/etc/letsencrypt/live/${TARGET_DOMAIN}"
if [ -n "${RENEWED_LINEAGE:-}" ] && [ "$RENEWED_LINEAGE" != "$LE_LIVE_DIR" ]; then
    # La renovación actual corresponde a otro certificado ajeno
    exit 0
fi

if [ ! -f "${LE_LIVE_DIR}/fullchain.pem" ] || [ ! -f "${LE_LIVE_DIR}/privkey.pem" ]; then
    echo "[BLUE COMPANY SSL Hook] No se encontraron archivos en ${LE_LIVE_DIR}" >&2
    exit 1
fi

mkdir -p "$CONF_SSL_DIR"
chown root:bluecompany "$CONF_SSL_DIR"
chmod 0750 "$CONF_SSL_DIR"

install -m 0640 -o root -g bluecompany "${LE_LIVE_DIR}/fullchain.pem" "${CONF_SSL_DIR}/cert.pem"
install -m 0640 -o root -g bluecompany "${LE_LIVE_DIR}/privkey.pem" "${CONF_SSL_DIR}/key.pem"

if systemctl is-active --quiet blue-company.service 2>/dev/null; then
    systemctl restart blue-company.service
fi
