"""Conexión a PostgreSQL con psycopg 3.

Cada usuario se conecta con SUS credenciales de PostgreSQL: así los permisos
(administrador / lector) los hace cumplir la propia base de datos.
"""

from contextlib import contextmanager
from typing import Iterator

import psycopg
from psycopg.rows import dict_row

from .config import config


class ErrorAutoAudit(Exception):
    """Error de negocio con un mensaje apto para mostrar al usuario."""


def mensaje_error(exc: Exception) -> str:
    """Extrae el mensaje legible de un error de PostgreSQL."""
    if isinstance(exc, psycopg.Error) and exc.diag.message_primary:
        texto = exc.diag.message_primary
        if exc.diag.message_hint:
            texto += f" ({exc.diag.message_hint})"
        return texto
    return str(exc)


@contextmanager
def conectar(usuario: str, clave: str) -> Iterator[psycopg.Connection]:
    """Abre una conexión, confirma al salir y revierte si hubo error."""
    conn = psycopg.connect(
        host=config.db_host,
        port=config.db_port,
        dbname=config.db_name,
        user=usuario,
        password=clave,
        application_name="AutoAudit",
        row_factory=dict_row,
        connect_timeout=5,
    )
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
