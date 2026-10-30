-- =============================================================================
-- AutoAudit - 04_generador_triggers.sql
-- Módulo de generación dinámica de triggers (PL/pgSQL).
--
-- Por cada tabla configurada se genera:
--   * UNA función PL/pgSQL específica  autoaudit.aa_fn_t<id>_<esquema>_<tabla>()
--   * UN trigger AFTER ... FOR EACH ROW  "aa_auditoria" sobre esa única tabla.
-- El código se "desenrolla" con las columnas configuradas (sin bucles ni
-- reflexión en tiempo de ejecución) para minimizar el impacto en rendimiento.
-- =============================================================================

SET ROLE autoaudit_owner;
SET search_path = autoaudit, pg_catalog;

-- -----------------------------------------------------------------------------
-- Contexto de la operación: usuario y estación (con caché por sesión).
-- Devuelve {usuario_id, estacion_id}, o NULL si el usuario/estación está
-- excluido de la auditoría (auditar = false). Un cambio de "auditar" se aplica
-- a las sesiones nuevas o al cambiar autoaudit.usuario_app / autoaudit.estacion.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fn_contexto()
RETURNS integer[]
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_usuario_app text := coalesce(nullif(current_setting('autoaudit.usuario_app', true), ''), '');
    v_estacion    text := coalesce(nullif(current_setting('autoaudit.estacion', true), ''), '');
    v_aplicacion  text := coalesce(current_setting('application_name', true), '');
    v_ip          inet := inet_client_addr();
    v_clave       text;
    v_cache       text;
    v_uid         integer;
    v_eid         integer;
    v_u_auditar   boolean;
    v_e_auditar   boolean;
    v_modo        text;
    v_ip_reg      text;
BEGIN
    v_clave := md5(concat_ws('|', session_user, v_usuario_app, host(v_ip), v_aplicacion, v_estacion));
    v_cache := current_setting('autoaudit._ctx', true);

    IF v_cache IS NOT NULL AND split_part(v_cache, '#', 1) = v_clave THEN
        IF split_part(v_cache, '#', 2) = '' THEN
            RETURN NULL;
        END IF;
        RETURN ARRAY[split_part(v_cache, '#', 2)::integer, split_part(v_cache, '#', 3)::integer];
    END IF;

    -- Usuario
    SELECT id, auditar INTO v_uid, v_u_auditar
      FROM aud_usuario WHERE usuario_bd = session_user AND usuario_app = v_usuario_app;
    IF NOT FOUND THEN
        INSERT INTO aud_usuario (usuario_bd, usuario_app)
        VALUES (session_user, v_usuario_app)
        ON CONFLICT (usuario_bd, usuario_app) DO UPDATE SET usuario_app = EXCLUDED.usuario_app
        RETURNING id, auditar INTO v_uid, v_u_auditar;
    END IF;

    -- IP según la política de privacidad
    SELECT valor INTO v_modo FROM aud_parametro WHERE clave = 'modo_ip';
    v_ip_reg := CASE
        WHEN v_ip IS NULL THEN 'local'
        WHEN v_modo = 'completa' THEN host(v_ip)
        WHEN v_modo = 'hash' THEN
            'sha256:' || left(encode(sha256(convert_to(
                host(v_ip) || coalesce((SELECT valor FROM aud_parametro WHERE clave = 'sal_ip'), ''),
                'UTF8')), 'hex'), 32)
        ELSE abbrev(network(set_masklen(v_ip, CASE WHEN family(v_ip) = 4 THEN 24 ELSE 48 END)))
    END;

    -- Estación
    SELECT id, auditar INTO v_eid, v_e_auditar
      FROM aud_estacion WHERE ip = v_ip_reg AND hostname = v_estacion AND aplicacion = v_aplicacion;
    IF NOT FOUND THEN
        INSERT INTO aud_estacion (ip, hostname, aplicacion)
        VALUES (v_ip_reg, v_estacion, v_aplicacion)
        ON CONFLICT (ip, hostname, aplicacion) DO UPDATE SET aplicacion = EXCLUDED.aplicacion
        RETURNING id, auditar INTO v_eid, v_e_auditar;
    END IF;

    -- Caché por sesión (is_local = false). Si la transacción se revierte, PostgreSQL
    -- revierte también este set_config, así nunca queda un id inexistente en caché.
    IF NOT (v_u_auditar AND v_e_auditar) THEN
        PERFORM set_config('autoaudit._ctx', v_clave || '##', false);
        RETURN NULL;
    END IF;

    PERFORM set_config('autoaudit._ctx', v_clave || '#' || v_uid || '#' || v_eid, false);
    RETURN ARRAY[v_uid, v_eid];
