# kafka-mtls

Mutual TLS against a Kafka **dependency** — `environment.dependencies.broker: { type: kafka }` —
tested end-to-end with [vouchfx](https://github.com/tomas-rampas/vouchfx): a produce/consume round
trip over a broker Aspire itself manages, secured with plain PEM certificate material and no JDK
anywhere in the setup.

## What this demonstrates

The engine repo's own `examples/security-mtls.e2e.yaml` proves `security:` + mutual TLS against a
Kafka broker declared as a **service** — `cp-kafka:7.6.1`, standing in for a broker a customer
already runs and has already secured. That is a different, and more common, shape than the one
this sample exists to prove: can the same `security:` block secure the broker **vouchfx itself
starts** for you, via `type: kafka`? The dependency form resolves to a different image
(`docker.io/confluentinc/confluent-local:8.2.0`, not `cp-kafka:7.6.1`) with a different
entrypoint script, so nothing about the service-form example transfers without separately
measuring it — which is what this sample's setup scripts and suite do.

This sample demonstrates:

- a `kafka` **dependency** carrying a `security:` block (`profile: mtls`, `caCert`, `clientCert`,
  `clientKey`, `serverArtifacts`) — the one dependency kind that accepts one in this release
  (`docs/02_YAML_DSL_Specification_and_VSCode_Extension_Design.md` §3.2.6b);
- securing the broker's own listener entirely with **PEM** material
  (`KAFKA_SSL_KEYSTORE_TYPE: PEM`) — no `keytool`, no JDK, no JKS keystore anywhere in
  `setup.sh`/`setup.ps1`;
- a dependency's `env:` map **overriding** three variables Aspire's own `AddKafka` resource sets
  by default, which is what makes a secured listener possible at all (see "Two things you will
  otherwise get wrong" below);
- that the assurance a green run gives you comes from the **engine's own pre-run confirmation
  probe**, not from a hand-written negative-control step (see "Why there's no negative control in
  this suite" below).

## The suite (`tests/kafka-mtls.e2e.yaml`)

Two steps, one narrative:

1. **`publish-order`** (`mq-publish.kafka`, target `broker`) — publishes a JSON payload to the
   `orders` topic over the mutually-authenticated listener.
2. **`consume-order`** (`mq-expect.kafka`, `verifyMode: RETRY`) — reads it back over the same
   connection, matching two JSON fields. Proves the round trip completed end to end, not merely
   that the engine's own probe could reach the broker.

There is no `app/` directory and no `environment.services` entry: this sample has no system under
test, only the secured dependency and the two steps that exercise it.

## Why there's no negative control in this suite

For a secured `kafka` **target** — dependency or service, `profile: mtls` — the engine's own
pre-run confirmation probe reports `AuthenticatedRoundTrip` only when **both** of these succeed,
before step 1 ever runs:

1. a real Kafka `ApiVersions` round trip completes over the mutually-authenticated connection, and
2. a **second** connection presenting no client certificate is **refused**.

Both halves are required — a broker that never asks for a certificate objects to nothing, so the
refusal alone would prove nothing without the first half, and the round trip alone would not prove
mTLS was enforced without the second. It fails **closed**: an unconfirmable `security:` declaration
exits non-zero with no gating flag needed (docs §3.2.6b, "Confirmation before the suite runs").

A hand-written negative-control step in this suite — connect without a cert, expect a rejection —
would only prove something the engine already proved before the suite's first step ran, using the
same broker, the same CA, and the same declared client identity. Leaving it out is the accurate
statement of where the assurance comes from: **the engine**, independently of what this suite's own
steps do or don't assert. This mirrors `examples/security-mtls.e2e.yaml`'s own closing note in the
engine repo almost exactly, for the Kafka leg specifically (that example's negative controls for
the *HTTP* leg live in the engine's own drill suite instead, for the same reason: an example that
deliberately fails is one CI would reject).

## How to run

Via the repository's sample runner, which now runs `setup.sh` for you automatically before the
suite (see `scripts/run-sample.sh`'s setup-hook, added alongside this sample):

```bash
scripts/run-sample.sh kafka-mtls
```

The equivalent manual steps:

```bash
# 1. Generate the CA + broker/client PEM material (openssl only, no JDK).
bash samples/kafka-mtls/setup.sh

# 2. Run the suite (from the vouchfx engine checkout, with the CLI built).
vouchfx run samples/kafka-mtls/tests/kafka-mtls.e2e.yaml --fail-on-env-error --fail-on-inconclusive
```

On Windows, `setup.ps1` is the PowerShell-native sibling — no `openssl` needed there either, since
PowerShell 7 is built on .NET and the script uses `X509Certificate2`/`CertificateRequest` directly.
Both scripts are idempotent (re-running is a no-op while the existing material is still valid,
regenerating automatically once within a day of expiry) and **cross-compatible**: material either
script writes validates correctly through the other's own currency check — measured, not assumed,
by generating with one and re-running the other against the same `certs/` directory.

**Prerequisite:** `setup.sh` needs `openssl` on `PATH` (present on essentially every Linux/macOS
install and every GitHub-hosted runner; also works under Git Bash on Windows — see the script's own
header for the two portability fixes that took, both verified not to change behaviour on a real
POSIX shell). `setup.ps1` needs only PowerShell 7 itself.

**The certificates are never committed.** Everything under `certs/` is generated, git-ignored
(`samples/kafka-mtls/tests/certs*/` in the repository `.gitignore`) and thrown away. See `setup.sh`'s own
header for the full "this is not a real CA" warning, inherited verbatim from
`examples/security-mtls.setup.sh` in the engine repo.

## Two things you will otherwise get wrong

### 1. The listener name must NOT end in `SSL`

`confluent-local:8.2.0`'s own `/etc/confluent/docker/configure` entrypoint script string-matches
`KAFKA_ADVERTISED_LISTENERS` for the literal substring `"SSL://"`. If found, it unconditionally
demands `KAFKA_SSL_KEYSTORE_FILENAME` (a JKS-only, file-*indirection* variable this sample never
sets, since it uses `KAFKA_SSL_KEYSTORE_LOCATION` pointing straight at a PEM file) via a `ub ensure`
preflight check — a bash script failure, not a Kafka broker error, and it happens before Kafka
itself ever starts.

**Measured, both directions, before this sample was written:**

- A listener named `PLAINTEXT_HOST` (no `"SSL"` substring) — what this suite uses — skips that
  bash branch entirely, and the image's generic `KAFKA_*` → property-name mapper applies
  `KAFKA_SSL_KEYSTORE_TYPE=PEM` and friends directly. The broker starts clean.
- A listener named `EXTERNAL_SSL` made the container **exit 1 immediately**:
  ```
  SSL is enabled.
  Error: environment variable "KAFKA_SSL_KEYSTORE_FILENAME" is not set
  ```

If you copy this sample's `env:` block and rename the secured listener to anything ending in
`SSL` — a natural-looking name — the container will not start, and the error names a variable this
sample's PEM path deliberately never sets, which is confusing without this context.

### 2. The `env:` map deliberately overrides three variables Aspire itself sets

`AddKafka` wires `KAFKA_LISTENERS` / `KAFKA_ADVERTISED_LISTENERS` /
`KAFKA_LISTENER_SECURITY_PROTOCOL_MAP` itself by default — three all-`PLAINTEXT` listeners
(`PLAINTEXT`, `PLAINTEXT_HOST`, `PLAINTEXT_INTERNAL`), with no secured listener anywhere. This
sample's `env:` block sets the same three names to different values, and — per docs §3.2.6c — **the
author's value wins**: a dependency's `env:` entry overrides Aspire's own default for any name the
engine does not itself reserve for that dependency type (only `elasticsearch`, `minio` and
`azureservicebus` reserve names in this release; `kafka` does not). Without this override there is
no secured listener for `profile: mtls` to attach to at all — the suite would validate and start a
container, then fail the pre-run confirmation probe because nothing on the broker speaks TLS.

## Exact provider fields used

| Step type | Fields used | Verified against |
| --- | --- | --- |
| `mq-publish.kafka` | `target`, `topic`, `payload`, `timeout` | `Vouchfx.Steps.MqPublish.Kafka` — takes its transport from the target's declared `security` block (docs §3.2.6b/§5.2). |
| `mq-expect.kafka` | `target`, `topic`, `verifyMode: RETRY`, `timeout`, `match.json` | `Vouchfx.Steps.MqExpect.Kafka` — the plain-JSON (non-Avro) path; RETRY absorbs residual broker/consumer-group startup latency, no author-written `sleep`. |

## Known unverified

**This sample has not yet been run end to end through `scripts/run-sample.sh`.** It needs a
dependency's `env:` map, which landed together with dependency-level `security:` support at the
same engine commit — and [`../../ENGINE_PIN`](../../ENGINE_PIN) has not yet been advanced to a
commit that includes it as of this sample being written. `scripts/run-sample.sh`'s auto-bootstrap
would build against the *current* pin and the suite would not compile.

What **has** been measured, directly, before this sample was written:

- the exact eight-variable `env:` set, against `docker.io/confluentinc/confluent-local:8.2.0`
  started directly with `docker run` (not Aspire-orchestrated) — broker logs confirmed
  `ssl.keystore.type = PEM`, `ssl.truststore.type = PEM`, `ssl.client.auth = required`,
  `ssl.keystore.password = null`, and a real `Confluent.Kafka` client completed a produce/consume
  round trip with a client certificate and was refused (`SSL alert number 116: certificate
  required`) without one;
- the listener-name gotcha above, both directions;
- that the keystore file's concatenation order (key, then leaf certificate, then CA, in one file)
  works, via the same direct `docker run` measurement;
- that both `setup.sh` and `setup.ps1` produce valid, chain-verified, non-expired material, and
  that material from either script validates through the other's own currency check.

What has **not** been measured, and is a real, specifically-identified risk rather than a vague
disclaimer: **`KAFKA_ADVERTISED_LISTENERS`'s host port.** This suite's `env:` block advertises
`localhost:9092` literally. Every measurement behind this sample used a container started directly
with `docker run -p <chosen-port>:9092`, where the host port was picked and pinned by the person
running the command. An Aspire-orchestrated `kafka` dependency has no author-facing field to pin
its host port the way a service's `ports: ["19093:9093"]` can — the earlier census of Aspire's own
`AddKafka` defaults shows it using a *templated* placeholder (`{broker.bindings.tcp.port}`) for
exactly this binding, which is Aspire's own signal that the host port is dynamically allocated, not
fixed. A Kafka client's second hop — reconnecting to whatever `advertised.listeners` names, after
the initial bootstrap — is standard protocol behaviour, not specific to this provider. If Aspire's
actual allocated host port differs from the literal `9092` this suite advertises, that second hop
would target a port nothing is listening on, and the suite would environment-error on the produce
step even though the pre-run confirmation probe (which dials Aspire's own resolved endpoint
directly, not the text in `KAFKA_ADVERTISED_LISTENERS`) might still succeed. **Resolving this needs
a live run against an engine pin that supports dependency `env:`, which had not yet happened when
this sample was written.** If the literal port turns out to be wrong once that run is possible, the
fix is confined to one line in `tests/kafka-mtls.e2e.yaml`.

## Key documents

- **[Engine blueprint](https://vouchfx.io/01_Technical_Architecture_and_Engineering_Blueprint/)** — the five-layer design, §4 Aspire, §11 security
- **[YAML DSL specification](https://vouchfx.io/02_YAML_DSL_Specification_and_VSCode_Extension_Design/)** — §3.2.6b "Transport security: reaching a service or a Kafka broker over TLS or mutual TLS"
- **[`examples/security-mtls.e2e.yaml`](https://github.com/tomas-rampas/vouchfx/blob/main/examples/security-mtls.e2e.yaml)** — the same `security:` block against a Kafka broker declared as a *service*, plus an HTTP leg this sample does not have
- **[Engine CONTRIBUTING.md](https://github.com/tomas-rampas/vouchfx/blob/main/CONTRIBUTING.md)** — provider/SDK contract
