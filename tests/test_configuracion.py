"""Pruebas del módulo de configuración, gestión de dependencias (DDL) y manejo de errores."""

import psycopg
import pytest

from app import servicios
from conftest import cabeceras, configurar

TODO = {"nombre": ["I", "U", "D"], "salario": ["I", "U", "D"], "puesto": ["I", "U", "D"]}


def _eventos_trigger(su, tabla) -> str:
    return su.execute(
        "SELECT pg_get_triggerdef(oid) AS d FROM pg_trigger WHERE tgrelid = %s::regclass AND tgname = 'aa_auditoria'",
        (f"demo.{tabla}",)).fetchone()["d"]


# ------------------------------------------------------------------ validación
def test_tabla_inexistente(su):
    with pytest.raises(psycopg.errors.UndefinedTable, match="no existe"):
        configurar(su, "no_existe", {"x": ["I"]})


def test_columna_inexistente(su, tabla):
    with pytest.raises(psycopg.errors.UndefinedColumn, match="columna_falsa"):
        configurar(su, tabla, {"columna_falsa": ["I"]})


def test_evento_invalido(su, tabla):
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="Eventos no válidos"):
        configurar(su, tabla, {"nombre": ["X"]})


def test_no_se_auditan_tablas_del_sistema(su):
    with pytest.raises(psycopg.Error):
        su.execute("SELECT autoaudit.fn_configurar_tabla('autoaudit', 'aud_bitacora', '{\"id\": [\"I\"]}')")


def test_diccionario_lista_tablas_y_columnas(su, tabla):
    tablas = {(t["esquema"], t["tabla"]) for t in servicios.listar_tablas(su)}
    assert ("demo", tabla) in tablas
    assert not any(e == "autoaudit" for e, _ in tablas)  # nunca se ofrecen tablas del sistema
    cols = servicios.listar_columnas(su, "demo", tabla)
    assert [c["columna"] for c in cols] == ["id", "nombre", "salario", "puesto", "notas", "datos"]
    assert cols[0]["es_pk"] is True


# ------------------------------------------------------------------ estado de la configuración
def test_desactivar_evento_lo_quita_del_trigger(su, cajero, tabla):
    configurar(su, tabla, TODO)
    assert "INSERT" in _eventos_trigger(su, tabla)
    configurar(su, tabla, {"nombre": ["U", "D"], "salario": ["U", "D"], "puesto": ["U", "D"]})
    definicion = _eventos_trigger(su, tabla)
    assert "INSERT" not in definicion and "UPDATE OF" in definicion
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('Sin auditar')")
    assert cabeceras(su, tabla) == []


def test_configuracion_refleja_estado_actual(su, tabla):
    configurar(su, tabla, {"nombre": ["I", "U"]})
    cols = {c["columna"]: c for c in servicios.listar_columnas(su, "demo", tabla)}
    assert (cols["nombre"]["audita_insert"], cols["nombre"]["audita_update"], cols["nombre"]["audita_delete"]) == (True, True, False)
    assert not cols["salario"]["audita_update"]

    r = su.execute("SELECT autoaudit.fn_desactivar_tabla('demo', %s) AS r", (tabla,)).fetchone()["r"]
    assert r["generacion"]["accion"] == "ELIMINADO"
    assert su.execute("SELECT count(*) AS n FROM pg_trigger WHERE tgrelid = %s::regclass AND tgname = 'aa_auditoria'",
                      (f"demo.{tabla}",)).fetchone()["n"] == 0
    t = su.execute("SELECT activa FROM autoaudit.aud_tabla WHERE nombre = %s AND NOT eliminada", (tabla,)).fetchone()
    assert t["activa"] is False


def test_regenerar_sin_cambios_es_idempotente(su, tabla):
    configurar(su, tabla, TODO)
    r = su.execute("SELECT autoaudit.fn_generar_trigger('demo', %s) AS r", (tabla,)).fetchone()["r"]
    assert r["accion"] == "SIN_CAMBIOS"


def test_vista_previa_no_guarda(su, tabla):
    with su.transaction():
        ddl = servicios.previsualizar(su, "demo", tabla, {"nombre": ["I"]})
    assert "CREATE OR REPLACE TRIGGER aa_auditoria" in ddl and "AFTER INSERT" in ddl
    assert su.execute("SELECT count(*) AS n FROM autoaudit.aud_tabla WHERE nombre = %s", (tabla,)).fetchone()["n"] == 0


