-- =============================================================================
-- AutoAudit - 05_event_triggers.sql
-- Gestión de dependencias entre triggers y tablas origen mediante
-- EVENT TRIGGERS (se disparan ante cualquier DDL en la base de datos):
--   * DROP TABLE auditada         -> configuración marcada como eliminada
--   * DROP COLUMN auditada        -> columna desactivada y trigger regenerado
--   * RENAME tabla/columna        -> nombres sincronizados y trigger regenerado
--   * DROP TRIGGER manual         -> estado ELIMINADO_EXTERNO + registro de quién lo hizo
--   * DISABLE TRIGGER manual      -> registro de quién lo hizo
-- Requiere superusuario para CREATE EVENT TRIGGER.
-- =============================================================================

SET ROLE autoaudit_owner;
SET search_path = autoaudit, pg_catalog;

CREATE OR REPLACE FUNCTION _fn_evt_sql_drop()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    r        record;
    v_id     integer;
    v_fn     name;
    v_tablas integer[] := '{}';
    v_res    jsonb;
BEGIN
    -- Los DROP que hace el propio generador no se procesan.
    IF current_setting('autoaudit.en_generacion', true) = 'on' THEN
        RETURN;
    END IF;

    FOR r IN SELECT * FROM pg_event_trigger_dropped_objects() LOOP
        v_id := NULL;

        IF r.object_type = 'table' THEN
            UPDATE aud_tabla
               SET activa = false, eliminada = true, fecha_baja = now()
             WHERE oid_tabla = r.objid AND NOT eliminada
            RETURNING id INTO v_id;

            IF v_id IS NOT NULL THEN
                UPDATE aud_columna SET activa = false WHERE tabla_id = v_id;
                UPDATE aud_configuracion cf SET activa = false, modificado = now(), modificado_por = session_user
                  FROM aud_columna ac WHERE cf.columna_id = ac.id AND ac.tabla_id = v_id AND cf.activa;
                UPDATE aud_trigger SET estado = 'TABLA_ELIMINADA'
                 WHERE tabla_id = v_id AND estado = 'ACTIVO'
                RETURNING nombre_funcion INTO v_fn;

                IF v_fn IS NOT NULL THEN
                    PERFORM set_config('autoaudit.en_generacion', 'on', true);
                    EXECUTE format('DROP FUNCTION IF EXISTS autoaudit.%I()', v_fn);
                    PERFORM set_config('autoaudit.en_generacion', 'off', true);
                END IF;

                INSERT INTO aud_cambio_config (accion, tabla_id, detalle)
                VALUES ('DDL_DROP_TABLE', v_id, jsonb_build_object('objeto', r.object_identity));
            END IF;

        ELSIF r.object_type = 'table column' THEN
            SELECT t.id INTO v_id
              FROM aud_tabla t
              JOIN aud_columna ac ON ac.tabla_id = t.id AND ac.attnum = r.objsubid
             WHERE t.oid_tabla = r.objid AND NOT t.eliminada;

            IF v_id IS NOT NULL AND NOT v_id = ANY (v_tablas) THEN
                v_tablas := v_tablas || v_id;
                INSERT INTO aud_cambio_config (accion, tabla_id, detalle)
                VALUES ('DDL_DROP_COLUMN', v_id, jsonb_build_object('objeto', r.object_identity));
            END IF;

        ELSIF r.object_type = 'trigger' AND r.original THEN
            UPDATE aud_trigger SET estado = 'ELIMINADO_EXTERNO'
             WHERE trigger_oid = r.objid AND estado = 'ACTIVO'
            RETURNING tabla_id INTO v_id;

            IF v_id IS NOT NULL THEN
                INSERT INTO aud_cambio_config (accion, tabla_id, detalle)
                VALUES ('DDL_DROP_TRIGGER', v_id, jsonb_build_object('objeto', r.object_identity,
                        'advertencia', 'Trigger de auditoría eliminado manualmente'));
                INSERT INTO aud_error (contexto, tabla_id, mensaje)
                VALUES ('DDL', v_id, format('El trigger %s fue eliminado manualmente por %s', r.object_identity, session_user));
            END IF;
        END IF;
    END LOOP;

    -- Tablas con columnas eliminadas: sincronizar y regenerar el trigger.
    FOREACH v_id IN ARRAY v_tablas LOOP
        PERFORM _fn_sincronizar_tabla(v_id);
        UPDATE aud_columna ac SET activa = EXISTS (SELECT 1 FROM aud_configuracion cf WHERE cf.columna_id = ac.id AND cf.activa)
         WHERE ac.tabla_id = v_id;
        v_res := _fn_generar_trigger(v_id, true, true);
        IF NOT (v_res ->> 'ok')::boolean THEN
            RAISE WARNING 'AutoAudit: no se pudo regenerar el trigger de la tabla %: %', v_id, v_res ->> 'mensaje';
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION _fn_evt_ddl_end()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    r       record;
    v_id    integer;
    v_antes text;
    v_desp  text;
    v_res   jsonb;
