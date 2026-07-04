# inventory-python

A vouchfx sample proving the engine can orchestrate and test a **non-.NET**
system under test. The service here is a small Python (FastAPI) "Inventory"
API; the suite exercises the same REST → database → cache → broker shape as
vouchfx's own .NET reference scenario, reproduced against a different stack
end to end.

## What this demonstrates

- vouchfx's container topology (`environment.services` / `environment.dependencies`)
  is technology-agnostic: the system under test is an ordinary OCI image, and
  nothing about the engine cares that it happens to be Python rather than C#.
- One HTTP call fanning out into three different kinds of durable state —
  a relational row, a cache entry, a broker event — and each is asserted with
  a *different* provider family: `db-assert.mysql`, `cache-assert.redis`,
  `mq-expect.rabbitmq`.
- Cross-step data flow via `capture` / `{placeholder}` substitution: the sku
  is captured from the creation response and threaded through every
  subsequent step, never hard-coded twice.
- The engine's health-gating contract: the suite (and any orchestrator) waits
  for `GET /` to return 2xx before running a single step, so a slow-starting
  dependency is never mistaken for a broken test.

## Architecture

```
                         ┌─────────────────────────┐
  vouchfx suite          │   inventory-api (8080)  │
  (tests/inventory.      │   Python 3.12 / FastAPI │
   e2e.yaml)             │                         │
       │                 │  GET  /                 │
       │  1. POST/GET    │  POST /items             │
       └────────────────►│  GET  /items/{sku}       │
                          └──────┬───────┬──────┬────┘
                                 │       │      │
                     upsert row  │       │      │ publish
                                 ▼       │      ▼ "stock-changed"
                          ┌──────────┐  │  ┌──────────────┐
                          │  MySQL   │  │  │  RabbitMQ    │
                          │  invdb   │  │  │  stock-events│
                          │  items   │  │  │  (durable)   │
                          └────┬─────┘  │  └──────┬───────┘
                               │        │         │
                    2. db-assert.mysql  │  4. mq-expect.rabbitmq
                        (row exists)    │      (event matched)
                                        ▼
                                 ┌─────────────┐
                                 │    Redis    │
                                 │  item:<sku> │
                                 └──────┬──────┘
                                        │
                          3. cache-assert.redis (key exists)
                                        │
                          5. GET /items/{sku} — 200, served
                             from this same cache entry
                             (read-through proof)
```

The suite itself never talks to MySQL/Redis/RabbitMQ directly except through
their vouchfx provider steps — the assertions run against the *actual*
side effects the app produced, not a mock.

## The app (`app/`)

A deliberately small, typed FastAPI service:

| File | Responsibility |
|---|---|
| `main.py` | FastAPI app, lifespan-based startup retry loop, the three HTTP endpoints. |
| `config.py` | Reads all configuration from environment variables (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `RABBITMQ_URL`, `REDIS_HOST`, `REDIS_PORT`). No config file. |
| `models.py` | `ItemIn` / `ItemOut` Pydantic models — the request/response contract. |
| `db.py` | MySQL access (`pymysql`): schema creation, upsert, read-by-sku. One short-lived connection per call. |
| `cache.py` | Redis access (`redis-py`): a single shared client, `item:<sku>` write/read. |
| `mq.py` | RabbitMQ access (`pika`): durable `stock-events` queue declaration and publish. A fresh connection per call, because `pika.BlockingConnection` is not thread-safe and FastAPI runs each sync route in its own thread. |

Endpoints:

- `GET /` — readiness probe. Returns `503 {"status":"starting"}` until MySQL,
  RabbitMQ, and Redis have all answered and been provisioned (schema created,
  queue declared); `200 {"status":"ready"}` afterwards. vouchfx health-gates
  the topology on this endpoint before running the first step.
- `POST /items` — validates `{sku, name, stock}`, upserts the row into MySQL,
  writes the JSON representation to Redis at `item:<sku>`, publishes
  `{"sku","stock","event":"stock-changed"}` to the durable `stock-events`
  queue (default exchange, routing key = queue name), and echoes the stored
  item with `201`.
- `GET /items/{sku}` — Redis-first read-through: a cache hit returns
  immediately; a miss falls back to MySQL and repopulates the cache. `404` if
  the item exists nowhere.

Startup retries every dependency for up to ~60 seconds (2-second interval)
before giving up and staying not-ready — it never crashes the process, so a
slow-to-schedule dependency container is a startup delay, not a hard failure.

## The suite (`tests/inventory.e2e.yaml`)

