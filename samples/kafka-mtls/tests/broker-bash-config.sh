# samples/kafka-mtls/tests/broker-bash-config.sh
#
# Extra broker configuration for the `broker` service of ./kafka-mtls.e2e.yaml.
#
# THE FIX THIS FILE IS. CI measured the broker container starting but never
# becoming healthy: the TCP probe against the secured listener failed for the
# whole ~45s health-gate window, then
#   fail: Stopped waiting for resource 'broker' to become healthy because it
#   failed to start.
# A direct `docker run` reproduction with this suite's exact 22-variable
# `env:` block and the two PEM files BIND-MOUNTED (present from the container's
# first instant) reached STARTED in 6.4s — so the variable set was correct and
# the broker was not slow. The difference is delivery timing: Aspire delivers
# `serverArtifacts` via `WithContainerFiles`, which lands after the container
# starts, not before like a bind mount. The old suite put KAFKA_SSL_KEYSTORE_
# LOCATION straight into `env:`, unconditionally — so SSL initialisation could
# run before the keystore file had actually arrived, and once Kafka decides
# there is no usable key store for a listener it never binds that listener
# again. No amount of waiting fixes that; the health probe fails for the
# entire window because nothing is ever going to answer on 9092.
#
# THE MECHANISM, same one examples/security-mtls/broker-entrypoint.sh in the
# engine repo uses for exactly this reason: the Confluent image sources
# /etc/confluent/docker/bash-config before it renders broker properties, so
# exporting KAFKA_* here is equivalent to setting them in `env:` — with one
# difference that matters. This file can make the secured listener
# CONDITIONAL on the key material having actually arrived, so the broker never
# comes up half-secured — SSL is either fully configured or entirely off.
#
# WHERE IT FAILS IF THE MATERIAL DOES NOT ARRIVE, stated precisely, because
# this suite differs from the engine example this file is modelled on. That
# example keeps a plaintext listener the health check can reach, so a delivery
# failure there surfaces later, at a step's handshake. HERE the health check is
# `{ type: tcp, port: 9092 }` — the SECURED port — so with no secured listener
# nothing binds 9092, the health gate times out, and the run stops before any
# step executes. Either way it is loud and it is not half-secured; but expect a
# health-gate failure, not a handshake one, and expect zero steps to have run.
#
# Delivered to /etc/confluent/docker/bash-config — see `serverArtifacts` in
# ./kafka-mtls.e2e.yaml, where this file is listed ahead of the two PEM
# stores (order does not matter to Aspire, but it matches the order the
# broker actually needs them in: config, then key material).
#
# ADAPTED FROM, NOT COPIED FROM, the engine's own broker-entrypoint.sh: that
# fixture's secured listener is named SECURE and its stores are kafka.
# keystore.pem / kafka.truststore.pem. This suite already used the listener
# name PLAINTEXT_HOST (chosen before this fix existed, and kept — it does not
# end in "SSL" either, so the same trap below does not apply to it) and
# broker.keystore.pem / broker.truststore.pem, so this file keeps both rather
# than renaming things that were never broken.

# NO `set -o nounset -o errexit` HERE. This file is SOURCED by the Confluent
# image's own entrypoint, so a shell option set at the top applies to
# everything that entrypoint does afterwards, not just to the dozen or so
# lines below — a scope nobody reviewing this file is thinking about, and one
# that turns an unset variable somewhere in Confluent's own scripts into an
# abrupt exit. The only thing those options would protect here is the
# expansion immediately below, so that expansion guards itself, locally:
# (No apostrophe in that message, deliberately: bash parses the word inside
# ${var:?word} for quoting even within double quotes, so a stray quote makes
# the whole sourced file a syntax error — measured, and it silently costs you
# the secured listener rather than announcing itself.)
: "${VOUCHFX_SECURE_ADVERTISED:?must be set in the suite env block to the pinned host address}"

