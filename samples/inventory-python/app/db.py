"""MySQL access for the Inventory service.

One short-lived connection per call. That is the right trade-off for a
showcase service under test load, not a production connection-pool design.
"""
from __future__ import annotations

import pymysql
import pymysql.cursors

from config import Settings
from models import ItemIn, ItemOut

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS items (
    sku VARCHAR(64) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    stock INT NOT NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
"""

_UPSERT_SQL = """
INSERT INTO items (sku, name, stock)
VALUES (%s, %s, %s)
ON DUPLICATE KEY UPDATE name = VALUES(name), stock = VALUES(stock)
"""

_SELECT_SQL = "SELECT sku, name, stock FROM items WHERE sku = %s"


def connect(settings: Settings) -> pymysql.connections.Connection:
    """Opens a new MySQL connection. Raises on failure — callers use this as
    the reachability probe during startup as well as for real queries.
    """
    return pymysql.connect(
        host=settings.db_host,
        port=settings.db_port,
        user=settings.db_user,
        password=settings.db_password,
        database=settings.db_name,
        connect_timeout=5,
        autocommit=True,
        cursorclass=pymysql.cursors.DictCursor,
    )


def init_schema(settings: Settings) -> None:
    """Creates the ``items`` table if it does not already exist."""
    conn = connect(settings)
    try:
        with conn.cursor() as cursor:
            cursor.execute(CREATE_TABLE_SQL)
    finally:
        conn.close()


def upsert_item(settings: Settings, item: ItemIn) -> None:
    """Inserts a new item, or updates name/stock if the sku already exists."""
    conn = connect(settings)
    try:
        with conn.cursor() as cursor:
            cursor.execute(_UPSERT_SQL, (item.sku, item.name, item.stock))
    finally:
        conn.close()


def fetch_item(settings: Settings, sku: str) -> ItemOut | None:
    """Reads one item by sku, or ``None`` if it does not exist."""
    conn = connect(settings)
    try:
        with conn.cursor() as cursor:
            cursor.execute(_SELECT_SQL, (sku,))
            row = cursor.fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    return ItemOut(sku=row["sku"], name=row["name"], stock=row["stock"])
