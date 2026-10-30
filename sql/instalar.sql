-- =============================================================================
-- AutoAudit - instalar.sql
-- Instala el sistema completo. Uso (como superusuario, dentro de la BD destino):
--     psql -U postgres -d autoaudit -f sql/instalar.sql
-- Para omitir los datos de ejemplo:
--     psql -U postgres -d autoaudit -v demo=0 -f sql/instalar.sql
-- =============================================================================
\set ON_ERROR_STOP on
\if :{?demo}
\else
    \set demo 1
\endif

BEGIN;
\echo '== 00 Roles'
\ir 00_roles.sql
\echo '== 01 Tablas del sistema'
\ir 01_esquema_tablas.sql
\echo '== 02 Diccionario de datos'
\ir 02_diccionario.sql
\echo '== 03 Configuración'
\ir 03_configuracion.sql
\echo '== 04 Generador de triggers'
\ir 04_generador_triggers.sql
\echo '== 05 Event triggers'
\ir 05_event_triggers.sql
\echo '== 06 Consultas'
\ir 06_consultas.sql
\echo '== 07 Seguridad'
\ir 07_seguridad.sql
COMMIT;

\if :demo
\echo '== 90 Datos de ejemplo'
BEGIN;
\ir 90_demo_datos.sql
COMMIT;
\endif

\echo '== AutoAudit instalado'
SELECT * FROM autoaudit.v_estado_triggers;