# BOTH stores, and both non-empty. Gating on the keystore alone was the first
# version of this file, and it left the exact hole this conditional exists to
# close, just one file along: `serverArtifacts` delivers the keystore and the
# truststore as two separate operations, so the keystore can land first, and a
# broker that turns SSL on with KAFKA_SSL_TRUSTSTORE_LOCATION pointing at a file
# that is not there yet fails SSL init and never binds the listener — the same
# silent, never-healthy shape as before, reached by a different route. `-s`
# rather than `-f` because a partially-written file is present but useless, and
# the delivery is not atomic.
if [ -s /etc/kafka/secrets/broker.keystore.pem ] \
   && [ -s /etc/kafka/secrets/broker.truststore.pem ]; then
  # THE LISTENER NAME `PLAINTEXT_HOST` IS LOAD-BEARING. DO NOT RENAME IT TO
  # ANYTHING ENDING IN `SSL`.
  #
  # confluent-local:8.2.0's own /etc/confluent/docker/configure script greps
  # the rendered KAFKA_ADVERTISED_LISTENERS for the literal substring
  # "SSL://", and when it matches it unconditionally demands the JKS-only,
  # file-INDIRECTION variables this sample's PEM path has no equivalent of
  # (KAFKA_SSL_KEYSTORE_FILENAME plus KAFKA_SSL_KEY_CREDENTIALS and
  # KAFKA_SSL_KEYSTORE_CREDENTIALS — password FILES a PEM store holding an
  # unencrypted key does not have) via a bash preflight check, before Kafka
  # itself ever starts. See ../README.md "Two things you will otherwise get
  # wrong" for the measurement this sample already carries: a listener named
  # EXTERNAL_SSL exits the container immediately with `KAFKA_SSL_KEYSTORE_
  # FILENAME is not set`. Any name that does NOT END IN "SSL" works — the
  # protocol is chosen by KAFKA_LISTENER_SECURITY_PROTOCOL_MAP below, not by
  # the listener's own name.
  #
  # VOUCHFX_SECURE_ADVERTISED is set in the suite's `env:` block to the
  # pinned host port from `ports:` (../README.md "KAFKA_ADVERTISED_LISTENERS
  # must name the SAME pinned port `ports:` declares" — the earlier, already-
  # fixed defect this suite carries a note about; this file changes nothing
  # about that fix, it only changes WHEN these three lines take effect).
  export KAFKA_LISTENERS="PLAINTEXT://localhost:29092,CONTROLLER://localhost:29093,PLAINTEXT_HOST://0.0.0.0:9092"
  export KAFKA_ADVERTISED_LISTENERS="PLAINTEXT://localhost:29092,PLAINTEXT_HOST://${VOUCHFX_SECURE_ADVERTISED}"
  export KAFKA_LISTENER_SECURITY_PROTOCOL_MAP="CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,PLAINTEXT_HOST:SSL"

  # PEM, not JKS — see ../setup.sh's own header for why neither setup script
  # ever shells out to keytool. Concatenation order (key, then leaf
  # certificate, then CA, all three in ONE file) is measured, not assumed;
  # see ../setup.sh step 4.
  export KAFKA_SSL_KEYSTORE_TYPE="PEM"
  export KAFKA_SSL_KEYSTORE_LOCATION="/etc/kafka/secrets/broker.keystore.pem"
  export KAFKA_SSL_TRUSTSTORE_TYPE="PEM"
  export KAFKA_SSL_TRUSTSTORE_LOCATION="/etc/kafka/secrets/broker.truststore.pem"

  # `required`, not `requested`. This is what makes the broker DEMAND a
  # client identity, and it is what lets the engine's own pre-run
  # confirmation probe report AuthenticatedRoundTrip — a real authenticated
  # round trip AND a refused anonymous connection, both proved before step 1
  # of the suite ever runs.
  export KAFKA_SSL_CLIENT_AUTH="required"

  # ── AUTHENTICATION IS NOT AUTHORISATION, and this fixture has only the
  # first. No authorizer.class.name is configured, so Kafka enforces no ACLs
  # — every identity the CA issues is an unrestricted super-user. Acceptable
  # here, where the CA exists for the length of one test run and issues
  # exactly two leaves; not acceptable anywhere else. See
  # examples/security-mtls/broker-entrypoint.sh in the engine repo for the
  # fuller version of this warning.
fi
