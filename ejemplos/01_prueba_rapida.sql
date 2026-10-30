-- =============================================================================
-- AutoAudit - Ejemplo 1: prueba rápida de INSERT / UPDATE / DELETE
-- Ejecutar conectado como un usuario de negocio, por ejemplo:
--   psql "host=localhost dbname=autoaudit user=cajero1" -f ejemplos/01_prueba_rapida.sql
-- =============================================================================
\set ON_ERROR_STOP on

-- Opcional: usuario de la aplicación y estación (cuando la app usa un usuario de conexión compartido)
SET autoaudit.usuario_app = 'jperez';
SET autoaudit.estacion = 'CAJA-01';

INSERT INTO demo.clientes (nit, nombre, correo, limite_credito)
VALUES ('999-PRUEBA', 'Cliente de Prueba', 'prueba@correo.gt', 1000);

UPDATE demo.clientes SET limite_credito = 2500, correo = 'nuevo@correo.gt' WHERE nit = '999-PRUEBA';

-- Este UPDATE no cambia columnas auditadas: NO debe registrarse.
UPDATE demo.clientes SET telefono = '5555-0000' WHERE nit = '999-PRUEBA';

DELETE FROM demo.clientes WHERE nit = '999-PRUEBA';

-- Un usuario de negocio NO puede leer ni escribir la bitácora.
-- Para ver el resultado use ejemplos/02_consultas.sql como aa_lector o aa_admin.
