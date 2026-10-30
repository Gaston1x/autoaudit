-- =============================================================================
-- AutoAudit - 06_consultas.sql
-- Módulo de consulta: vistas y funciones parametrizadas de consulta histórica.
-- =============================================================================

SET ROLE autoaudit_owner;
SET search_path = autoaudit, pg_catalog;

-- -----------------------------------------------------------------------------
-- IP visible según privilegios: el administrador ve lo almacenado,
-- el lector siempre ve la IP enmascarada (política de privacidad).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_ip_visible(p_ip text)
RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
BEGIN
    IF p_ip IS NULL OR p_ip = 'local' OR p_ip LIKE 'sha256:%'
       OR pg_has_role(session_user, 'autoaudit_admin', 'MEMBER') THEN
        RETURN p_ip;
    END IF;
    RETURN abbrev(network(set_masklen(p_ip::inet,
                  CASE WHEN family(p_ip::inet) = 4 THEN 24 ELSE 48 END)));
EXCEPTION WHEN invalid_text_representation THEN
    RETURN '***';
END;
$$;

-- -----------------------------------------------------------------------------
-- Vista plana de la bitácora: una fila por columna afectada.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_bitacora AS
SELECT b.id               AS bitacora_id,
       b.fecha_hora,
       b.txid,
       ev.nombre          AS operacion,
       t.esquema,
       t.nombre           AS tabla,
       b.pk_registro,
       u.usuario_bd,
       nullif(u.usuario_app, '') AS usuario_app,
       fn_ip_visible(e.ip)       AS ip,
       nullif(e.hostname, '')    AS estacion,
       nullif(e.aplicacion, '')  AS aplicacion,
       ac.nombre          AS columna,
       d.valor_anterior,
       d.valor_nuevo,
       d.configuracion_id,
       b.tabla_id,
       b.usuario_id,
       b.estacion_id
  FROM aud_bitacora b
  JOIN aud_evento   ev ON ev.id = b.evento_id
  JOIN aud_tabla    t  ON t.id  = b.tabla_id
  JOIN aud_usuario  u  ON u.id  = b.usuario_id
  JOIN aud_estacion e  ON e.id  = b.estacion_id
  LEFT JOIN aud_bitacora_detalle d  ON d.bitacora_id = b.id
  LEFT JOIN aud_configuracion    cf ON cf.id = d.configuracion_id
  LEFT JOIN aud_columna          ac ON ac.id = cf.columna_id;
COMMENT ON VIEW v_bitacora IS 'Bitácora completa: una fila por columna afectada, con usuario, estación y valores';

-- Estaciones con la IP según los privilegios de quien consulta.
CREATE OR REPLACE VIEW v_estacion AS
SELECT e.id, fn_ip_visible(e.ip) AS ip, e.hostname, e.aplicacion, e.auditar, e.primera_actividad,
       (SELECT count(*) FROM aud_bitacora b WHERE b.estacion_id = e.id) AS operaciones
  FROM aud_estacion e;
COMMENT ON VIEW v_estacion IS 'Estaciones de trabajo auditadas (IP enmascarada para lectores)';

-- -----------------------------------------------------------------------------
-- Consulta por usuario (usuario de BD o de aplicación): historial completo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cambios_por_usuario(
    p_usuario text,
    p_desde   timestamptz DEFAULT NULL,
    p_hasta   timestamptz DEFAULT NULL,
    p_esquema name        DEFAULT NULL,
    p_tabla   name        DEFAULT NULL
)
RETURNS SETOF v_bitacora
LANGUAGE sql STABLE
SET search_path = autoaudit, pg_catalog
AS $$
    -- Primero se obtienen los ids por índice (usuario_id, fecha_hora) y después
    -- se arman las filas completas: el costo no depende del tamaño de la bitácora.
    SELECT v.*
      FROM v_bitacora v
     WHERE v.bitacora_id = ANY (ARRAY(
               SELECT b.id FROM aud_bitacora b
                WHERE b.usuario_id IN (SELECT id FROM aud_usuario
                                        WHERE usuario_bd = p_usuario OR usuario_app = p_usuario)
                  AND b.fecha_hora >= coalesce(p_desde, '-infinity')
                  AND b.fecha_hora <  coalesce(p_hasta, 'infinity')))
       AND (p_esquema IS NULL OR v.esquema = p_esquema)
       AND (p_tabla   IS NULL OR v.tabla = p_tabla)
     ORDER BY v.fecha_hora, v.bitacora_id, v.columna;
