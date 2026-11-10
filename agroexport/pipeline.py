"""Carga de una entrega: de los archivos al almacén, todo o nada.

Pasos:
  1. Verificar el manifiesto: cada archivo conserva su huella.
  2. Registrar el intento como Running (en una conexión aparte, con autocommit).
  3. Validar los archivos en Python (tipos, reglas, referencias, duplicados).
  4. En UNA transacción:
       a. Tomar un candado exclusivo para que nunca publiquen dos cargas a la vez.
       b. Si este paquete ya se publicó, marcar Skipped y salir (idempotencia).
       c. Vaciar staging y llenarlo con las filas válidas.
       d. Publicar al almacén y conciliar (etl.usp_PublishBatch).
       e. Calcular alertas (dq.usp_RunChecks) y guardar las filas rechazadas.
       f. Marcar Succeeded y confirmar (COMMIT).
  5. Si algo falla: ROLLBACK (el almacén queda como estaba) y marcar Failed.

¿Por qué dos conexiones? Si el estado Failed se escribiera en la misma
transacción, el ROLLBACK también lo borraría y no quedaría rastro del fallo.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from . import db
from .manifest import read_and_verify
from .schemas import FILES
from .validate import validate_package

PUBLISH_LOCK = "AgroExport.Publish"


class SimulatedFailure(RuntimeError):
    """Fallo provocado a propósito para demostrar la recuperación."""


@dataclass
class LoadResult:
    batch_id: int
    status: str
    rows_read: int = 0
    rows_rejected: int = 0
    rows_duplicated: int = 0
    message: str = ""


def load_package(folder: Path, simulate_failure: bool = False) -> LoadResult:
    folder = Path(folder)
    manifest = read_and_verify(folder)

    audit = db.connect(autocommit=True)
    work = db.connect(autocommit=False)
    try:
        batch_id = _register_running(audit, manifest)

        try:
            validation = validate_package(folder)
            cursor = work.cursor()

            lock = cursor.execute(
                "SET NOCOUNT ON; DECLARE @r INT; "
                "EXEC @r = sp_getapplock @Resource = ?, @LockMode = 'Exclusive', "
                "@LockOwner = 'Transaction', @LockTimeout = 60000; SELECT @r;", PUBLISH_LOCK).fetchval()
            if lock < 0:
                raise RuntimeError("No se obtuvo el candado de publicación: otra carga sigue en curso.")

            # Se pregunta DENTRO del candado: dos procesos simultáneos no pueden pasar ambos.
            # CAST: el parámetro llega como NVARCHAR; convertirlo permite usar el índice filtrado.
            published = cursor.execute(
                "SELECT LoadBatchID FROM etl.LoadBatch "
                "WHERE PackageSha256 = CAST(? AS CHAR(64)) AND Status = 'Succeeded'",
                manifest.package_sha256).fetchval()
            if published:
                work.rollback()
                message = f"El paquete ya se publicó en la carga {published}. No se modificó nada."
                _finish(audit, batch_id, "Skipped", message=message)
                return LoadResult(batch_id, "Skipped", message=message)

            _fill_staging(cursor, validation.rows)
            cursor.execute("EXEC etl.usp_PublishBatch @LoadBatchID = ?", batch_id)
            cursor.execute("EXEC dq.usp_RunChecks @LoadBatchID = ?, @CutDate = ?", batch_id, manifest.cut_date)
            _save_files_and_rejects(cursor, batch_id, manifest.files, validation.rejected)

            if simulate_failure:
                raise SimulatedFailure("Fallo simulado después de publicar y antes de confirmar.")

            cursor.execute(
                "UPDATE etl.LoadBatch SET Status = 'Succeeded', FinishedAtUtc = SYSUTCDATETIME(), "
                "RowsRead = ?, RowsRejected = ?, RowsDuplicated = ? WHERE LoadBatchID = ?",
                validation.rows_read, len(validation.rejected), validation.duplicates, batch_id)
            work.commit()
            return LoadResult(batch_id, "Succeeded", validation.rows_read,
                              len(validation.rejected), validation.duplicates)

        except Exception as error:
            work.rollback()                    # primero deshacer (libera candados)...
            _finish(audit, batch_id, "Failed", message=str(error)[:2000])   # ...después registrar
            raise
    finally:
        work.close()
        audit.close()


def _register_running(audit, manifest) -> int:
    """Inserta el intento como Running y devuelve su ID.

    Se consume todo el resultado y se cierra el cursor: con INSERT ... OUTPUT
    la sentencia no termina hasta que el cliente lee todo lo que devuelve.
    """
    cursor = audit.cursor()
    try:
        cursor.execute("INSERT etl.LoadBatch (PackageName, PackageSha256, CutDate) "
                       "OUTPUT inserted.LoadBatchID VALUES (?, ?, ?)",
                       manifest.package_name, manifest.package_sha256, manifest.cut_date)
        batch_id = cursor.fetchval()
        while cursor.nextset():
            pass
        return batch_id
    finally:
        cursor.close()


def _finish(audit, batch_id: int, status: str, message: str) -> None:
    audit.execute("UPDATE etl.LoadBatch SET Status = ?, FinishedAtUtc = SYSUTCDATETIME(), ErrorMessage = ? "
                  "WHERE LoadBatchID = ?", status, message, batch_id)


def _fill_staging(cursor, rows: dict[str, list[dict]]) -> None:
    cursor.fast_executemany = True             # envía las filas en bloque, no una por una
    for schema in FILES:
        cursor.execute(f"DELETE FROM {schema.table}")
        data = [tuple(row[c.name] for c in schema.columns) for row in rows[schema.file_name]]
        if data:
            columns = ", ".join(c.sql_name for c in schema.columns)
            marks = ", ".join("?" for _ in schema.columns)
            cursor.executemany(f"INSERT {schema.table} ({columns}) VALUES ({marks})", data)


def _save_files_and_rejects(cursor, batch_id: int, files: dict, rejected: list) -> None:
    cursor.executemany(
        "INSERT etl.LoadBatchFile (LoadBatchID, FileName, FileSha256, RowsInFile) VALUES (?, ?, ?, ?)",
        [(batch_id, name, info["sha256"], info["rows"]) for name, info in files.items()])
    if rejected:
        cursor.executemany(
            "INSERT dq.RejectedRow (LoadBatchID, FileName, LineNumber, Reason, RawData) VALUES (?, ?, ?, ?, ?)",
            [(batch_id, r.file_name, r.line_number, r.reason, json.dumps(r.raw, ensure_ascii=False))
             for r in rejected])


def recent_batches(limit: int = 10) -> list:
    with db.connect(autocommit=True) as conn:
        return conn.execute(
            "SELECT TOP (?) LoadBatchID, PackageName, Status, RowsRead, RowsRejected, RowsDuplicated, "
            "StartedAtUtc, LEFT(ISNULL(ErrorMessage, ''), 90) FROM etl.LoadBatch ORDER BY LoadBatchID DESC",
            limit).fetchall()
