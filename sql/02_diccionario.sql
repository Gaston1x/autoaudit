-- =============================================================================
-- AutoAudit - 02_diccionario.sql
-- Consultas al diccionario de datos de PostgreSQL (pg_catalog).
-- Son la base del módulo de configuración: solo se ofrece lo que existe.
-- =============================================================================

SET ROLE autoaudit_owner;
SET search_path = autoaudit, pg_catalog;

-- Esquemas del sistema que nunca se ofrecen para auditar.
CREATE OR REPLACE FUNCTION fn_es_esquema_sistema(p_esquema name)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
    SELECT p_esquema IN ('pg_catalog', 'information_schema', 'autoaudit', 'pg_toast')
        OR p_esquema LIKE 'pg\_temp\_%' OR p_esquema LIKE 'pg\_toast\_temp\_%';
$$;

-- -----------------------------------------------------------------------------
-- Tablas existentes en la base de datos que pueden auditarse.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_listar_tablas()
RETURNS TABLE (
    esquema          name,
    tabla            name,
    oid_tabla        oid,
    filas_estimadas  bigint,
    tiene_pk         boolean,
    comentario       text,
    auditada         boolean,
    tabla_id         integer,
    trigger_activo   boolean
)
LANGUAGE sql STABLE
AS $$
    SELECT n.nspname,
           c.relname,
           c.oid,
           greatest(c.reltuples, 0)::bigint,
           EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p'),
           obj_description(c.oid, 'pg_class'),
           coalesce(t.activa, false),
           t.id,
           EXISTS (SELECT 1 FROM autoaudit.aud_trigger g
                    WHERE g.tabla_id = t.id AND g.estado = 'ACTIVO')
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      LEFT JOIN autoaudit.aud_tabla t ON t.oid_tabla = c.oid AND NOT t.eliminada
     WHERE c.relkind IN ('r', 'p')          -- tablas normales y particionadas
       AND NOT c.relispartition             -- se audita la tabla padre, no cada partición
       AND NOT autoaudit.fn_es_esquema_sistema(n.nspname)
     ORDER BY n.nspname, c.relname;
$$;
COMMENT ON FUNCTION fn_listar_tablas() IS
    'Diccionario de datos: tablas de usuario disponibles para auditoría';

-- -----------------------------------------------------------------------------
-- Columnas de una tabla, con su estado de auditoría por evento.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_listar_columnas(p_esquema name, p_tabla name)
RETURNS TABLE (
    attnum         smallint,
    columna        name,
    tipo_dato      text,
    no_nulo        boolean,
    valor_defecto  text,
    es_pk          boolean,
    comentario     text,
    audita_insert  boolean,
    audita_update  boolean,
    audita_delete  boolean
)
LANGUAGE sql STABLE
AS $$
    SELECT a.attnum,
           a.attname,
           format_type(a.atttypid, a.atttypmod),
           a.attnotnull,
           pg_get_expr(d.adbin, d.adrelid),
           EXISTS (SELECT 1 FROM pg_constraint k
                    WHERE k.conrelid = c.oid AND k.contype = 'p' AND a.attnum = ANY (k.conkey)),
           col_description(c.oid, a.attnum),
           coalesce(bool_or(cf.activa) FILTER (WHERE cf.evento_id = 1), false),
           coalesce(bool_or(cf.activa) FILTER (WHERE cf.evento_id = 2), false),
           coalesce(bool_or(cf.activa) FILTER (WHERE cf.evento_id = 3), false)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
      LEFT JOIN autoaudit.aud_tabla t ON t.oid_tabla = c.oid AND NOT t.eliminada
      LEFT JOIN autoaudit.aud_columna ac ON ac.tabla_id = t.id AND ac.attnum = a.attnum AND NOT ac.eliminada
      LEFT JOIN autoaudit.aud_configuracion cf ON cf.columna_id = ac.id
     WHERE n.nspname = p_esquema
       AND c.relname = p_tabla
     GROUP BY a.attnum, a.attname, a.atttypid, a.atttypmod, a.attnotnull, d.adbin, d.adrelid, c.oid
     ORDER BY a.attnum;
$$;
COMMENT ON FUNCTION fn_listar_columnas(name, name) IS
    'Diccionario de datos: columnas de una tabla y eventos auditados en cada una';

-- -----------------------------------------------------------------------------
-- Llave primaria de una tabla (en orden).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_columnas_pk(p_oid oid)
RETURNS name[]
LANGUAGE sql STABLE
AS $$
    SELECT array_agg(a.attname ORDER BY k.ord)
      FROM pg_constraint c
     CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k (attnum, ord)
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
     WHERE c.conrelid = p_oid
       AND c.contype = 'p';
$$;

-- -----------------------------------------------------------------------------
-- Diccionario de datos completo de un esquema (usado para la documentación).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_diccionario_datos(p_esquema name DEFAULT 'autoaudit')
RETURNS TABLE (
    tabla          name,
    comentario_tabla text,
    posicion       smallint,
    columna        name,
    tipo_dato      text,
    nulo           text,
    valor_defecto  text,
    llave          text,
    referencia     text,
    descripcion    text
)
LANGUAGE sql STABLE
AS $$
    SELECT c.relname,
           obj_description(c.oid, 'pg_class'),
           a.attnum,
           a.attname,
           format_type(a.atttypid, a.atttypmod),
           CASE WHEN a.attnotnull THEN 'NO' ELSE 'SÍ' END,
           coalesce(pg_get_expr(d.adbin, d.adrelid),
                    CASE a.attidentity WHEN 'a' THEN 'IDENTITY (ALWAYS)'
                                       WHEN 'd' THEN 'IDENTITY (BY DEFAULT)' END),
           (SELECT string_agg(CASE k.contype WHEN 'p' THEN 'PK' WHEN 'f' THEN 'FK' WHEN 'u' THEN 'UQ' END,
                              ', ' ORDER BY k.contype DESC)
              FROM pg_constraint k
             WHERE k.conrelid = c.oid AND k.contype IN ('p', 'f', 'u') AND a.attnum = ANY (k.conkey)),
           (SELECT string_agg(k.confrelid::regclass::text, ', ')
              FROM pg_constraint k
             WHERE k.conrelid = c.oid AND k.contype = 'f' AND a.attnum = ANY (k.conkey)),
           col_description(c.oid, a.attnum)
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
      LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
     WHERE n.nspname = p_esquema
       AND c.relkind IN ('r', 'p')
       AND NOT c.relispartition
     ORDER BY c.relname, a.attnum;
$$;
COMMENT ON FUNCTION fn_diccionario_datos(name) IS
    'Diccionario de datos detallado de un esquema (tipos, nulos, llaves, comentarios)';

RESET ROLE;