$$;
COMMENT ON FUNCTION fn_cambios_por_usuario(text, timestamptz, timestamptz, name, name) IS
    'Historial completo de cambios realizados por un usuario (de BD o de aplicación)';

-- -----------------------------------------------------------------------------
-- Consulta por columna específica: todos sus cambios.
-- Se enlaza por configuración, así sobrevive a renombres de la columna.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cambios_por_columna(
    p_esquema   name,
    p_tabla     name,
    p_columna   name,
    p_desde     timestamptz DEFAULT NULL,
    p_hasta     timestamptz DEFAULT NULL,
    p_operacion text        DEFAULT NULL
)
RETURNS SETOF v_bitacora
LANGUAGE plpgsql STABLE
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_cfg integer[];
    v_ids bigint[];
BEGIN
    -- 1. Configuraciones de la columna (y operación, si se indicó).
    SELECT array_agg(cf.id) INTO v_cfg
      FROM aud_configuracion cf
      JOIN aud_columna ac ON ac.id = cf.columna_id
      JOIN aud_tabla t    ON t.id  = ac.tabla_id
      JOIN aud_evento e   ON e.id  = cf.evento_id
     WHERE t.esquema = p_esquema AND t.nombre = p_tabla AND ac.nombre = p_columna
       AND (p_operacion IS NULL OR e.nombre = upper(p_operacion));
    IF v_cfg IS NULL THEN
        RETURN;
    END IF;

    -- 2. Registros de bitácora de esas configuraciones (índice del detalle).
    SELECT array_agg(d.bitacora_id) INTO v_ids
      FROM aud_bitacora_detalle d WHERE d.configuracion_id = ANY (v_cfg);
    IF v_ids IS NULL THEN
        RETURN;
    END IF;

    -- 3. Filtro opcional de fechas (por llave primaria de la cabecera).
    IF p_desde IS NOT NULL OR p_hasta IS NOT NULL THEN
        SELECT array_agg(b.id) INTO v_ids
          FROM aud_bitacora b
         WHERE b.id = ANY (v_ids)
           AND b.fecha_hora >= coalesce(p_desde, '-infinity')
           AND b.fecha_hora <  coalesce(p_hasta, 'infinity');
    END IF;

    RETURN QUERY
        SELECT v.* FROM v_bitacora v
         WHERE v.bitacora_id = ANY (v_ids) AND v.configuracion_id = ANY (v_cfg)
         ORDER BY v.fecha_hora, v.bitacora_id;
END;
$$;
COMMENT ON FUNCTION fn_cambios_por_columna(name, name, name, timestamptz, timestamptz, text) IS
    'Todos los cambios registrados en una columna específica';

-- -----------------------------------------------------------------------------
-- Línea de tiempo de un registro (por su llave primaria).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_historial_registro(p_esquema name, p_tabla name, p_pk jsonb)
RETURNS SETOF v_bitacora
LANGUAGE sql STABLE
SET search_path = autoaudit, pg_catalog
AS $$
    SELECT v.*
      FROM v_bitacora v
     WHERE v.bitacora_id = ANY (ARRAY(
               SELECT b.id FROM aud_bitacora b
                WHERE b.tabla_id IN (SELECT id FROM aud_tabla WHERE esquema = p_esquema AND nombre = p_tabla)
                  AND b.pk_registro @> p_pk))
     ORDER BY v.fecha_hora, v.bitacora_id, v.columna;
$$;
COMMENT ON FUNCTION fn_historial_registro(name, name, jsonb) IS
    'Cronología de todos los cambios de un registro identificado por su llave primaria';

-- -----------------------------------------------------------------------------
-- "Viaje en el tiempo": cómo estaba un registro en una fecha dada.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_estado_en_fecha(p_esquema name, p_tabla name, p_pk jsonb, p_fecha timestamptz)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = autoaudit, pg_catalog
AS $$
    SELECT coalesce(
        (SELECT jsonb_build_object(
                    'existia', ev.codigo <> 'D',
                    'fila', CASE WHEN ev.codigo = 'D' THEN NULL ELSE b.fila_nueva END,
                    'ultima_operacion', ev.nombre,
                    'fecha_operacion', b.fecha_hora)
           FROM aud_bitacora b
           JOIN aud_tabla t   ON t.id = b.tabla_id
           JOIN aud_evento ev ON ev.id = b.evento_id
          WHERE t.esquema = p_esquema AND t.nombre = p_tabla
            AND b.pk_registro @> p_pk
            AND b.fecha_hora <= p_fecha
          ORDER BY b.fecha_hora DESC, b.id DESC
          LIMIT 1),
        jsonb_build_object('existia', NULL, 'fila', NULL,
                           'mensaje', 'Sin registros de auditoría hasta esa fecha'));
