"""AutoAudit - aplicación web (FastAPI + Jinja2).

Ejecutar:  uvicorn app.main:app --reload
"""

import json
from datetime import date, datetime
from pathlib import Path

import psycopg
from fastapi import Depends, FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from . import __version__, auth, exportar, servicios
from .auth import Sesion
from .config import config
from .db import ErrorAutoAudit, conectar, mensaje_error

BASE = Path(__file__).resolve().parent
app = FastAPI(title="AutoAudit", version=__version__)
app.mount("/static", StaticFiles(directory=BASE / "static"), name="static")
plantillas = Jinja2Templates(directory=BASE / "templates")
plantillas.env.filters["json"] = lambda v: json.dumps(v, ensure_ascii=False, default=str)
plantillas.env.filters["fecha"] = lambda v: v.strftime("%Y-%m-%d %H:%M:%S") if v else ""

EVENTOS = [("I", "INSERT"), ("U", "UPDATE"), ("D", "DELETE")]


def pagina(request: Request, nombre: str, sesion: Sesion | None = None, **ctx) -> HTMLResponse:
    ctx.update(sesion=sesion, mensajes=sesion.tomar_mensajes() if sesion else [], version=__version__,
               demo={"usuario": config.demo_usuario, "clave": config.demo_clave} if config.demo_usuario else None)
    return plantillas.TemplateResponse(request, nombre, ctx)


def volver(url: str) -> RedirectResponse:
    return RedirectResponse(url, status_code=303)


def _fecha(valor: str | None) -> date | None:
    return date.fromisoformat(valor) if valor else None


@app.exception_handler(auth.NoAutenticado)
async def _sin_sesion(request: Request, exc: auth.NoAutenticado):
    return volver("/login")


@app.exception_handler(auth.NoAutorizado)
async def _sin_permiso(request: Request, exc: auth.NoAutorizado):
    sesion = auth.actual(request)
    sesion.avisar("Esta acción requiere el rol de administrador de auditoría (autoaudit_admin).", "danger")
    return volver("/")


# =========================================================================== sesión
@app.get("/login", response_class=HTMLResponse)
def login_form(request: Request):
    return pagina(request, "login.html")


@app.post("/login")
def login(request: Request, usuario: str = Form(...), clave: str = Form(...)):
    try:
        with conectar(usuario, clave) as conn:
            r = servicios.roles(conn)
    except psycopg.OperationalError:
        return pagina(request, "login.html", error="Usuario o contraseña incorrectos, o la base de datos no está disponible.",
                      usuario=usuario)
    if not r["es_lector"]:
        return pagina(request, "login.html", usuario=usuario,
                      error="El usuario no tiene permisos de auditoría (autoaudit_lector o autoaudit_admin).")
    token = auth.crear(Sesion(usuario=usuario, clave=clave, es_admin=r["es_admin"], es_lector=True))
    respuesta = volver("/")
    respuesta.set_cookie(auth.COOKIE, token, httponly=True, samesite="lax")
    return respuesta


@app.get("/salir")
def salir(request: Request):
    auth.cerrar(request.cookies.get(auth.COOKIE))
    respuesta = volver("/login")
    respuesta.delete_cookie(auth.COOKIE)
    return respuesta


# =========================================================================== panel
@app.get("/", response_class=HTMLResponse)
def panel(request: Request, sesion: Sesion = Depends(auth.actual), dias: int = 30):
    with conectar(sesion.usuario, sesion.clave) as conn:
        datos = servicios.resumen(conn, dias)
        estado = servicios.estado(conn)
    dias_eje = sorted({str(a["dia"]) for a in datos["actividad"]})
    series = {nombre: [0] * len(dias_eje) for _, nombre in EVENTOS}
    for a in datos["actividad"]:
        series[a["operacion"]][dias_eje.index(str(a["dia"]))] = a["total"]
    return pagina(request, "panel.html", sesion, datos=datos, estado=estado, dias=dias,
                  grafica={"dias": dias_eje, "series": series})


