"""Environment-driven configuration for the Inventory service.

All configuration arrives as environment variables — never a config file —
so the same image runs unchanged under vouchfx's orchestrated topology, a
plain ``docker run`` smoke test, or any other container runtime.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Settings:
    """Immutable snapshot of the service's runtime configuration."""

    db_host: str
    db_port: int
    db_user: str
    db_password: str
    db_name: str
    rabbitmq_url: str
    redis_host: str
    redis_port: int
    redis_password: str | None

    @classmethod
    def from_env(cls) -> "Settings":
        """Builds a :class:`Settings` from the process environment.

        Raises:
            KeyError: if a required variable is not set. Fails fast and
                loudly rather than starting the service half-configured.
        """
        return cls(
            db_host=os.environ["DB_HOST"],
            db_port=int(os.environ.get("DB_PORT", "3306")),
            db_user=os.environ["DB_USER"],
            db_password=os.environ["DB_PASSWORD"],
            db_name=os.environ["DB_NAME"],
            rabbitmq_url=os.environ["RABBITMQ_URL"],
            redis_host=os.environ["REDIS_HOST"],
            redis_port=int(os.environ.get("REDIS_PORT", "6379")),
            # Optional: managed Redis instances (including vouchfx's Aspire-provisioned
            # dependency) usually require authentication; plain smoke-test containers
            # may not, so absence is tolerated.
            redis_password=os.environ.get("REDIS_PASSWORD") or None,
        )