END;
$$;
COMMENT ON FUNCTION _fn_contexto() IS
    'Obtiene usuario y estación de la operación actual (caché por transacción)';

-- -----------------------------------------------------------------------------
-- Expresión "la columna cambió" adecuada al tipo de dato.
-- Tipos sin operador "=" (json, xml, point...) y arreglos se comparan como texto.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fn_expr_cambio(p_columna name, p_tipo oid)
RETURNS text
LANGUAGE sql STABLE
AS $$
    SELECT CASE
        WHEN EXISTS (SELECT 1 FROM pg_type t WHERE t.oid = p_tipo AND t.typcategory <> 'A')
         AND EXISTS (SELECT 1 FROM pg_operator o
                      WHERE o.oprname = '=' AND o.oprleft = p_tipo AND o.oprright = p_tipo)
        THEN format('NEW.%1$I IS DISTINCT FROM OLD.%1$I', p_columna)
        ELSE format('NEW.%1$I::text IS DISTINCT FROM OLD.%1$I::text', p_columna)
    END;
$$;

-- -----------------------------------------------------------------------------
-- Construye (sin ejecutar) el SQL de la función y el trigger de una tabla.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fn_construir_ddl(
    p_tabla_id      integer,
    OUT nombre_funcion name,
    OUT relacion       text,
    OUT eventos        text,
    OUT ddl_funcion    text,
    OUT ddl_trigger    text,
    OUT total_config   integer
)
LANGUAGE plpgsql STABLE
SECURITY DEFINER   -- solo lectura; lo usa también la vista v_estado_triggers
SET search_path = autoaudit, pg_catalog
AS $gen$
DECLARE
    v_t        aud_tabla%ROWTYPE;
    v_pk       name[];
    v_pk_new   text;
    v_pk_old   text;
    v_vals_i   text;
    v_vals_u   text;
    v_vals_d   text;
    v_cond_u   text;
    v_cols_u   text;
    v_modo     text;
    v_cuerpo   text := '';
    v_evts     text[] := '{}';
    v_codigos  text[] := '{}';
    v_det      text := 'INSERT INTO autoaudit.aud_bitacora_detalle (bitacora_id, configuracion_id, valor_anterior, valor_nuevo)';
    v_cab      text := 'INSERT INTO autoaudit.aud_bitacora (fecha_hora, tabla_id, evento_id, usuario_id, estacion_id, txid, pk_registro, fila_anterior, fila_nueva)';