# =========================================================================== configuración
@app.get("/tablas", response_class=HTMLResponse)
def tablas(request: Request, sesion: Sesion = Depends(auth.actual)):
    with conectar(sesion.usuario, sesion.clave) as conn:
        filas = servicios.listar_tablas(conn)
    return pagina(request, "tablas.html", sesion, tablas=filas)


def _form_a_config(form) -> dict[str, list[str]]:
    """Checkboxes 'ev|columna|I' -> {"columna": ["I", ...]}."""
    config: dict[str, list[str]] = {}
    for clave in form.keys():
        if clave.startswith("ev|"):
            _, columna, evento = clave.split("|", 2)
            config.setdefault(columna, []).append(evento)
    return config


def _vista_tabla(request, sesion, esquema, tabla, **extra):
    with conectar(sesion.usuario, sesion.clave) as conn:
        columnas = servicios.listar_columnas(conn, esquema, tabla)
        historial = servicios.historial_triggers(conn, esquema, tabla)
        estado = next((e for e in servicios.estado(conn) if e["esquema"] == esquema and e["tabla"] == tabla), None)
    seleccion = extra.pop("seleccion", None)
    if seleccion is not None:  # mantener lo marcado en la vista previa
        for c in columnas:
            eventos = seleccion.get(c["columna"], [])
            c["audita_insert"], c["audita_update"], c["audita_delete"] = ("I" in eventos, "U" in eventos, "D" in eventos)
    return pagina(request, "tabla.html", sesion, esquema=esquema, tabla=tabla, columnas=columnas,
                  historial=historial, estado=estado, eventos=EVENTOS, **extra)


@app.get("/tablas/{esquema}/{tabla}", response_class=HTMLResponse)
def tabla_detalle(request: Request, esquema: str, tabla: str, sesion: Sesion = Depends(auth.actual)):
    try:
        return _vista_tabla(request, sesion, esquema, tabla)
    except ErrorAutoAudit as e:
        sesion.avisar(str(e), "danger")
        return volver("/tablas")


@app.post("/tablas/{esquema}/{tabla}", response_class=HTMLResponse)
async def tabla_guardar(request: Request, esquema: str, tabla: str, sesion: Sesion = Depends(auth.admin)):
    form = await request.form()
    accion = form.get("accion", "guardar")
    seleccion = _form_a_config(form)
    try:
        with conectar(sesion.usuario, sesion.clave) as conn:
            if accion == "previsualizar":
                ddl = servicios.previsualizar(conn, esquema, tabla, seleccion)
                return _vista_tabla(request, sesion, esquema, tabla, vista_previa=ddl, seleccion=seleccion)
            if accion == "desactivar":
                r = servicios.desactivar(conn, esquema, tabla)
            elif accion == "regenerar":
                r = {"generacion": servicios.generar(conn, esquema, tabla, forzar=True)}
            else:
                r = servicios.configurar(conn, esquema, tabla, seleccion, generar=True)
        gen = r.get("generacion") or {}
        for v in r.get("validacion", []):
            sesion.avisar(v["mensaje"], "warning" if v["nivel"] != "ERROR" else "danger")
        if gen.get("ok") is False:
            sesion.avisar(f"Configuración guardada, pero el trigger no se generó: {gen.get('mensaje')}", "danger")
        else:
            sesion.avisar(gen.get("mensaje") or "Configuración guardada.", "success")
    except psycopg.Error as e:
        sesion.avisar(mensaje_error(e), "danger")
        _registrar_error_app(sesion, "WEB_CONFIGURACION", e, f"{esquema}.{tabla}")
    return volver(f"/tablas/{esquema}/{tabla}")


def _registrar_error_app(sesion: Sesion, contexto: str, exc: Exception, detalle: str) -> None:
    try:
        with conectar(sesion.usuario, sesion.clave) as conn:
            servicios.registrar_error(conn, contexto, mensaje_error(exc), detalle)
    except psycopg.Error:
        pass


