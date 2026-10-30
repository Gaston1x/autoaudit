-- =============================================================================
-- AutoAudit - 01_esquema_tablas.sql
-- Estructura de tablas del sistema (configuración, catálogos y bitácora).
-- Ejecutar como superusuario; los objetos quedan a nombre de autoaudit_owner.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS autoaudit AUTHORIZATION autoaudit_owner;
COMMENT ON SCHEMA autoaudit IS 'AutoAudit: sistema de auditoría automatizado';

SET ROLE autoaudit_owner;
SET search_path = autoaudit, pg_catalog;

-- -----------------------------------------------------------------------------
-- Parámetros generales (política de privacidad de IP, modo de error, etc.)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_parametro (
    clave        varchar(60)  PRIMARY KEY,
    valor        text         NOT NULL,
    descripcion  text         NOT NULL,
    modificado   timestamptz  NOT NULL DEFAULT now(),
    modificado_por name       NOT NULL DEFAULT session_user
);
COMMENT ON TABLE  aud_parametro IS 'Parámetros de funcionamiento de AutoAudit';
COMMENT ON COLUMN aud_parametro.clave IS 'Nombre del parámetro';
COMMENT ON COLUMN aud_parametro.valor IS 'Valor actual del parámetro';
COMMENT ON COLUMN aud_parametro.descripcion IS 'Explicación del parámetro y valores permitidos';
COMMENT ON COLUMN aud_parametro.modificado IS 'Fecha y hora de la última modificación';
COMMENT ON COLUMN aud_parametro.modificado_por IS 'Usuario de base de datos que lo modificó';

INSERT INTO aud_parametro (clave, valor, descripcion) VALUES
    ('modo_ip', 'enmascarada',
     'Cómo se guarda la IP origen: completa | enmascarada (red /24 o /48) | hash (SHA-256 con sal)'),
    ('sal_ip', md5(random()::text || clock_timestamp()::text),
     'Sal secreta usada cuando modo_ip = hash'),
    ('modo_error', 'estricto',
     'Si la auditoría falla durante un cambio: estricto (se revierte la operación) | tolerante (se registra el error y la operación continúa)')
ON CONFLICT (clave) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Catálogo de eventos (operaciones DML auditables)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_evento (
    id      smallint    PRIMARY KEY,
    codigo  char(1)     NOT NULL UNIQUE CHECK (codigo IN ('I', 'U', 'D')),
    nombre  varchar(10) NOT NULL UNIQUE
);
COMMENT ON TABLE  aud_evento IS 'Catálogo de eventos auditables (INSERT, UPDATE, DELETE)';
COMMENT ON COLUMN aud_evento.id IS 'Identificador del evento';
COMMENT ON COLUMN aud_evento.codigo IS 'Código corto: I, U o D';
COMMENT ON COLUMN aud_evento.nombre IS 'Nombre de la operación SQL';

INSERT INTO aud_evento (id, codigo, nombre) VALUES
    (1, 'I', 'INSERT'), (2, 'U', 'UPDATE'), (3, 'D', 'DELETE')
