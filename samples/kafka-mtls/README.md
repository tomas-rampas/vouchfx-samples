# kafka-mtls

Mutual TLS against a real Kafka broker, tested end-to-end with
[vouchfx](https://github.com/tomas-rampas/vouchfx): a produce/consume round trip over a
mutually-authenticated `confluentinc/confluent-local:8.2.0` listener, secured entirely with plain
PEM certificate material — no JDK, no `keytool` anywhere in `setup.sh`/`setup.ps1`.

## What this demonstrates

- `security: profile: mtls` (`caCert`, `clientCert`, `clientKey`, `serverArtifacts`) against a
  Kafka broker vouchfx itself starts, secured with **PEM**, not JKS — `KAFKA_SSL_KEYSTORE_TYPE:
  PEM` reads a plain PEM file, so neither setup script ever shells out to `keytool`;
  `docs/02_YAML_DSL_Specification_and_VSCode_Extension_Design.md` §3.2.6b is the authoritative
  section this whole sample is built against.
- that the assurance a green run gives you comes from the **engine's own pre-run confirmation
  probe**, not from a hand-written negative-control step (see "Why there's no negative control in
  this suite" below).
- the `env:` block that actually turns TLS on for the broker — the eight `KAFKA_LISTENER_*` /
  `KAFKA_SSL_*` variables that wire a secured `PLAINTEXT_HOST` listener alongside the broker's
  ordinary internal ones, plus the KRaft/cluster-identity variables a lone container needs when
  nothing else is standing it up for you (see "The broker is a service, not a dependency" below).

## The broker is a service, not a dependency

An earlier version of this suite declared `broker` under `environment.dependencies` with
`type: kafka` — vouchfx does accept a `security:` block on a `kafka` dependency, on the same terms
as a service (docs §3.2.6b). That version reached CI (vouchfx-samples PR #37, engine v1.0.0-rc.5)
and **broke there**: Aspire allocated an unpredictable host port for the dependency's own `tcp`
binding (measured: `39725`), the suite's `KAFKA_ADVERTISED_LISTENERS` necessarily advertised a
different, guessed port (`localhost:9092`), and every Kafka client's standard second hop —
reconnecting to whatever `advertised.listeners` names, after the initial bootstrap succeeds — then
targeted a port nothing was listening on. The broker never became healthy, so the whole topology
failed before any step ran:

```
[thrd:localhost:39725/bootstrap]: Disconnected: connection closed by peer:
  receive 0 after POLLIN (after 3ms in state APIVERSION_QUERY)
fail: Stopped waiting for resource 'broker' to become healthy because it failed to start.
```

A `kafka` **dependency** has no author-facing field to pin its own host port: no `ports:`,
`${conn:}` is refused inside its own `env:` (docs §3.2.6c — a dependency is a connection *source*,
not a consumer), and `${env:}` cannot know a port Aspire has not allocated yet at authoring time.
This is filed as **engine issue #443** — until it lands, securing a `kafka` dependency's own
listener with a self-managed image (rather than a customer-supplied broker declared as a service)
is blocked.

A **service** does not have this problem. `ports:` accepts the `"<host>:<container>"` form
specifically to *pin* the host side, and docs §3.2.6b spells out exactly this case under *Kafka
targets*, third limit:

> "Pin the host port the broker's container port publishes on (`ports: ["19093:9093"]`, §3.2.6a),
> and configure the broker's own `advertised.listeners` through its `env:` map to name that same
> pinned host port on the host address the run reaches it at (`localhost`). With both in place a
> service-form broker is produced to and consumed from exactly like a dependency."

`tests/kafka-mtls.e2e.yaml` now does exactly that: `ports: ["19093:9092"]` pins the host side, and
`KAFKA_ADVERTISED_LISTENERS` names `localhost:19093` — a port that is actually knowable, because
this suite chose it rather than Aspire allocating it. This is not a downgrade in what the sample
proves: `security: profile: mtls` + PEM `serverArtifacts` behave identically on a service and on a
dependency (docs §3.2.6b: "on the same terms"); only the container topology declaration changed.

## Why `confluentinc/confluent-local:8.2.0`, not `cp-kafka:7.6.1`

The engine repo's own `examples/security-mtls.e2e.yaml` proves the identical `security:` block
against a Kafka broker declared as a service too — but using `confluentinc/cp-kafka:7.6.1`, an
older, ZooKeeper-capable Confluent Platform image, with its own `broker-entrypoint.sh` indirection
(a `serverArtifacts` entry that overrides `/etc/confluent/docker/bash-config` so the secured
listener is only added once the keystore has actually arrived). Every measurement behind *this*
sample — the exact `env:` set, the listener-name trap below, the keystore's key-then-cert-then-CA
concatenation order, a real produce/consume round trip, and the negative-control refusal — was
taken directly against `confluent-local:8.2.0` (the same image Aspire's own `AddKafka` resolves
to), with a plain `env:` block and no custom entrypoint override. Switching to `cp-kafka:7.6.1` on
top of switching from dependency to service form would trade one now-fixed unverified claim for a
new one; staying on `confluent-local:8.2.0` keeps every fact behind this sample measured against
the exact image it runs.

## The suite (`tests/kafka-mtls.e2e.yaml`)

Two steps, one narrative:

1. **`publish-order`** (`mq-publish.kafka`, target `broker`) — publishes a JSON payload to the
   `orders` topic over the mutually-authenticated listener.
2. **`consume-order`** (`mq-expect.kafka`, `verifyMode: RETRY`) — reads it back over the same
   connection, matching two JSON fields. Proves the round trip completed end to end, not merely
   that the engine's own probe could reach the broker.

There is no `app/` directory: this sample has no system under test, only the secured broker and the
two steps that exercise it.

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

Via the repository's sample runner, which runs `setup.sh` for you automatically before the suite:

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
script writes validates correctly through the other's own currency check.

**Prerequisite:** `setup.sh` needs `openssl` on `PATH` (present on essentially every Linux/macOS
install and every GitHub-hosted runner; also works under Git Bash on Windows — see the script's own
header for the two portability fixes that took, both verified not to change behaviour on a real
POSIX shell). `setup.ps1` needs only PowerShell 7 itself.

**The certificates are never committed.** Everything under `tests/certs/` is generated, git-ignored
(`samples/kafka-mtls/tests/certs*/` in the repository `.gitignore`) and thrown away. See
`setup.sh`'s own header for the full "this is not a real CA" warning, inherited verbatim from
`examples/security-mtls.setup.sh` in the engine repo. Every path under this suite's `security:`
block is also checked for **containment** — it must resolve inside `samples/kafka-mtls/tests/`,
the directory holding the `.e2e.yaml` file itself — and for existence, before any container starts
(docs §3.2.6b); a certificate path pointing outside that directory is rejected at `vouchfx validate`
time, not at run time.

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

### 2. `KAFKA_ADVERTISED_LISTENERS` must name the SAME pinned port `ports:` declares

This is the specific line that broke the dependency-form version of this suite (see "The broker is
a service, not a dependency" above), and it is easy to get wrong even on a service: `ports:
["19093:9092"]` pins the **host** side to `19093`, and `KAFKA_ADVERTISED_LISTENERS` must name that
exact host port (`localhost:19093`) for the `PLAINTEXT_HOST` listener — not `9092` (the container
side), and not a different number you picked without also changing `ports:` to match. If the two
disagree, the bootstrap connection can still succeed, but every subsequent produce/consume request
follows the broker's own advertised address, which then points nowhere reachable. Change `19093` in
one place, change it in both.

## Exact provider fields used

| Step type | Fields used | Verified against |
| --- | --- | --- |
| `mq-publish.kafka` | `target`, `topic`, `payload`, `timeout` | `Vouchfx.Steps.MqPublish.Kafka` — takes its transport from the target's declared `security` block (docs §3.2.6b/§5.2), whether the target is a dependency or a service. |
| `mq-expect.kafka` | `target`, `topic`, `verifyMode: RETRY`, `timeout`, `match.json` | `Vouchfx.Steps.MqExpect.Kafka` — the plain-JSON (non-Avro) path; RETRY absorbs residual broker startup latency, no author-written `sleep`. |

## Known unverified

**This exact service-form suite has not yet been run end to end.** The dependency-form version was
run through CI (vouchfx-samples PR #37, engine v1.0.0-rc.5) and that run is what surfaced the
port-allocation failure this README documents — CI is the validator for this repository's samples,
and the machine this sample was authored on has a local DCP port-allocation fault that blocks
`scripts/run-sample.sh` for every sample here, not just this one, so a local run was not attempted
for the converted suite either.

What **has** been measured, directly, before and during this sample's authoring:

- the exact `env:` set (including the KRaft/cluster-identity variables a lone service-form
  container needs, which a `kafka` dependency would otherwise get from Aspire's own `AddKafka`
  wiring), against `docker.io/confluentinc/confluent-local:8.2.0` started directly with
  `docker run -p <pinned-port>:9092` — broker logs confirmed `ssl.keystore.type = PEM`,
  `ssl.truststore.type = PEM`, `ssl.client.auth = required`, `ssl.keystore.password = null`, and a
  real `Confluent.Kafka` client completed a produce/consume round trip with a client certificate
  and was refused (`SSL alert number 116: certificate required`) without one — this is precisely
  the `docker run -p <host>:<container>` shape a pinned-port service now reproduces;
- the listener-name gotcha above, both directions;
- that the keystore file's concatenation order (key, then leaf certificate, then CA, in one file)
  works, via the same direct `docker run` measurement;
- that both `setup.sh` and `setup.ps1` produce valid, chain-verified, non-expired material, and
  that material from either script validates through the other's own currency check;
- that the failure mode described above is real and specific — quoted directly from the CI run
  that produced it, not inferred.

What remains genuinely open until a live CI run: whether `endpoint: "9092"` on the service's
`security:` block, `healthCheck: { type: tcp, port: 9092 }`, and the exact 22-variable `env:` block
combine to bring the topology healthy on the first try, or whether some interaction only a real
Aspire-orchestrated container start would surface (a stricter port-conflict check, a different
default the image applies inside a full topology versus a bare `docker run`, etc.) still needs a
second fix. If it does, the fix is confined to this one file — the underlying mechanism (pin the
host port, advertise the same one) is the one docs §3.2.6b already documents as working, and engine
issue #443 tracks the one confirmed defect this sample ran into.

## Key documents

- **[Engine blueprint](https://vouchfx.io/01_Technical_Architecture_and_Engineering_Blueprint/)** — the five-layer design, §4 Aspire, §11 security
- **[YAML DSL specification](https://vouchfx.io/02_YAML_DSL_Specification_and_VSCode_Extension_Design/)** — §3.2.6b "Transport security: reaching a service or a Kafka broker over TLS or mutual TLS"
- **[`examples/security-mtls.e2e.yaml`](https://github.com/tomas-rampas/vouchfx/blob/main/examples/security-mtls.e2e.yaml)** — the same `security:` block against a Kafka broker declared as a service on `cp-kafka:7.6.1`, plus an HTTP leg this sample does not have
- **[Engine CONTRIBUTING.md](https://github.com/tomas-rampas/vouchfx/blob/main/CONTRIBUTING.md)** — provider/SDK contract