BEGIN
    SELECT * INTO v_t FROM aud_tabla WHERE id = p_tabla_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la tabla configurada con id %', p_tabla_id;
    END IF;

    relacion := format('%I.%I', v_t.esquema, v_t.nombre);

    -- Mantener el nombre de función ya existente (sobrevive a renombres de la tabla).
    SELECT g.nombre_funcion INTO nombre_funcion
      FROM aud_trigger g WHERE g.tabla_id = p_tabla_id AND g.estado = 'ACTIVO';
    nombre_funcion := coalesce(nombre_funcion,
        left(format('aa_fn_t%s_%s', p_tabla_id,
             regexp_replace(lower(v_t.esquema || '_' || v_t.nombre), '[^a-z0-9_]', '_', 'g')), 63));

    -- Llave primaria para identificar el registro.
    v_pk := fn_columnas_pk(v_t.oid_tabla);
    IF v_pk IS NULL THEN
        v_pk_new := 'to_jsonb(NEW)';
        v_pk_old := 'to_jsonb(OLD)';
    ELSE
        SELECT 'jsonb_build_object(' || string_agg(format('%L, NEW.%I', c, c), ', ') || ')',
               'jsonb_build_object(' || string_agg(format('%L, OLD.%I', c, c), ', ') || ')'
          INTO v_pk_new, v_pk_old
          FROM unnest(v_pk) AS c;
    END IF;

    -- Configuración activa, desenrollada por evento.
    WITH cfg AS (
        SELECT cf.id AS cfg_id, cf.evento_id, ac.nombre, ac.attnum, a.atttypid
          FROM aud_configuracion cf
          JOIN aud_columna ac ON ac.id = cf.columna_id
          JOIN pg_attribute a ON a.attrelid = v_t.oid_tabla AND a.attnum = ac.attnum AND NOT a.attisdropped
         WHERE ac.tabla_id = p_tabla_id AND cf.activa AND ac.activa AND NOT ac.eliminada
    )
    SELECT count(*)::integer,
           string_agg(format('(v_id, %s, NULL::text, NEW.%I::text)', cfg_id, nombre),
                      E',\n               ' ORDER BY attnum) FILTER (WHERE evento_id = 1),
           string_agg(format('(%s, OLD.%I::text, NEW.%I::text, %s)', cfg_id, nombre, nombre,
                             _fn_expr_cambio(nombre, atttypid)),
                      E',\n                       ' ORDER BY attnum) FILTER (WHERE evento_id = 2),
           string_agg(_fn_expr_cambio(nombre, atttypid), E'\n               OR ' ORDER BY attnum)
                      FILTER (WHERE evento_id = 2),
           string_agg(quote_ident(nombre), ', ' ORDER BY attnum) FILTER (WHERE evento_id = 2),
           string_agg(format('(v_id, %s, OLD.%I::text, NULL::text)', cfg_id, nombre),
                      E',\n               ' ORDER BY attnum) FILTER (WHERE evento_id = 3)
      INTO total_config, v_vals_i, v_vals_u, v_cond_u, v_cols_u, v_vals_d
      FROM cfg;

    IF total_config = 0 THEN
        eventos := '';
        RETURN;
    END IF;

    IF v_vals_i IS NOT NULL THEN
        v_evts := v_evts || 'INSERT'::text;
        v_codigos := v_codigos || 'I'::text;
        v_cuerpo := v_cuerpo || format($b$
    %sIF TG_OP = 'INSERT' THEN
        %s
        VALUES (v_fecha, %s, 1, v_ctx[1], v_ctx[2], pg_current_xact_id()::text::bigint, %s, NULL, to_jsonb(NEW))
        RETURNING id INTO v_id;
        %s
        VALUES %s;
$b$, '', v_cab, p_tabla_id, v_pk_new, v_det, v_vals_i);
    END IF;

    IF v_vals_u IS NOT NULL THEN
        v_evts := v_evts || format('UPDATE OF %s', v_cols_u);
        v_codigos := v_codigos || 'U'::text;
        v_cuerpo := v_cuerpo || format($b$
    %sIF TG_OP = 'UPDATE' THEN
        IF NOT (%s) THEN
            RETURN NULL;  -- ninguna columna auditada cambió realmente
        END IF;
        %s
        VALUES (v_fecha, %s, 2, v_ctx[1], v_ctx[2], pg_current_xact_id()::text::bigint, %s, to_jsonb(OLD), to_jsonb(NEW))
        RETURNING id INTO v_id;
        %s
        SELECT v_id, v.cfg, v.anterior, v.nuevo
          FROM (VALUES %s) AS v (cfg, anterior, nuevo, cambio)
         WHERE v.cambio;
$b$, CASE WHEN v_cuerpo = '' THEN '' ELSE 'ELS' END, v_cond_u, v_cab, p_tabla_id, v_pk_new, v_det, v_vals_u);
    END IF;

    IF v_vals_d IS NOT NULL THEN
        v_evts := v_evts || 'DELETE'::text;
        v_codigos := v_codigos || 'D'::text;
        v_cuerpo := v_cuerpo || format($b$
    %sIF TG_OP = 'DELETE' THEN
        %s
        VALUES (v_fecha, %s, 3, v_ctx[1], v_ctx[2], pg_current_xact_id()::text::bigint, %s, to_jsonb(OLD), NULL)
        RETURNING id INTO v_id;
        %s
        VALUES %s;
$b$, CASE WHEN v_cuerpo = '' THEN '' ELSE 'ELS' END, v_cab, p_tabla_id, v_pk_old, v_det, v_vals_d);
    END IF;

    v_cuerpo := v_cuerpo || E'    END IF;\n';
    eventos := array_to_string(v_codigos, ',');

    SELECT valor INTO v_modo FROM aud_parametro WHERE clave = 'modo_error';

    ddl_funcion := format($f$CREATE OR REPLACE FUNCTION autoaudit.%I()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, autoaudit
AS $aa$
-- Generado por AutoAudit para %s (tabla_id %s). No editar: se regenera desde la configuración.
DECLARE
    v_ctx   integer[];
    v_id    bigint;
    v_fecha timestamptz := clock_timestamp();
BEGIN
    v_ctx := autoaudit._fn_contexto();
    IF v_ctx IS NULL THEN
        RETURN NULL;  -- usuario o estación excluidos de la auditoría
    END IF;
%s
    RETURN NULL;%s
END;
$aa$;$f$,
        nombre_funcion, relacion, p_tabla_id, v_cuerpo,
        CASE WHEN v_modo = 'tolerante' THEN format($e$
EXCEPTION WHEN OTHERS THEN
    -- modo_error = tolerante: se registra el fallo y la operación de negocio continúa.
    INSERT INTO autoaudit.aud_error (contexto, tabla_id, sqlstate, mensaje, detalle)
    VALUES ('EJECUCION', %s, SQLSTATE, SQLERRM, TG_OP || ' en %s');
    RETURN NULL;$e$, p_tabla_id, relacion)
        ELSE '' END);

    ddl_trigger := format(
        E'CREATE OR REPLACE TRIGGER aa_auditoria\nAFTER %s ON %s\nFOR EACH ROW EXECUTE FUNCTION autoaudit.%I();',
        array_to_string(v_evts, ' OR '), relacion, nombre_funcion);