ON CONFLICT (id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Tablas auditadas
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_tabla (
    id          integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    esquema     name         NOT NULL,
    nombre      name         NOT NULL,
    oid_tabla   oid          NOT NULL,
    activa      boolean      NOT NULL DEFAULT true,
    eliminada   boolean      NOT NULL DEFAULT false,
    fecha_alta  timestamptz  NOT NULL DEFAULT now(),
    alta_por    name         NOT NULL DEFAULT session_user,
    fecha_baja  timestamptz,
    CONSTRAINT uq_aud_tabla_oid UNIQUE (oid_tabla)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_aud_tabla_nombre
    ON aud_tabla (esquema, nombre) WHERE NOT eliminada;
COMMENT ON TABLE  aud_tabla IS 'Tablas de negocio registradas para auditoría';
COMMENT ON COLUMN aud_tabla.id IS 'Identificador interno';
COMMENT ON COLUMN aud_tabla.esquema IS 'Esquema de la tabla origen';
COMMENT ON COLUMN aud_tabla.nombre IS 'Nombre de la tabla origen';
COMMENT ON COLUMN aud_tabla.oid_tabla IS 'OID de la tabla en pg_class (sobrevive a renombres)';
COMMENT ON COLUMN aud_tabla.activa IS 'true si la auditoría de la tabla está habilitada';
COMMENT ON COLUMN aud_tabla.eliminada IS 'true si la tabla origen fue eliminada (DROP TABLE)';
COMMENT ON COLUMN aud_tabla.fecha_alta IS 'Fecha en que se registró la tabla';
COMMENT ON COLUMN aud_tabla.alta_por IS 'Administrador que registró la tabla';
COMMENT ON COLUMN aud_tabla.fecha_baja IS 'Fecha en que se desactivó o eliminó';

-- -----------------------------------------------------------------------------
-- Columnas auditadas
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_columna (
    id          integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tabla_id    integer      NOT NULL REFERENCES aud_tabla (id) ON DELETE RESTRICT,
    nombre      name         NOT NULL,
    attnum      smallint     NOT NULL,
    tipo_dato   text         NOT NULL,
    activa      boolean      NOT NULL DEFAULT true,
    eliminada   boolean      NOT NULL DEFAULT false,
    fecha_alta  timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_aud_columna UNIQUE (tabla_id, attnum)
);
COMMENT ON TABLE  aud_columna IS 'Columnas de las tablas auditadas';
COMMENT ON COLUMN aud_columna.id IS 'Identificador interno';
COMMENT ON COLUMN aud_columna.tabla_id IS 'Tabla a la que pertenece (aud_tabla)';
COMMENT ON COLUMN aud_columna.nombre IS 'Nombre actual de la columna';
COMMENT ON COLUMN aud_columna.attnum IS 'Número de columna en pg_attribute (sobrevive a renombres)';
COMMENT ON COLUMN aud_columna.tipo_dato IS 'Tipo de dato según el diccionario de datos';
COMMENT ON COLUMN aud_columna.activa IS 'true si al menos un evento puede auditarse en la columna';
COMMENT ON COLUMN aud_columna.eliminada IS 'true si la columna fue eliminada de la tabla origen';
COMMENT ON COLUMN aud_columna.fecha_alta IS 'Fecha de registro';

-- -----------------------------------------------------------------------------
-- Configuración: qué evento se audita en qué columna
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_configuracion (
    id             integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    columna_id     integer      NOT NULL REFERENCES aud_columna (id) ON DELETE RESTRICT,
    evento_id      smallint     NOT NULL REFERENCES aud_evento (id) ON DELETE RESTRICT,
    activa         boolean      NOT NULL DEFAULT true,
    fecha_alta     timestamptz  NOT NULL DEFAULT now(),
    modificado     timestamptz  NOT NULL DEFAULT now(),
    modificado_por name         NOT NULL DEFAULT session_user,
    CONSTRAINT uq_aud_configuracion UNIQUE (columna_id, evento_id)
);
CREATE INDEX IF NOT EXISTS ix_aud_configuracion_evento ON aud_configuracion (evento_id);
COMMENT ON TABLE  aud_configuracion IS 'Eventos que deben auditarse por cada columna de cada tabla';
COMMENT ON COLUMN aud_configuracion.id IS 'Identificador de la configuración (referenciado por la bitácora)';
COMMENT ON COLUMN aud_configuracion.columna_id IS 'Columna auditada (aud_columna)';
COMMENT ON COLUMN aud_configuracion.evento_id IS 'Evento auditado (aud_evento)';
COMMENT ON COLUMN aud_configuracion.activa IS 'true si el evento está habilitado para la columna';
COMMENT ON COLUMN aud_configuracion.fecha_alta IS 'Fecha de creación';
COMMENT ON COLUMN aud_configuracion.modificado IS 'Fecha del último cambio de estado';
COMMENT ON COLUMN aud_configuracion.modificado_por IS 'Administrador que hizo el último cambio';

-- -----------------------------------------------------------------------------
-- Usuarios auditados
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_usuario (
    id                integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_bd        name         NOT NULL,
    usuario_app       varchar(120) NOT NULL DEFAULT '',
    auditar           boolean      NOT NULL DEFAULT true,
    primera_actividad timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_aud_usuario UNIQUE (usuario_bd, usuario_app)
);
COMMENT ON TABLE  aud_usuario IS 'Usuarios que han realizado cambios auditados';
COMMENT ON COLUMN aud_usuario.id IS 'Identificador interno';
COMMENT ON COLUMN aud_usuario.usuario_bd IS 'Usuario de conexión a PostgreSQL (session_user)';
COMMENT ON COLUMN aud_usuario.usuario_app IS 'Usuario de aplicación informado con SET autoaudit.usuario_app (vacío si no aplica)';
COMMENT ON COLUMN aud_usuario.auditar IS 'false para excluir de la auditoría (ej. procesos de carga masiva)';
COMMENT ON COLUMN aud_usuario.primera_actividad IS 'Primera vez que se registró actividad';

-- -----------------------------------------------------------------------------
-- Estaciones de trabajo auditadas
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_estacion (
    id                integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ip                varchar(80)  NOT NULL,
    hostname          varchar(255) NOT NULL DEFAULT '',
    aplicacion        varchar(120) NOT NULL DEFAULT '',
    auditar           boolean      NOT NULL DEFAULT true,
    primera_actividad timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_aud_estacion UNIQUE (ip, hostname, aplicacion)
);
COMMENT ON TABLE  aud_estacion IS 'Estaciones de trabajo desde donde se realizaron cambios';
COMMENT ON COLUMN aud_estacion.id IS 'Identificador interno';
COMMENT ON COLUMN aud_estacion.ip IS 'IP origen almacenada según la política modo_ip (completa, enmascarada o hash)';
COMMENT ON COLUMN aud_estacion.hostname IS 'Nombre de la estación informado por la aplicación con SET autoaudit.estacion';
COMMENT ON COLUMN aud_estacion.aplicacion IS 'application_name de la conexión';
COMMENT ON COLUMN aud_estacion.auditar IS 'false para excluir la estación de la auditoría';
COMMENT ON COLUMN aud_estacion.primera_actividad IS 'Primera vez que se registró actividad';

-- -----------------------------------------------------------------------------
-- Bitácora centralizada (cabecera, una fila por operación)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_bitacora (
    id             bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha_hora     timestamptz  NOT NULL DEFAULT clock_timestamp(),
    tabla_id       integer      NOT NULL REFERENCES aud_tabla (id) ON DELETE RESTRICT,
    evento_id      smallint     NOT NULL REFERENCES aud_evento (id) ON DELETE RESTRICT,
    usuario_id     integer      NOT NULL REFERENCES aud_usuario (id) ON DELETE RESTRICT,
    estacion_id    integer      NOT NULL REFERENCES aud_estacion (id) ON DELETE RESTRICT,
    txid           bigint       NOT NULL,
    pk_registro    jsonb        NOT NULL,
    fila_anterior  jsonb,
    fila_nueva     jsonb
);

CREATE INDEX IF NOT EXISTS ix_aud_bitacora_usuario ON aud_bitacora (usuario_id, fecha_hora);
CREATE INDEX IF NOT EXISTS ix_aud_bitacora_tabla   ON aud_bitacora (tabla_id, fecha_hora);
CREATE INDEX IF NOT EXISTS ix_aud_bitacora_pk      ON aud_bitacora USING gin (pk_registro jsonb_path_ops);
CREATE INDEX IF NOT EXISTS ix_aud_bitacora_fecha   ON aud_bitacora (fecha_hora);

COMMENT ON TABLE  aud_bitacora IS 'Bitácora centralizada: una fila por operación auditada';
COMMENT ON COLUMN aud_bitacora.id IS 'Identificador del registro de bitácora';
COMMENT ON COLUMN aud_bitacora.fecha_hora IS 'Fecha y hora exacta del cambio';
COMMENT ON COLUMN aud_bitacora.tabla_id IS 'Tabla origen (aud_tabla)';
COMMENT ON COLUMN aud_bitacora.evento_id IS 'Operación realizada (aud_evento)';
COMMENT ON COLUMN aud_bitacora.usuario_id IS 'Usuario responsable (aud_usuario)';
COMMENT ON COLUMN aud_bitacora.estacion_id IS 'Estación de trabajo de origen (aud_estacion)';
COMMENT ON COLUMN aud_bitacora.txid IS 'Identificador de la transacción (agrupa cambios de una misma transacción)';
COMMENT ON COLUMN aud_bitacora.pk_registro IS 'Llave primaria del registro modificado (JSON)';
COMMENT ON COLUMN aud_bitacora.fila_anterior IS 'Fila completa antes del cambio (UPDATE/DELETE); preserva datos borrados';
COMMENT ON COLUMN aud_bitacora.fila_nueva IS 'Fila completa después del cambio (INSERT/UPDATE)';

-- -----------------------------------------------------------------------------
-- Detalle de bitácora (una fila por columna afectada)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_bitacora_detalle (
    id                bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bitacora_id       bigint      NOT NULL REFERENCES aud_bitacora (id) ON DELETE RESTRICT,
    configuracion_id  integer     NOT NULL REFERENCES aud_configuracion (id) ON DELETE RESTRICT,
    valor_anterior    text,
    valor_nuevo       text
);
CREATE INDEX IF NOT EXISTS ix_aud_detalle_bitacora ON aud_bitacora_detalle (bitacora_id);
CREATE INDEX IF NOT EXISTS ix_aud_detalle_config   ON aud_bitacora_detalle (configuracion_id, bitacora_id);

COMMENT ON TABLE  aud_bitacora_detalle IS 'Valores antiguo y nuevo de cada columna afectada por una operación';
COMMENT ON COLUMN aud_bitacora_detalle.id IS 'Identificador del detalle';
COMMENT ON COLUMN aud_bitacora_detalle.bitacora_id IS 'Registro de bitácora (cabecera)';
COMMENT ON COLUMN aud_bitacora_detalle.configuracion_id IS 'Configuración (columna + evento) que originó el registro';
COMMENT ON COLUMN aud_bitacora_detalle.valor_anterior IS 'Valor antes del cambio (NULL en INSERT)';
COMMENT ON COLUMN aud_bitacora_detalle.valor_nuevo IS 'Valor después del cambio (NULL en DELETE)';

-- -----------------------------------------------------------------------------
-- Triggers generados (gestión de dependencias trigger <-> tabla origen)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_trigger (
    id              integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tabla_id        integer      NOT NULL REFERENCES aud_tabla (id) ON DELETE RESTRICT,
    nombre_trigger  name         NOT NULL,
    nombre_funcion  name         NOT NULL,
    trigger_oid     oid,
    eventos         varchar(20)  NOT NULL DEFAULT '',
    ddl             text         NOT NULL,
    hash_ddl        char(32)     NOT NULL,
    estado          varchar(20)  NOT NULL
        CHECK (estado IN ('ACTIVO', 'REEMPLAZADO', 'ELIMINADO', 'TABLA_ELIMINADA', 'ELIMINADO_EXTERNO')),
    generado        timestamptz  NOT NULL DEFAULT now(),
    generado_por    name         NOT NULL DEFAULT session_user
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_aud_trigger_activo ON aud_trigger (tabla_id) WHERE estado = 'ACTIVO';
COMMENT ON TABLE  aud_trigger IS 'Historial y estado de los triggers generados (uno activo por tabla)';
COMMENT ON COLUMN aud_trigger.id IS 'Identificador';
COMMENT ON COLUMN aud_trigger.tabla_id IS 'Tabla origen que maneja el trigger (exactamente una)';
COMMENT ON COLUMN aud_trigger.nombre_trigger IS 'Nombre del trigger en pg_trigger';
COMMENT ON COLUMN aud_trigger.nombre_funcion IS 'Función PL/pgSQL generada que ejecuta el trigger';
COMMENT ON COLUMN aud_trigger.trigger_oid IS 'OID del trigger en pg_trigger';
COMMENT ON COLUMN aud_trigger.eventos IS 'Operaciones que cubre (ej. I,U,D)';
COMMENT ON COLUMN aud_trigger.ddl IS 'Código SQL generado';
COMMENT ON COLUMN aud_trigger.hash_ddl IS 'MD5 del código, para detectar cambios';
COMMENT ON COLUMN aud_trigger.estado IS 'ACTIVO, REEMPLAZADO, ELIMINADO, TABLA_ELIMINADA o ELIMINADO_EXTERNO';
COMMENT ON COLUMN aud_trigger.generado IS 'Fecha de generación';
COMMENT ON COLUMN aud_trigger.generado_por IS 'Administrador que lo generó';

-- -----------------------------------------------------------------------------
-- Errores de generación / ejecución
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_error (
    id        bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha     timestamptz  NOT NULL DEFAULT clock_timestamp(),
    usuario   name         NOT NULL DEFAULT session_user,
    contexto  varchar(60)  NOT NULL,
    tabla_id  integer      REFERENCES aud_tabla (id) ON DELETE RESTRICT,
    sqlstate  char(5),
    mensaje   text         NOT NULL,
    detalle   text
);
CREATE INDEX IF NOT EXISTS ix_aud_error_fecha ON aud_error (fecha);
COMMENT ON TABLE  aud_error IS 'Errores ocurridos al generar o ejecutar triggers de auditoría';
COMMENT ON COLUMN aud_error.id IS 'Identificador';
COMMENT ON COLUMN aud_error.fecha IS 'Momento del error';
COMMENT ON COLUMN aud_error.usuario IS 'Usuario que provocó el error';
COMMENT ON COLUMN aud_error.contexto IS 'Dónde ocurrió: GENERACION, EJECUCION, VALIDACION, DDL';
COMMENT ON COLUMN aud_error.tabla_id IS 'Tabla relacionada (si aplica)';
COMMENT ON COLUMN aud_error.sqlstate IS 'Código SQLSTATE de PostgreSQL';
COMMENT ON COLUMN aud_error.mensaje IS 'Mensaje de error';
COMMENT ON COLUMN aud_error.detalle IS 'Detalle, pista o contexto adicional';

-- -----------------------------------------------------------------------------
-- Historial de cambios de configuración (quién activó/desactivó qué)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS aud_cambio_config (
    id        bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fecha     timestamptz  NOT NULL DEFAULT clock_timestamp(),
    usuario   name         NOT NULL DEFAULT session_user,
    accion    varchar(40)  NOT NULL,
    tabla_id  integer      REFERENCES aud_tabla (id) ON DELETE RESTRICT,
    detalle   jsonb        NOT NULL DEFAULT '{}'
);
COMMENT ON TABLE  aud_cambio_config IS 'Auditoría de la propia configuración de AutoAudit';
COMMENT ON COLUMN aud_cambio_config.id IS 'Identificador';
COMMENT ON COLUMN aud_cambio_config.fecha IS 'Fecha del cambio';
COMMENT ON COLUMN aud_cambio_config.usuario IS 'Administrador que realizó el cambio';
COMMENT ON COLUMN aud_cambio_config.accion IS 'Acción: CONFIGURAR, DESACTIVAR_TABLA, GENERAR, PARAMETRO, DDL_EXTERNO...';
COMMENT ON COLUMN aud_cambio_config.tabla_id IS 'Tabla afectada (si aplica)';
COMMENT ON COLUMN aud_cambio_config.detalle IS 'Detalle del cambio en JSON';

RESET ROLE;
