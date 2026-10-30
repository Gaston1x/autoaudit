-- =============================================================================
-- AutoAudit - 03_configuracion.sql
-- Módulo de configuración: validación contra el diccionario de datos y
-- persistencia de la configuración en las tablas del sistema.
--
-- Convención:
--   fn_*   funciones públicas (verifican rol administrador)
--   _fn_*  funciones internas (las usan los event triggers; sin EXECUTE público)
-- =============================================================================

SET ROLE autoaudit_owner;
SET search_path = autoaudit, pg_catalog;

-- -----------------------------------------------------------------------------
-- Seguridad: solo administradores configuran.
-- session_user es el usuario real conectado (no cambia con SECURITY DEFINER).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_exigir_admin()
RETURNS void
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
BEGIN
    IF NOT pg_has_role(session_user, 'autoaudit_admin', 'MEMBER') THEN
        RAISE EXCEPTION 'El usuario "%" no tiene privilegios de administrador de auditoría', session_user
            USING ERRCODE = 'insufficient_privilege',
                  HINT = 'Solicite el rol autoaudit_admin.';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- Sincroniza nombres de tabla/columnas con el catálogo (por OID y attnum),
-- y marca como eliminadas las columnas que ya no existen.
-- Devuelve true si la tabla sigue existiendo.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fn_sincronizar_tabla(p_tabla_id integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_oid     oid;
    v_esquema name;
    v_nombre  name;
BEGIN
    SELECT oid_tabla INTO v_oid FROM aud_tabla WHERE id = p_tabla_id;

    SELECT n.nspname, c.relname INTO v_esquema, v_nombre
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = v_oid;

    IF NOT FOUND THEN
        UPDATE aud_tabla
           SET activa = false, eliminada = true, fecha_baja = coalesce(fecha_baja, now())
         WHERE id = p_tabla_id AND NOT eliminada;
        RETURN false;
    END IF;

    UPDATE aud_tabla SET esquema = v_esquema, nombre = v_nombre
     WHERE id = p_tabla_id AND (esquema, nombre) IS DISTINCT FROM (v_esquema, v_nombre);

    -- Renombres y cambios de tipo.
    UPDATE aud_columna ac
       SET nombre = a.attname,
           tipo_dato = format_type(a.atttypid, a.atttypmod)
      FROM pg_attribute a
     WHERE ac.tabla_id = p_tabla_id
       AND a.attrelid = v_oid AND a.attnum = ac.attnum AND NOT a.attisdropped
       AND (ac.nombre, ac.tipo_dato) IS DISTINCT FROM (a.attname, format_type(a.atttypid, a.atttypmod));

    -- Columnas eliminadas.
    UPDATE aud_columna ac
       SET eliminada = true, activa = false
     WHERE ac.tabla_id = p_tabla_id
       AND NOT ac.eliminada
       AND NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = v_oid AND a.attnum = ac.attnum AND NOT a.attisdropped);

    UPDATE aud_configuracion cf
       SET activa = false, modificado = now(), modificado_por = session_user
      FROM aud_columna ac
     WHERE cf.columna_id = ac.id AND ac.tabla_id = p_tabla_id AND ac.eliminada AND cf.activa;

    RETURN true;
END;
$$;