$$;
COMMENT ON FUNCTION fn_estado_en_fecha(name, name, jsonb, timestamptz) IS
    'Reconstruye el estado de un registro en una fecha a partir de la bitácora';

-- -----------------------------------------------------------------------------
-- Resúmenes para el panel (dashboard).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_actividad_diaria(p_desde timestamptz, p_hasta timestamptz)
RETURNS TABLE (dia date, operacion varchar, total bigint)
LANGUAGE sql STABLE
SET search_path = autoaudit, pg_catalog
AS $$
    SELECT b.fecha_hora::date, ev.nombre, count(*)
      FROM aud_bitacora b JOIN aud_evento ev ON ev.id = b.evento_id
     WHERE b.fecha_hora >= p_desde AND b.fecha_hora < p_hasta
     GROUP BY 1, 2
     ORDER BY 1, 2;
$$;

CREATE OR REPLACE FUNCTION fn_resumen(p_desde timestamptz, p_hasta timestamptz)
RETURNS jsonb
LANGUAGE sql STABLE
SECURITY DEFINER   -- solo devuelve conteos; el lector no lee aud_error directamente
SET search_path = autoaudit, pg_catalog
AS $$
    SELECT jsonb_build_object(
        'operaciones', (SELECT count(*) FROM aud_bitacora WHERE fecha_hora >= p_desde AND fecha_hora < p_hasta),
        'tablas_auditadas', (SELECT count(*) FROM aud_tabla WHERE activa AND NOT eliminada),
        'columnas_auditadas', (SELECT count(*) FROM aud_columna WHERE activa AND NOT eliminada),
        'errores', (SELECT count(*) FROM aud_error WHERE fecha >= p_desde AND fecha < p_hasta),
        'top_usuarios', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
              SELECT u.usuario_bd || coalesce(' / ' || nullif(u.usuario_app, ''), '') AS usuario, count(*) AS total
                FROM aud_bitacora b JOIN aud_usuario u ON u.id = b.usuario_id
               WHERE b.fecha_hora >= p_desde AND b.fecha_hora < p_hasta
               GROUP BY 1 ORDER BY 2 DESC LIMIT 5) x),
        'top_tablas', (SELECT coalesce(jsonb_agg(x), '[]') FROM (
              SELECT t.esquema || '.' || t.nombre AS tabla, count(*) AS total
                FROM aud_bitacora b JOIN aud_tabla t ON t.id = b.tabla_id
               WHERE b.fecha_hora >= p_desde AND b.fecha_hora < p_hasta
               GROUP BY 1 ORDER BY 2 DESC LIMIT 5) x));
$$;

-- -----------------------------------------------------------------------------
-- Estado real de la auditoría: configuración vs triggers existentes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_estado_triggers AS
SELECT t.id AS tabla_id,
       t.esquema,
       t.nombre AS tabla,
       t.activa,
       (SELECT count(*) FROM aud_configuracion cf JOIN aud_columna ac ON ac.id = cf.columna_id
         WHERE ac.tabla_id = t.id AND cf.activa AND NOT ac.eliminada) AS configuraciones_activas,
       g.eventos,
       g.generado,
       g.generado_por,
       CASE
           WHEN NOT t.activa AND g.id IS NULL                            THEN 'SIN_AUDITORIA'
           WHEN t.activa AND g.id IS NULL                                THEN 'PENDIENTE'
           WHEN NOT EXISTS (SELECT 1 FROM pg_trigger p WHERE p.oid = g.trigger_oid AND p.tgrelid = t.oid_tabla)
                                                                         THEN 'TRIGGER_FALTANTE'
           WHEN EXISTS (SELECT 1 FROM pg_trigger p WHERE p.oid = g.trigger_oid AND p.tgenabled = 'D')
                                                                         THEN 'DESHABILITADO'
           WHEN g.hash_ddl <> md5((SELECT d.ddl_funcion || E'\n\n' || d.ddl_trigger
                                     FROM _fn_construir_ddl(t.id) d))    THEN 'DESACTUALIZADO'
           ELSE 'OK'
       END AS estado
  FROM aud_tabla t
  LEFT JOIN aud_trigger g ON g.tabla_id = t.id AND g.estado = 'ACTIVO'
 WHERE NOT t.eliminada;
COMMENT ON VIEW v_estado_triggers IS
    'Compara la configuración con los triggers reales (OK, PENDIENTE, TRIGGER_FALTANTE, DESHABILITADO, DESACTUALIZADO)';

RESET ROLE;
