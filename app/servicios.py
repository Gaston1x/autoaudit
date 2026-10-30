"""Operaciones de AutoAudit. Las usan la web, la CLI y las pruebas.

Toda la lógica de auditoría vive en PostgreSQL (PL/pgSQL); aquí solo se llaman
las funciones del esquema "autoaudit" con consultas parametrizadas.
"""

from datetime import date, datetime, timedelta
from typing import Any

from psycopg import Connection
from psycopg.types.json import Jsonb

from .db import ErrorAutoAudit

# Columnas que se muestran/exportan en las consultas históricas.
COLUMNAS_BITACORA = [
    "fecha_hora", "operacion", "esquema", "tabla", "pk_registro", "columna",
    "valor_anterior", "valor_nuevo", "usuario_bd", "usuario_app", "estacion", "ip", "aplicacion",
]
_SELECT_BITACORA = ", ".join(["bitacora_id", "txid", *COLUMNAS_BITACORA])


# --------------------------------------------------------------------------- sesión
def roles(conn: Connection) -> dict[str, bool]:
    fila = conn.execute(
        """SELECT session_user AS usuario,
                  pg_has_role(session_user, 'autoaudit_admin', 'MEMBER')  AS es_admin,
                  pg_has_role(session_user, 'autoaudit_lector', 'MEMBER') AS es_lector"""
    ).fetchone()
    return fila


# --------------------------------------------------------------------------- diccionario
def listar_tablas(conn: Connection) -> list[dict]:
    return conn.execute("SELECT * FROM autoaudit.fn_listar_tablas()").fetchall()


def listar_columnas(conn: Connection, esquema: str, tabla: str) -> list[dict]:
    filas = conn.execute(
        "SELECT * FROM autoaudit.fn_listar_columnas(%s, %s)", (esquema, tabla)
    ).fetchall()
    if not filas:
        raise ErrorAutoAudit(f"La tabla {esquema}.{tabla} no existe")
    return filas


def diccionario_datos(conn: Connection, esquema: str = "autoaudit") -> list[dict]:
    return conn.execute(
        "SELECT * FROM autoaudit.fn_diccionario_datos(%s)", (esquema,)
    ).fetchall()


# --------------------------------------------------------------------------- configuración
def configurar(conn: Connection, esquema: str, tabla: str,
               columnas: dict[str, list[str]], generar: bool = True) -> dict:
    """columnas = {"nombre": ["I", "U", "D"], ...}; las omitidas quedan sin auditar."""
    return conn.execute(
        "SELECT autoaudit.fn_configurar_tabla(%s, %s, %s, %s) AS r",
        (esquema, tabla, Jsonb(columnas), generar),
    ).fetchone()["r"]


def previsualizar(conn: Connection, esquema: str, tabla: str,
                  columnas: dict[str, list[str]]) -> str:
    """SQL que se generaría con esa configuración, sin guardar nada."""
    with conn.transaction(force_rollback=True):
        configurar(conn, esquema, tabla, columnas, generar=False)
        return conn.execute(
            "SELECT autoaudit.fn_previsualizar_trigger(%s, %s) AS ddl", (esquema, tabla)
        ).fetchone()["ddl"]


def generar(conn: Connection, esquema: str, tabla: str, forzar: bool = False) -> dict:
    return conn.execute(
        "SELECT autoaudit.fn_generar_trigger(%s, %s, %s) AS r", (esquema, tabla, forzar)
    ).fetchone()["r"]


def desactivar(conn: Connection, esquema: str, tabla: str) -> dict:
    return conn.execute(
        "SELECT autoaudit.fn_desactivar_tabla(%s, %s) AS r", (esquema, tabla)
    ).fetchone()["r"]


def regenerar_todos(conn: Connection, forzar: bool = False) -> list[dict]:
    return conn.execute("SELECT * FROM autoaudit.fn_regenerar_todos(%s)", (forzar,)).fetchall()


def historial_triggers(conn: Connection, esquema: str, tabla: str) -> list[dict]:
    return conn.execute(
        """SELECT g.id, g.eventos, g.estado, g.generado, g.generado_por, g.ddl
             FROM autoaudit.aud_trigger g
             JOIN autoaudit.aud_tabla t ON t.id = g.tabla_id
            WHERE t.esquema = %s AND t.nombre = %s AND NOT t.eliminada
            ORDER BY g.id DESC""",
        (esquema, tabla),
    ).fetchall()


# --------------------------------------------------------------------------- estado
def estado(conn: Connection) -> list[dict]:
    return conn.execute(
        "SELECT * FROM autoaudit.v_estado_triggers ORDER BY esquema, tabla"
    ).fetchall()


def errores(conn: Connection, limite: int = 50) -> list[dict]:
    return conn.execute(
        """SELECT e.fecha, e.usuario, e.contexto, t.esquema || '.' || t.nombre AS tabla,
                  e.sqlstate, e.mensaje, e.detalle
             FROM autoaudit.aud_error e LEFT JOIN autoaudit.aud_tabla t ON t.id = e.tabla_id
            ORDER BY e.id DESC LIMIT %s""",
        (limite,),
    ).fetchall()


def cambios_configuracion(conn: Connection, limite: int = 50) -> list[dict]:
    return conn.execute(
        """SELECT c.fecha, c.usuario, c.accion, t.esquema || '.' || t.nombre AS tabla, c.detalle
             FROM autoaudit.aud_cambio_config c LEFT JOIN autoaudit.aud_tabla t ON t.id = c.tabla_id
            ORDER BY c.id DESC LIMIT %s""",
        (limite,),
    ).fetchall()


def registrar_error(conn: Connection, contexto: str, mensaje: str, detalle: str | None = None) -> None:
    conn.execute("SELECT autoaudit.fn_registrar_error(%s, %s, %s)", (contexto, mensaje, detalle))


