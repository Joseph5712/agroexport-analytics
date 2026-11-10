"""Generador de datos sintéticos de AgroExport Demo.

Crea un "mundo" determinista (misma semilla = mismos archivos, byte a byte)
con dos sociedades y casi dos años de operación. Después lo corta en dos
entregas, como las enviaría un ERP:

  entrega_2026-10-31  carga inicial con todo el historial
  entrega_2026-11-07  incremental: ventas de la semana, una factura de octubre
                      que se anula, embarques que cambiaron de estado, un
                      cliente nuevo y otro que cambió de nombre

También siembra errores a propósito para demostrar la validación.
Todos los datos son ficticios.
"""
from __future__ import annotations

import csv
import math
import random
import zlib
from dataclasses import dataclass, field
from datetime import date, timedelta
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

from .manifest import write_manifest
from .schemas import FILES

SEED = 2026
START = date(2025, 1, 2)
CUT_1 = date(2026, 10, 31)
CUT_2 = date(2026, 11, 7)
CENT = Decimal("0.01")

COMPANIES = [
    ("CR01", "AgroExport Costa Rica S.A.", "Costa Rica", "CRC"),
    ("GT01", "AgroExport Guatemala S.A.", "Guatemala", "GTQ"),
]

# código: (nombre, categoría, subcategoría, unidad, kg por unidad, vida útil en días, precio base USD)
PRODUCTS = {
    "PIN-001": ("Piña MD2 caja 12 kg", "Fresco", "Piña", "Caja", "12.000", 21, "14.50"),
    "BAN-001": ("Banano Cavendish caja 18.14 kg", "Fresco", "Banano", "Caja", "18.140", 28, "16.20"),
    "PAP-001": ("Papaya Pococí caja 10 kg", "Fresco", "Papaya", "Caja", "10.000", 14, "15.80"),
    "MAN-001": ("Mango Tommy Atkins caja 4 kg", "Fresco", "Mango", "Caja", "4.000", 21, "9.40"),
    "AGU-001": ("Aguacate Hass caja 10 kg", "Fresco", "Aguacate", "Caja", "10.000", 28, "31.00"),
    "PUL-001": ("Pulpa de piña congelada tambor 200 kg", "Procesado", "Pulpa", "Tambor", "200.000", 540, "410.00"),
    "JUG-001": ("Jugo concentrado de piña tambor 250 kg", "Procesado", "Jugo concentrado", "Tambor", "250.000", 540, "620.00"),
    "PUR-001": ("Puré de banano aséptico tambor 220 kg", "Procesado", "Puré", "Tambor", "220.000", 365, "370.00"),
    "DES-001": ("Piña deshidratada caja 5 kg", "Procesado", "Deshidratado", "Caja", "5.000", 365, "39.00"),
}
# PIN-001 y BAN-001 existen en ambas sociedades: por eso la sociedad es parte de la clave.
COMPANY_PRODUCTS = {
    "CR01": ["PIN-001", "BAN-001", "PAP-001", "PUL-001", "JUG-001", "DES-001"],
    "GT01": ["BAN-001", "MAN-001", "AGU-001", "PIN-001", "PUR-001"],
}
WAREHOUSES = {"CR01": ["BOD-LIMON", "BOD-ALAJUELA"], "GT01": ["BOD-ESCUINTLA"]}

# (código, nombre, país, moneda de facturación, días de crédito). C001 existe en ambas sociedades.
CUSTOMERS = {
    "CR01": [
        ("C001", "FreshBay Imports LLC", "Estados Unidos", "USD", 30),
        ("C002", "Rotterdam Fruit Trading B.V.", "Países Bajos", "EUR", 45),
        ("C003", "Hamburg Frische GmbH", "Alemania", "EUR", 45),
        ("C004", "Northern Produce Ltd", "Reino Unido", "USD", 30),
        ("C005", "Iberia Frutas S.L.", "España", "EUR", 60),
        ("C006", "Maple Fresh Inc.", "Canadá", "USD", 30),
        ("C007", "Antwerp Juice Partners", "Bélgica", "EUR", 60),
        ("C008", "Pacific Rim Foods", "Estados Unidos", "USD", 45),
    ],
    "GT01": [
        ("C001", "Gulf Coast Produce Co.", "Estados Unidos", "USD", 30),
        ("C002", "Milano Ortofrutta S.p.A.", "Italia", "EUR", 60),
        ("C003", "Lyon Primeurs SAS", "Francia", "EUR", 45),
        ("C004", "Tokyo Green Market K.K.", "Japón", "USD", 60),
        ("C005", "Texas Fresh Distributors", "Estados Unidos", "USD", 30),
        ("C006", "Nordic Fruit AB", "Suecia", "EUR", 45),
    ],
}
# Cambios en datos maestros que llegan con la segunda entrega.
NEW_CUSTOMER = ("CR01", ("C009", "Seoul Tropical Co.", "Corea del Sur", "USD", 45), date(2026, 11, 2))
RENAMED_CUSTOMER = ("CR01", "C003", "Hamburg Frische Handels GmbH", date(2026, 11, 4))


