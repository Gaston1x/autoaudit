"""Genera la documentación técnica en PDF (docs/AutoAudit_Documentacion.pdf).

Todo se obtiene del sistema real:
  * Diagrama entidad-relación  -> llaves foráneas de pg_constraint (Graphviz)
  * Diccionario de datos       -> autoaudit.fn_diccionario_datos() + COMMENT ON
  * Capturas de pantalla       -> la aplicación web en ejecución (Playwright)
  * Resultados de pruebas      -> pytest (JUnit XML) y pruebas_rendimiento.py

Requisitos: graphviz (dot), playwright + chromium, la app en http://localhost:8000.
Uso:  python docs/generar_documentacion.py [--sin-capturas] [--sin-pruebas]
"""

import argparse
import csv
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import psycopg
from jinja2 import Environment, FileSystemLoader
from psycopg.rows import dict_row

DOCS = Path(__file__).resolve().parent
RAIZ = DOCS.parent
sys.path.insert(0, str(RAIZ))
from app.config import config  # noqa: E402

IMG = DOCS / "img"
URL_APP = os.getenv("AA_URL_APP", "http://localhost:8000")

GRUPOS = {
    "Configuración": ["aud_tabla", "aud_columna", "aud_evento", "aud_configuracion"],
    "Actores": ["aud_usuario", "aud_estacion"],
    "Bitácora": ["aud_bitacora", "aud_bitacora_detalle"],
    "Soporte": ["aud_trigger", "aud_error", "aud_cambio_config", "aud_parametro"],
}
COLOR_GRUPO = {"Configuración": "#EAF3F5", "Actores": "#FFF6DD", "Bitácora": "#EEF3F8", "Soporte": "#F4F5F7"}


def conectar():
    return psycopg.connect(dbname=config.db_name, row_factory=dict_row, autocommit=True)


# ----------------------------------------------------------------------------- ER
def diagrama_er(conn) -> str:
    cols = conn.execute("SELECT * FROM autoaudit.fn_diccionario_datos('autoaudit')").fetchall()
    fks = conn.execute("""
        SELECT c.conrelid::regclass::text AS origen, c.confrelid::regclass::text AS destino,
               (SELECT string_agg(a.attname, ', ') FROM unnest(c.conkey) k
                  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k) AS columnas
          FROM pg_constraint c
         WHERE c.contype = 'f' AND c.connamespace = 'autoaudit'::regnamespace""").fetchall()
    por_tabla = defaultdict(list)
    for c in cols:
        por_tabla[c["tabla"]].append(c)

    def etiqueta(tabla: str, grupo: str) -> str:
        filas = []
        for c in por_tabla[tabla]:
            llave = c["llave"] or ""
            marca = "PK" if "PK" in llave else ("FK" if "FK" in llave else "")
            nombre = f"<B>{c['columna']}</B>" if marca == "PK" else c["columna"]
            tipo = c["tipo_dato"].replace("character varying", "varchar").replace("timestamp with time zone", "timestamptz")
            celda_llave = f'<FONT COLOR="#00616A" POINT-SIZE="8">{marca}</FONT>' if marca else " "
            filas.append(f'<TR><TD ALIGN="LEFT" WIDTH="22">{celda_llave}</TD>'
                         f'<TD ALIGN="LEFT">{nombre}</TD><TD ALIGN="LEFT"><FONT COLOR="#6B7280">{tipo}</FONT></TD></TR>')
        return (f'<<TABLE BORDER="1" CELLBORDER="0" CELLSPACING="0" CELLPADDING="4" COLOR="#C9D3DC" BGCOLOR="white">'
                f'<TR><TD COLSPAN="3" BGCOLOR="#003865" ALIGN="LEFT"><FONT COLOR="white"><B>{tabla}</B></FONT></TD></TR>'
                f'{"".join(filas)}</TABLE>>')

    dot = ['digraph ER {', 'graph [rankdir=LR, fontname="Open Sans", fontsize=11, nodesep=0.35, ranksep=0.9, pad=0.2, bgcolor="white", newrank=true];',
           'node [shape=plain, fontname="Open Sans", fontsize=9];',
           'edge [color="#003865", arrowhead=crow, arrowtail=tee, dir=both, fontname="Open Sans", fontsize=8, fontcolor="#00616A"];']
    for i, (grupo, tablas) in enumerate(GRUPOS.items()):
        dot.append(f'subgraph cluster_{i} {{ label="{grupo}"; style="rounded,filled"; color="#D9E2EA"; fillcolor="{COLOR_GRUPO[grupo]}"; fontcolor="#003865";')
        for t in tablas:
            if t in por_tabla:
                dot.append(f'"{t}" [label={etiqueta(t, grupo)}];')
        dot.append("}")
    for fk in fks:
        o, d = fk["origen"].split(".")[-1], fk["destino"].split(".")[-1]
        dot.append(f'"{d}" -> "{o}" [label=" {fk["columnas"]}"];')
    dot.append("}")
    (IMG / "er_autoaudit.dot").write_text("\n".join(dot), encoding="utf-8")
    svg = subprocess.run(["dot", "-Tsvg"], input="\n".join(dot), capture_output=True, text=True, check=True).stdout
    (IMG / "er_autoaudit.svg").write_text(svg, encoding="utf-8")
    subprocess.run(["dot", "-Tpng", "-Gdpi=160", "-o", str(IMG / "er_autoaudit.png")], input="\n".join(dot), text=True, check=True)
    return svg[svg.index("<svg"):]