# =========================================================================== estado / administración
@app.get("/estado", response_class=HTMLResponse)
def estado(request: Request, sesion: Sesion = Depends(auth.actual)):
    with conectar(sesion.usuario, sesion.clave) as conn:
        filas = servicios.estado(conn)
        errores = servicios.errores(conn) if sesion.es_admin else []
        cambios = servicios.cambios_configuracion(conn) if sesion.es_admin else []
    return pagina(request, "estado.html", sesion, estado=filas, errores=errores, cambios=cambios)


@app.post("/estado/regenerar")
def regenerar(request: Request, sesion: Sesion = Depends(auth.admin)):
    try:
        with conectar(sesion.usuario, sesion.clave) as conn:
            for r in servicios.regenerar_todos(conn, forzar=True):
                sesion.avisar(f"{r['tabla']}: {r['mensaje']}", "success" if r["ok"] else "danger")
    except psycopg.Error as e:
        sesion.avisar(mensaje_error(e), "danger")
    return volver("/estado")


@app.get("/usuarios", response_class=HTMLResponse)
def usuarios(request: Request, sesion: Sesion = Depends(auth.actual)):
    with conectar(sesion.usuario, sesion.clave) as conn:
        us = servicios.usuarios_auditados(conn)
        es = servicios.estaciones_auditadas(conn)
    return pagina(request, "usuarios.html", sesion, usuarios=us, estaciones=es)


@app.post("/usuarios/{tipo}/{ident}")
def usuarios_auditar(request: Request, tipo: str, ident: int, auditar: str = Form(...),
                     sesion: Sesion = Depends(auth.admin)):
    try:
        with conectar(sesion.usuario, sesion.clave) as conn:
            if tipo == "estacion":
                servicios.set_auditar_estacion(conn, ident, auditar == "1")
            else:
                servicios.set_auditar_usuario(conn, ident, auditar == "1")
        sesion.avisar("Cambio aplicado.")
    except psycopg.Error as e:
        sesion.avisar(mensaje_error(e), "danger")
    return volver("/usuarios")


@app.get("/parametros", response_class=HTMLResponse)
def parametros(request: Request, sesion: Sesion = Depends(auth.admin)):
    with conectar(sesion.usuario, sesion.clave) as conn:
        filas = servicios.parametros(conn)
    return pagina(request, "parametros.html", sesion, parametros=filas)


@app.post("/parametros")
def parametros_guardar(request: Request, clave: str = Form(...), valor: str = Form(...),
                       sesion: Sesion = Depends(auth.admin)):
    try:
        with conectar(sesion.usuario, sesion.clave) as conn:
            servicios.set_parametro(conn, clave, valor)
        sesion.avisar(f"Parámetro {clave} actualizado.")
    except psycopg.Error as e:
        sesion.avisar(mensaje_error(e), "danger")
    return volver("/parametros")


@app.get("/diccionario", response_class=HTMLResponse)
def diccionario(request: Request, esquema: str = "autoaudit", formato: str | None = None,
                sesion: Sesion = Depends(auth.actual)):
    with conectar(sesion.usuario, sesion.clave) as conn:
        filas = servicios.diccionario_datos(conn, esquema)
    if formato:
        cols = ["tabla", "posicion", "columna", "tipo_dato", "nulo", "valor_defecto", "llave", "referencia", "descripcion"]
        contenido, tipo = exportar.exportar(filas, cols, formato, f"Diccionario de datos - {esquema}")
        return Response(contenido, media_type=tipo,
                        headers={"Content-Disposition": f'attachment; filename="diccionario_{esquema}.{formato}"'})
    tablas_dic: dict[str, dict] = {}
    for f in filas:
        tablas_dic.setdefault(f["tabla"], {"comentario": f["comentario_tabla"], "columnas": []})["columnas"].append(f)
    return pagina(request, "diccionario.html", sesion, esquema=esquema, tablas=tablas_dic)


