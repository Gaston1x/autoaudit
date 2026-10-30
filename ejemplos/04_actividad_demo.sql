-- =============================================================================
-- AutoAudit - Ejemplo 4: actividad de demostración con varios usuarios y estaciones
--   psql -d autoaudit -f ejemplos/04_actividad_demo.sql
-- (usa las contraseñas de prueba de sql/90_demo_datos.sql)
-- =============================================================================
\set ON_ERROR_STOP on

\connect "host=localhost dbname=autoaudit user=cajero1 password=Cajero.Uno1 application_name=PuntoDeVenta"
SET autoaudit.usuario_app = 'mlopez';
SET autoaudit.estacion = 'CAJA-02';
INSERT INTO demo.clientes (nit, nombre, correo, telefono, limite_credito) VALUES
    ('4455667-1', 'Distribuidora El Quetzal', 'pedidos@elquetzal.gt', '2444-5566', 8000),
    ('9988776-5', 'Constructora Los Altos', 'compras@losaltos.gt', '7765-1122', 25000);
UPDATE demo.productos SET precio = 89.50 WHERE codigo = 'MART-01';
UPDATE demo.productos SET existencia = existencia - 12 WHERE codigo = 'CLAV-25';
UPDATE demo.clientes SET limite_credito = 15000 WHERE nit = '7654321-0';

\connect "host=localhost dbname=autoaudit user=cajero2 password=Cajero.Dos2 application_name=Inventario"
SET autoaudit.usuario_app = 'acastillo';
SET autoaudit.estacion = 'BODEGA-01';
INSERT INTO demo.productos (codigo, descripcion, precio, existencia, atributos) VALUES
    ('CEM-42', 'Cemento gris 42.5 kg', 89.00, 120, '{"marca": "Progreso"}'),
    ('VAR-38', 'Varilla de hierro 3/8"', 32.75, 500, '{}');
UPDATE demo.productos SET existencia = existencia + 50, atributos = '{"marca": "Truper", "garantia": "1 año"}' WHERE codigo = 'MART-01';
UPDATE demo.productos SET activo = false WHERE codigo = 'PINT-GL';
UPDATE demo.clientes SET correo = 'facturacion@esperanza.gt' WHERE nit = '1234567-8';
DELETE FROM demo.productos WHERE codigo = 'VAR-38';

\connect "host=localhost dbname=autoaudit user=cajero1 password=Cajero.Uno1 application_name=PuntoDeVenta"
SET autoaudit.usuario_app = 'jperez';
SET autoaudit.estacion = 'CAJA-01';
UPDATE demo.clientes SET nombre = 'Distribuidora El Quetzal, S.A.', limite_credito = 9500 WHERE nit = '4455667-1';
UPDATE demo.productos SET precio = 92.00 WHERE codigo = 'CEM-42';
DELETE FROM demo.clientes WHERE nit = '9988776-5';
