#!/usr/bin/env bash
# =============================================================================
#  setup.sh — generate the throwaway certificates that kafka-mtls.e2e.yaml
#  declares for a mutually-authenticated Kafka broker, declared as a SERVICE
#  under `environment.services` so its host port can be pinned — a dependency
#  cannot advertise a reachable address (engine issue #443).
#
#  ###########################################################################
#  #  THIS IS A TEST CERTIFICATE AUTHORITY.  IT IS NOT SECURE.               #
#  #                                                                         #
#  #  Every private key it writes is unencrypted, world-generatable and      #
#  #  reproducible by anyone who runs this file.  The authority signs        #
#  #  anything asked of it and is trusted by nothing.  Do not install it,    #
#  #  do not copy it into another project, and never present anything it     #
#  #  issues to a system you did not create for the purpose.                 #
#  ###########################################################################
#
#  WHY A SCRIPT AND NOT A STEP.  vouchfx checks every path under a `security:`
#  block — that it stays inside the suite directory, and that the file is
#  actually there — BEFORE it starts a single container. A `script.csharp`
#  step runs long after that gate, so no step can create this material in
#  time. This mirrors examples/security-mtls.setup.sh in the engine repo
#  exactly, for the same reason.
#
#  WHY openssl ONLY. This sample's whole point is that a mutually-authenticated
#  Kafka dependency needs no JDK: `KAFKA_SSL_KEYSTORE_TYPE: PEM` reads a plain
#  PEM keystore file, not a JKS one, so there is no `keytool` step anywhere in
#  this script. openssl is present on essentially every Linux/macOS machine
#  and every GitHub-hosted runner. See setup.ps1 for the Windows-native sibling
#  (PowerShell 7's own X509 APIs, no openssl needed there either).
#
#  THE KEYSTORE FILE'S CONCATENATION ORDER — key, then leaf certificate, then
#  CA, in that order, all three in ONE file — is the order actually MEASURED
#  against docker.io/confluentinc/confluent-local:8.2.0 with
#  KAFKA_SSL_KEYSTORE_TYPE=PEM before this sample was written. Kafka's PEM
#  store parser scans for BEGIN PRIVATE KEY / BEGIN CERTIFICATE markers rather
#  than depending on position, so this is not the only order that would work —
#  it is the one that was actually run, broker logs inspected
#  (`ssl.keystore.location`/`ssl.truststore.location` populated,
#  `ssl.client.auth = required`, `ssl.keystore.password = null`), and a real
#  produce/consume round trip completed against it. Do not "simplify" this to
#  key+cert only without re-measuring — that is a DIFFERENT, unverified claim.
#
#  THE KEY IS UNENCRYPTED. Kafka's PEM path resolves `ssl.key.password` from
#  KAFKA_SSL_KEY_PASSWORD, which this sample does not set, and the measured
#  broker config confirms `ssl.key.password = null` — no password variable is
#  needed for an unencrypted key. This is the same shape vouchfx engine issue
#  #384 tracks generally: mTLS material that must be unencrypted at rest is a
#  known, open constraint, not something this script works around.
#
#  PREREQUISITE: openssl on PATH.
#
#  USAGE  (invoked through `bash` so no executable bit is required)
#      bash samples/kafka-mtls/setup.sh           # generate if needed
#      bash samples/kafka-mtls/setup.sh --force   # always regenerate
#
#  Idempotent: re-running is a no-op while the existing material is still
#  valid, and regenerates automatically once it is within a day of expiry.
# =============================================================================
#
#  WHY THE SUBJECT NAME NEVER GOES THROUGH `-subj`, AND WHAT WAS TRIED FIRST.
#  A bare `-subj "/CN=Test CA"` is indistinguishable, to Git Bash's MSYS
#  runtime on Windows, from an absolute POSIX path, and gets silently
#  rewritten before openssl ever sees it (measured: it arrived as
#  `-subj C:/Program Files/Git/CN=Test CA` and failed with "subject name is
#  expected to be in the format /type0=value0/..."). The first fix here was
#  `-subj "//CN=X"`, on the claim that openssl's subject parser treats a
#  leading empty RDN as a no-op on every platform — verified only against
#  `openssl x509 -noout -subject` on this maintainer's own machine (OpenSSL
#  3.5.6). IT IS NOT TRUE ON EVERY PLATFORM: OpenSSL 3.0.13 — Ubuntu 24.04's
#  stock version, i.e. every GitHub-hosted `ubuntu-latest` CI runner — parses
#  `-subj "//CN=X"` into a certificate with a GENUINELY EMPTY subject/issuer
#  DN (measured directly on the runner: `openssl x509 -noout -subject`
#  printed nothing, and `openssl asn1parse` showed a zero-length Name
#  SEQUENCE), not `CN=X`. Kafka's Java PEM store does not tolerate that:
#  loading a keystore built from such a certificate fails the broker's own
#  SSL init with `java.security.cert.CertificateParsingException: Empty
#  issuer DN not allowed in X509Certificates`, and the container exits ---
#  which is why this is called out here rather than left to be rediscovered:
#  do NOT go back to a doubled leading slash to solve a future MSYS problem
#  with `-subj`.
#
#  MSYS_NO_PATHCONV=1 was tried next, and measured to fail differently: it is
#  a per-PROCESS toggle, not a per-ARGUMENT one, so applying it to an
#  `openssl req` invocation that also carries `-keyout`/`-out` as absolute
#  POSIX paths (this script's `$work`/`$secrets_work`, both produced by
#  `$(cd .. && pwd)`) suppresses MSYS's conversion of THOSE paths too —
#  measured: `req: Can't open ".../ca-key.pem" for writing, No such file or
#  directory`. One env var cannot both stop MSYS rewriting `-subj` and keep
#  it rewriting `-keyout`/`-out` on the same command line.
#
#  THE FIX: `dn_config` below writes the Common Name into a tiny openssl
#  CONFIG FILE and every `openssl req` call here takes `-config` instead of
#  `-subj`. The DN value never becomes an argv token, so MSYS never sees
#  anything resembling a path to rewrite, and it never passes through
#  `-subj`'s own parser, so the OpenSSL-3.0.13-specific empty-DN behaviour
#  above never triggers either. The config FILE's own path is a normal
#  `-keyout`-style absolute POSIX path and is left to MSYS's ordinary
#  (unsuppressed) conversion, exactly like every other path this script
#  passes to openssl.
set -euo pipefail

