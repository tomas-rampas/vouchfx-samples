"""Inventory service — FastAPI application entrypoint.

The vouchfx system under test for the inventory-python sample: a small
showcase service proving that a single REST call fans out into a MySQL row,
a Redis cache entry, and a RabbitMQ event — the four-technology "business
transaction" pattern vouchfx's own reference scenario demonstrates for a
.NET stack, here reproduced against a Python service.

Endpoints:
    GET  /             — readiness probe; vouchfx health-gates the topology
                         on this returning 2xx before running any suite step.
    POST /items        — create/update an item: MySQL upsert, Redis write,
                         RabbitMQ "stock-changed" event.
    GET  /items/{sku}  — read-through: Redis first, MySQL on a cache miss.
"""
from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from cache import build_client as build_redis_client
from cache import get_item as cache_get_item
from cache import set_item as cache_set_item
from config import Settings
from db import connect as db_connect
from db import fetch_item, init_schema, upsert_item
from models import ItemIn, ItemOut
from mq import declare_queue, publish_stock_changed

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
# pika logs every connection-workflow frame at INFO, which drowns out the
# service's own structured logs; WARNING keeps genuine connection problems
# visible without the per-request noise.
logging.getLogger("pika").setLevel(logging.WARNING)
logger = logging.getLogger("inventory")

STARTUP_TIMEOUT_SECONDS = 60.0
STARTUP_RETRY_INTERVAL_SECONDS = 2.0


def _wait_for_dependencies(settings: Settings) -> bool:
    """Retries MySQL, RabbitMQ, and Redis until all three are reachable and
    provisioned, or the startup timeout elapses.

    Runs synchronously on a worker thread (see `lifespan`) so the retry
    loop's blocking sleeps never stall the event loop. Returns True once
    the MySQL schema exists, the RabbitMQ queue is declared, and Redis
    answers a PING.
    """
    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        try:
            conn = db_connect(settings)
            conn.close()
            init_schema(settings)

            declare_queue(settings)

            probe = build_redis_client(settings)
            try:
                probe.ping()
            finally:
                probe.close()

            logger.info("all dependencies reachable after %d attempt(s)", attempt)
            return True
        except Exception as exc:  # noqa: BLE001 - broad by design in a readiness probe
            logger.warning(
                "startup attempt %d failed (%s: %s); retrying in %.0fs",
                attempt,
                type(exc).__name__,
                exc,
                STARTUP_RETRY_INTERVAL_SECONDS,
            )
            time.sleep(STARTUP_RETRY_INTERVAL_SECONDS)

    logger.error(
        "dependencies not reachable after %.0fs; service stays not-ready",
        STARTUP_TIMEOUT_SECONDS,
    )
    return False


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = Settings.from_env()
    app.state.settings = settings
    app.state.ready = False

    app.state.ready = await asyncio.to_thread(_wait_for_dependencies, settings)
    app.state.redis = build_redis_client(settings)

    yield

    app.state.redis.close()


app = FastAPI(title="vouchfx inventory-python sample", lifespan=lifespan)


@app.get("/")
async def root() -> JSONResponse:
    """Readiness probe. 503 until startup has finished provisioning MySQL,
    RabbitMQ, and Redis; 200 {"status": "ready"} once it has.
    """
    if not app.state.ready:
        return JSONResponse(status_code=503, content={"status": "starting"})
    return JSONResponse(status_code=200, content={"status": "ready"})


@app.post("/items", response_model=ItemOut, status_code=201)
def create_item(item: ItemIn, request: Request) -> ItemOut:
    """Upserts the item into MySQL, writes it through to Redis, and
    publishes a stock-changed event to RabbitMQ. Echoes the stored item.
    """
    settings: Settings = request.app.state.settings

    upsert_item(settings, item)
    logger.info("item upserted in mysql sku=%s stock=%d", item.sku, item.stock)

    result = ItemOut(**item.model_dump())
    cache_set_item(request.app.state.redis, result)
    logger.info("item cached in redis sku=%s", item.sku)

    publish_stock_changed(settings, item)
    logger.info("stock-changed event published sku=%s", item.sku)

    return result


@app.get("/items/{sku}", response_model=ItemOut)
def get_item(sku: str, request: Request) -> ItemOut:
    """Read-through lookup: Redis first, MySQL on a cache miss (populating
    the cache for next time). 404 if the item does not exist anywhere.
    """
    cached = cache_get_item(request.app.state.redis, sku)
    if cached is not None:
        logger.info("cache hit sku=%s", sku)
        return cached

    logger.info("cache miss sku=%s; falling back to mysql", sku)
    settings: Settings = request.app.state.settings
    row = fetch_item(settings, sku)
    if row is None:
        raise HTTPException(status_code=404, detail=f"item '{sku}' not found")

    cache_set_item(request.app.state.redis, row)
    return row