# --------------------------------------------------------------------------- consultas
def _rango(desde: date | None, hasta: date | None) -> tuple[datetime | None, datetime | None]:
    """Convierte fechas (inclusivas) en un rango [desde, hasta+1día)."""
    d = datetime.combine(desde, datetime.min.time()).astimezone() if desde else None
    h = datetime.combine(hasta + timedelta(days=1), datetime.min.time()).astimezone() if hasta else None
    return d, h


def cambios_por_usuario(conn: Connection, usuario: str, desde: date | None = None,
                        hasta: date | None = None, esquema: str | None = None,
                        tabla: str | None = None) -> list[dict]:
    d, h = _rango(desde, hasta)
    return conn.execute(
        f"SELECT {_SELECT_BITACORA} FROM autoaudit.fn_cambios_por_usuario(%s, %s, %s, %s, %s)",
        (usuario, d, h, esquema or None, tabla or None),
    ).fetchall()


def cambios_por_columna(conn: Connection, esquema: str, tabla: str, columna: str,
                        desde: date | None = None, hasta: date | None = None,
                        operacion: str | None = None) -> list[dict]:
    d, h = _rango(desde, hasta)
    return conn.execute(
        f"SELECT {_SELECT_BITACORA} FROM autoaudit.fn_cambios_por_columna(%s, %s, %s, %s, %s, %s)",
        (esquema, tabla, columna, d, h, operacion or None),
    ).fetchall()


def historial_registro(conn: Connection, esquema: str, tabla: str, pk: dict) -> list[dict]:
    return conn.execute(
        f"SELECT {_SELECT_BITACORA} FROM autoaudit.fn_historial_registro(%s, %s, %s)",
        (esquema, tabla, Jsonb(pk)),
    ).fetchall()


def estado_en_fecha(conn: Connection, esquema: str, tabla: str, pk: dict, fecha: datetime) -> dict:
    return conn.execute(
        "SELECT autoaudit.fn_estado_en_fecha(%s, %s, %s, %s) AS r",
        (esquema, tabla, Jsonb(pk), fecha),
    ).fetchone()["r"]


def agrupar_operaciones(filas: list[dict]) -> list[dict]:
    """Agrupa las filas (una por columna) en operaciones, para la línea de tiempo."""
    ops: dict[int, dict[str, Any]] = {}
    for f in filas:
        op = ops.setdefault(f["bitacora_id"], {
            "bitacora_id": f["bitacora_id"], "fecha_hora": f["fecha_hora"], "operacion": f["operacion"],
            "esquema": f["esquema"], "tabla": f["tabla"], "pk_registro": f["pk_registro"],
            "usuario_bd": f["usuario_bd"], "usuario_app": f["usuario_app"],
            "estacion": f["estacion"], "ip": f["ip"], "cambios": [],
        })
        if f["columna"] is not None:
            op["cambios"].append(f)
    return sorted(ops.values(), key=lambda o: (o["fecha_hora"], o["bitacora_id"]))


def usuarios_auditados(conn: Connection) -> list[dict]:
    return conn.execute(
        """SELECT u.id, u.usuario_bd, u.usuario_app, u.auditar, u.primera_actividad,
                  (SELECT count(*) FROM autoaudit.aud_bitacora b WHERE b.usuario_id = u.id) AS operaciones
             FROM autoaudit.aud_usuario u ORDER BY u.usuario_bd, u.usuario_app"""
    ).fetchall()


def estaciones_auditadas(conn: Connection) -> list[dict]:
    return conn.execute("SELECT * FROM autoaudit.v_estacion ORDER BY id").fetchall()


def columnas_auditadas(conn: Connection) -> list[dict]:
    """Columnas con historial (para los filtros de consulta)."""
    return conn.execute(
        """SELECT DISTINCT t.esquema, t.nombre AS tabla, c.nombre AS columna
             FROM autoaudit.aud_columna c JOIN autoaudit.aud_tabla t ON t.id = c.tabla_id
            WHERE EXISTS (SELECT 1 FROM autoaudit.aud_configuracion cf WHERE cf.columna_id = c.id)
            ORDER BY 1, 2, 3"""
    ).fetchall()


def set_auditar_usuario(conn: Connection, usuario_id: int, auditar: bool) -> None:
    conn.execute("SELECT autoaudit.fn_set_auditar_usuario(%s, %s)", (usuario_id, auditar))


def set_auditar_estacion(conn: Connection, estacion_id: int, auditar: bool) -> None:
    conn.execute("SELECT autoaudit.fn_set_auditar_estacion(%s, %s)", (estacion_id, auditar))


# --------------------------------------------------------------------------- panel
def resumen(conn: Connection, dias: int = 30) -> dict:
    hasta = datetime.now().astimezone() + timedelta(days=1)
    desde = hasta - timedelta(days=dias + 1)
    datos = conn.execute("SELECT autoaudit.fn_resumen(%s, %s) AS r", (desde, hasta)).fetchone()["r"]
    datos["actividad"] = conn.execute(
        "SELECT dia, operacion, total FROM autoaudit.fn_actividad_diaria(%s, %s)", (desde, hasta)
    ).fetchall()
    return datos


# --------------------------------------------------------------------------- parámetros
def parametros(conn: Connection) -> list[dict]:
    return conn.execute(
        """SELECT clave, CASE WHEN clave = 'sal_ip' THEN '********' ELSE valor END AS valor,
                  descripcion, modificado, modificado_por
             FROM autoaudit.aud_parametro ORDER BY clave"""
    ).fetchall()


def set_parametro(conn: Connection, clave: str, valor: str) -> None:
    conn.execute("SELECT autoaudit.fn_set_parametro(%s, %s)", (clave, valor))