def test_historial_de_cambios_de_configuracion(su, tabla):
    configurar(su, tabla, {"nombre": ["I"]})
    configurar(su, tabla, {"nombre": ["I", "U"]})
    acciones = su.execute(
        """SELECT c.accion FROM autoaudit.aud_cambio_config c JOIN autoaudit.aud_tabla t ON t.id = c.tabla_id
            WHERE t.nombre = %s ORDER BY c.id""", (tabla,)).fetchall()
    assert [a["accion"] for a in acciones] == ["CONFIGURAR", "GENERAR", "CONFIGURAR", "GENERAR"]


# ------------------------------------------------------------------ dependencias (event triggers)
def test_drop_column_regenera_trigger(su, cajero, tabla):
    configurar(su, tabla, TODO)
    su.execute(f"ALTER TABLE demo.{tabla} DROP COLUMN puesto CASCADE")
    col = su.execute("""SELECT c.activa, c.eliminada FROM autoaudit.aud_columna c JOIN autoaudit.aud_tabla t ON t.id = c.tabla_id
                         WHERE t.nombre = %s AND c.nombre = 'puesto'""", (tabla,)).fetchone()
    assert col == {"activa": False, "eliminada": True}
    assert "puesto" not in _eventos_trigger(su, tabla)
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre, salario) VALUES ('Post DDL', 1)")
    assert len(cabeceras(su, tabla)) == 1


def test_drop_column_sin_cascade_esta_protegido(su, tabla):
    """PostgreSQL impide borrar una columna usada en UPDATE OF del trigger."""
    configurar(su, tabla, TODO)
    with pytest.raises(psycopg.errors.DependentObjectsStillExist):
        su.execute(f"ALTER TABLE demo.{tabla} DROP COLUMN salario")


def test_rename_column_y_tabla(su, cajero, tabla):
    configurar(su, tabla, TODO)
    su.execute(f"ALTER TABLE demo.{tabla} RENAME COLUMN nombre TO nombre_completo")
    nuevo = tabla + "_r"
    su.execute(f"ALTER TABLE demo.{tabla} RENAME TO {nuevo}")
    cajero.execute(f"INSERT INTO demo.{nuevo} (nombre_completo) VALUES ('Renombrado')")
    filas = su.execute("SELECT tabla, columna FROM autoaudit.v_bitacora WHERE tabla = %s", (nuevo,)).fetchall()
    assert ("nombre_completo" in {f["columna"] for f in filas})
    assert su.execute("SELECT estado FROM autoaudit.v_estado_triggers WHERE tabla = %s", (nuevo,)).fetchone()["estado"] == "OK"


def test_drop_table_conserva_bitacora(su, cajero, tabla):
    configurar(su, tabla, TODO)
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('Antes del DROP')")
    tid = su.execute("SELECT id FROM autoaudit.aud_tabla WHERE nombre = %s", (tabla,)).fetchone()["id"]
    su.execute(f"DROP TABLE demo.{tabla}")
    t = su.execute("SELECT activa, eliminada FROM autoaudit.aud_tabla WHERE id = %s", (tid,)).fetchone()
    assert t == {"activa": False, "eliminada": True}
    assert su.execute("SELECT count(*) AS n FROM autoaudit.aud_bitacora WHERE tabla_id = %s", (tid,)).fetchone()["n"] == 1
    assert su.execute("SELECT estado FROM autoaudit.aud_trigger WHERE tabla_id = %s ORDER BY id DESC LIMIT 1",
                      (tid,)).fetchone()["estado"] == "TABLA_ELIMINADA"


def test_drop_trigger_manual_queda_registrado(su, tabla):
    configurar(su, tabla, TODO)
    su.execute(f"DROP TRIGGER aa_auditoria ON demo.{tabla}")
    c = su.execute("SELECT accion, usuario FROM autoaudit.aud_cambio_config ORDER BY id DESC LIMIT 1").fetchone()
    assert c["accion"] == "DDL_DROP_TRIGGER"
    assert su.execute("SELECT estado FROM autoaudit.v_estado_triggers WHERE tabla = %s", (tabla,)).fetchone()["estado"] == "PENDIENTE"
    r = su.execute("SELECT autoaudit.fn_generar_trigger('demo', %s) AS r", (tabla,)).fetchone()["r"]
    assert r["ok"] and r["accion"] == "CREADO"