BEGIN
    IF current_setting('autoaudit.en_generacion', true) = 'on' THEN
        RETURN;
    END IF;

    FOR r IN SELECT DISTINCT objid
               FROM pg_event_trigger_ddl_commands()
              WHERE command_tag = 'ALTER TABLE'
                AND classid = 'pg_class'::regclass
    LOOP
        SELECT id, format('%I.%I', esquema, nombre) INTO v_id, v_antes
          FROM aud_tabla WHERE oid_tabla = r.objid AND NOT eliminada;
        CONTINUE WHEN v_id IS NULL;

        PERFORM _fn_sincronizar_tabla(v_id);
        SELECT format('%I.%I', esquema, nombre) INTO v_desp FROM aud_tabla WHERE id = v_id;

        -- Regenera solo si el código resultante cambió (renombres, tipos...).
        v_res := _fn_generar_trigger(v_id, true, false);
        IF v_res ->> 'accion' IN ('CREADO', 'ACTUALIZADO') OR v_antes <> v_desp THEN
            INSERT INTO aud_cambio_config (accion, tabla_id, detalle)
            VALUES ('DDL_ALTER_TABLE', v_id, jsonb_build_object('antes', v_antes, 'despues', v_desp,
                                                                'regeneracion', v_res ->> 'accion'));
        END IF;
        IF NOT (v_res ->> 'ok')::boolean THEN
            RAISE WARNING 'AutoAudit: no se pudo regenerar el trigger de %: %', v_desp, v_res ->> 'mensaje';
        END IF;

        -- ¿Alguien deshabilitó el trigger de auditoría?
        IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = r.objid AND tgname = 'aa_auditoria' AND tgenabled = 'D') THEN
            INSERT INTO aud_cambio_config (accion, tabla_id, detalle)
            VALUES ('DDL_DISABLE_TRIGGER', v_id, jsonb_build_object('tabla', v_desp,
                    'advertencia', 'Trigger de auditoría deshabilitado manualmente'));
        END IF;
    END LOOP;
END;
$$;

RESET ROLE;

-- Los event triggers solo los puede crear un superusuario.
DROP EVENT TRIGGER IF EXISTS autoaudit_sql_drop;
CREATE EVENT TRIGGER autoaudit_sql_drop ON sql_drop
    EXECUTE FUNCTION autoaudit._fn_evt_sql_drop();

DROP EVENT TRIGGER IF EXISTS autoaudit_ddl_end;
CREATE EVENT TRIGGER autoaudit_ddl_end ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE')
    EXECUTE FUNCTION autoaudit._fn_evt_ddl_end();

COMMENT ON EVENT TRIGGER autoaudit_sql_drop IS 'AutoAudit: mantiene la configuración ante DROP TABLE/COLUMN/TRIGGER';
COMMENT ON EVENT TRIGGER autoaudit_ddl_end  IS 'AutoAudit: sincroniza renombres y regenera triggers ante ALTER TABLE';
