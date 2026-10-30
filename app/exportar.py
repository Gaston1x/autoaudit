"""Exportación de reportes en formatos estándar: CSV, Excel, PDF y JSON."""

import csv
import io
import json
from datetime import date, datetime
from decimal import Decimal

FORMATOS = {
    "csv": "text/csv; charset=utf-8",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "pdf": "application/pdf",
    "json": "application/json",
}


def _texto(valor) -> str:
    if valor is None:
        return ""
    if isinstance(valor, datetime):
        return valor.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(valor, (dict, list)):
        return json.dumps(valor, ensure_ascii=False)
    return str(valor)


def _json_default(valor):
    if isinstance(valor, (datetime, date)):
        return valor.isoformat()
    if isinstance(valor, Decimal):
        return str(valor)
    return str(valor)


def a_csv(filas: list[dict], columnas: list[str]) -> bytes:
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(columnas)
    for f in filas:
        w.writerow([_texto(f.get(c)) for c in columnas])
    return ("﻿" + buf.getvalue()).encode("utf-8")  # BOM para que Excel lea las tildes


def a_json(filas: list[dict], columnas: list[str], titulo: str) -> bytes:
    datos = {
        "reporte": titulo,
        "generado": datetime.now().astimezone().isoformat(),
        "total": len(filas),
        "registros": [{c: f.get(c) for c in columnas} for f in filas],
    }
    return json.dumps(datos, ensure_ascii=False, indent=2, default=_json_default).encode("utf-8")


def a_xlsx(filas: list[dict], columnas: list[str], titulo: str) -> bytes:
    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill
    from openpyxl.utils import get_column_letter

    wb = Workbook()
    ws = wb.active
    ws.title = "Bitácora"
    ws.append([titulo])
    ws["A1"].font = Font(bold=True, size=14)
    ws.append([f"Generado: {datetime.now():%Y-%m-%d %H:%M}  -  {len(filas)} registros"])
    ws.append([])
    ws.append(columnas)
    for celda in ws[4]:
        celda.font = Font(bold=True, color="FFFFFF")
        celda.fill = PatternFill("solid", fgColor="1F4E79")
    for f in filas:
        fila = []
        for c in columnas:
            v = f.get(c)
            if isinstance(v, datetime):
                v = v.replace(tzinfo=None)
            elif isinstance(v, (dict, list)):
                v = json.dumps(v, ensure_ascii=False)
            fila.append(v)
        ws.append(fila)
    for i, c in enumerate(columnas, start=1):
        ancho = max([len(c)] + [len(_texto(f.get(c))) for f in filas[:500]])
        ws.column_dimensions[get_column_letter(i)].width = min(ancho + 2, 45)
    ws.freeze_panes = "A5"
    ws.auto_filter.ref = f"A4:{get_column_letter(len(columnas))}{len(filas) + 4}"
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def a_pdf(filas: list[dict], columnas: list[str], titulo: str) -> bytes:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import landscape, letter
    from reportlab.lib.styles import getSampleStyleSheet
    from reportlab.lib.units import cm
    from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

    estilos = getSampleStyleSheet()
    celda = estilos["BodyText"].clone("celda", fontSize=6.5, leading=8)
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=landscape(letter), leftMargin=1 * cm, rightMargin=1 * cm,
                            topMargin=1 * cm, bottomMargin=1 * cm, title=titulo)
    datos = [[Paragraph(f"<b>{c}</b>", celda) for c in columnas]]
    for f in filas:
        datos.append([Paragraph(_texto(f.get(c)).replace("&", "&amp;").replace("<", "&lt;")[:300], celda)
                      for c in columnas])
    tabla = Table(datos, repeatRows=1)
    tabla.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1F4E79")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("GRID", (0, 0), (-1, -1), 0.25, colors.grey),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#EEF3F8")]),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ]))
    doc.build([
        Paragraph(f"AutoAudit - {titulo}", estilos["Title"]),
        Paragraph(f"Generado: {datetime.now():%Y-%m-%d %H:%M} &nbsp; Registros: {len(filas)}", estilos["Normal"]),
        Spacer(1, 0.4 * cm),
        tabla,
    ])
    return buf.getvalue()


def exportar(filas: list[dict], columnas: list[str], formato: str, titulo: str) -> tuple[bytes, str]:
    """Devuelve (contenido, media_type)."""
    formato = formato.lower()
    if formato not in FORMATOS:
        raise ValueError(f"Formato no soportado: {formato}")
    if formato == "csv":
        contenido = a_csv(filas, columnas)
    elif formato == "json":
        contenido = a_json(filas, columnas, titulo)
    elif formato == "xlsx":
        contenido = a_xlsx(filas, columnas, titulo)
    else:
        contenido = a_pdf(filas, columnas, titulo)
    return contenido, FORMATOS[formato]
