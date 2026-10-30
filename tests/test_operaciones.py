"""Pruebas de validación: INSERT, UPDATE y DELETE quedan registrados correctamente."""

from conftest import bitacora, cabeceras, configurar

TODO = {"nombre": ["I", "U", "D"], "salario": ["I", "U", "D"], "puesto": ["I", "U", "D"]}


def test_trigger_generado_es_valido(su, tabla):
    r = configurar(su, tabla, TODO)
    assert r["generacion"]["ok"], r
    assert r["generacion"]["accion"] == "CREADO"
    trig = su.execute(
        "SELECT tgname, tgenabled FROM pg_trigger WHERE tgrelid = %s::regclass AND NOT tgisinternal",
        (f"demo.{tabla}",)).fetchall()
    assert trig == [{"tgname": "aa_auditoria", "tgenabled": "O"}]  # un único trigger por tabla
    estado = su.execute("SELECT estado FROM autoaudit.v_estado_triggers WHERE tabla = %s", (tabla,)).fetchone()
    assert estado["estado"] == "OK"


def test_insert_registra_todos_los_campos(su, cajero, tabla):
    configurar(su, tabla, TODO)
    cajero.execute("SET autoaudit.usuario_app = 'ana'; SET autoaudit.estacion = 'PC-07'")
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre, salario, puesto, notas) VALUES ('Ana', 5000, 'Analista', 'x')")

    cab = cabeceras(su, tabla)
    assert len(cab) == 1
    c = cab[0]
    assert c["operacion"] == "INSERT"
    assert c["fecha_hora"] is not None and c["txid"] > 0
    assert c["pk_registro"] == {"id": 1}
    assert c["fila_anterior"] is None
    assert c["fila_nueva"]["nombre"] == "Ana" and c["fila_nueva"]["notas"] == "x"  # fila completa

    filas = bitacora(su, tabla)
    assert {f["columna"]: (f["valor_anterior"], f["valor_nuevo"]) for f in filas} == {
        "nombre": (None, "Ana"), "salario": (None, "5000.00"), "puesto": (None, "Analista")}
    f = filas[0]
    assert f["usuario_bd"] == "cajero1"
    assert f["usuario_app"] == "ana"
    assert f["estacion"] == "PC-07"
    assert f["aplicacion"] == "pruebas"
    assert f["ip"] and f["ip"] != "local"  # conexión TCP: hay IP origen


def test_update_captura_valor_antiguo_y_nuevo(su, cajero, tabla):
    configurar(su, tabla, TODO)
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre, salario, puesto) VALUES ('Luis', 4000, 'Cajero')")
    cajero.execute(f"UPDATE demo.{tabla} SET salario = 4500, puesto = 'Supervisor' WHERE id = 1")

    upd = [f for f in bitacora(su, tabla) if f["operacion"] == "UPDATE"]
    assert {f["columna"]: (f["valor_anterior"], f["valor_nuevo"]) for f in upd} == {
        "salario": ("4000.00", "4500.00"), "puesto": ("Cajero", "Supervisor")}
    cab = [c for c in cabeceras(su, tabla) if c["operacion"] == "UPDATE"][0]
    assert cab["fila_anterior"]["salario"] == 4000 and cab["fila_nueva"]["salario"] == 4500


def test_update_sin_cambios_reales_no_se_registra(su, cajero, tabla):
    configurar(su, tabla, TODO)
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre, salario) VALUES ('Eva', 100)")
    cajero.execute(f"UPDATE demo.{tabla} SET notas = 'columna no auditada' WHERE id = 1")
    cajero.execute(f"UPDATE demo.{tabla} SET salario = 100 WHERE id = 1")  # mismo valor
    assert [c["operacion"] for c in cabeceras(su, tabla)] == ["INSERT"]


def test_delete_preserva_los_datos(su, cajero, tabla):
    configurar(su, tabla, TODO)
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre, salario, puesto, notas) VALUES ('Raúl', 3000, 'Bodega', 'n1')")
    cajero.execute(f"DELETE FROM demo.{tabla} WHERE id = 1")

    assert su.execute(f"SELECT count(*) AS n FROM demo.{tabla}").fetchone()["n"] == 0
    dele = [c for c in cabeceras(su, tabla) if c["operacion"] == "DELETE"][0]
    assert dele["fila_anterior"] == {"id": 1, "nombre": "Raúl", "salario": 3000, "puesto": "Bodega",
                                     "notas": "n1", "datos": None}
    assert dele["fila_nueva"] is None
    det = {f["columna"]: (f["valor_anterior"], f["valor_nuevo"])
           for f in bitacora(su, tabla) if f["operacion"] == "DELETE"}
    assert det == {"nombre": ("Raúl", None), "salario": ("3000.00", None), "puesto": ("Bodega", None)}


