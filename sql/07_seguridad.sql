-- =============================================================================
-- AutoAudit - 07_seguridad.sql
-- Permisos, bitácora inmutable y administración de usuarios/estaciones.
-- =============================================================================

SET ROLE autoaudit_owner;
SET search_path = autoaudit, pg_catalog;

-- -----------------------------------------------------------------------------
-- Bitácora inmutable: ni siquiera el dueño puede modificar o borrar registros
-- (solo un superusuario deshabilitando explícitamente este trigger).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION _fn_bitacora_inmutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'La tabla %.% es de solo inserción: no se permite %', TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'insufficient_privilege',
              HINT = 'Los registros de auditoría no pueden modificarse ni eliminarse.';
END;
$$;

DROP TRIGGER IF EXISTS aa_inmutable ON aud_bitacora;
CREATE TRIGGER aa_inmutable BEFORE UPDATE OR DELETE ON aud_bitacora
    FOR EACH ROW EXECUTE FUNCTION _fn_bitacora_inmutable();
DROP TRIGGER IF EXISTS aa_inmutable_truncate ON aud_bitacora;
CREATE TRIGGER aa_inmutable_truncate BEFORE TRUNCATE ON aud_bitacora
    FOR EACH STATEMENT EXECUTE FUNCTION _fn_bitacora_inmutable();

DROP TRIGGER IF EXISTS aa_inmutable ON aud_bitacora_detalle;
CREATE TRIGGER aa_inmutable BEFORE UPDATE OR DELETE ON aud_bitacora_detalle
    FOR EACH ROW EXECUTE FUNCTION _fn_bitacora_inmutable();
DROP TRIGGER IF EXISTS aa_inmutable_truncate ON aud_bitacora_detalle;
CREATE TRIGGER aa_inmutable_truncate BEFORE TRUNCATE ON aud_bitacora_detalle
    FOR EACH STATEMENT EXECUTE FUNCTION _fn_bitacora_inmutable();

DROP TRIGGER IF EXISTS aa_inmutable ON aud_cambio_config;
CREATE TRIGGER aa_inmutable BEFORE UPDATE OR DELETE ON aud_cambio_config
    FOR EACH ROW EXECUTE FUNCTION _fn_bitacora_inmutable();

-- -----------------------------------------------------------------------------
-- Administración de usuarios y estaciones auditadas (solo administradores).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_auditar_usuario(p_usuario_id integer, p_auditar boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
BEGIN
    PERFORM fn_exigir_admin();
    UPDATE aud_usuario SET auditar = p_auditar WHERE id = p_usuario_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el usuario auditado %', p_usuario_id;
    END IF;
    INSERT INTO aud_cambio_config (accion, detalle)
    VALUES ('AUDITAR_USUARIO', jsonb_build_object('usuario_id', p_usuario_id, 'auditar', p_auditar));
END;
$$;

CREATE OR REPLACE FUNCTION fn_set_auditar_estacion(p_estacion_id integer, p_auditar boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
BEGIN
    PERFORM fn_exigir_admin();
    UPDATE aud_estacion SET auditar = p_auditar WHERE id = p_estacion_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la estación auditada %', p_estacion_id;
    END IF;
    INSERT INTO aud_cambio_config (accion, detalle)
    VALUES ('AUDITAR_ESTACION', jsonb_build_object('estacion_id', p_estacion_id, 'auditar', p_auditar));
END;
$$;

-- Registra de antemano un usuario de BD (para poder excluirlo antes de que actúe).
CREATE OR REPLACE FUNCTION fn_registrar_usuario(p_usuario_bd name, p_usuario_app text DEFAULT '', p_auditar boolean DEFAULT true)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = autoaudit, pg_catalog
AS $$
DECLARE
    v_id integer;
BEGIN
    PERFORM fn_exigir_admin();
    INSERT INTO aud_usuario (usuario_bd, usuario_app, auditar)
    VALUES (p_usuario_bd, coalesce(p_usuario_app, ''), p_auditar)
    ON CONFLICT (usuario_bd, usuario_app) DO UPDATE SET auditar = EXCLUDED.auditar
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

RESET ROLE;

-- -----------------------------------------------------------------------------
-- Privilegios
-- -----------------------------------------------------------------------------
REVOKE ALL ON SCHEMA autoaudit FROM PUBLIC;
GRANT USAGE ON SCHEMA autoaudit TO autoaudit_admin, autoaudit_lector;

-- Nadie (salvo el dueño) escribe directamente en ninguna tabla del sistema.
REVOKE ALL ON ALL TABLES IN SCHEMA autoaudit FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA autoaudit FROM autoaudit_admin, autoaudit_lector;

-- Lectura.
GRANT SELECT ON autoaudit.aud_tabla, autoaudit.aud_columna, autoaudit.aud_evento,
                autoaudit.aud_configuracion, autoaudit.aud_usuario, autoaudit.aud_trigger,
                autoaudit.aud_bitacora, autoaudit.aud_bitacora_detalle,
                autoaudit.v_bitacora, autoaudit.v_estado_triggers, autoaudit.v_estacion
      TO autoaudit_lector;
-- La IP de la estación solo la ve el administrador (el lector la ve enmascarada en v_bitacora).
GRANT SELECT (id, hostname, aplicacion, auditar, primera_actividad) ON autoaudit.aud_estacion TO autoaudit_lector;
GRANT SELECT ON autoaudit.aud_estacion, autoaudit.aud_error, autoaudit.aud_cambio_config TO autoaudit_admin;
GRANT SELECT (clave, valor, descripcion, modificado, modificado_por) ON autoaudit.aud_parametro TO autoaudit_admin;

-- Funciones: nada es público por defecto.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA autoaudit FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE autoaudit_owner IN SCHEMA autoaudit REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    autoaudit.fn_es_esquema_sistema(name),
    autoaudit.fn_listar_tablas(),
    autoaudit.fn_listar_columnas(name, name),
    autoaudit.fn_columnas_pk(oid),
    autoaudit.fn_diccionario_datos(name),
    autoaudit.fn_ip_visible(text),
    autoaudit.fn_cambios_por_usuario(text, timestamptz, timestamptz, name, name),
    autoaudit.fn_cambios_por_columna(name, name, name, timestamptz, timestamptz, text),
    autoaudit.fn_historial_registro(name, name, jsonb),
    autoaudit.fn_estado_en_fecha(name, name, jsonb, timestamptz),
    autoaudit.fn_actividad_diaria(timestamptz, timestamptz),
    autoaudit.fn_resumen(timestamptz, timestamptz),
    autoaudit._fn_construir_ddl(integer),
    autoaudit._fn_expr_cambio(name, oid)
TO autoaudit_lector;

GRANT EXECUTE ON FUNCTION
    autoaudit.fn_exigir_admin(),
    autoaudit.fn_validar_config(integer),
    autoaudit.fn_configurar_tabla(name, name, jsonb, boolean),
    autoaudit.fn_configurar_columna(name, name, name, boolean, boolean, boolean, boolean),
    autoaudit.fn_desactivar_tabla(name, name),
    autoaudit.fn_set_parametro(text, text),
    autoaudit.fn_generar_trigger(name, name, boolean),
    autoaudit.fn_previsualizar_trigger(name, name),
    autoaudit.fn_regenerar_todos(boolean),
    autoaudit.fn_registrar_error(text, text, text),
    autoaudit.fn_set_auditar_usuario(integer, boolean),
    autoaudit.fn_set_auditar_estacion(integer, boolean),
    autoaudit.fn_registrar_usuario(name, text, boolean)
TO autoaudit_admin;