readonly CA_SUBJECT="Vouchfx Sample kafka-mtls CA"
readonly CLIENT_SUBJECT="vouchfx-kafka-mtls-client"
readonly BROKER_SUBJECT="localhost"
readonly DAYS=30

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly certs_dir="${script_dir}/tests/certs"

# Staging sits BESIDE the destination, not in /tmp, so publishing is a rename
# within one filesystem rather than a cross-device copy. See the publish step.
readonly staging_dir="${certs_dir}.new"

force=0
if [ "${1:-}" = "--force" ]; then
  force=1
elif [ "$#" -gt 0 ]; then
  printf 'usage: %s [--force]\n' "$0" >&2
  exit 2
fi

# The seven files the suite declares. Named once, checked once, listed once.
readonly OUTPUTS=(
  ca.pem
  client.pem client-key.pem
  broker.pem broker-key.pem
  broker.keystore.pem broker.truststore.pem
)

# ── Is the existing material still usable? ───────────────────────────────────
# Same three questions as examples/security-mtls.setup.sh: present, chains to
# the CA beside it, and not within a day of expiring.
material_is_current() {
  local f
  for f in "${OUTPUTS[@]}"; do
    [ -s "${certs_dir}/${f}" ] || return 1
  done

  openssl verify -CAfile "${certs_dir}/ca.pem" \
    "${certs_dir}/broker.pem" "${certs_dir}/client.pem" >/dev/null 2>&1 || return 1

  openssl x509 -in "${certs_dir}/ca.pem" -noout -checkend 86400 >/dev/null 2>&1
}

