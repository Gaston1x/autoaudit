#!/usr/bin/env bash
# Borra y vuelve a crear la base de desarrollo "autoaudit" con datos de ejemplo.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dropdb --if-exists --force autoaudit
createdb autoaudit
psql -q -X -d autoaudit -v demo=1 -f "${DIR}/sql/instalar.sql" > /dev/null
PGPASSWORD=Cajero.Uno1 psql -q -X -h localhost -d autoaudit -U cajero1 -f "${DIR}/ejemplos/01_prueba_rapida.sql"
echo "== base 'autoaudit' reinstalada"
