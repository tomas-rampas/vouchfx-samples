"""Pydantic request/response models for the Inventory service."""
from __future__ import annotations

from pydantic import BaseModel, Field


class ItemIn(BaseModel):
    """The payload accepted by ``POST /items``."""

    sku: str = Field(min_length=1, max_length=64, description="Stock-keeping unit identifier.")
    name: str = Field(min_length=1, max_length=255, description="Human-readable item name.")
    stock: int = Field(ge=0, description="Units currently in stock.")


class ItemOut(ItemIn):
    """The representation returned by ``POST /items`` and ``GET /items/{sku}``.

    Identical shape to :class:`ItemIn` today; kept as a distinct type so the
    request and response contracts can diverge later without a breaking
    rename.
    """