@dataclass
class Line:
    number: int
    product: str
    lot: str | None
    quantity: int
    unit_price: Decimal       # en la moneda del documento
    cost_usd: Decimal


@dataclass
class Shipment:
    number: str
    scheduled: date
    actual: date | None       # fecha real de despacho (en el "futuro" si aún no ocurre)
    containers: int


@dataclass
class Invoice:
    company: str
    number: str
    doc_date: date
    customer: str
    currency: str
    lines: list[Line]
    due_date: date
    paid_date: date | None
    shipment: Shipment
    cancel_date: date | None = None
    credit_notes: list["CreditNote"] = field(default_factory=list)


@dataclass
class CreditNote:
    company: str
    number: str
    doc_date: date
    invoice: Invoice
    line: Line                # cantidad acreditada; el costo no se recupera (reclamo de calidad)


def money(value: Decimal) -> Decimal:
    """Redondeo comercial a centavos (0.005 sube), igual que ROUND() de SQL Server."""
    return value.quantize(CENT, rounding=ROUND_HALF_UP)


def lot_code(company: str, product: str, produced: date) -> str:
    return f"{company}-{product[:3]}-{produced:%y%m%d}"


def monday_of(day: date) -> date:
    return day - timedelta(days=day.isoweekday() - 1)


class World:
    """Toda la operación simulada, de START a CUT_2."""

    def __init__(self, seed: int = SEED, scale: int = 1):
        self.seed = seed
        self.rng = random.Random(seed)
        self.fx = self._fx_rates()
        self.invoices: list[Invoice] = []
        self.credit_notes: list[CreditNote] = []
        self._simulate_sales(scale)
        self._october_cancellation()

    # --- Tipos de cambio ---------------------------------------------------
    def _fx_rates(self) -> dict[date, Decimal]:
        rates, rate, day = {}, 1.085, date(2025, 1, 1)
        while day <= CUT_2:
            rate = min(1.16, max(1.03, rate + self.rng.gauss(0, 0.003)))
            rates[day] = Decimal(f"{rate:.6f}")
            day += timedelta(days=1)
        return rates

    def usd_per_unit(self, currency: str, day: date) -> Decimal:
        return Decimal(1) if currency == "USD" else self.fx[day]

    def line_usd(self, currency: str, day: date, quantity: int, unit_price: Decimal) -> Decimal:
        return money(quantity * unit_price * self.usd_per_unit(currency, day))

    # --- Clientes ------------------------------------------------------------
    @staticmethod
    def customers_at(company: str, day: date) -> list[tuple]:
        customers = list(CUSTOMERS[company])
        new_company, new_customer, active_from = NEW_CUSTOMER
        if company == new_company and day >= active_from:
            customers.append(new_customer)
        return customers

    # --- Ventas, embarques y cobros --------------------------------------------
    def _simulate_sales(self, scale: int) -> None:
        rng = self.rng
        counters = {code: {"INV": 0, "CN": 0, "SHP": 0} for code, *_ in COMPANIES}
        day = START
        while day <= CUT_2:
            if day.isoweekday() != 7:                     # no se factura en domingo
                season = 1 + 0.08 * math.sin(2 * math.pi * day.timetuple().tm_yday / 365)
                for company, *_ in COMPANIES:
                    invoices_today = rng.choices([3, 4, 5, 6, 7], weights=[2, 3, 3, 2, 1])[0] * scale
                    for _ in range(invoices_today):
                        self._new_invoice(company, day, season, counters[company])
            day += timedelta(days=1)

    def _new_invoice(self, company: str, day: date, season: float, counter: dict) -> None:
        rng = self.rng
        code, _name, _country, currency, terms = rng.choice(self.customers_at(company, day))
        products = rng.sample(COMPANY_PRODUCTS[company], k=rng.choices([1, 2, 3], weights=[5, 3, 2])[0])

        lines, total_kg = [], 0.0
        for number, product in enumerate(products, start=1):
            _pname, category, _sub, unit, kg, shelf, base = PRODUCTS[product]
            base_price = Decimal(base)
            if unit == "Tambor":
                quantity = rng.randint(20, 80)
            elif category == "Fresco":
                quantity = rng.randint(300, 1500)
            else:
                quantity = rng.randint(100, 600)
            price_usd = float(base_price) * rng.uniform(0.92, 1.08) * season
            if rng.random() < 0.02:                       # liquidación: margen negativo
                price_usd *= 0.70
            unit_price = Decimal(f"{price_usd / float(self.usd_per_unit(currency, day)):.4f}")
            cost_usd = money(Decimal(quantity) * base_price * Decimal(f"{rng.uniform(0.68, 0.82):.4f}"))

            if rng.random() < 0.02:                       # sin lote: problema de trazabilidad
                lot = None
            elif category == "Fresco":
                lot = lot_code(company, product, day - timedelta(days=rng.randint(1, 4)))
            else:
                lot = lot_code(company, product, monday_of(day - timedelta(days=rng.randint(14, 150))))
            lines.append(Line(number, product, lot, quantity, unit_price, cost_usd))
            total_kg += quantity * float(kg)

        counter["INV"] += 1
        counter["SHP"] += 1
        scheduled = day + timedelta(days=rng.randint(1, 4))
        delay = rng.choices([0, rng.randint(1, 2), rng.randint(3, 7)], weights=[80, 12, 8])[0]
        shipment = Shipment(f"SHP-{counter['SHP']:06d}", scheduled, scheduled + timedelta(days=delay),
                            max(1, math.ceil(total_kg / 20000)))

        due = day + timedelta(days=terms)
        payment = rng.random()
        if payment < 0.50:
            paid = due - timedelta(days=rng.randint(0, 10))
        elif payment < 0.85:
            paid = due + timedelta(days=rng.randint(1, 30))
        elif payment < 0.97:
            paid = due + timedelta(days=rng.randint(31, 90))
        else:
            paid = None                                   # nunca se cobró

        invoice = Invoice(company, f"INV-{counter['INV']:06d}", day, code, currency, lines, due, paid, shipment)
        if rng.random() < 0.006:
            invoice.cancel_date = day + timedelta(days=1)
            invoice.paid_date = None
        self.invoices.append(invoice)

        # Reclamo de calidad: nota de crédito por una parte de una línea.
        if invoice.cancel_date is None and rng.random() < 0.04:
            credit_day = day + timedelta(days=rng.randint(5, 20))
            if credit_day <= CUT_2:
                line = rng.choice(lines)
                quantity = max(1, round(line.quantity * rng.uniform(0.05, 0.25)))
                counter["CN"] += 1
                note = CreditNote(company, f"CN-{counter['CN']:06d}", credit_day, invoice,
                                  Line(1, line.product, line.lot, quantity, line.unit_price, Decimal("0.00")))
                invoice.credit_notes.append(note)
                self.credit_notes.append(note)

    def _october_cancellation(self) -> None:
        """Una factura del 30 de octubre se anula el 3 de noviembre (llega en la entrega 2)."""
        invoice = next(i for i in self.invoices
                       if i.company == "CR01" and i.doc_date == date(2026, 10, 30)
                       and i.cancel_date is None and not i.credit_notes)
        invoice.cancel_date = date(2026, 11, 3)
        invoice.paid_date = None
        invoice.shipment.scheduled = date(2026, 11, 4)
        invoice.shipment.actual = None

    # --- Estado "visto" en una fecha de corte -----------------------------------
    @staticmethod
    def invoice_status(invoice: Invoice, cut: date) -> str:
        return "CANCELLED" if invoice.cancel_date and invoice.cancel_date <= cut else "ACTIVE"

    @staticmethod
    def shipment_state(invoice: Invoice, cut: date) -> tuple[str, date | None]:
        if invoice.cancel_date and invoice.cancel_date <= cut:
            return "CANCELLED", None
        actual = invoice.shipment.actual
        if actual and actual <= cut:
            return "SHIPPED", actual
        return "PENDING", None

    def invoice_usd(self, invoice: Invoice) -> Decimal:
        return sum((self.line_usd(invoice.currency, invoice.doc_date, l.quantity, l.unit_price)
                    for l in invoice.lines), Decimal(0))

    def credit_usd(self, note: CreditNote) -> Decimal:
        return self.line_usd(note.invoice.currency, note.doc_date, note.line.quantity, note.line.unit_price)


