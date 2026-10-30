-- =============================================================================
-- AutoAudit - 00_roles.sql
-- Roles del sistema. Ejecutar como superusuario (postgres).
--   autoaudit_owner  : dueño de todos los objetos de AutoAudit (NOLOGIN).
--                      Las funciones SECURITY DEFINER se ejecutan con este rol,
--                      por eso es el único que puede escribir en la bitácora.
--   autoaudit_admin  : puede configurar la auditoría y generar triggers.
--   autoaudit_lector : solo puede consultar la bitácora y los reportes.
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_owner') THEN
        CREATE ROLE autoaudit_owner NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_admin') THEN
        CREATE ROLE autoaudit_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autoaudit_lector') THEN
        CREATE ROLE autoaudit_lector NOLOGIN;
    END IF;
END
$$;

-- Un administrador también puede hacer todo lo que hace un lector.
GRANT autoaudit_lector TO autoaudit_admin;

COMMENT ON ROLE autoaudit_owner  IS 'AutoAudit: dueño de objetos; único rol con escritura en la bitácora';
COMMENT ON ROLE autoaudit_admin  IS 'AutoAudit: configura auditoría y genera triggers';
COMMENT ON ROLE autoaudit_lector IS 'AutoAudit: consulta bitácora y reportes';
