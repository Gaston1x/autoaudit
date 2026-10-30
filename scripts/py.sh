#!/usr/bin/env bash
# Ejecuta un comando de Python del proyecto con el entorno virtual, desde la raíz.
#   bash scripts/py.sh cli.py tablas
#   bash scripts/py.sh -m pytest
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec "${HOME}/.venvs/autoaudit/bin/python" "$@"
