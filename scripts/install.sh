#!/usr/bin/env bash
# =============================================================================
# AutoAudit - instalación en Ubuntu 26.04 LTS con PostgreSQL 18
# Uso:   sudo bash scripts/install.sh            (con datos de ejemplo)
#        sudo DEMO=0 bash scripts/install.sh     (sin datos de ejemplo)
# =============================================================================
set -euo pipefail

DB_NAME="${DB_NAME:-autoaudit}"
DEMO="${DEMO:-1}"
PG_VERSION=18
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== Sistema: $(. /etc/os-release && echo "$PRETTY_NAME")"

# 1. PostgreSQL 18 (repositorio de Ubuntu; si no lo trae, repositorio oficial PGDG)
if ! command -v "/usr/lib/postgresql/${PG_VERSION}/bin/postgres" >/dev/null 2>&1; then
    apt-get update
    if ! apt-get install -y "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"; then
        echo "== Agregando repositorio PGDG"
        apt-get install -y postgresql-common ca-certificates
        /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
        apt-get install -y "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}"
    fi
fi
systemctl enable --now postgresql 2>/dev/null || service postgresql start

# 2. Python
apt-get install -y python3 python3-venv python3-pip

# 3. Base de datos y objetos de AutoAudit
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    sudo -u postgres createdb "${DB_NAME}"
fi
cp -r "${DIR}/sql" /tmp/autoaudit_sql
chmod -R a+rX /tmp/autoaudit_sql
sudo -u postgres psql -d "${DB_NAME}" -v demo="${DEMO}" -f /tmp/autoaudit_sql/instalar.sql
rm -rf /tmp/autoaudit_sql

# 4. Entorno virtual de la aplicación
REAL_USER="${SUDO_USER:-$USER}"
sudo -u "${REAL_USER}" python3 -m venv "${DIR}/.venv"
sudo -u "${REAL_USER}" "${DIR}/.venv/bin/pip" install -q -r "${DIR}/requirements.txt"
[ -f "${DIR}/.env" ] || sudo -u "${REAL_USER}" cp "${DIR}/.env.example" "${DIR}/.env"

echo
echo "== AutoAudit instalado en la base de datos '${DB_NAME}'"
sudo -u postgres psql -d "${DB_NAME}" -tAc "SELECT version()"
echo "Iniciar la aplicación:  ${DIR}/.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000"