def test_trigger_deshabilitado_se_detecta(su, tabla):
    configurar(su, tabla, TODO)
    su.execute(f"ALTER TABLE demo.{tabla} DISABLE TRIGGER aa_auditoria")
    assert su.execute("SELECT estado FROM autoaudit.v_estado_triggers WHERE tabla = %s", (tabla,)).fetchone()["estado"] == "DESHABILITADO"
    assert su.execute("SELECT accion FROM autoaudit.aud_cambio_config ORDER BY id DESC LIMIT 1").fetchone()["accion"] == "DDL_DISABLE_TRIGGER"


# ------------------------------------------------------------------ manejo de errores
def test_error_de_generacion_se_registra_y_no_deja_triggers_a_medias(su):
    """Tabla cuyo dueño no está delegado a AutoAudit: no se puede crear el trigger."""
    su.execute("""
        DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'otro_owner') THEN CREATE ROLE otro_owner NOLOGIN; END IF; END $$;
        CREATE SCHEMA IF NOT EXISTS ajeno AUTHORIZATION otro_owner;
        SET ROLE otro_owner;
        CREATE TABLE IF NOT EXISTS ajeno.datos (id int PRIMARY KEY, valor text);
        RESET ROLE;
    """)
    r = su.execute("SELECT autoaudit.fn_configurar_tabla('ajeno', 'datos', '{\"valor\": [\"I\"]}') AS r").fetchone()["r"]
    assert r["generacion"]["ok"] is False
    assert r["generacion"]["sqlstate"] == "42501"  # insufficient_privilege
    err = su.execute("SELECT contexto, mensaje FROM autoaudit.aud_error ORDER BY id DESC LIMIT 1").fetchone()
    assert err["contexto"] == "GENERACION"
    assert su.execute("SELECT count(*) AS n FROM pg_trigger WHERE tgrelid = 'ajeno.datos'::regclass AND NOT tgisinternal").fetchone()["n"] == 0
    assert su.execute("SELECT count(*) AS n FROM pg_proc WHERE proname LIKE 'aa_fn_%%ajeno%%'").fetchone()["n"] == 0
    estado = su.execute("SELECT estado FROM autoaudit.v_estado_triggers WHERE esquema = 'ajeno'").fetchone()["estado"]
    assert estado == "PENDIENTE"


def test_modo_tolerante_registra_error_de_ejecucion(su, cajero, tabla):
    """En modo tolerante, si la auditoría falla la operación continúa y el error queda registrado."""
    configurar(su, tabla, TODO)
    su.execute("SELECT autoaudit.fn_set_parametro('modo_error', 'tolerante')")
    try:
        # Simular un fallo: la bitácora rechaza temporalmente nuevos registros.
        su.execute("""CREATE FUNCTION autoaudit._fallo() RETURNS trigger LANGUAGE plpgsql AS
                      $$ BEGIN RAISE EXCEPTION 'fallo simulado'; END $$;
                      CREATE TRIGGER zz_fallo BEFORE INSERT ON autoaudit.aud_bitacora_detalle
                      FOR EACH ROW EXECUTE FUNCTION autoaudit._fallo();""")
        cajero.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('Sigue')")
        assert su.execute(f"SELECT count(*) AS n FROM demo.{tabla}").fetchone()["n"] == 1
        err = su.execute("SELECT contexto, mensaje FROM autoaudit.aud_error ORDER BY id DESC LIMIT 1").fetchone()
        assert err == {"contexto": "EJECUCION", "mensaje": "fallo simulado"}
    finally:
        su.execute("DROP TRIGGER IF EXISTS zz_fallo ON autoaudit.aud_bitacora_detalle; DROP FUNCTION IF EXISTS autoaudit._fallo()")
        su.execute("SELECT autoaudit.fn_set_parametro('modo_error', 'estricto')")


def test_modo_estricto_revierte_la_operacion(su, cajero, tabla):
    configurar(su, tabla, TODO)
    su.execute("""CREATE FUNCTION autoaudit._fallo2() RETURNS trigger LANGUAGE plpgsql AS
                  $$ BEGIN RAISE EXCEPTION 'fallo simulado'; END $$;
                  CREATE TRIGGER zz_fallo BEFORE INSERT ON autoaudit.aud_bitacora_detalle
                  FOR EACH ROW EXECUTE FUNCTION autoaudit._fallo2();""")
    try:
        with pytest.raises(psycopg.errors.RaiseException):
            cajero.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('No debe quedar')")
        assert su.execute(f"SELECT count(*) AS n FROM demo.{tabla}").fetchone()["n"] == 0
    finally:
        su.execute("DROP TRIGGER IF EXISTS zz_fallo ON autoaudit.aud_bitacora_detalle; DROP FUNCTION IF EXISTS autoaudit._fallo2()")