-- -----------------------------------------------------------------------------
-- Valida la configuración de una tabla antes de activar/generar.
-- nivel: ERROR (impide generar), ADVERTENCIA o INFO.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_validar_config(p_tabla_id integer)
RETURNS TABLE (nivel text, mensaje text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_t   aud_tabla%ROWTYPE;
    r     record;
BEGIN
    SELECT * INTO v_t FROM aud_tabla WHERE id = p_tabla_id;
    IF NOT FOUND THEN
        RETURN QUERY SELECT 'ERROR', format('No existe configuración con id %s', p_tabla_id);
        RETURN;
    END IF;

    IF NOT _fn_sincronizar_tabla(p_tabla_id) THEN
        RETURN QUERY SELECT 'ERROR', format('La tabla %I.%I ya no existe en la base de datos', v_t.esquema, v_t.nombre);
        RETURN;
    END IF;

    SELECT * INTO v_t FROM aud_tabla WHERE id = p_tabla_id;

    IF fn_columnas_pk(v_t.oid_tabla) IS NULL THEN
        RETURN QUERY SELECT 'ADVERTENCIA',
            format('La tabla %I.%I no tiene llave primaria: el registro se identificará con la fila completa', v_t.esquema, v_t.nombre);
    END IF;

    FOR r IN
        SELECT ac.nombre FROM aud_columna ac
         WHERE ac.tabla_id = p_tabla_id AND ac.eliminada
           AND EXISTS (SELECT 1 FROM aud_configuracion cf WHERE cf.columna_id = ac.id)
    LOOP
        RETURN QUERY SELECT 'INFO', format('La columna %I fue eliminada de la tabla; su auditoría quedó desactivada', r.nombre);
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM aud_configuracion cf JOIN aud_columna ac ON ac.id = cf.columna_id
                    WHERE ac.tabla_id = p_tabla_id AND cf.activa AND NOT ac.eliminada) THEN
        RETURN QUERY SELECT 'INFO', 'No hay columnas/eventos activos: el trigger de la tabla se eliminará';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- Registra (o reactiva) una tabla, validando que exista en el diccionario.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fn_registrar_tabla(p_esquema name, p_tabla name)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_oid oid;
    v_kind "char";
    v_id integer;
    r record;
BEGIN
    SELECT c.oid, c.relkind INTO v_oid, v_kind
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = p_esquema AND c.relname = p_tabla;

    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'La tabla %.% no existe en la base de datos', p_esquema, p_tabla
            USING ERRCODE = 'undefined_table';
    END IF;
    IF v_kind NOT IN ('r', 'p') THEN
        RAISE EXCEPTION '%.% no es una tabla (vistas y otros objetos no se auditan)', p_esquema, p_tabla
            USING ERRCODE = 'wrong_object_type';
    END IF;
    IF fn_es_esquema_sistema(p_esquema) THEN
        RAISE EXCEPTION 'No se pueden auditar tablas del esquema de sistema %', p_esquema
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Registros viejos con el mismo nombre cuya tabla ya no existe (DROP + CREATE).
    FOR r IN SELECT id FROM aud_tabla
              WHERE esquema = p_esquema AND nombre = p_tabla AND NOT eliminada AND oid_tabla <> v_oid
    LOOP
        PERFORM _fn_sincronizar_tabla(r.id);
    END LOOP;

    INSERT INTO aud_tabla (esquema, nombre, oid_tabla)
    VALUES (p_esquema, p_tabla, v_oid)
    ON CONFLICT (oid_tabla) DO UPDATE
       SET esquema = EXCLUDED.esquema, nombre = EXCLUDED.nombre,
           eliminada = false, fecha_baja = NULL
    RETURNING id INTO v_id;

    PERFORM _fn_sincronizar_tabla(v_id);
    RETURN v_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- Configura la auditoría de una tabla completa.
