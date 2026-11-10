"""Pruebas sin base de datos: generador, manifiesto y validación."""
from datetime import date
from decimal import Decimal

import pytest

from agroexport.generate import generate, money
from agroexport.manifest import read_and_verify
from agroexport.validate import validate_package


@pytest.fixture(scope="module")
def deliveries(tmp_path_factory):
    return generate(tmp_path_factory.mktemp("entregas"))


def test_generator_is_deterministic(deliveries, tmp_path):
    again = generate(tmp_path)
    for first, second in zip(deliveries, again):
        assert read_and_verify(first).package_sha256 == read_and_verify(second).package_sha256


def test_manifest_detects_tampering(tmp_path):
    first, _ = generate(tmp_path)
    with (first / "sales_lines.csv").open("a", encoding="utf-8") as handle:
        handle.write("alterado\n")
    with pytest.raises(ValueError, match="huella"):
        read_and_verify(first)


def test_initial_delivery_rejects_exactly_the_injected_errors(deliveries):
    result = validate_package(deliveries[0])
    reasons = sorted((r.file_name, r.reason.split(":")[0]) for r in result.rejected)
    assert len(result.rejected) == 8
    assert result.duplicates == 1
    assert ("lot_snapshots.csv", "existencia en kg negativa") in reasons
    assert ("shipments.csv", "embarque SHIPPED sin fecha real de despacho") in reasons
    assert ("sales_lines.csv", "doc_date") in reasons
    # Las dos versiones de la clave en conflicto se rechazan, no solo una.
    assert sum("repetida con datos distintos" in r.reason for r in result.rejected) == 2


def test_incremental_delivery(deliveries):
    result = validate_package(deliveries[1])
    assert [r.reason for r in result.rejected] == ["producto ZZZ-999 no existe en CR01"]
    sales = result.rows["sales_lines.csv"]
    # La factura de octubre anulada viaja en la entrega de noviembre.
    assert any(r["doc_status"] == "CANCELLED" and r["doc_date"] < date(2026, 11, 1) for r in sales)
    customers = {(r["company_code"], r["customer_code"]): r["customer_name"] for r in result.rows["customers.csv"]}
    assert customers[("CR01", "C009")] == "Seoul Tropical Co."
    assert customers[("CR01", "C003")] == "Hamburg Frische Handels GmbH"
    assert {r["snapshot_date"] for r in result.rows["lot_snapshots.csv"]} == {date(2026, 11, 7)}


def test_money_rounds_half_up():
    assert money(Decimal("2.345")) == Decimal("2.35")
    assert money(Decimal("2.344")) == Decimal("2.34")
