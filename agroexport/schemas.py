"""Contrato de los archivos de una entrega.

Cada archivo CSV tiene: columnas con su tipo, la tabla de staging destino y
su clave (qué identifica una fila). El generador escribe con estas columnas y
el validador las usa para convertir y revisar cada fila.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Any, Callable


class ParseError(ValueError):
    """Un valor no cumple el tipo esperado."""


# --- Conversores: reciben el texto del CSV y devuelven el valor tipado ------

def text(max_len: int) -> Callable[[str], str]:
    def parse(value: str) -> str:
        if len(value) > max_len:
            raise ParseError(f"supera {max_len} caracteres")
        return value
    return parse


def integer(value: str) -> int:
    try:
        return int(value)
    except ValueError:
        raise ParseError(f"'{value}' no es un entero") from None


def decimal(scale: int) -> Callable[[str], Decimal]:
    def parse(value: str) -> Decimal:
        try:
            number = Decimal(value)
        except InvalidOperation:
            raise ParseError(f"'{value}' no es un número") from None
        if not number.is_finite():
            raise ParseError(f"'{value}' no es un número finito")
        if -number.as_tuple().exponent > scale:
            raise ParseError(f"'{value}' tiene más de {scale} decimales")
        return number
    return parse


def iso_date(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise ParseError(f"'{value}' no es una fecha AAAA-MM-DD válida") from None


def choice(*allowed: str) -> Callable[[str], str]:
    def parse(value: str) -> str:
        if value not in allowed:
            raise ParseError(f"'{value}' no está entre {allowed}")
        return value
    return parse


# --- Definición de archivos -------------------------------------------------

@dataclass(frozen=True)
class Column:
    name: str                       # nombre en el CSV
    sql_name: str                   # columna en staging
    parse: Callable[[str], Any]
    required: bool = True


@dataclass(frozen=True)
class FileSchema:
    file_name: str
    table: str
    key: tuple[str, ...]            # columnas CSV que identifican una fila
    columns: tuple[Column, ...]

    @property
    def column_names(self) -> list[str]:
        return [c.name for c in self.columns]


COMPANY = "company_code"

FILES: tuple[FileSchema, ...] = (
    FileSchema("companies.csv", "stg.Company", (COMPANY,), (
        Column(COMPANY, "CompanyCode", text(10)),
        Column("company_name", "CompanyName", text(100)),
        Column("country", "Country", text(50)),
        Column("local_currency", "LocalCurrency", text(3)),
    )),
    FileSchema("customers.csv", "stg.Customer", (COMPANY, "customer_code"), (
        Column(COMPANY, "CompanyCode", text(10)),
        Column("customer_code", "CustomerCode", text(20)),
        Column("customer_name", "CustomerName", text(150)),
        Column("country", "Country", text(50)),
        Column("payment_terms_days", "PaymentTermsDays", integer),
    )),
    FileSchema("products.csv", "stg.Product", (COMPANY, "product_code"), (
        Column(COMPANY, "CompanyCode", text(10)),
        Column("product_code", "ProductCode", text(20)),
        Column("product_name", "ProductName", text(150)),
        Column("category", "Category", choice("Fresco", "Procesado")),
        Column("subcategory", "Subcategory", text(50)),
        Column("sales_unit", "SalesUnit", text(20)),
        Column("kg_per_unit", "KgPerUnit", decimal(3)),
        Column("shelf_life_days", "ShelfLifeDays", integer),
    )),
    FileSchema("fx_rates.csv", "stg.FxRate", ("rate_date", "currency"), (
        Column("rate_date", "RateDate", iso_date),
        Column("currency", "Currency", text(3)),
        Column("usd_per_unit", "UsdPerUnit", decimal(6)),
    )),
    FileSchema("sales_lines.csv", "stg.SalesLine", (COMPANY, "doc_type", "doc_number", "line_number"), (
        Column(COMPANY, "CompanyCode", text(10)),
        Column("doc_type", "DocType", choice("INV", "CN")),
        Column("doc_number", "DocNumber", text(20)),
        Column("line_number", "LineNumber", integer),
        Column("doc_date", "DocDate", iso_date),
        Column("doc_status", "DocStatus", choice("ACTIVE", "CANCELLED")),
        Column("customer_code", "CustomerCode", text(20)),
        Column("product_code", "ProductCode", text(20)),
        Column("lot_code", "LotCode", text(40), required=False),
        Column("quantity", "Quantity", integer),
        Column("unit_price", "UnitPrice", decimal(4)),
        Column("currency", "Currency", text(3)),
        Column("line_cost_usd", "LineCostUsd", decimal(2)),
        Column("ref_doc_number", "RefDocNumber", text(20), required=False),
    )),
    FileSchema("lot_snapshots.csv", "stg.LotSnapshot", ("snapshot_date", COMPANY, "lot_code"), (
        Column("snapshot_date", "SnapshotDate", iso_date),
        Column(COMPANY, "CompanyCode", text(10)),
        Column("lot_code", "LotCode", text(40)),
        Column("product_code", "ProductCode", text(20)),
        Column("warehouse_code", "WarehouseCode", text(20)),
        Column("production_date", "ProductionDate", iso_date),
        Column("expiry_date", "ExpiryDate", iso_date),
        Column("qty_kg", "QtyKg", decimal(3)),
    )),
    FileSchema("shipments.csv", "stg.Shipment", (COMPANY, "shipment_number"), (
        Column(COMPANY, "CompanyCode", text(10)),
        Column("shipment_number", "ShipmentNumber", text(20)),
        Column("invoice_number", "InvoiceNumber", text(20)),
        Column("customer_code", "CustomerCode", text(20)),
        Column("destination_country", "DestinationCountry", text(50)),
        Column("scheduled_date", "ScheduledDate", iso_date),
        Column("actual_ship_date", "ActualShipDate", iso_date, required=False),
        Column("status", "Status", choice("PENDING", "SHIPPED", "CANCELLED")),
        Column("containers", "Containers", integer),
    )),
    FileSchema("receivables.csv", "stg.Receivable", ("snapshot_date", COMPANY, "doc_number"), (
        Column("snapshot_date", "SnapshotDate", iso_date),
        Column(COMPANY, "CompanyCode", text(10)),
        Column("doc_number", "DocNumber", text(20)),
        Column("customer_code", "CustomerCode", text(20)),
        Column("doc_date", "DocDate", iso_date),
        Column("due_date", "DueDate", iso_date),
        Column("open_amount_usd", "OpenAmountUsd", decimal(2)),
    )),
)

FILES_BY_NAME = {f.file_name: f for f in FILES}
