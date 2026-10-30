"""Pruebas de seguridad: solo administradores configuran; la bitácora no admite escritura directa."""

import psycopg
import pytest

from conftest import conectar_como, configurar

TODO = {"nombre": ["I", "U", "D"]}


@pytest.mark.parametrize("quien", ["cajero1", "lector"])
def test_solo_administradores_configuran(quien, tabla):
    with conectar_como(quien) as conn, pytest.raises(psycopg.errors.InsufficientPrivilege):
        conn.execute("SELECT autoaudit.fn_configurar_tabla('demo', %s, '{\"nombre\": [\"I\"]}')", (tabla,))


def test_administrador_si_configura(tabla):
    with conectar_como("admin") as conn:
        r = conn.execute("SELECT autoaudit.fn_configurar_tabla('demo', %s, '{\"nombre\": [\"I\"]}') AS r",
                         (tabla,)).fetchone()["r"]
    assert r["generacion"]["ok"]


def test_chequeo_interno_de_administrador(su):
    """Aunque alguien obtuviera EXECUTE, la función verifica el rol (defensa en profundidad)."""
    su.execute("GRANT EXECUTE ON FUNCTION autoaudit.fn_set_parametro(text, text) TO autoaudit_lector")
    try:
        with conectar_como("lector") as conn, pytest.raises(psycopg.errors.InsufficientPrivilege,
                                                           match="privilegios de administrador"):
            conn.execute("SELECT autoaudit.fn_set_parametro('modo_ip', 'completa')")
    finally:
        su.execute("REVOKE EXECUTE ON FUNCTION autoaudit.fn_set_parametro(text, text) FROM autoaudit_lector")


@pytest.mark.parametrize("quien", ["admin", "lector", "cajero1"])
@pytest.mark.parametrize("sql", [
    "INSERT INTO autoaudit.aud_bitacora (tabla_id, evento_id, usuario_id, estacion_id, txid, pk_registro) VALUES (1,1,1,1,0,'{}')",
    "UPDATE autoaudit.aud_bitacora_detalle SET valor_nuevo = 'x'",
    "DELETE FROM autoaudit.aud_bitacora",
    "TRUNCATE autoaudit.aud_bitacora",
    "UPDATE autoaudit.aud_configuracion SET activa = false",
])
def test_sin_escritura_directa(quien, sql):
    with conectar_como(quien) as conn, pytest.raises(psycopg.errors.InsufficientPrivilege):
        conn.execute(sql)


def test_bitacora_inmutable_incluso_para_superusuario(su, cajero, tabla):
    configurar(su, tabla, TODO)
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('Inmutable')")
    for sql in ("UPDATE autoaudit.aud_bitacora SET pk_registro = '{}'",
                "DELETE FROM autoaudit.aud_bitacora_detalle",
                "TRUNCATE autoaudit.aud_bitacora CASCADE"):
        with pytest.raises(psycopg.errors.InsufficientPrivilege, match="solo inserción"):
            su.execute(sql)


def test_usuario_de_negocio_no_lee_la_bitacora():
    with conectar_como("cajero1") as conn, pytest.raises(psycopg.errors.InsufficientPrivilege):
        conn.execute("SELECT * FROM autoaudit.v_bitacora")


def test_lector_no_ve_ip_ni_sal_directamente():
    with conectar_como("lector") as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT ip FROM autoaudit.aud_estacion")
    with conectar_como("lector") as conn:
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("SELECT valor FROM autoaudit.aud_parametro")


def test_funciones_generadas_no_son_publicas(su, tabla):
    configurar(su, tabla, TODO)
    filas = su.execute(
        """SELECT p.proname, has_function_privilege('cajero1', p.oid, 'EXECUTE') AS puede
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'autoaudit' AND p.proname LIKE 'aa_fn_%'""").fetchall()
    assert filas and not any(f["puede"] for f in filas)