END;
$gen$;

-- -----------------------------------------------------------------------------
-- Genera (o elimina) el trigger de una tabla según su configuración actual.
--   p_aplicar = false  -> solo devuelve el SQL (vista previa)
--   p_forzar  = true   -> recrea aunque el código no haya cambiado
-- Nunca deja triggers a medias: cualquier error revierte la generación,
-- se registra en aud_error y se devuelve {"ok": false, "mensaje": ...}.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fn_generar_trigger(
    p_tabla_id integer,
    p_aplicar  boolean DEFAULT true,
    p_forzar   boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_t       aud_tabla%ROWTYPE;
    v_d       record;
    v_actual  aud_trigger%ROWTYPE;
    v_ddl     text;
    v_hash    text;
    v_oid     oid;
    v_errores text;
    v_estado  text;
    v_detalle text;
BEGIN
    SELECT * INTO v_t FROM aud_tabla WHERE id = p_tabla_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'mensaje', format('No existe la tabla configurada con id %s', p_tabla_id));
    END IF;

    -- Validación previa contra el diccionario de datos.
    SELECT string_agg(mensaje, '; ') INTO v_errores FROM fn_validar_config(p_tabla_id) WHERE nivel = 'ERROR';
    IF v_errores IS NOT NULL THEN
        IF p_aplicar THEN
            INSERT INTO aud_error (contexto, tabla_id, mensaje) VALUES ('VALIDACION', p_tabla_id, v_errores);
        END IF;
        RETURN jsonb_build_object('ok', false, 'accion', 'VALIDACION', 'mensaje', v_errores);
    END IF;

    SELECT * INTO v_t FROM aud_tabla WHERE id = p_tabla_id;   -- nombres sincronizados
    SELECT * INTO v_d FROM _fn_construir_ddl(p_tabla_id);
    SELECT * INTO v_actual FROM aud_trigger WHERE tabla_id = p_tabla_id AND estado = 'ACTIVO';

    -- Sin configuración activa: eliminar trigger y función.
    IF v_d.total_config = 0 THEN
        v_ddl := format(E'DROP TRIGGER IF EXISTS aa_auditoria ON %s;\nDROP FUNCTION IF EXISTS autoaudit.%I();',
                        v_d.relacion, v_d.nombre_funcion);
        IF NOT p_aplicar THEN
            RETURN jsonb_build_object('ok', true, 'accion', 'VISTA_PREVIA', 'ddl', v_ddl);
        END IF;
        IF v_actual.id IS NULL THEN
            RETURN jsonb_build_object('ok', true, 'accion', 'SIN_TRIGGER', 'mensaje', 'La tabla no tiene auditoría activa');
        END IF;
        BEGIN
            PERFORM set_config('autoaudit.en_generacion', 'on', true);
            EXECUTE format('DROP TRIGGER IF EXISTS aa_auditoria ON %s', v_d.relacion);
            EXECUTE format('DROP FUNCTION IF EXISTS autoaudit.%I()', v_d.nombre_funcion);
            PERFORM set_config('autoaudit.en_generacion', 'off', true);
        EXCEPTION WHEN OTHERS THEN
            PERFORM set_config('autoaudit.en_generacion', 'off', true);
            GET STACKED DIAGNOSTICS v_estado = RETURNED_SQLSTATE, v_detalle = PG_EXCEPTION_HINT;
            INSERT INTO aud_error (contexto, tabla_id, sqlstate, mensaje, detalle)
            VALUES ('GENERACION', p_tabla_id, v_estado, SQLERRM, nullif(v_detalle, ''));
            RETURN jsonb_build_object('ok', false, 'accion', 'ERROR', 'mensaje', SQLERRM, 'sqlstate', v_estado);
        END;
        UPDATE aud_trigger SET estado = 'ELIMINADO' WHERE id = v_actual.id;
        INSERT INTO aud_cambio_config (accion, tabla_id, detalle)
        VALUES ('ELIMINAR_TRIGGER', p_tabla_id, jsonb_build_object('trigger', v_actual.nombre_trigger));
        RETURN jsonb_build_object('ok', true, 'accion', 'ELIMINADO', 'ddl', v_ddl,
                                  'mensaje', format('Trigger de %s eliminado', v_d.relacion));
    END IF;

    v_ddl  := v_d.ddl_funcion || E'\n\n' || v_d.ddl_trigger;
    v_hash := md5(v_ddl);

    IF NOT p_aplicar THEN
        RETURN jsonb_build_object('ok', true, 'accion', 'VISTA_PREVIA', 'ddl', v_ddl, 'eventos', v_d.eventos);
    END IF;

    IF NOT p_forzar AND v_actual.hash_ddl = v_hash
       AND EXISTS (SELECT 1 FROM pg_trigger WHERE oid = v_actual.trigger_oid AND tgrelid = v_t.oid_tabla) THEN
        RETURN jsonb_build_object('ok', true, 'accion', 'SIN_CAMBIOS', 'ddl', v_ddl,
                                  'mensaje', format('El trigger de %s ya está actualizado', v_d.relacion));
    END IF;

    BEGIN
        PERFORM set_config('autoaudit.en_generacion', 'on', true);
        EXECUTE v_d.ddl_funcion;
        EXECUTE format('REVOKE ALL ON FUNCTION autoaudit.%I() FROM PUBLIC', v_d.nombre_funcion);
        EXECUTE v_d.ddl_trigger;
        PERFORM set_config('autoaudit.en_generacion', 'off', true);
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('autoaudit.en_generacion', 'off', true);
        GET STACKED DIAGNOSTICS v_estado = RETURNED_SQLSTATE, v_detalle = PG_EXCEPTION_HINT;
        INSERT INTO aud_error (contexto, tabla_id, sqlstate, mensaje, detalle)
        VALUES ('GENERACION', p_tabla_id, v_estado, SQLERRM,
                concat_ws(E'\n', nullif(v_detalle, ''), 'SQL: ' || left(v_ddl, 2000)));
        RETURN jsonb_build_object('ok', false, 'accion', 'ERROR', 'mensaje', SQLERRM,
                                  'sqlstate', v_estado, 'hint', nullif(v_detalle, ''));
    END;

    SELECT oid INTO v_oid FROM pg_trigger WHERE tgrelid = v_t.oid_tabla AND tgname = 'aa_auditoria';

    UPDATE aud_trigger SET estado = 'REEMPLAZADO' WHERE id = v_actual.id;
    INSERT INTO aud_trigger (tabla_id, nombre_trigger, nombre_funcion, trigger_oid, eventos, ddl, hash_ddl, estado)
    VALUES (p_tabla_id, 'aa_auditoria', v_d.nombre_funcion, v_oid, v_d.eventos, v_ddl, v_hash, 'ACTIVO');

    INSERT INTO aud_cambio_config (accion, tabla_id, detalle)
    VALUES ('GENERAR', p_tabla_id, jsonb_build_object('eventos', v_d.eventos, 'hash', v_hash));

    RETURN jsonb_build_object('ok', true,
                              'accion', CASE WHEN v_actual.id IS NULL THEN 'CREADO' ELSE 'ACTUALIZADO' END,
                              'eventos', v_d.eventos, 'ddl', v_ddl,
                              'mensaje', format('Trigger de %s generado (%s)', v_d.relacion, v_d.eventos));
