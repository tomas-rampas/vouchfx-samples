"""Redis access for the Inventory service.

The service keeps one shared ``redis.Redis`` client for its lifetime (it is
internally connection-pooled and safe to share across the request
threadpool); MySQL and RabbitMQ deliberately open a fresh connection per
call instead — see db.py / mq.py for why.
"""
from __future__ import annotations

import redis

from config import Settings
from models import ItemOut


def build_client(settings: Settings) -> redis.Redis:
    """Builds a Redis client. Connection is lazy — the first command (e.g.
    ``ping``) is what actually proves reachability.
    """
    return redis.Redis(
        host=settings.redis_host,
        port=settings.redis_port,
        password=settings.redis_password,
        decode_responses=True,
        socket_connect_timeout=5,
    )


def cache_key(sku: str) -> str:
    """The Redis key an item is stored under: ``item:<sku>``."""
    return f"item:{sku}"


def set_item(client: redis.Redis, item: ItemOut) -> None:
    """Writes an item to the cache as its JSON representation."""
    client.set(cache_key(item.sku), item.model_dump_json())


def get_item(client: redis.Redis, sku: str) -> ItemOut | None:
    """Reads an item from the cache, or ``None`` on a cache miss."""
    raw = client.get(cache_key(sku))
    if raw is None:
        return None
    return ItemOut.model_validate_json(raw)
