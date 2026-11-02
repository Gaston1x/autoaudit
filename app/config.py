"""Configuración leída del entorno (.env)."""

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

RAIZ = Path(__file__).resolve().parent.parent
load_dotenv(RAIZ / ".env")


@dataclass(frozen=True)
class Config:
    db_host: str = os.getenv("AA_DB_HOST", "localhost")
    db_port: int = int(os.getenv("AA_DB_PORT", "5432"))
    db_name: str = os.getenv("AA_DB_NAME", "autoaudit")
    usuario: str = os.getenv("AA_USUARIO", "")
    clave: str = os.getenv("AA_CLAVE", "")
    sesion_minutos: int = int(os.getenv("AA_SESION_MINUTOS", "60"))
    # Acceso de demostración que se muestra en la pantalla de inicio (opcional, solo lectura).
    demo_usuario: str = os.getenv("AA_DEMO_USUARIO", "")
    demo_clave: str = os.getenv("AA_DEMO_CLAVE", "")


config = Config()
