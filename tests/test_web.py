"""Pruebas de la aplicación web y de la exportación de reportes."""

import json
from datetime import datetime
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient

from app import exportar
from app.main import app
from conftest import CRED, conectar_como, configurar


def _cliente(quien: str) -> TestClient:
    c = TestClient(app)
    usuario, clave = CRED[quien]
    r = c.post("/login", data={"usuario": usuario, "clave": clave}, follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/"
    return c


def test_login_incorrecto():
    r = TestClient(app).post("/login", data={"usuario": "aa_admin", "clave": "mala"})
    assert "incorrectos" in r.text


def test_usuario_sin_rol_de_auditoria_no_entra():
    usuario, clave = CRED["cajero1"]
    r = TestClient(app).post("/login", data={"usuario": usuario, "clave": clave})
    assert "no tiene permisos de auditoría" in r.text


def test_acceso_demo_en_inicio(monkeypatch):
    import dataclasses
    import app.main as principal

    r = TestClient(app).get("/login")
    assert "Acceso de demostración" not in r.text  # sin configurar no se muestra
    monkeypatch.setattr(principal, "config",
                        dataclasses.replace(principal.config, demo_usuario="aa_lector", demo_clave="clave-demo"))
    r = TestClient(app).get("/login")
    assert "Acceso de demostración" in r.text and "clave-demo" in r.text


def test_paginas_requieren_sesion():
    r = TestClient(app).get("/consultas", follow_redirects=False)
    assert r.status_code == 303 and r.headers["location"] == "/login"


@pytest.mark.parametrize("ruta", ["/", "/tablas", "/tablas/demo/clientes", "/consultas", "/registro",
                                  "/usuarios", "/estado", "/diccionario", "/diccionario?esquema=demo"])
def test_paginas_cargan(ruta):
    assert _cliente("lector").get(ruta).status_code == 200


def test_lector_no_puede_configurar_desde_la_web(su, tabla):
    c = _cliente("lector")
    r = c.post(f"/tablas/demo/{tabla}", data={"accion": "guardar", f"ev|nombre|I": "on"}, follow_redirects=False)
    assert r.status_code == 303
    assert su.execute("SELECT count(*) AS n FROM autoaudit.aud_tabla WHERE nombre = %s", (tabla,)).fetchone()["n"] == 0
    assert c.get("/parametros", follow_redirects=False).status_code == 303


def test_admin_configura_desde_la_web(su, tabla):
    c = _cliente("admin")
    r = c.post(f"/tablas/demo/{tabla}", data={"accion": "previsualizar", "ev|nombre|I": "on"})
    assert "CREATE OR REPLACE TRIGGER aa_auditoria" in r.text
    r = c.post(f"/tablas/demo/{tabla}", data={"accion": "guardar", "ev|nombre|I": "on", "ev|salario|U": "on"})
    assert "generado (I,U)" in r.text
    assert su.execute("SELECT estado FROM autoaudit.v_estado_triggers WHERE tabla = %s", (tabla,)).fetchone()["estado"] == "OK"


@pytest.mark.parametrize("formato,tipo", [("csv", "text/csv"), ("xlsx", "spreadsheetml"),
                                          ("pdf", "application/pdf"), ("json", "application/json")])
def test_exportar_desde_la_web(su, tabla, formato, tipo):
    configurar(su, tabla, {"nombre": ["I"]})
    with conectar_como("cajero1") as conn:
        conn.execute(f"INSERT INTO demo.{tabla} (nombre) VALUES ('Exportar')")
    r = _cliente("lector").get(f"/consultas/exportar?tipo=columna&columna=demo|{tabla}|nombre&formato={formato}")
    assert r.status_code == 200 and tipo in r.headers["content-type"]
    assert "attachment" in r.headers["content-disposition"]
    if formato == "json":
        datos = r.json()
        assert datos["total"] == 1 and datos["registros"][0]["valor_nuevo"] == "Exportar"
    if formato == "csv":
        assert "Exportar" in r.content.decode("utf-8-sig")


FILAS = [{"fecha_hora": datetime(2026, 10, 30, 10, 0), "operacion": "UPDATE", "pk_registro": {"id": 1},
          "valor_anterior": "Ñandú & <b>", "valor_nuevo": Decimal("1.50")}]
COLS = ["fecha_hora", "operacion", "pk_registro", "valor_anterior", "valor_nuevo"]


def test_exportar_csv_con_tildes():
    texto = exportar.a_csv(FILAS, COLS).decode("utf-8-sig")
    assert texto.splitlines()[1] == '2026-10-30 10:00:00,UPDATE,"{""id"": 1}",Ñandú & <b>,1.50'


def test_exportar_json_y_formatos_binarios():
    assert json.loads(exportar.a_json(FILAS, COLS, "t"))["registros"][0]["valor_nuevo"] == "1.50"
    assert exportar.a_xlsx(FILAS, COLS, "t")[:2] == b"PK"
    assert exportar.a_pdf(FILAS, COLS, "t")[:4] == b"%PDF"
    with pytest.raises(ValueError):
        exportar.exportar(FILAS, COLS, "doc", "t")