if [ "$force" -eq 0 ] && material_is_current; then
  printf 'kafka-mtls: certificates in %s are current — nothing to do.\n' "$certs_dir"
  printf 'kafka-mtls: pass --force to regenerate them anyway.\n'
  exit 0
fi

command -v openssl >/dev/null 2>&1 || {
  printf 'error: openssl not found on PATH, and this script needs it.\n' >&2
  printf '       Install it with your package manager — for example:\n' >&2
  printf '         Debian/Ubuntu   sudo apt-get install openssl\n' >&2
  printf '         Fedora/RHEL     sudo dnf install openssl\n' >&2
  printf '         macOS           brew install openssl\n' >&2
  printf '       If you happen to have PowerShell 7, the sibling script\n' >&2
  printf '       setup.ps1 needs no openssl at all — it uses .NET, which pwsh\n' >&2
  printf '       already carries. That is the normal route on Windows.\n' >&2
  exit 1
}

mkdir -p "$(dirname -- "$certs_dir")"

# Everything below is written into a STAGING DIRECTORY and published by
# swapping the directory itself — see examples/security-mtls.setup.sh in the
# engine repo for the full rationale (an interrupted file-by-file publish can
# leave a set that mixes two authorities and looks complete).
work="$staging_dir"

# THE CA'S OWN PRIVATE KEY AND THE CSRs NEVER TOUCH THE REPOSITORY. They go to
# a temporary directory outside the working tree; only the seven published
# files are written under samples/kafka-mtls/tests/certs/.
secrets_work="$(mktemp -d)"
trap 'rm -rf -- "$secrets_work" "$work"' EXIT
rm -rf -- "$work"
mkdir -p "$work"

printf 'kafka-mtls: generating a TEST certificate authority in %s\n' "$certs_dir"

# dn_config writes a minimal openssl config naming ONLY the Subject/Issuer DN
# for $1 (a Common Name) to path $2. See the header note above for why every
# `openssl req` call below takes `-config "$(...)"` instead of `-subj`.
dn_config() {
  local cn="$1" out="$2"
  cat > "$out" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = ${cn}
CNF
}

# ── 1. The private CA ────────────────────────────────────────────────────────
dn_config "$CA_SUBJECT" "${secrets_work}/ca-dn.cnf"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${secrets_work}/ca-key.pem" -out "${work}/ca.pem" -days "$DAYS" \
  -config "${secrets_work}/ca-dn.cnf" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" \
  >/dev/null 2>&1

# ── 2. The broker identity ───────────────────────────────────────────────────
# CN/SAN localhost + 127.0.0.1: the same hostname the client dials for every
# secured target vouchfx starts (docs/02, "Which hostname your server
# certificate must carry"). serverAuth+clientAuth so the same leaf is legal
# whichever way a TLS library checks EKU.
dn_config "$BROKER_SUBJECT" "${secrets_work}/broker-dn.cnf"
openssl req -newkey rsa:2048 -nodes \
  -keyout "${work}/broker-key.pem" -out "${secrets_work}/broker.csr" \
  -config "${secrets_work}/broker-dn.cnf" \
  >/dev/null 2>&1

# A real temp file, not `-extfile <(...)` process substitution: the latter
# hands openssl a /dev/fd/N path, which the native mingw64 openssl.exe build
# Git Bash resolves on Windows cannot open (measured: "unable to load
# extensions section" against /dev/fd/63) — a second, independent Windows/
# Git-Bash gap alongside the -subj one above. A plain file is identical on
# every platform, so this is a portability fix, not a behaviour change.
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth,clientAuth' \
  'subjectAltName=DNS:localhost,DNS:broker,IP:127.0.0.1' \
  'subjectKeyIdentifier=hash' \
  > "${secrets_work}/broker-ext.cnf"

