"""Conexión a SQL Server e instalación de los scripts.

La conexión se configura con variables de entorno (nunca en el código):
  AGROEXPORT_SERVER    servidor o instancia, p. ej. localhost o .\\SQLEXPRESS   (por defecto: localhost)
  AGROEXPORT_DATABASE  base de datos                                             (por defecto: AgroExport)
  AGROEXPORT_USER      si se define, usa usuario/clave de SQL; si no, autenticación de Windows
  AGROEXPORT_PASSWORD  clave del usuario anterior
  AGROEXPORT_DRIVER    controlador ODBC                                          (por defecto: ODBC Driver 18 for SQL Server)
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import pyodbc

# Sin pool de conexiones ODBC. Con el pool activo, una conexión que se usó con
# autocommit=False puede reutilizarse para una con autocommit=True y conservar
# una transacción implícita abierta: la fila de auditoría quedaba bloqueada y
# la otra conexión esperaba para siempre. Lo detectamos con sys.dm_tran_locks.
pyodbc.pooling = False

SQL_DIR = Path(__file__).resolve().parent.parent / "sql" / "install"
GO_LINE = re.compile(r"^\s*GO\s*$", re.IGNORECASE | re.MULTILINE)


def database_name() -> str:
    return os.getenv("AGROEXPORT_DATABASE", "AgroExport")


def connection_string(database: str | None = None) -> str:
    server = os.getenv("AGROEXPORT_SERVER", "localhost")
    driver = os.getenv("AGROEXPORT_DRIVER", "ODBC Driver 18 for SQL Server")
    user = os.getenv("AGROEXPORT_USER")
    auth = f"UID={user};PWD={os.environ['AGROEXPORT_PASSWORD']}" if user else "Trusted_Connection=yes"
    # TrustServerCertificate=yes: aceptable en una instancia local de desarrollo.
    return (f"DRIVER={{{driver}}};SERVER={server};DATABASE={database or database_name()};"
            f"{auth};TrustServerCertificate=yes")


def connect(autocommit: bool = False, database: str | None = None) -> pyodbc.Connection:
    return pyodbc.connect(connection_string(database), autocommit=autocommit, timeout=30)


def run_script(conn: pyodbc.Connection, path: Path) -> None:
    """Ejecuta un .sql separando los lotes por GO, como hacen SSMS y VS Code."""
    for batch in GO_LINE.split(path.read_text(encoding="utf-8")):
        if batch.strip():
            conn.execute(batch)


def install(drop_existing: bool = False) -> None:
    """Crea la base si no existe y ejecuta sql/install en orden."""
    name = database_name()
    if not re.fullmatch(r"[A-Za-z0-9_]+", name):
        raise ValueError("El nombre de la base solo admite letras, números y guion bajo.")
    with connect(autocommit=True, database="master") as master:
        if drop_existing:
            master.execute(f"IF DB_ID('{name}') IS NOT NULL BEGIN "
                           f"ALTER DATABASE [{name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
                           f"DROP DATABASE [{name}]; END")
        master.execute(f"IF DB_ID('{name}') IS NULL CREATE DATABASE [{name}]")
    with connect(autocommit=True) as conn:
        # 00_create_database.sql es para la ejecución manual; aquí la base ya existe.
        for script in sorted(SQL_DIR.glob("*.sql")):
            if not script.name.startswith("00_"):
                run_script(conn, script)