# --- Construcción de una entrega ---------------------------------------------

def _in_window(day: date | None, prev_cut: date | None, cut: date) -> bool:
    return day is not None and (prev_cut is None or day > prev_cut) and day <= cut


def snapshot_dates(prev_cut: date | None, cut: date) -> list[date]:
    """Fin de cada mes desde enero de 2025, más la fecha de corte."""
    dates, year, month = [], 2025, 1
    while True:
        last = date(year + month // 12, month % 12 + 1, 1) - timedelta(days=1)
        if last > cut:
            break
        dates.append(last)
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    if cut not in dates:
        dates.append(cut)
    return [d for d in dates if _in_window(d, prev_cut, cut)]


def build_delivery(world: World, cut: date, prev_cut: date | None) -> dict[str, list[dict]]:
    rows: dict[str, list[dict]] = {f.file_name: [] for f in FILES}

    # Datos maestros: siempre completos en cada entrega.
    for code, name, country, currency in COMPANIES:
        rows["companies.csv"].append({"company_code": code, "company_name": name,
                                      "country": country, "local_currency": currency})
        for c_code, c_name, c_country, _cur, terms in world.customers_at(code, cut):
            r_company, r_code, r_name, r_from = RENAMED_CUSTOMER
            if code == r_company and c_code == r_code and cut >= r_from:
                c_name = r_name
            rows["customers.csv"].append({"company_code": code, "customer_code": c_code, "customer_name": c_name,
                                          "country": c_country, "payment_terms_days": terms})
        for p_code in COMPANY_PRODUCTS[code]:
            name_, category, sub, unit, kg, shelf, _price = PRODUCTS[p_code]
            rows["products.csv"].append({"company_code": code, "product_code": p_code, "product_name": name_,
                                         "category": category, "subcategory": sub, "sales_unit": unit,
                                         "kg_per_unit": kg, "shelf_life_days": shelf})
    for day, rate in world.fx.items():
        if day <= cut:
            rows["fx_rates.csv"].append({"rate_date": day.isoformat(), "currency": "EUR",
                                         "usd_per_unit": f"{rate:.6f}"})

    for invoice in world.invoices:
        if invoice.doc_date > cut:
            continue
        # Facturas nuevas, o anteriores cuyo estado cambió (anulación) dentro de la ventana.
        if _in_window(invoice.doc_date, prev_cut, cut) or _in_window(invoice.cancel_date, prev_cut, cut):
            for line in invoice.lines:
                rows["sales_lines.csv"].append(_sales_row(invoice, "INV", invoice.number, invoice.doc_date,
                                                          world.invoice_status(invoice, cut), line, None))
        status, actual = world.shipment_state(invoice, cut)
        previous = world.shipment_state(invoice, prev_cut) if prev_cut and invoice.doc_date <= prev_cut else None
        if previous != (status, actual):
            customer = next(c for c in world.customers_at(invoice.company, cut) if c[0] == invoice.customer)
            rows["shipments.csv"].append({
                "company_code": invoice.company, "shipment_number": invoice.shipment.number,
                "invoice_number": invoice.number, "customer_code": invoice.customer,
                "destination_country": customer[2], "scheduled_date": invoice.shipment.scheduled.isoformat(),
                "actual_ship_date": actual.isoformat() if actual else "", "status": status,
                "containers": invoice.shipment.containers})

    for note in world.credit_notes:
        if _in_window(note.doc_date, prev_cut, cut):
            rows["sales_lines.csv"].append(_sales_row(note.invoice, "CN", note.number, note.doc_date,
                                                      "ACTIVE", note.line, note.invoice.number))

    for snap in snapshot_dates(prev_cut, cut):
        rows["lot_snapshots.csv"].extend(_lot_rows(world, snap))
        rows["receivables.csv"].extend(_receivable_rows(world, snap))
    return rows


def _sales_row(invoice: Invoice, doc_type: str, number: str, day: date, status: str,
               line: Line, ref: str | None) -> dict:
    return {"company_code": invoice.company, "doc_type": doc_type, "doc_number": number,
            "line_number": line.number, "doc_date": day.isoformat(), "doc_status": status,
            "customer_code": invoice.customer, "product_code": line.product, "lot_code": line.lot or "",
            "quantity": line.quantity, "unit_price": f"{line.unit_price:.4f}", "currency": invoice.currency,
            "line_cost_usd": f"{line.cost_usd:.2f}", "ref_doc_number": ref or ""}


def _lot_rows(world: World, snap: date) -> list[dict]:
    """Existencia de cada lote en una fecha de corte (fotografía de inventario)."""
    rows = []
    for company, *_ in COMPANIES:
        for product in COMPANY_PRODUCTS[company]:
            _n, category, _s, _u, _kg, shelf, _p = PRODUCTS[product]
            fresh = category == "Fresco"
            first = snap - timedelta(days=shelf + (0 if fresh else 45))
            day = first if fresh else monday_of(first) + timedelta(days=7)
            while day <= snap:
                if not fresh or day.isoweekday() != 7:
                    code = lot_code(company, product, day)
                    # Cada lote tiene su propio generador: su historia no depende del resto.
                    r = random.Random(zlib.crc32(f"{world.seed}-{code}".encode()))
                    initial = r.uniform(15000, 45000) if fresh else r.uniform(3000, 12000)
                    speed, stuck, warehouse = r.uniform(1.0, 2.4), r.random() < 0.05, r.choice(WAREHOUSES[company])
                    age = (snap - day).days
                    remaining = max(0.0, 1 - age / shelf * speed)
                    if age > shelf:
                        remaining = 0.04 if stuck else 0.0    # lote vencido que nadie dio de baja
                    qty = round(initial * remaining, 3)
                    if qty > 0:
                        rows.append({"snapshot_date": snap.isoformat(), "company_code": company,
                                     "lot_code": code, "product_code": product, "warehouse_code": warehouse,
                                     "production_date": day.isoformat(),
                                     "expiry_date": (day + timedelta(days=shelf)).isoformat(),
                                     "qty_kg": f"{qty:.3f}"})
                day += timedelta(days=1 if fresh else 7)
    return rows


def _receivable_rows(world: World, snap: date) -> list[dict]:
    """Documentos con saldo abierto en una fecha de corte."""
    rows = []
    for invoice in world.invoices:
        if invoice.doc_date > snap or (invoice.cancel_date and invoice.cancel_date <= snap):
            continue
        if invoice.paid_date and invoice.paid_date <= snap:
            continue
        credits = sum((world.credit_usd(n) for n in invoice.credit_notes if n.doc_date <= snap), Decimal(0))
        open_amount = world.invoice_usd(invoice) - credits
        if open_amount > 0:
            rows.append({"snapshot_date": snap.isoformat(), "company_code": invoice.company,
                         "doc_number": invoice.number, "customer_code": invoice.customer,
                         "doc_date": invoice.doc_date.isoformat(), "due_date": invoice.due_date.isoformat(),
                         "open_amount_usd": f"{open_amount:.2f}"})
    return rows


# --- Errores sembrados a propósito ---------------------------------------------

def inject_errors_initial(rows: dict[str, list[dict]]) -> None:
    sales = rows["sales_lines.csv"]
    sales.append({**sales[10], "doc_number": "INV-ERR001", "customer_code": "C999"})    # cliente inexistente
    sales.append({**sales[20], "doc_number": "INV-ERR002", "quantity": 0})              # cantidad cero
    sales.append({**sales[30], "doc_number": "INV-ERR003", "doc_date": "2026-02-30"})   # fecha imposible
    sales.append({**sales[40]})                                                         # duplicado idéntico
    sales.append({**sales[50], "quantity": int(sales[50]["quantity"]) + 10})            # misma clave, otro dato
    sales.append({**sales[60], "doc_number": "INV-ERR004", "doc_type": "XXX"})          # tipo desconocido

    lots = rows["lot_snapshots.csv"]
    lots.append({**lots[5], "lot_code": lots[5]["lot_code"] + "-X", "qty_kg": "-25.000"})  # kg negativos

    shipments = rows["shipments.csv"]
    shipped = next(s for s in shipments if s["status"] == "SHIPPED")
    shipments.append({**shipped, "shipment_number": "SHP-ERR001", "actual_ship_date": ""})  # despachado sin fecha


def inject_errors_incremental(rows: dict[str, list[dict]]) -> None:
    sales = rows["sales_lines.csv"]
    sales.append({**sales[0], "doc_number": "INV-ERR101", "product_code": "ZZZ-999"})   # producto inexistente


# --- Escritura -------------------------------------------------------------------

def write_delivery(folder: Path, rows: dict[str, list[dict]], cut: date, kind: str) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    counts = {}
    for schema in FILES:
        with (folder / schema.file_name).open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=schema.column_names, lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows[schema.file_name])
        counts[schema.file_name] = len(rows[schema.file_name])
    write_manifest(folder, cut, kind, counts)


def generate(output: Path, seed: int = SEED, scale: int = 1) -> list[Path]:
    world = World(seed, scale)
    first = build_delivery(world, CUT_1, None)
    inject_errors_initial(first)
    second = build_delivery(world, CUT_2, CUT_1)
    inject_errors_incremental(second)

    folders = [output / f"entrega_{CUT_1}", output / f"entrega_{CUT_2}"]
    write_delivery(folders[0], first, CUT_1, "inicial")
    write_delivery(folders[1], second, CUT_2, "incremental")
    return folders
