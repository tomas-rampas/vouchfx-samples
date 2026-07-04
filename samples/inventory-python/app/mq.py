"""RabbitMQ access for the Inventory service.

``pika.BlockingConnection`` is not thread-safe, so — unlike the shared Redis
client — every call here opens and closes its own short-lived connection.
Under FastAPI's threadpool-per-sync-request model that means each request
gets its own connection, which is safe by construction and cheap enough for
a showcase service.
"""
from __future__ import annotations

import json

import pika

from config import Settings
from models import ItemIn

QUEUE_NAME = "stock-events"


def declare_queue(settings: Settings) -> None:
    """Declares the durable ``stock-events`` queue.

    Called both at startup (so the queue exists before any publish) and used
    as part of the startup RabbitMQ-reachability probe.
    """
    connection = pika.BlockingConnection(pika.URLParameters(settings.rabbitmq_url))
    try:
        channel = connection.channel()
        channel.queue_declare(queue=QUEUE_NAME, durable=True)
    finally:
        connection.close()


def publish_stock_changed(settings: Settings, item: ItemIn) -> None:
    """Publishes a ``stock-changed`` event for *item* to the default
    exchange, routed by queue name to ``stock-events``.
    """
    connection = pika.BlockingConnection(pika.URLParameters(settings.rabbitmq_url))
    try:
        channel = connection.channel()
        payload = json.dumps({"sku": item.sku, "stock": item.stock, "event": "stock-changed"})
        channel.basic_publish(
            exchange="",
            routing_key=QUEUE_NAME,
            body=payload,
            properties=pika.BasicProperties(
                content_type="application/json",
                delivery_mode=pika.DeliveryMode.Persistent,
            ),
        )
    finally:
        connection.close()