| Step | Provider | Proves |
|---|---|---|
| `create-item` | `http.rest` | `POST /items` returns `201`; captures `sku` from the response body (`$.sku`) so every later step references the *actual* created value, never a duplicated literal. |
| `assert-mysql-row` | `db-assert.mysql` | The row exists in MySQL with the expected `name` and `stock`, keyed by the captured `sku`. |
| `assert-redis-key` | `cache-assert.redis` | The `item:<sku>` cache entry exists in Redis. See the YAML comment on this step: `cache-assert.redis` only supports exact string equality or presence checks (no JSONPath/substring matching against the cached value per its schema), so this step uses `operation: exists` rather than an exact-value match that would couple the suite to the app's precise JSON serialisation. |
| `assert-stock-event` | `mq-expect.rabbitmq` | A `stock-changed` event for the captured `sku` reached the durable `stock-events` queue, polling with `verifyMode: RETRY` because the publish happens after the HTTP response returns. **Assumption**: the app declares the queue durable at startup (`app/mq.py::declare_queue`, called from the FastAPI lifespan) — the suite itself does not declare it. |
| `get-item` | `http.rest` | `GET /items/{sku}` returns `200`, proving the Redis read-through path actually serves the second read. |

## How to run

This sample is driven by the repo-level runner, not directly:

```bash
scripts/run-sample inventory-python
```

That script builds `app/Dockerfile` as `vouchfx-samples-inventory-python:local`,
stands up the topology declared in `tests/inventory.e2e.yaml` via vouchfx, and
runs the suite. Do not run `tests/inventory.e2e.yaml` directly with `vouchfx
run` unless you know the orchestrator's image tag and topology conventions —
`scripts/run-sample` exists precisely to keep those consistent across every
sample in this repo.

To iterate on the app in isolation without the engine (what this sample's
build was validated with), build and run it by hand against real containers:

```bash
docker build -t vouchfx-samples-inventory-python:local samples/inventory-python/app

docker network create inv-dev
docker run -d --name inv-mysql --network inv-dev \
  -e MYSQL_ROOT_PASSWORD=rootpass -e MYSQL_DATABASE=invdb \
  -e MYSQL_USER=invuser -e MYSQL_PASSWORD=invpass mysql:8
docker run -d --name inv-redis --network inv-dev redis:7
docker run -d --name inv-rabbitmq --network inv-dev rabbitmq:3-management

docker run -d --name inv-api --network inv-dev -p 18081:8080 \
  -e DB_HOST=inv-mysql -e DB_PORT=3306 -e DB_USER=invuser \
  -e DB_PASSWORD=invpass -e DB_NAME=invdb \
  -e RABBITMQ_URL=amqp://guest:guest@inv-rabbitmq:5672/ \
  -e REDIS_HOST=inv-redis -e REDIS_PORT=6379 \
  vouchfx-samples-inventory-python:local

curl http://localhost:18081/
curl -X POST http://localhost:18081/items -H "Content-Type: application/json" \
  -d '{"sku":"SKU-1042","name":"Bluetooth Keyboard","stock":25}'
curl http://localhost:18081/items/SKU-1042

docker rm -f inv-api inv-mysql inv-redis inv-rabbitmq
docker network rm inv-dev
```

## Troubleshooting

- **`RuntimeError: 'cryptography' package is required for sha256_password or
  caching_sha2_password auth methods`** — MySQL 8's default auth plugin is
  `caching_sha2_password`, and `pymysql` needs the `cryptography` package to
  speak it. It is pinned in `requirements.txt`; if you see this, check the
  dependency actually installed in your image (`pip show cryptography`).
- **Startup stays at `503 {"status":"starting"}` past ~60 seconds** — one of
  MySQL/RabbitMQ/Redis never became reachable within the retry window. Check
  `docker logs` on the app container: each failed attempt logs the exception
  type and message. Common causes: wrong hostname/port env var, a dependency
  container still pulling its image, or a firewalled Docker network.
  vouchfx itself would classify a persistent `503` on the health gate as an
  **environment error**, not a test failure — this is deliberate (§12.1 of
  the engine's verdict taxonomy): a container that never came up is an
  infrastructure problem, not a product defect.
- **`mq-expect.rabbitmq` step times out** — confirm the app actually declared
  `stock-events` as durable before the publish (check the app logs for
  `stock-changed event published`), and that nothing else drained the queue
  first (e.g. a stray manual `rabbitmqadmin get` during debugging — use
  `ackmode=ack_requeue_true` or a management-UI "Get messages" with requeue
  if you need to peek without consuming).
- **Port already allocated when smoke-testing locally** — the manual
  `docker run` commands above use container-to-container networking for
  everything except the app's own published port; only `-p 18081:8080` needs
  a free host port, so change that mapping if `18081` is already in use.
- **Redis shows the old value after changing `stock`** — `POST /items` is an
  upsert; posting the same `sku` again with different fields is expected to
  update MySQL, Redis, and publish a new event, not append a new row.
