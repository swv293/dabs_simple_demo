"""Unit tests for the pure-Python helpers inside src/notebooks/ingest.py.

The notebook itself can't be imported directly (it uses dbutils + %magic
cells), so we extract the `generate_orders` function via exec on the source
lines that don't depend on the Databricks runtime.
"""

from __future__ import annotations

import re
from datetime import date, datetime
from pathlib import Path


def _load_generate_orders():
    src = (Path(__file__).resolve().parents[2] / "src" / "notebooks" / "ingest.py").read_text()
    # Pull just the function definition out of the notebook source.
    match = re.search(r"def generate_orders\(.*?\n    return rows", src, re.S)
    assert match, "generate_orders function not found in ingest.py"
    ns: dict = {}
    exec("import random\nfrom datetime import date, timedelta\n" + match.group(0), ns)
    return ns["generate_orders"]


generate_orders = _load_generate_orders()


def test_generate_orders_default_count():
    rows = generate_orders()
    assert len(rows) == 5000


def test_generate_orders_seed_is_deterministic():
    a = generate_orders(n=100, seed=7)
    b = generate_orders(n=100, seed=7)
    assert a == b


def test_generate_orders_schema():
    rows = generate_orders(n=10)
    expected = {"order_id", "customer_id", "product_id", "region", "order_date", "amount"}
    for row in rows:
        assert set(row) == expected
        # order_date parses as ISO date
        datetime.strptime(row["order_date"], "%Y-%m-%d")
        # amount parses as a positive number
        assert float(row["amount"]) > 0
        # region is one of the expected values
        assert row["region"] in {"NORTH", "SOUTH", "EAST", "WEST"}


def test_generate_orders_dates_within_window():
    rows = generate_orders(n=200, seed=1)
    today = date.today()
    for row in rows:
        d = datetime.strptime(row["order_date"], "%Y-%m-%d").date()
        delta = (today - d).days
        assert 0 <= delta <= 29
