-- =============================================================================
-- AutoAudit - Ejemplo 3: seguridad y gestión de dependencias (DDL)
-- Ejecutar como superusuario o dueño (cada bloque se revierte, no deja cambios):
--   psql -d autoaudit -f ejemplos/03_seguridad_y_ddl.sql
-- =============================================================================
\pset null '(nulo)'

\echo '--- 1. Un usuario sin rol admin no puede configurar auditoría'
BEGIN;
SET LOCAL ROLE cajero1;
SAVEPOINT s;
SELECT autoaudit.fn_configurar_tabla('demo', 'ventas', '{"total": ["U"]}');
ROLLBACK TO s;
ROLLBACK;

\echo '--- 2. Nadie puede escribir directamente en la bitácora (ni el administrador)'
BEGIN;
SET LOCAL ROLE aa_admin;
INSERT INTO autoaudit.aud_bitacora (tabla_id, evento_id, usuario_id, estacion_id, txid, pk_registro)
VALUES (1, 1, 1, 1, 0, '{}');
ROLLBACK;

\echo '--- 3. La bitácora es inmutable (ni siquiera el superusuario modifica registros)'
BEGIN;
UPDATE autoaudit.aud_bitacora SET pk_registro = '{}' WHERE id = 1;
ROLLBACK;
BEGIN;
DELETE FROM autoaudit.aud_bitacora_detalle;
ROLLBACK;

\echo '--- 4. Validación: tabla y columna inexistentes'
BEGIN;
SAVEPOINT s;
SELECT autoaudit.fn_configurar_tabla('demo', 'no_existe', '{"x": ["I"]}');
ROLLBACK TO s;
SELECT autoaudit.fn_configurar_tabla('demo', 'clientes', '{"columna_falsa": ["I"]}');
ROLLBACK;

\echo '--- 5. DROP COLUMN de una columna auditada: el trigger se regenera solo'
BEGIN;
ALTER TABLE demo.clientes DROP COLUMN correo CASCADE;
SELECT nombre, activa, eliminada FROM autoaudit.aud_columna WHERE tabla_id = 1 ORDER BY attnum;
SELECT tabla, eventos, estado FROM autoaudit.v_estado_triggers WHERE tabla = 'clientes';
INSERT INTO demo.clientes (nit, nombre) VALUES ('DDL-1', 'Prueba DDL');
ROLLBACK;

\echo '--- 6. RENAME COLUMN: la configuración sigue la columna'
BEGIN;
ALTER TABLE demo.clientes RENAME COLUMN nombre TO razon_social;
SELECT nombre FROM autoaudit.aud_columna WHERE tabla_id = 1 AND attnum = 3;
SELECT estado FROM autoaudit.v_estado_triggers WHERE tabla = 'clientes';
UPDATE demo.clientes SET razon_social = razon_social || ' S.A.' WHERE id = 1;
ROLLBACK;

\echo '--- 7. DROP TRIGGER manual: queda registrado quién lo hizo'
BEGIN;
DROP TRIGGER aa_auditoria ON demo.productos;
SELECT accion, usuario, detalle FROM autoaudit.aud_cambio_config ORDER BY id DESC LIMIT 1;
SELECT tabla, estado FROM autoaudit.v_estado_triggers WHERE tabla = 'productos';
ROLLBACK;

\echo '--- 8. DROP TABLE auditada: la bitácora histórica se conserva'
BEGIN;
DROP TABLE demo.venta_detalle, demo.ventas, demo.clientes CASCADE;
SELECT id, nombre, activa, eliminada FROM autoaudit.aud_tabla WHERE id = 1;
SELECT count(*) AS registros_conservados FROM autoaudit.aud_bitacora WHERE tabla_id = 1;
ROLLBACK;