--   p_columnas: {"columna": ["I","U","D"], ...}
--   Las columnas que no aparezcan quedan sin auditar.
--   p_generar:  si es true, genera/actualiza el trigger inmediatamente.
-- Devuelve un JSON con el resultado (tabla_id, validación, generación).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_configurar_tabla(
    p_esquema  name,
    p_tabla    name,
    p_columnas jsonb,
    p_generar  boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_tid       integer;
    v_oid       oid;
    v_antes     jsonb;
    v_faltantes text;
    v_malos     text;
    v_res       jsonb;
BEGIN
    PERFORM fn_exigir_admin();

    IF p_columnas IS NULL OR jsonb_typeof(p_columnas) <> 'object' THEN
        RAISE EXCEPTION 'p_columnas debe ser un objeto JSON {"columna": ["I","U","D"]}'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_tid := _fn_registrar_tabla(p_esquema, p_tabla);
    SELECT oid_tabla INTO v_oid FROM aud_tabla WHERE id = v_tid;

    -- Validar que todas las columnas existan en el diccionario de datos.
    SELECT string_agg(quote_ident(j.key), ', ') INTO v_faltantes
      FROM jsonb_object_keys(p_columnas) AS j (key)
     WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                        WHERE a.attrelid = v_oid AND a.attname = j.key
                          AND a.attnum > 0 AND NOT a.attisdropped);
    IF v_faltantes IS NOT NULL THEN
        RAISE EXCEPTION 'Columnas inexistentes en %.%: %', p_esquema, p_tabla, v_faltantes
            USING ERRCODE = 'undefined_column';
    END IF;

    -- Validar códigos de evento.
    SELECT string_agg(DISTINCT e.value, ', ') INTO v_malos
      FROM jsonb_each(p_columnas) AS c (key, value)
     CROSS JOIN LATERAL jsonb_array_elements_text(
               CASE WHEN jsonb_typeof(c.value) = 'array' THEN c.value ELSE '["?"]'::jsonb END) AS e (value)
     WHERE upper(e.value) NOT IN ('I', 'U', 'D', 'INSERT', 'UPDATE', 'DELETE');
    IF v_malos IS NOT NULL THEN
        RAISE EXCEPTION 'Eventos no válidos: % (use I, U, D)', v_malos
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT coalesce(jsonb_object_agg(x.columna, x.eventos), '{}') INTO v_antes
      FROM (SELECT ac.nombre AS columna, jsonb_agg(ev.codigo ORDER BY ev.id) AS eventos
              FROM aud_columna ac
              JOIN aud_configuracion cf ON cf.columna_id = ac.id AND cf.activa
              JOIN aud_evento ev ON ev.id = cf.evento_id
             WHERE ac.tabla_id = v_tid
             GROUP BY ac.nombre) x;

    -- Columnas solicitadas.
    INSERT INTO aud_columna (tabla_id, nombre, attnum, tipo_dato)
    SELECT v_tid, a.attname, a.attnum, format_type(a.atttypid, a.atttypmod)
      FROM pg_attribute a
     WHERE a.attrelid = v_oid AND a.attnum > 0 AND NOT a.attisdropped
       AND p_columnas ? a.attname
    ON CONFLICT (tabla_id, attnum) DO UPDATE
       SET nombre = EXCLUDED.nombre, tipo_dato = EXCLUDED.tipo_dato, eliminada = false;

    -- Combinaciones columna x evento deseadas.
    WITH deseado AS (
        SELECT ac.id AS columna_id, ev.id AS evento_id
          FROM aud_columna ac
          JOIN jsonb_each(p_columnas) c (key, value) ON c.key = ac.nombre
         CROSS JOIN LATERAL jsonb_array_elements_text(c.value) e (value)
          JOIN aud_evento ev ON ev.codigo = left(upper(e.value), 1)
         WHERE ac.tabla_id = v_tid AND NOT ac.eliminada
    ),
    activar AS (
        INSERT INTO aud_configuracion (columna_id, evento_id, activa)
        SELECT DISTINCT columna_id, evento_id, true FROM deseado
        ON CONFLICT (columna_id, evento_id) DO UPDATE
           SET activa = true, modificado = now(), modificado_por = session_user
         WHERE NOT aud_configuracion.activa
        RETURNING 1
    )
    UPDATE aud_configuracion cf
       SET activa = false, modificado = now(), modificado_por = session_user
      FROM aud_columna ac
     WHERE cf.columna_id = ac.id AND ac.tabla_id = v_tid AND cf.activa
       AND NOT EXISTS (SELECT 1 FROM deseado d
                        WHERE d.columna_id = cf.columna_id AND d.evento_id = cf.evento_id);

    UPDATE aud_columna ac
       SET activa = EXISTS (SELECT 1 FROM aud_configuracion cf WHERE cf.columna_id = ac.id AND cf.activa)
     WHERE ac.tabla_id = v_tid;

    UPDATE aud_tabla t
       SET activa = EXISTS (SELECT 1 FROM aud_columna ac WHERE ac.tabla_id = t.id AND ac.activa),
           fecha_baja = CASE WHEN EXISTS (SELECT 1 FROM aud_columna ac WHERE ac.tabla_id = t.id AND ac.activa)
                             THEN NULL ELSE now() END
     WHERE t.id = v_tid;

    INSERT INTO aud_cambio_config (accion, tabla_id, detalle)
    VALUES ('CONFIGURAR', v_tid, jsonb_build_object('antes', v_antes, 'despues', p_columnas));

    v_res := jsonb_build_object(
        'tabla_id', v_tid,
        'validacion', (SELECT coalesce(jsonb_agg(jsonb_build_object('nivel', nivel, 'mensaje', mensaje)), '[]')
                         FROM fn_validar_config(v_tid)));

    IF p_generar THEN
        v_res := v_res || jsonb_build_object('generacion', _fn_generar_trigger(v_tid, true, false));
    END IF;

    RETURN v_res;
