"""Pruebas del módulo de consulta: por usuario, por columna, historial y viaje en el tiempo."""

from datetime import date, datetime, timedelta

from app import servicios
from conftest import configurar, conectar_como

TODO = {"nombre": ["I", "U", "D"], "salario": ["I", "U", "D"], "puesto": ["I", "U", "D"]}


def _escenario(su, tabla):
    """cajero1 hace 3 operaciones, cajero2 hace 2."""
    configurar(su, tabla, TODO)
    with conectar_como("cajero1") as c1:
        c1.execute(f"INSERT INTO demo.{tabla} (nombre, salario) VALUES ('Ana', 100)")
        c1.execute(f"UPDATE demo.{tabla} SET salario = 200 WHERE id = 1")
        c1.execute(f"INSERT INTO demo.{tabla} (nombre, salario) VALUES ('Beto', 50)")
    with conectar_como("cajero2") as c2:
        c2.execute(f"UPDATE demo.{tabla} SET salario = 300, puesto = 'Jefe' WHERE id = 1")
        c2.execute(f"DELETE FROM demo.{tabla} WHERE id = 2")


def test_consulta_por_usuario_historial_completo(su, tabla):
    _escenario(su, tabla)
    filas = servicios.cambios_por_usuario(su, "cajero2", esquema="demo", tabla=tabla)
    assert {(f["operacion"], f["columna"]) for f in filas} == {
        ("UPDATE", "salario"), ("UPDATE", "puesto"),
        ("DELETE", "nombre"), ("DELETE", "salario"), ("DELETE", "puesto")}
    assert all(f["usuario_bd"] == "cajero2" for f in filas)
    ops = servicios.agrupar_operaciones(servicios.cambios_por_usuario(su, "cajero1", esquema="demo", tabla=tabla))
    assert [o["operacion"] for o in ops] == ["INSERT", "UPDATE", "INSERT"]  # orden cronológico


def test_consulta_por_columna_todos_los_cambios(su, tabla):
    _escenario(su, tabla)
    filas = servicios.cambios_por_columna(su, "demo", tabla, "salario")
    assert [(f["operacion"], f["valor_anterior"], f["valor_nuevo"], f["usuario_bd"]) for f in filas] == [
        ("INSERT", None, "100.00", "cajero1"),
        ("UPDATE", "100.00", "200.00", "cajero1"),
        ("INSERT", None, "50.00", "cajero1"),
        ("UPDATE", "200.00", "300.00", "cajero2"),
        ("DELETE", "50.00", None, "cajero2"),
    ]
    assert all(f["columna"] == "salario" for f in filas)
    solo_upd = servicios.cambios_por_columna(su, "demo", tabla, "salario", operacion="UPDATE")
    assert len(solo_upd) == 2


def test_filtro_por_fechas(su, tabla):
    _escenario(su, tabla)
    hoy = date.today()
    assert servicios.cambios_por_columna(su, "demo", tabla, "salario", desde=hoy, hasta=hoy)
    assert servicios.cambios_por_columna(su, "demo", tabla, "salario", desde=hoy + timedelta(days=1)) == []


def test_consulta_por_columna_sobrevive_renombre(su, tabla):
    _escenario(su, tabla)
    su.execute(f"ALTER TABLE demo.{tabla} RENAME COLUMN salario TO sueldo")
    assert len(servicios.cambios_por_columna(su, "demo", tabla, "sueldo")) == 5


def test_historial_y_estado_en_fecha(su, tabla):
    configurar(su, tabla, TODO)
    with conectar_como("cajero1") as c1:
        c1.execute(f"INSERT INTO demo.{tabla} (nombre, salario) VALUES ('Ana', 100)")
        medio = su.execute("SELECT clock_timestamp() AS t").fetchone()["t"]
        c1.execute(f"UPDATE demo.{tabla} SET salario = 999 WHERE id = 1")
        c1.execute(f"DELETE FROM demo.{tabla} WHERE id = 1")

    ops = servicios.agrupar_operaciones(servicios.historial_registro(su, "demo", tabla, {"id": 1}))
    assert [o["operacion"] for o in ops] == ["INSERT", "UPDATE", "DELETE"]

    antes = servicios.estado_en_fecha(su, "demo", tabla, {"id": 1}, medio)
    assert antes["existia"] is True and antes["fila"]["salario"] == 100
    ahora = servicios.estado_en_fecha(su, "demo", tabla, {"id": 1}, datetime.now().astimezone())
    assert ahora["existia"] is False


def test_lector_ve_ip_enmascarada(su, tabla):
    su.execute("SELECT autoaudit.fn_set_parametro('modo_ip', 'completa')")
    try:
        configurar(su, tabla, TODO)
        with conectar_como("cajero1") as c1:
            c1.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('IP')")
        ip_admin = su.execute("SELECT ip FROM autoaudit.v_bitacora WHERE tabla = %s LIMIT 1", (tabla,)).fetchone()["ip"]
        with conectar_como("lector") as lec:
            ip_lector = lec.execute("SELECT ip FROM autoaudit.v_bitacora WHERE tabla = %s LIMIT 1", (tabla,)).fetchone()["ip"]
        assert "/" not in ip_admin          # IP completa para el administrador
        assert ip_lector.endswith("/24")    # enmascarada para el lector
    finally:
        su.execute("SELECT autoaudit.fn_set_parametro('modo_ip', 'enmascarada')")


def test_modo_ip_hash(su, tabla):
    su.execute("SELECT autoaudit.fn_set_parametro('modo_ip', 'hash')")
    try:
        configurar(su, tabla, TODO)
        with conectar_como("cajero1") as c1:
            c1.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('H')")
        ip = su.execute("SELECT ip FROM autoaudit.v_bitacora WHERE tabla = %s LIMIT 1", (tabla,)).fetchone()["ip"]
        assert ip.startswith("sha256:")
    finally:
        su.execute("SELECT autoaudit.fn_set_parametro('modo_ip', 'enmascarada')")
