# Migrating from Postman

**Source:** [`source/orders-smoke.postman_collection.json`](source/orders-smoke.postman_collection.json) + [`source/local.postman_environment.json`](source/local.postman_environment.json) — a genuine Postman Collection v2.1 export: two requests (`Place order`, `Fetch order by id`), each with a `pm.test` script, chained through a collection variable.

**Ported:** [`ported/orders-smoke.e2e.yaml`](ported/orders-smoke.e2e.yaml) — the same two-request flow as a vouchfx suite against `samples/orders-dotnet/app`, the same service `samples/orders-dotnet/tests/orders.e2e.yaml` already exercises.

This is a worked example for [vouchfx issue #118](https://github.com/tomas-rampas/vouchfx/issues/118) (via this repository) — see [`../README.md`](../README.md) for the philosophy behind every migration in this tree: **re-author, don't auto-convert.**

## Why this collection, specifically

Most teams that reach for Postman have exactly this shape of collection lying around: a couple of requests a developer built up while exercising an API by hand, later pressed into service as a "smoke test" run manually before a release, or through `newman` in CI. It is realistic, not a strawman — no folder structure, no pre-request scripts, no environment-swapping ceremony, just two requests and some `pm.test` assertions chaining through a variable.

## Field-by-field mapping

| Postman element | vouchfx equivalent | Notes |
| --- | --- | --- |
| `item[].request` (`method`, `url`, `header`, `body`) | an `http.rest` step (`target`, `method`, `path`, `headers`, `body`) | `target` replaces the collection's `{{baseUrl}}` — see below. |
| `pm.test("Status code is …", () => pm.response.to.have.status(N))` | `expect.status: N` | A direct, declarative equivalent. |
| `pm.test(...)` deep JSON-body assertion (`pm.expect(json.field).to.eql(...)`) | `capture` the field, then assert it in a `script.csharp` step | `http.rest`'s `expect` block supports **only** a status-code check — there is no declarative "assert this response field equals that value" block. `script.csharp` is the escape hatch; see `assert-place-order-fields` / `assert-fetch-order-fields` in the ported suite. |
| `pm.collectionVariables.set("orderId", pm.response.json().id)` / `pm.collectionVariables.get("orderId")` | `capture: { orderId: "$.id" }` (writes into the shared `Vars` context) + `{orderId}` placeholder substitution | Same idea, different syntax: a step captures a value once, and every later step can reference it. |
| `{{baseUrl}}` — swapped per active Postman environment | `environment.services.orders-api` + `target: orders-api` | vouchfx resolves the running container's real address itself, via Aspire service discovery, at orchestration time. There is no per-environment base-URL variable to maintain, because there is no "environment" to point at in the first place — the suite **is** the environment; it stands the service up. |
| Postman environment variable with `"type": "secret"` (`{{apiKey}}`) | `${secret:env/VOUCHFX_SAMPLES_ORDERS_API_KEY}` on the `X-Api-Key` header | Resolved from the run environment at **step-execution time**, never baked into the compiled suite (§17 of the engine's blueprint). `scripts/run-migrations.*` sets the environment variable before invoking the CLI — see [`../README.md`](../README.md#running-the-migrations). |
| Two requests, run top-to-bottom in the Collection Runner | two ordered entries under `steps:` | A vouchfx suite is already an ordered list; there is no separate "run order" concept to configure. |
| A test script calling `pm.sendRequest()` to chain an extra async call | plain step ordering | A later step's `capture`/`{placeholder}` reads directly from an earlier step's response. There is no equivalent of firing a request *from inside* an assertion script — every HTTP call is its own `http.rest` step. |

## What does NOT map

- **Arbitrary pre-request JavaScript** (computing an HMAC signature, mutating headers based on a previous response, generating a nonce) has no declarative vouchfx equivalent. `script.csharp` is the escape hatch: it runs inside the same compiled delegate with full `Vars` access, but it is deliberately **not sandboxed** (§13 of the engine's blueprint) — treat it as trusted test code, exactly like the Postman script it replaces.
- **Newman folder runs** (`newman run collection.json --folder "Smoke"`) have no folder concept in vouchfx. The equivalent is `metadata.tags` plus the CLI's tag-selection flag, or simply splitting a suite into separate `.e2e.yaml` files — a suite is already the unit newman's `--folder` approximates.
- **Postman's dynamic variables** (`{{$guid}}`, `{{$timestamp}}`, `{{$randomInt}}`) have no built-in equivalent. Generate the value in a `script.csharp` step and write it into `Vars` if a suite genuinely needs a client-supplied random value; most of the time the system under test should be generating its own identifiers, so vouchfx deliberately does not provide a magic-variable shortcut that would let a suite paper over that.
- **Deep structural body assertions** (`pm.expect(json).to.deep.equal({...})` against a whole nested object) are the same limitation as single-field assertions above, just more of it: there is no declarative deep-equality block for an HTTP response body. Reach for `script.csharp`, or — often the better test — assert what actually matters (a handful of fields, or what landed in the database) rather than the entire response shape.

## Running this example

Via the repository's migration runner (builds the shared `orders-dotnet` image and runs all three ported suites):

```bash
scripts/run-migrations.sh
```

```powershell
scripts\run-migrations.ps1
```

Or standalone, once `scripts/bootstrap.*` has built the engine CLI and the `vouchfx-samples-orders-dotnet:local` image exists (see `samples/orders-dotnet/README.md`):

```bash
# Note: dotnet run --project sets the launched process's working directory to the
# CLI project's own directory, not your shell's — pass an absolute suite path (as
# scripts/run-migrations.* does) rather than a relative one.
VOUCHFX_SAMPLES_ORDERS_API_KEY=local-dev-key-not-real \
  dotnet run --project .vouchfx-src/src/Cli/Vouchfx.Cli/Vouchfx.Cli.csproj -c Release -- \
  run "$(pwd)/migrations/from-postman/ported" --fail-on-env-error --fail-on-inconclusive
```

Expected result: **Pass**, 4 steps (`place-order`, `assert-place-order-fields`, `fetch-order`, `assert-fetch-order-fields`).