END;
$$;
COMMENT ON FUNCTION fn_configurar_tabla(name, name, jsonb, boolean) IS
    'Configura columnas y eventos auditados de una tabla y (opcional) genera su trigger';

-- -----------------------------------------------------------------------------
-- Configuración granular de una sola columna.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_configurar_columna(
    p_esquema name,
    p_tabla   name,
    p_columna name,
    p_insert  boolean,
    p_update  boolean,
    p_delete  boolean,
    p_generar boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_actual jsonb;
    v_eventos jsonb;
BEGIN
    PERFORM fn_exigir_admin();

    SELECT coalesce(jsonb_object_agg(x.columna, x.eventos), '{}') INTO v_actual
      FROM (SELECT ac.nombre AS columna, jsonb_agg(ev.codigo ORDER BY ev.id) AS eventos
              FROM aud_tabla t
              JOIN aud_columna ac ON ac.tabla_id = t.id AND NOT ac.eliminada
              JOIN aud_configuracion cf ON cf.columna_id = ac.id AND cf.activa
              JOIN aud_evento ev ON ev.id = cf.evento_id
             WHERE t.esquema = p_esquema AND t.nombre = p_tabla AND NOT t.eliminada
             GROUP BY ac.nombre) x;

    v_eventos := to_jsonb(array_remove(ARRAY[
        CASE WHEN p_insert THEN 'I' END,
        CASE WHEN p_update THEN 'U' END,
        CASE WHEN p_delete THEN 'D' END], NULL));

    IF jsonb_array_length(v_eventos) = 0 THEN
        v_actual := v_actual - p_columna::text;
    ELSE
        v_actual := v_actual || jsonb_build_object(p_columna, v_eventos);
    END IF;

    RETURN fn_configurar_tabla(p_esquema, p_tabla, v_actual, p_generar);
END;
$$;
COMMENT ON FUNCTION fn_configurar_columna(name, name, name, boolean, boolean, boolean, boolean) IS
    'Activa/desactiva INSERT, UPDATE y DELETE para una columna específica';

-- -----------------------------------------------------------------------------
-- Desactiva por completo la auditoría de una tabla (elimina su trigger).
-- La bitácora histórica se conserva.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_desactivar_tabla(p_esquema name, p_tabla name)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
BEGIN
    PERFORM fn_exigir_admin();
    RETURN fn_configurar_tabla(p_esquema, p_tabla, '{}'::jsonb, true);
END;
$$;

-- -----------------------------------------------------------------------------
-- Cambia un parámetro del sistema.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_parametro(p_clave text, p_valor text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_antes text;
BEGIN
    PERFORM fn_exigir_admin();

    IF p_clave = 'modo_ip' AND p_valor NOT IN ('completa', 'enmascarada', 'hash') THEN
        RAISE EXCEPTION 'modo_ip debe ser completa, enmascarada o hash' USING ERRCODE = 'invalid_parameter_value';
    ELSIF p_clave = 'modo_error' AND p_valor NOT IN ('estricto', 'tolerante') THEN
        RAISE EXCEPTION 'modo_error debe ser estricto o tolerante' USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT valor INTO v_antes FROM aud_parametro WHERE clave = p_clave;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Parámetro desconocido: %', p_clave USING ERRCODE = 'invalid_parameter_value';
    END IF;

    UPDATE aud_parametro SET valor = p_valor, modificado = now(), modificado_por = session_user
     WHERE clave = p_clave;

    INSERT INTO aud_cambio_config (accion, detalle)
    VALUES ('PARAMETRO', jsonb_build_object('clave', p_clave,
            'antes', CASE WHEN p_clave = 'sal_ip' THEN '***' ELSE v_antes END,
            'despues', CASE WHEN p_clave = 'sal_ip' THEN '***' ELSE p_valor END));

    -- modo_error cambia el código generado: regenerar los triggers activos.
    IF p_clave = 'modo_error' THEN
        PERFORM _fn_generar_trigger(t.tabla_id, true, true)
           FROM aud_trigger t WHERE t.estado = 'ACTIVO';
    END IF;
END;
$$;

RESET ROLE;
