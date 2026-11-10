"""Validación de una entrega antes de tocar la base de datos.

Cada fila pasa por tres filtros, en este orden:
  1. Tipos: ¿la fecha es una fecha?, ¿la cantidad es un entero?
  2. Reglas de negocio: cantidad > 0, un embarque despachado tiene fecha, etc.
  3. Referencias: ¿el cliente y el producto existen en los datos maestros?
Después se revisan los duplicados por clave:
  * Copias idénticas: se conserva una y se cuentan (advertencia).
  * Misma clave con datos distintos: no sabemos cuál es la correcta, así que
    se rechazan todas las versiones para que alguien las revise.
Una fila rechazada no detiene la carga: se guarda en dq.RejectedRow.
"""
from __future__ import annotations

import csv
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from .schemas import FILES, FileSchema, ParseError

MASTER_FILES = ("companies.csv", "customers.csv", "products.csv", "fx_rates.csv")


@dataclass
class Rejected:
    file_name: str
    line_number: int          # línea del CSV; la 1 es el encabezado
    reason: str
    raw: dict


@dataclass
class ValidationResult:
    rows: dict[str, list[dict]] = field(default_factory=dict)   # filas válidas y tipadas
    rejected: list[Rejected] = field(default_factory=list)
    duplicates: int = 0
    rows_read: int = 0


@dataclass
class References:
    companies: set = field(default_factory=set)
    customers: set = field(default_factory=set)
    products: set = field(default_factory=set)
    fx: set = field(default_factory=set)


# --- Reglas por archivo: devuelven el motivo del rechazo o None ---------------

def _customer(row, refs):
    if row["payment_terms_days"] < 0:
        return "días de crédito negativos"


def _product(row, refs):
    if row["kg_per_unit"] <= 0:
        return "kg por unidad debe ser mayor que cero"
    if row["shelf_life_days"] <= 0:
        return "vida útil debe ser mayor que cero"


def _fx(row, refs):
    if row["usd_per_unit"] <= 0:
        return "tipo de cambio debe ser positivo"


def _sales(row, refs):
    company = row["company_code"]
    if company not in refs.companies:
        return f"sociedad {company} no existe"
    if (company, row["customer_code"]) not in refs.customers:
        return f"cliente {row['customer_code']} no existe en {company}"
    if (company, row["product_code"]) not in refs.products:
        return f"producto {row['product_code']} no existe en {company}"
    if row["quantity"] <= 0:
        return "la cantidad debe ser mayor que cero (el signo lo da el tipo de documento)"
    if row["unit_price"] < 0 or row["line_cost_usd"] < 0:
        return "precio y costo no pueden ser negativos"
    if row["currency"] != "USD" and (row["doc_date"], row["currency"]) not in refs.fx:
        return f"no hay tipo de cambio {row['currency']} para {row['doc_date']}"
    if row["doc_type"] == "CN" and not row["ref_doc_number"]:
        return "una nota de crédito debe indicar su factura de referencia"


def _lot(row, refs):
    if (row["company_code"], row["product_code"]) not in refs.products:
        return f"producto {row['product_code']} no existe en {row['company_code']}"
    if row["qty_kg"] < 0:
        return "existencia en kg negativa"
    if row["expiry_date"] < row["production_date"]:
        return "vence antes de producirse"


def _shipment(row, refs):
    if (row["company_code"], row["customer_code"]) not in refs.customers:
        return f"cliente {row['customer_code']} no existe en {row['company_code']}"
    if row["containers"] <= 0:
        return "contenedores debe ser mayor que cero"
    shipped = row["status"] == "SHIPPED"
    if shipped and row["actual_ship_date"] is None:
        return "embarque SHIPPED sin fecha real de despacho"
    if not shipped and row["actual_ship_date"] is not None:
        return f"embarque {row['status']} no debería tener fecha real"


def _receivable(row, refs):
    if (row["company_code"], row["customer_code"]) not in refs.customers:
        return f"cliente {row['customer_code']} no existe en {row['company_code']}"
    if row["open_amount_usd"] <= 0:
        return "saldo abierto debe ser positivo"
    if row["due_date"] < row["doc_date"]:
        return "vence antes de emitirse"


RULES: dict[str, Callable] = {
    "companies.csv": lambda row, refs: None,
    "customers.csv": _customer,
    "products.csv": _product,
    "fx_rates.csv": _fx,
    "sales_lines.csv": _sales,
    "lot_snapshots.csv": _lot,
    "shipments.csv": _shipment,
    "receivables.csv": _receivable,
}


# --- Proceso -------------------------------------------------------------------

def _parse_row(schema: FileSchema, raw: dict) -> dict:
    typed = {}
    for column in schema.columns:
        value = (raw.get(column.name) or "").strip()
        if value == "":
            if column.required:
                raise ParseError(f"{column.name}: valor obligatorio vacío")
            typed[column.name] = None
        else:
            try:
                typed[column.name] = column.parse(value)
            except ParseError as error:
                raise ParseError(f"{column.name}: {error}") from None
    return typed


def _validate_file(folder: Path, schema: FileSchema, refs: References, result: ValidationResult) -> None:
    candidates = []   # (número de línea, fila original, fila tipada)
    with (folder / schema.file_name).open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        missing = set(schema.column_names) - set(reader.fieldnames or [])
        if missing:
            # Un archivo sin las columnas del contrato no se puede interpretar: se detiene todo.
            raise ValueError(f"{schema.file_name}: faltan columnas {sorted(missing)}")
        for line_number, raw in enumerate(reader, start=2):
            result.rows_read += 1
            try:
                typed = _parse_row(schema, raw)
            except ParseError as error:
                result.rejected.append(Rejected(schema.file_name, line_number, str(error), raw))
                continue
            reason = RULES[schema.file_name](typed, refs)
            if reason:
                result.rejected.append(Rejected(schema.file_name, line_number, reason, raw))
                continue
            candidates.append((line_number, raw, typed))

    by_key = defaultdict(list)
    for item in candidates:
        by_key[tuple(item[2][k] for k in schema.key)].append(item)

    valid = []
    for key, group in by_key.items():
        first_typed = group[0][2]
        if all(typed == first_typed for _, _, typed in group):
            valid.append(first_typed)
            result.duplicates += len(group) - 1
        else:
            for line_number, raw, _ in group:
                result.rejected.append(Rejected(schema.file_name, line_number,
                                                f"clave {key} repetida con datos distintos", raw))
    result.rows[schema.file_name] = valid


def validate_package(folder: Path) -> ValidationResult:
    result, refs = ValidationResult(), References()
    # Primero los maestros: las reglas de los hechos dependen de ellos.
    ordered = sorted(FILES, key=lambda s: s.file_name not in MASTER_FILES)
    for schema in ordered:
        _validate_file(folder, schema, refs, result)
        rows = result.rows[schema.file_name]
        if schema.file_name == "companies.csv":
            refs.companies = {r["company_code"] for r in rows}
        elif schema.file_name == "customers.csv":
            refs.customers = {(r["company_code"], r["customer_code"]) for r in rows
                              if r["company_code"] in refs.companies}
        elif schema.file_name == "products.csv":
            refs.products = {(r["company_code"], r["product_code"]) for r in rows
                             if r["company_code"] in refs.companies}
        elif schema.file_name == "fx_rates.csv":
            refs.fx = {(r["rate_date"], r["currency"]) for r in rows}
    return result
