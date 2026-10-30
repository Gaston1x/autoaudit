"""AutoAudit - interfaz de línea de comandos.

Ejemplos:
    python cli.py tablas
    python cli.py columnas demo clientes
    python cli.py configurar demo clientes nombre=IUD correo=U
    python cli.py previsualizar demo clientes nombre=IUD
    python cli.py estado
    python cli.py usuario cajero1 --formato csv --salida cajero1.csv
    python cli.py columna demo clientes limite_credito

Credenciales: variables AA_USUARIO / AA_CLAVE (archivo .env) o --usuario/--clave.
"""

from datetime import date
from pathlib import Path
from typing import Optional

import psycopg
import typer

from app import exportar, servicios
from app.config import config
from app.db import ErrorAutoAudit, conectar, mensaje_error

cli = typer.Typer(help="AutoAudit: auditoría automatizada para PostgreSQL", no_args_is_help=True)
_cred = {"usuario": config.usuario, "clave": config.clave}


@cli.callback()
def principal(usuario: Optional[str] = typer.Option(None, help="Usuario de PostgreSQL"),
              clave: Optional[str] = typer.Option(None, help="Contraseña")):
    if usuario:
        _cred["usuario"] = usuario
    if clave:
        _cred["clave"] = clave


def _conn():
    return conectar(_cred["usuario"], _cred["clave"])


def _tabla(filas: list[dict], columnas: list[str]) -> None:
    if not filas:
        typer.echo("(sin resultados)")
        return
    textos = [[exportar._texto(f.get(c)) for c in columnas] for f in filas]
    anchos = [min(max(len(c), *(len(t[i]) for t in textos)), 40) for i, c in enumerate(columnas)]
    typer.echo("  ".join(c.ljust(a) for c, a in zip(columnas, anchos)))
    typer.echo("  ".join("-" * a for a in anchos))
    for t in textos:
        typer.echo("  ".join(v[:a].ljust(a) for v, a in zip(t, anchos)))


def _parsear_columnas(pares: list[str]) -> dict[str, list[str]]:
    """['nombre=IUD', 'correo=U'] -> {'nombre': ['I','U','D'], 'correo': ['U']}"""
    resultado = {}
    for par in pares:
        if "=" not in par:
            raise typer.BadParameter(f"Use columna=EVENTOS, por ejemplo nombre=IUD (recibido: {par})")
        col, ev = par.split("=", 1)
        resultado[col] = list(dict.fromkeys(ev.upper()))
    return resultado


def _ejecutar(fn):
    try:
        return fn()
    except (psycopg.Error, ErrorAutoAudit) as e:
        typer.secho(f"Error: {mensaje_error(e)}", fg=typer.colors.RED, err=True)
        raise typer.Exit(1)


@cli.command()
def tablas():
    """Lista las tablas de la base de datos (diccionario de datos)."""
    with _conn() as conn:
        filas = _ejecutar(lambda: servicios.listar_tablas(conn))
    _tabla(filas, ["esquema", "tabla", "filas_estimadas", "tiene_pk", "auditada", "trigger_activo"])


@cli.command()
def columnas(esquema: str, tabla: str):
    """Lista las columnas de una tabla y lo que se audita en cada una."""
    with _conn() as conn:
        filas = _ejecutar(lambda: servicios.listar_columnas(conn, esquema, tabla))
    _tabla(filas, ["attnum", "columna", "tipo_dato", "es_pk", "audita_insert", "audita_update", "audita_delete"])


@cli.command()
def configurar(esquema: str, tabla: str, columnas: list[str] = typer.Argument(..., help="columna=IUD ...")):
    """Configura columnas/eventos y genera el trigger."""
    config_cols = _parsear_columnas(columnas)
    with _conn() as conn:
        r = _ejecutar(lambda: servicios.configurar(conn, esquema, tabla, config_cols))
    for v in r.get("validacion", []):
        typer.secho(f"[{v['nivel']}] {v['mensaje']}", fg=typer.colors.YELLOW)
    gen = r.get("generacion", {})
    typer.secho(gen.get("mensaje", ""), fg=typer.colors.GREEN if gen.get("ok") else typer.colors.RED)


@cli.command()
def previsualizar(esquema: str, tabla: str, columnas: list[str] = typer.Argument(..., help="columna=IUD ...")):
    """Muestra el SQL del trigger sin guardar nada."""
    config_cols = _parsear_columnas(columnas)
    with _conn() as conn:
        typer.echo(_ejecutar(lambda: servicios.previsualizar(conn, esquema, tabla, config_cols)))


@cli.command()
def desactivar(esquema: str, tabla: str):
    """Desactiva la auditoría de una tabla (la bitácora se conserva)."""
    with _conn() as conn:
        r = _ejecutar(lambda: servicios.desactivar(conn, esquema, tabla))
    typer.echo(r.get("generacion", {}).get("mensaje", "Listo"))


@cli.command()
def estado():
    """Estado de los triggers frente a la configuración."""
    with _conn() as conn:
        filas = _ejecutar(lambda: servicios.estado(conn))
    _tabla(filas, ["esquema", "tabla", "activa", "configuraciones_activas", "eventos", "estado"])


def _reporte(filas, titulo, formato, salida):
    if formato == "texto":
        _tabla(filas, ["fecha_hora", "operacion", "tabla", "pk_registro", "columna", "valor_anterior",
                       "valor_nuevo", "usuario_bd", "usuario_app", "estacion"])
        return
    contenido, _ = exportar.exportar(filas, servicios.COLUMNAS_BITACORA, formato, titulo)
    destino = salida or Path(f"reporte.{formato}")
    destino.write_bytes(contenido)
    typer.secho(f"{len(filas)} filas exportadas a {destino}", fg=typer.colors.GREEN)


@cli.command()
def usuario(nombre: str, desde: Optional[str] = None, hasta: Optional[str] = None,
            formato: str = typer.Option("texto", help="texto | csv | xlsx | pdf | json"),
            salida: Optional[Path] = None):
    """Historial de cambios de un usuario."""
    with _conn() as conn:
        filas = _ejecutar(lambda: servicios.cambios_por_usuario(
            conn, nombre, date.fromisoformat(desde) if desde else None, date.fromisoformat(hasta) if hasta else None))
    _reporte(filas, f"Cambios del usuario {nombre}", formato, salida)


@cli.command()
def columna(esquema: str, tabla: str, nombre: str, operacion: Optional[str] = None,
            formato: str = typer.Option("texto", help="texto | csv | xlsx | pdf | json"),
            salida: Optional[Path] = None):
    """Todos los cambios de una columna específica."""
    with _conn() as conn:
        filas = _ejecutar(lambda: servicios.cambios_por_columna(conn, esquema, tabla, nombre, operacion=operacion))
    _reporte(filas, f"Cambios en {esquema}.{tabla}.{nombre}", formato, salida)


if __name__ == "__main__":
    cli()
