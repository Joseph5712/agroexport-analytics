"""Línea de comandos: python -m agroexport <comando>

  instalar            crea la base AgroExport y ejecuta sql/install
  generar             genera las dos entregas en data/entregas
  cargar CARPETA      carga una entrega (añade --simular-fallo para la demo de recuperación)
  estado              muestra las últimas cargas
  demo                todo lo anterior en orden, de cero
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "entregas"


def _print_result(result) -> None:
    print(f"  Carga {result.batch_id}: {result.status}")
    if result.status == "Succeeded":
        print(f"    leídas {result.rows_read:,} · rechazadas {result.rows_rejected} · "
              f"duplicadas descartadas {result.rows_duplicated}")
    if result.message:
        print(f"    {result.message}")


def _status() -> None:
    from .pipeline import recent_batches
    print(f"{'ID':>4}  {'Paquete':<22} {'Estado':<10} {'Leídas':>8} {'Rech.':>6} {'Dup.':>5}  Mensaje")
    for row in recent_batches():
        print(f"{row[0]:>4}  {row[1]:<22} {row[2]:<10} {row[3] or 0:>8,} {row[4] or 0:>6} {row[5] or 0:>5}  {row[7]}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m agroexport", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    install = sub.add_parser("instalar")
    install.add_argument("--recrear", action="store_true", help="borra y vuelve a crear la base")
    generate = sub.add_parser("generar")
    generate.add_argument("--escala", type=int, default=1, help="multiplica el volumen de facturas")
    load = sub.add_parser("cargar")
    load.add_argument("carpeta", type=Path)
    load.add_argument("--simular-fallo", action="store_true")
    sub.add_parser("estado")
    sub.add_parser("demo")
    args = parser.parse_args(argv)

    if args.command == "generar":
        from .generate import generate as run_generate
        for folder in run_generate(DATA_DIR, scale=args.escala):
            print(f"  Entrega creada: {folder}")
        return 0

    from . import db
    from .pipeline import SimulatedFailure, load_package

    if args.command == "instalar":
        db.install(drop_existing=args.recrear)
        print(f"  Base {db.database_name()} lista.")
    elif args.command == "cargar":
        try:
            _print_result(load_package(args.carpeta, simulate_failure=args.simular_fallo))
        except SimulatedFailure as error:
            print(f"  {error} Se hizo ROLLBACK y la carga quedó como Failed.")
            return 1
    elif args.command == "estado":
        _status()
    elif args.command == "demo":
        from .generate import generate as run_generate
        print("1. Instalar la base desde cero")
        db.install(drop_existing=True)
        print("2. Generar las entregas")
        first, second = run_generate(DATA_DIR)
        print("3. Carga inicial con un fallo simulado (no debe quedar nada publicado)")
        try:
            load_package(first, simulate_failure=True)
        except SimulatedFailure as error:
            print(f"  {error}")
        print("4. Reintento de la carga inicial")
        _print_result(load_package(first))
        print("5. La misma entrega otra vez (debe saltarse)")
        _print_result(load_package(first))
        print("6. Entrega incremental")
        _print_result(load_package(second))
        print()
        _status()
    return 0


if __name__ == "__main__":
    sys.exit(main())