openssl x509 -req -in "${secrets_work}/broker.csr" \
  -CA "${work}/ca.pem" -CAkey "${secrets_work}/ca-key.pem" -CAcreateserial -CAserial "${secrets_work}/ca.srl" \
  -out "${work}/broker.pem" -days "$DAYS" -sha256 \
  -extfile "${secrets_work}/broker-ext.cnf" \
  >/dev/null 2>&1

# ── 3. The client identity (the engine's own clientCert/clientKey) ──────────
# No SAN: this identity is never dialled, only presented. Both EKUs (not just
# clientAuth) for parity with setup.ps1's New-Leaf, which adds both
# unconditionally to every leaf it issues — matching examples/security-mtls's
# own convention in the engine repo, so the two sibling scripts stay
# byte-compatible rather than diverging on a detail neither script's own
# comments call out as intentional.
dn_config "$CLIENT_SUBJECT" "${secrets_work}/client-dn.cnf"
openssl req -newkey rsa:2048 -nodes \
  -keyout "${work}/client-key.pem" -out "${secrets_work}/client.csr" \
  -config "${secrets_work}/client-dn.cnf" \
  >/dev/null 2>&1

# Real temp file, same reason as the broker one above.
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth,clientAuth' \
  'subjectKeyIdentifier=hash' \
  > "${secrets_work}/client-ext.cnf"

openssl x509 -req -in "${secrets_work}/client.csr" \
  -CA "${work}/ca.pem" -CAkey "${secrets_work}/ca-key.pem" -CAcreateserial -CAserial "${secrets_work}/ca.srl" \
  -out "${work}/client.pem" -days "$DAYS" -sha256 \
  -extfile "${secrets_work}/client-ext.cnf" \
  >/dev/null 2>&1

# ── 4. The broker's two PEM stores ───────────────────────────────────────────
# Keystore = key, then leaf certificate, then CA, concatenated into ONE file —
# the MEASURED order (see the header note). Truststore is the CA alone.
cat "${work}/broker-key.pem" "${work}/broker.pem" "${work}/ca.pem" > "${work}/broker.keystore.pem"
cp "${work}/ca.pem" "${work}/broker.truststore.pem"

# ── 5. Publish ───────────────────────────────────────────────────────────────
# Private keys are narrowed BEFORE the swap, so they are never briefly
# readable at the live path. The EXIT trap removes $secrets_work (the CA key,
# CSRs, serial file) on every ending a shell can observe except SIGKILL.
chmod 600 \
  "${work}/client-key.pem" \
  "${work}/broker-key.pem" \
  "${work}/broker.keystore.pem"

rm -rf -- "$certs_dir"
mv -- "$work" "$certs_dir"

# NO `trap - EXIT` HERE — see examples/security-mtls.setup.sh's own note on
# why disarming here would be the bug, not a cleanup: $secrets_work still
# needs removing on the success path too, and `rm -rf` over the already-moved
# $work is a harmless no-op.

cat <<EOF
kafka-mtls: wrote ${#OUTPUTS[@]} files to ${certs_dir}
kafka-mtls:   ca.pem                 the private CA the broker and client chain to
kafka-mtls:   client.pem/-key        the identity the suite presents (security.clientCert/clientKey)
kafka-mtls:   broker.pem/-key        the broker's own leaf identity (pre-concatenation)
kafka-mtls:   broker.keystore.pem    the broker's key store: key, then cert, then CA (serverArtifacts)
kafka-mtls:   broker.truststore.pem  the broker's trust store (= ca.pem) (serverArtifacts)
kafka-mtls: valid for ${DAYS} days. THIS IS TEST MATERIAL — the keys are
kafka-mtls: unencrypted and the authority is trusted by nothing. Never reuse it.
EOF