END;
$$;

-- -----------------------------------------------------------------------------
-- API pública (solo administradores)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_generar_trigger(p_esquema name, p_tabla name, p_forzar boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_id integer;
BEGIN
    PERFORM fn_exigir_admin();
    SELECT id INTO v_id FROM aud_tabla WHERE esquema = p_esquema AND nombre = p_tabla AND NOT eliminada;
    IF v_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'mensaje', format('La tabla %s.%s no está configurada', p_esquema, p_tabla));
    END IF;
    RETURN _fn_generar_trigger(v_id, true, p_forzar);
END;
$$;
COMMENT ON FUNCTION fn_generar_trigger(name, name, boolean) IS
    'Genera o actualiza el trigger de auditoría de una tabla según su configuración';

CREATE OR REPLACE FUNCTION fn_previsualizar_trigger(p_esquema name, p_tabla name)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_id integer;
BEGIN
    PERFORM fn_exigir_admin();
    SELECT id INTO v_id FROM aud_tabla WHERE esquema = p_esquema AND nombre = p_tabla AND NOT eliminada;
    IF v_id IS NULL THEN
        RETURN '-- La tabla no está configurada';
    END IF;
    RETURN coalesce(_fn_generar_trigger(v_id, false, false) ->> 'ddl',
                    _fn_generar_trigger(v_id, false, false) ->> 'mensaje');