# ----------------------------------------------------------------------------- capturas
def capturas() -> None:
    from playwright.sync_api import sync_playwright

    paginas = [
        ("login", "/login", None),
        ("panel", "/", None),
        ("tablas", "/tablas", None),
        ("tabla_config", "/tablas/demo/productos", None),
        ("vista_previa", "/tablas/demo/productos", "previsualizar"),
        ("consultas_usuario", "/consultas?tipo=usuario&usuario=cajero1", None),
        ("consultas_linea", "/consultas?tipo=columna&columna=demo|clientes|limite_credito&vista=linea", None),
        ("registro", "/registro?tabla=demo.clientes&pk=%7B%22id%22%3A+4%7D&fecha=", None),
        ("estado", "/estado", None),
        ("usuarios", "/usuarios", None),
        ("diccionario", "/diccionario?esquema=demo", None),
        ("parametros", "/parametros", None),
    ]
    with sync_playwright() as p:
        nav = p.chromium.launch()
        pagina = nav.new_page(viewport={"width": 1366, "height": 860}, device_scale_factor=1.5)
        pagina.goto(f"{URL_APP}/login")
        pagina.screenshot(path=str(IMG / "ui_login.png"))
        pagina.fill("#usuario", os.getenv("AA_USUARIO", "aa_admin"))
        pagina.fill("#clave", os.getenv("AA_CLAVE", ""))
        pagina.click("button[type=submit]")
        pagina.wait_for_url(f"{URL_APP}/")
        for nombre, ruta, accion in paginas[1:]:
            pagina.goto(URL_APP + ruta)
            if accion:
                pagina.click(f"button[value={accion}]")
                pagina.wait_for_selector(".ventana-sql")
                pagina.locator(".ventana-sql").scroll_into_view_if_needed()
            pagina.wait_for_timeout(700)
            completa = nombre in ("panel", "consultas_linea", "estado")
            pagina.screenshot(path=str(IMG / f"ui_{nombre}.png"), full_page=completa)
        nav.close()


# ----------------------------------------------------------------------------- pruebas
def pruebas(ejecutar: bool) -> dict:
    xml = DOCS / "pruebas" / "resultados.xml"
    xml.parent.mkdir(exist_ok=True)
    if ejecutar:
        subprocess.run([sys.executable, "-m", "pytest", "-q", f"--junitxml={xml}"], cwd=RAIZ)
    if not xml.exists():
        return {"total": 0, "casos": [], "por_archivo": {}}
    raiz = ET.parse(xml).getroot()
    suite = raiz if raiz.tag == "testsuite" else raiz.find("testsuite")
    casos = []
    for tc in suite.iter("testcase"):
        estado = "FALLÓ" if tc.find("failure") is not None or tc.find("error") is not None else (
            "OMITIDA" if tc.find("skipped") is not None else "OK")
        archivo = tc.get("classname", "").split(".")[-1]
        casos.append({"archivo": archivo, "nombre": tc.get("name"), "tiempo": float(tc.get("time", 0)), "estado": estado})
    por_archivo = defaultdict(lambda: {"total": 0, "ok": 0})
    for c in casos:
        por_archivo[c["archivo"]]["total"] += 1
        por_archivo[c["archivo"]]["ok"] += c["estado"] == "OK"
    return {"total": len(casos), "ok": sum(c["estado"] == "OK" for c in casos), "casos": casos,
            "por_archivo": dict(por_archivo), "tiempo": float(suite.get("time", 0))}