def test_solo_columnas_y_eventos_configurados(su, cajero, tabla):
    configurar(su, tabla, {"salario": ["U"], "puesto": ["D"]})
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre, salario, puesto) VALUES ('Sol', 1, 'A')")  # no INSERT
    cajero.execute(f"UPDATE demo.{tabla} SET nombre = 'Sol M.' WHERE id = 1")                       # nombre no auditado
    cajero.execute(f"UPDATE demo.{tabla} SET salario = 2, puesto = 'B' WHERE id = 1")              # puesto solo D
    cajero.execute(f"DELETE FROM demo.{tabla} WHERE id = 1")
    filas = bitacora(su, tabla)
    assert [(f["operacion"], f["columna"]) for f in filas] == [("UPDATE", "salario"), ("DELETE", "puesto")]


def test_tipos_sin_operador_de_igualdad(su, cajero, tabla):
    """jsonb y otros tipos se comparan correctamente en UPDATE."""
    configurar(su, tabla, {"datos": ["U"]})
    cajero.execute(f"""INSERT INTO demo.{tabla} (nombre, datos) VALUES ('J', '{{"a": 1}}')""")
    cajero.execute(f"""UPDATE demo.{tabla} SET datos = '{{"a": 2}}' WHERE id = 1""")
    filas = bitacora(su, tabla)
    assert [(f["valor_anterior"], f["valor_nuevo"]) for f in filas] == [('{"a": 1}', '{"a": 2}')]


def test_llave_primaria_compuesta(su, cajero):
    configurar(su, "venta_detalle", {"cantidad": ["I", "U", "D"]})
    with cajero.transaction():
        cajero.execute("INSERT INTO demo.ventas (cliente_id) VALUES (1) RETURNING id")
        vid = cajero.execute("SELECT max(id) AS id FROM demo.ventas").fetchone()["id"]
        cajero.execute("INSERT INTO demo.venta_detalle VALUES (%s, 1, 1, 3, 85)", (vid,))
    cab = cabeceras(su, "venta_detalle")
    assert cab[-1]["pk_registro"] == {"venta_id": vid, "linea": 1}


def test_cambios_en_una_transaccion_comparten_txid(su, cajero, tabla):
    configurar(su, tabla, TODO)
    with cajero.transaction():
        cajero.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('A'), ('B')")
        cajero.execute(f"UPDATE demo.{tabla} SET puesto = 'X'")
    assert len({c["txid"] for c in cabeceras(su, tabla)}) == 1


def test_rollback_no_deja_rastro(su, cajero, tabla):
    configurar(su, tabla, TODO)
    cajero.execute("BEGIN")
    cajero.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('Fantasma')")
    cajero.execute("ROLLBACK")
    assert cabeceras(su, tabla) == []


def test_cache_de_contexto_no_sobrevive_a_un_rollback(su, tabla):
    """Si la transacción que registró al usuario se revierte, la caché no debe apuntar a un id inexistente."""
    configurar(su, tabla, TODO)
    from conftest import conectar_como
    with conectar_como("cajero1") as c:
        c.execute("SELECT set_config('autoaudit.usuario_app', %s, false)", (f"nuevo_{tabla}",))
        c.execute("BEGIN")
        c.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('se revierte')")
        c.execute("ROLLBACK")
        c.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('queda')")  # no debe fallar por FK
    filas = cabeceras(su, tabla)
    assert len(filas) == 1 and filas[0]["fila_nueva"]["nombre"] == "queda"


def test_usuario_excluido_no_se_audita(su, tabla):
    configurar(su, tabla, TODO)
    uid = su.execute("SELECT autoaudit.fn_registrar_usuario('cajero2', '', false) AS id").fetchone()["id"]
    try:
        from conftest import conectar_como
        with conectar_como("cajero2") as c2:
            c2.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('Carga masiva')")
        assert cabeceras(su, tabla) == []
    finally:
        su.execute("SELECT autoaudit.fn_set_auditar_usuario(%s, true)", (uid,))