END;
$$;
COMMENT ON FUNCTION fn_previsualizar_trigger(name, name) IS
    'Devuelve el SQL que se generaría para la tabla, sin ejecutarlo';

CREATE OR REPLACE FUNCTION fn_regenerar_todos(p_forzar boolean DEFAULT false)
RETURNS TABLE (tabla text, ok boolean, accion text, mensaje text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    r   record;
    v_r jsonb;
BEGIN
    PERFORM fn_exigir_admin();
    FOR r IN SELECT id, format('%I.%I', esquema, nombre) AS rel FROM aud_tabla WHERE NOT eliminada ORDER BY id LOOP
        v_r := _fn_generar_trigger(r.id, true, p_forzar);
        tabla := r.rel; ok := (v_r ->> 'ok')::boolean; accion := v_r ->> 'accion'; mensaje := v_r ->> 'mensaje';
        RETURN NEXT;
    END LOOP;
END;
$$;

-- Permite que la aplicación registre errores ocurridos fuera de la BD.
CREATE OR REPLACE FUNCTION fn_registrar_error(p_contexto text, p_mensaje text, p_detalle text DEFAULT NULL)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
    INSERT INTO aud_error (contexto, mensaje, detalle) VALUES (left(p_contexto, 60), p_mensaje, p_detalle);
$$;

RESET ROLE;
