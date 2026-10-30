#!/usr/bin/env bash
# Crea el entorno virtual de Python dentro de Linux (más rápido que en /mnt/c)
# y deja un enlace .venv en el proyecto.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${HOME}/.venvs/autoaudit"
python3 -m venv "${VENV}"
"${VENV}/bin/pip" install -q --upgrade pip
"${VENV}/bin/pip" install -q -r "${DIR}/requirements.txt"
[ -f "${DIR}/.env" ] || cp "${DIR}/.env.example" "${DIR}/.env"
"${VENV}/bin/python" --version
echo "== venv listo en ${VENV}"
