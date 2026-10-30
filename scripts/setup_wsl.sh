#!/usr/bin/env bash
# Prepara el entorno de desarrollo en WSL (Ubuntu 26.04): PostgreSQL 18 + Python.
# Ejecutar como root desde Windows (no pide contraseña):
#     wsl -d Ubuntu-26.04 -u root -- bash scripts/setup_wsl.sh <usuario_linux>
# Deja a <usuario_linux> como superusuario de PostgreSQL (autenticación peer)
# y crea la base de datos "autoaudit".
set -euo pipefail

USUARIO="${1:?Indique el usuario de Linux}"
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y postgresql-18 postgresql-client-18 python3-venv python3-pip
service postgresql start

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${USUARIO}'" | grep -q 1; then
    sudo -u postgres createuser --superuser "${USUARIO}"
fi
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='autoaudit'" | grep -q 1; then
    sudo -u postgres createdb -O "${USUARIO}" autoaudit
fi

sudo -u "${USUARIO}" psql -d autoaudit -tAc "SELECT version()"
echo "== Entorno listo"
