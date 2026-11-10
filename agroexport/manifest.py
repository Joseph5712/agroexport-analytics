"""Manifiesto de una entrega: qué archivos trae, cuántas filas y su huella.

La huella SHA-256 identifica los bytes exactos de un archivo: si cambia un
solo carácter, cambia la huella. Con ella sabemos si una entrega ya se cargó
(idempotencia) y si un archivo se alteró después de generarse (integridad).
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import date
from pathlib import Path

MANIFEST_NAME = "manifest.json"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        # Se lee por bloques: funciona igual con archivos de varios GB.
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def package_sha256(file_hashes: dict[str, str]) -> str:
    """Huella del paquete completo: combina las huellas de todos sus archivos."""
    lines = "".join(f"{name}:{sha}\n" for name, sha in sorted(file_hashes.items()))
    return hashlib.sha256(lines.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class Manifest:
    package_name: str
    cut_date: date
    kind: str                       # inicial | incremental
    files: dict[str, dict]          # nombre -> {"sha256": ..., "rows": ...}

    @property
    def package_sha256(self) -> str:
        return package_sha256({name: info["sha256"] for name, info in self.files.items()})


def write_manifest(folder: Path, cut_date: date, kind: str, row_counts: dict[str, int]) -> Manifest:
    files = {name: {"sha256": file_sha256(folder / name), "rows": rows}
             for name, rows in sorted(row_counts.items())}
    manifest = Manifest(folder.name, cut_date, kind, files)
    payload = {"package_name": manifest.package_name, "cut_date": cut_date.isoformat(),
               "kind": kind, "files": files}
    (folder / MANIFEST_NAME).write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return manifest


def read_and_verify(folder: Path) -> Manifest:
    """Lee el manifiesto y comprueba que cada archivo conserve su huella."""
    path = folder / MANIFEST_NAME
    if not path.exists():
        raise FileNotFoundError(f"No existe {path}. Una entrega sin manifiesto no se carga.")
    payload = json.loads(path.read_text(encoding="utf-8"))
    for name, info in payload["files"].items():
        actual = file_sha256(folder / name)
        if actual != info["sha256"]:
            raise ValueError(f"{name}: la huella no coincide con el manifiesto. "
                             "El archivo cambió después de generarse.")
    return Manifest(payload["package_name"], date.fromisoformat(payload["cut_date"]),
                    payload["kind"], payload["files"])
