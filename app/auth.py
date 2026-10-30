"""Sesiones web.

El usuario inicia sesión con su usuario de PostgreSQL. Las credenciales se
guardan solo en memoria del servidor; el navegador recibe un token aleatorio.
"""

import secrets
import time
from dataclasses import dataclass, field

from fastapi import Request

from .config import config

COOKIE = "aa_sesion"


@dataclass
class Sesion:
    usuario: str
    clave: str
    es_admin: bool
    es_lector: bool
    expira: float = 0.0
    mensajes: list[tuple[str, str]] = field(default_factory=list)

    def avisar(self, texto: str, tipo: str = "success") -> None:
        self.mensajes.append((tipo, texto))

    def tomar_mensajes(self) -> list[tuple[str, str]]:
        m, self.mensajes = self.mensajes, []
        return m


class NoAutenticado(Exception):
    pass


class NoAutorizado(Exception):
    pass


_SESIONES: dict[str, Sesion] = {}


def crear(sesion: Sesion) -> str:
    token = secrets.token_urlsafe(32)
    sesion.expira = time.time() + config.sesion_minutos * 60
    _SESIONES[token] = sesion
    return token


def cerrar(token: str | None) -> None:
    if token:
        _SESIONES.pop(token, None)


def actual(request: Request) -> Sesion:
    token = request.cookies.get(COOKIE)
    sesion = _SESIONES.get(token or "")
    if sesion is None or sesion.expira < time.time():
        cerrar(token)
        raise NoAutenticado()
    sesion.expira = time.time() + config.sesion_minutos * 60
    return sesion


def admin(request: Request) -> Sesion:
    sesion = actual(request)
    if not sesion.es_admin:
        raise NoAutorizado()
    return sesion