def rendimiento() -> list[dict]:
    archivo = DOCS / "rendimiento" / "resultados.csv"
    if not archivo.exists():
        return []
    with open(archivo, encoding="utf-8") as f:
        return [{k: (float(v) if k != "volumen" else int(v)) for k, v in fila.items()} for fila in csv.DictReader(f)]


# ----------------------------------------------------------------------------- PDF
def generar_pdf(html: Path, pdf: Path) -> None:
    from playwright.sync_api import sync_playwright

    pie = ('<div style="font-family:Open Sans,sans-serif;font-size:8px;color:#6b7280;width:100%;padding:0 18mm;'
           'display:flex;justify-content:space-between"><span>AutoAudit · Documentación técnica</span>'
           '<span>Página <span class="pageNumber"></span> de <span class="totalPages"></span></span></div>')
    with sync_playwright() as p:
        nav = p.chromium.launch()
        pagina = nav.new_page()
        pagina.goto(html.as_uri())
        pagina.wait_for_timeout(500)
        pagina.pdf(path=str(pdf), format="Letter", print_background=True, display_header_footer=True,
                   header_template="<span></span>", footer_template=pie,
                   margin={"top": "18mm", "bottom": "20mm", "left": "18mm", "right": "18mm"})
        nav.close()


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sin-capturas", action="store_true")
    ap.add_argument("--sin-pruebas", action="store_true", help="usa el último resultados.xml en vez de ejecutar pytest")
    args = ap.parse_args()
    IMG.mkdir(exist_ok=True)

    with conectar() as conn:
        print("· Diagrama entidad-relación")
        svg_er = diagrama_er(conn)
        print("· Diccionario de datos")
        dic = conn.execute("SELECT * FROM autoaudit.fn_diccionario_datos('autoaudit')").fetchall()
        version_pg = conn.execute("SELECT version() AS v").fetchone()["v"]
        funciones = conn.execute("""
            SELECT p.proname AS nombre, pg_get_function_identity_arguments(p.oid) AS argumentos,
                   obj_description(p.oid, 'pg_proc') AS descripcion
              FROM pg_proc p WHERE p.pronamespace = 'autoaudit'::regnamespace
               AND p.proname LIKE 'fn\\_%' ORDER BY 1""").fetchall()
    tablas = defaultdict(lambda: {"comentario": "", "columnas": []})
    for c in dic:
        tablas[c["tabla"]]["comentario"] = c["comentario_tabla"]
        tablas[c["tabla"]]["columnas"].append(c)
    orden = [t for g in GRUPOS.values() for t in g if t in tablas]

    if not args.sin_capturas:
        print("· Capturas de pantalla")
        capturas()
    print("· Pruebas")
    res_pruebas = pruebas(not args.sin_pruebas)

    so = ""
    if Path("/etc/os-release").exists():
        so = next((l.split("=", 1)[1].strip().strip('"') for l in Path("/etc/os-release").read_text().splitlines()
                   if l.startswith("PRETTY_NAME")), "")

    env = Environment(loader=FileSystemLoader(DOCS), autoescape=True)
    html = env.get_template("plantilla_documento.html").render(
        p=json.loads((DOCS / "portada.json").read_text(encoding="utf-8")),
        svg_er=svg_er, tablas=tablas, orden=orden, grupos=GRUPOS, funciones=funciones,
        pruebas=res_pruebas, rendimiento=rendimiento(), version_pg=version_pg, so=so,
        generado=datetime.now().strftime("%d/%m/%Y %H:%M"), img=IMG.as_uri(),
    )
    salida_html = DOCS / "AutoAudit_Documentacion.html"
    salida_html.write_text(html, encoding="utf-8")
    print("· PDF")
    generar_pdf(salida_html, DOCS / "AutoAudit_Documentacion.pdf")
    print("Listo:", DOCS / "AutoAudit_Documentacion.pdf")


if __name__ == "__main__":
    main()
