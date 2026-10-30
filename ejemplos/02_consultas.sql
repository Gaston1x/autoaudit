-- =============================================================================
-- AutoAudit - Ejemplo 2: consultas históricas
--   psql "host=localhost dbname=autoaudit user=aa_lector" -f ejemplos/02_consultas.sql
-- =============================================================================
\set ON_ERROR_STOP on
\pset null '(nulo)'

\echo '--- Cambios realizados por el usuario cajero1'
SELECT fecha_hora::time(0) AS hora, operacion, tabla, usuario_app, estacion, ip, columna, valor_anterior, valor_nuevo
  FROM autoaudit.fn_cambios_por_usuario('cajero1');

\echo '--- Todos los cambios de la columna demo.clientes.limite_credito'
SELECT fecha_hora::time(0) AS hora, operacion, usuario_bd, pk_registro, valor_anterior, valor_nuevo
  FROM autoaudit.fn_cambios_por_columna('demo', 'clientes', 'limite_credito');

\echo '--- El registro borrado sigue preservado en la bitácora (fila completa)'
SELECT e.nombre AS operacion, b.fila_anterior
  FROM autoaudit.aud_bitacora b JOIN autoaudit.aud_evento e ON e.id = b.evento_id
 WHERE e.codigo = 'D'
 ORDER BY b.id DESC LIMIT 1;

\echo '--- Estado de la auditoría'
SELECT esquema, tabla, configuraciones_activas, eventos, estado FROM autoaudit.v_estado_triggers;
