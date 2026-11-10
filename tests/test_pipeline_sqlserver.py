"""Pruebas de integración contra SQL Server real.

Usan una base aparte (AgroExport_Test) que se borra y recrea en cada prueba.
Se activan con AGROEXPORT_RUN_DB_TESTS=1 y las variables de conexión de db.py.
"""
import os
import threading
from decimal import ROUND_HALF_UP, Decimal

import pytest

pytestmark = pytest.mark.skipif(os.getenv("AGROEXPORT_RUN_DB_TESTS") != "1",
                                reason="define AGROEXPORT_RUN_DB_TESTS=1 para probar contra SQL Server")


@pytest.fixture(scope="module")
def deliveries(tmp_path_factory):
    from agroexport.generate import generate
    return generate(tmp_path_factory.mktemp("entregas"))


@pytest.fixture
def fresh_db(monkeypatch):
    monkeypatch.setenv("AGROEXPORT_DATABASE", "AgroExport_Test")
    from agroexport import db
    db.install(drop_existing=True)
    conn = db.connect(autocommit=True)
    yield conn
    conn.close()


def scalar(conn, sql, *params):
    return conn.execute(sql, *params).fetchval()


def expected_net_sales(folder) -> Decimal:
    """Ventas netas calculadas en Python, por un camino independiente de SQL."""
    from agroexport.validate import validate_package
    rows = validate_package(folder).rows
    fx = {(r["rate_date"], r["currency"]): r["usd_per_unit"] for r in rows["fx_rates.csv"]}
    total = Decimal(0)
    for line in rows["sales_lines.csv"]:
        if line["doc_status"] == "CANCELLED":
            continue
        rate = Decimal(1) if line["currency"] == "USD" else fx[(line["doc_date"], line["currency"])]
        amount = (line["quantity"] * line["unit_price"] * rate).quantize(Decimal("0.01"), ROUND_HALF_UP)
        total += -amount if line["doc_type"] == "CN" else amount
    return total


def test_failure_rolls_back_everything(fresh_db, deliveries):
    from agroexport.pipeline import SimulatedFailure, load_package
    with pytest.raises(SimulatedFailure):
        load_package(deliveries[0], simulate_failure=True)
    assert scalar(fresh_db, "SELECT COUNT(*) FROM dw.FactSalesLine") == 0
    assert scalar(fresh_db, "SELECT COUNT(*) FROM dw.DimCustomer") == 0
    assert scalar(fresh_db, "SELECT Status FROM etl.LoadBatch") == "Failed"


def test_load_matches_independent_calculation(fresh_db, deliveries):
    from agroexport.pipeline import load_package
    assert load_package(deliveries[0]).status == "Succeeded"
    assert scalar(fresh_db, "SELECT SUM(NetAmountUsd) FROM rpt.FactSales") == expected_net_sales(deliveries[0])
    assert scalar(fresh_db, "SELECT COUNT(*) FROM dq.Reconciliation WHERE IsMatch = 0") == 0
    assert scalar(fresh_db, "SELECT COUNT(*) FROM dq.RejectedRow") == 8


def test_same_package_twice_is_skipped(fresh_db, deliveries):
    from agroexport.pipeline import load_package
    load_package(deliveries[0])
    before = scalar(fresh_db, "SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dw.FactSalesLine")
    assert load_package(deliveries[0]).status == "Skipped"
    assert scalar(fresh_db, "SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dw.FactSalesLine") == before


def test_concurrent_loads_publish_once(fresh_db, deliveries):
    from agroexport.pipeline import load_package
    statuses = []
    threads = [threading.Thread(target=lambda: statuses.append(load_package(deliveries[0]).status))
               for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(statuses) == ["Skipped", "Succeeded"]
    assert scalar(fresh_db, "SELECT COUNT(*) FROM etl.LoadBatch WHERE Status = 'Succeeded'") == 1


def test_incremental_applies_corrections_without_touching_history(fresh_db, deliveries):
    from agroexport.pipeline import load_package
    load_package(deliveries[0])
    october_lots = scalar(fresh_db, "SELECT SUM(QtyKg) FROM dw.FactLotSnapshot WHERE SnapshotDateKey = 20261031")
    lines_before = scalar(fresh_db, "SELECT COUNT(*) FROM dw.FactSalesLine")

    assert load_package(deliveries[1]).status == "Succeeded"
    # La factura de octubre quedó anulada y el reporte ya no la suma.
    cancelled = scalar(fresh_db, "SELECT COUNT(*) FROM dw.FactSalesLine "
                                 "WHERE IsCancelled = 1 AND DateKey = 20261030 AND LoadBatchID = 2")
    assert cancelled >= 1
    # Cambios de datos maestros (SCD tipo 1).
    assert scalar(fresh_db, "SELECT CustomerName FROM rpt.DimCustomer "
                            "WHERE CompanyCode = 'CR01' AND CustomerCode = 'C003'") == "Hamburg Frische Handels GmbH"
    assert scalar(fresh_db, "SELECT COUNT(*) FROM rpt.DimCustomer WHERE CustomerCode = 'C009'") == 1
    # La fotografía de octubre no cambia; se agrega la de noviembre.
    assert scalar(fresh_db, "SELECT SUM(QtyKg) FROM dw.FactLotSnapshot WHERE SnapshotDateKey = 20261031") == october_lots
    assert scalar(fresh_db, "SELECT COUNT(*) FROM dw.FactLotSnapshot WHERE SnapshotDateKey = 20261107") > 0
    # Las líneas reenviadas se actualizan, no se duplican.
    new_lines = scalar(fresh_db, "SELECT COUNT(*) FROM dw.FactSalesLine WHERE DateKey > 20261031")
    assert scalar(fresh_db, "SELECT COUNT(*) FROM dw.FactSalesLine") == lines_before + new_lines
