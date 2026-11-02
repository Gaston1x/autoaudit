#!/usr/bin/env bash
# =============================================================================
# AutoAudit - despliegue en un servidor Ubuntu 26.04 con HTTPS
# Uso (en el servidor, dentro del repositorio clonado):
#     sudo DOMINIO=midominio.com bash scripts/desplegar_servidor.sh
#     sudo DOMINIO=midominio.com CLAVE_DEMO=una-clave bash scripts/desplegar_servidor.sh   # + acceso demo
#
# 1. Instala PostgreSQL 18, la base y el entorno de Python (scripts/install.sh).
# 2. Carga actividad de ejemplo y cambia las contraseñas de prueba por unas
#    aleatorias (las de prueba están publicadas en el repositorio).
# 3. Deja la aplicación como servicio systemd escuchando solo en 127.0.0.1.
# 4. Publica la aplicación con HTTPS automático (Caddy + Let's Encrypt).
# =============================================================================
set -euo pipefail

DOMINIO="${DOMINIO:?Indique DOMINIO=nombre.del.servidor}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USUARIO="${SUDO_USER:-$(stat -c %U "$DIR")}"
CREDENCIALES=/root/autoaudit_credenciales.txt

echo "== 1. Instalación base"
DEMO=1 bash "${DIR}/scripts/install.sh"

echo "== 2. Datos de ejemplo y contraseñas"
if [ ! -f "$CREDENCIALES" ]; then
    # Se pasa por stdin: el usuario postgres no puede leer el directorio personal del usuario.
    sudo -u postgres psql -q -X -d autoaudit < "${DIR}/ejemplos/04_actividad_demo.sql" || true
    : > "$CREDENCIALES"
    chmod 600 "$CREDENCIALES"
    for rol in aa_admin aa_lector cajero1 cajero2; do
        clave="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)"
        sudo -u postgres psql -q -X -d autoaudit -c "ALTER ROLE ${rol} PASSWORD '${clave}'"
        echo "${rol}=${clave}" >> "$CREDENCIALES"
    done
    # Credenciales de la CLI en el servidor
    sed -i "s/^AA_CLAVE=.*/AA_CLAVE=$(grep '^aa_admin=' "$CREDENCIALES" | cut -d= -f2)/" "${DIR}/.env"
fi

# Acceso público de solo lectura (opcional): CLAVE_DEMO=... asigna esa contraseña
# a aa_lector y la muestra en la pantalla de inicio de sesión.
if [ -n "${CLAVE_DEMO:-}" ]; then
    sudo -u postgres psql -q -X -d autoaudit -c "ALTER ROLE aa_lector PASSWORD '${CLAVE_DEMO}'"
    sed -i "s/^aa_lector=.*/aa_lector=${CLAVE_DEMO}/" "$CREDENCIALES"
    sed -i '/^AA_DEMO_/d' "${DIR}/.env"
    printf 'AA_DEMO_USUARIO=aa_lector\nAA_DEMO_CLAVE=%s\n' "${CLAVE_DEMO}" >> "${DIR}/.env"
fi

echo "== 3. Servicio systemd"
cat > /etc/systemd/system/autoaudit.service <<EOF
[Unit]
Description=AutoAudit - aplicación web
After=network.target postgresql.service
Requires=postgresql.service

[Service]
User=${USUARIO}
WorkingDirectory=${DIR}
ExecStart=${DIR}/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --proxy-headers --forwarded-allow-ips=127.0.0.1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now autoaudit
systemctl restart autoaudit

echo "== 4. HTTPS con Caddy"
apt-get install -y caddy
cat > /etc/caddy/Caddyfile <<EOF
${DOMINIO} {
    encode gzip
    reverse_proxy 127.0.0.1:8000
    header {
        Strict-Transport-Security "max-age=31536000"
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
    }
}
EOF
systemctl enable caddy
systemctl reload caddy || systemctl restart caddy

echo
echo "== AutoAudit publicado en https://${DOMINIO}"
echo "   Credenciales generadas en ${CREDENCIALES} (solo root)"