# =========================================================================== consultas
def _consultar(conn, tipo, usuario, columna, desde, hasta, operacion):
    if tipo == "usuario":
        if not usuario:
            return [], "Seleccione un usuario"
        return (servicios.cambios_por_usuario(conn, usuario, _fecha(desde), _fecha(hasta)),
                f"Cambios del usuario {usuario}")
    if not columna:
        return [], "Seleccione una columna"
    esquema, tabla, col = columna.split("|", 2)
    return (servicios.cambios_por_columna(conn, esquema, tabla, col, _fecha(desde), _fecha(hasta), operacion),
            f"Cambios en la columna {esquema}.{tabla}.{col}")


@app.get("/consultas", response_class=HTMLResponse)
def consultas(request: Request, tipo: str = "usuario", usuario: str = "", columna: str = "",
              desde: str = "", hasta: str = "", operacion: str = "", vista: str = "tabla",
              sesion: Sesion = Depends(auth.actual)):
    filas, titulo = [], ""
    with conectar(sesion.usuario, sesion.clave) as conn:
        lista_usuarios = sorted({u["usuario_bd"] for u in servicios.usuarios_auditados(conn)} |
                                {u["usuario_app"] for u in servicios.usuarios_auditados(conn) if u["usuario_app"]})
        lista_columnas = servicios.columnas_auditadas(conn)
        if usuario or columna:
            filas, titulo = _consultar(conn, tipo, usuario, columna, desde, hasta, operacion)
    return pagina(request, "consultas.html", sesion, filas=filas[:2000], total=len(filas), titulo=titulo,
                  operaciones=servicios.agrupar_operaciones(filas[:2000]) if vista == "linea" else [],
                  usuarios=lista_usuarios, columnas=lista_columnas, columnas_bitacora=servicios.COLUMNAS_BITACORA,
                  f=dict(tipo=tipo, usuario=usuario, columna=columna, desde=desde, hasta=hasta,
                         operacion=operacion, vista=vista),
                  query=request.url.query)


@app.get("/consultas/exportar")
def consultas_exportar(tipo: str = "usuario", usuario: str = "", columna: str = "", desde: str = "",
                       hasta: str = "", operacion: str = "", formato: str = "csv",
                       sesion: Sesion = Depends(auth.actual)):
    with conectar(sesion.usuario, sesion.clave) as conn:
        filas, titulo = _consultar(conn, tipo, usuario, columna, desde, hasta, operacion)
    contenido, media = exportar.exportar(filas, servicios.COLUMNAS_BITACORA, formato, titulo)
    nombre = f"autoaudit_{tipo}_{datetime.now():%Y%m%d_%H%M%S}.{formato}"
    return Response(contenido, media_type=media, headers={"Content-Disposition": f'attachment; filename="{nombre}"'})


@app.get("/registro", response_class=HTMLResponse)
def registro(request: Request, tabla: str = "", pk: str = "", fecha: str = "",
             sesion: Sesion = Depends(auth.actual)):
    operaciones, estado_fecha, error = [], None, None
    with conectar(sesion.usuario, sesion.clave) as conn:
        tablas_aud = [t for t in servicios.listar_tablas(conn) if t["tabla_id"]]
        if tabla and pk:
            try:
                pk_json = json.loads(pk)
                if not isinstance(pk_json, dict):
                    raise ValueError
                esquema, nombre = tabla.split(".", 1)
                operaciones = servicios.agrupar_operaciones(servicios.historial_registro(conn, esquema, nombre, pk_json))
                if fecha:
                    estado_fecha = servicios.estado_en_fecha(conn, esquema, nombre, pk_json,
                                                             datetime.fromisoformat(fecha).astimezone())
            except ValueError:
                error = 'La llave debe ser un objeto JSON, por ejemplo {"id": 1}'
    return pagina(request, "registro.html", sesion, tablas=tablas_aud, operaciones=operaciones,
                  estado_fecha=estado_fecha, error=error, f=dict(tabla=tabla, pk=pk, fecha=fecha))
