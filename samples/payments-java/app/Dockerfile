# payments-java — multi-stage build (Maven runs inside the build stage; no local
# Java/Maven install is required on the host to build this image).
#
# Stage 1: compile + package with Maven on Temurin 17.
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /workspace

# ── Optional extra TLS trust anchors (opt-in; imports nothing by default) ─────
# On a network that terminates TLS at an inspecting proxy, that proxy presents
# its own CA and every Maven download fails with
#   PKIX path building failed ... unable to find valid certification path
# even though the proxy itself is reachable. Drop one or more PEM-encoded *.crt
# files into this directory's certs/ and each is added to the build stage's JDK
# truststore before Maven runs. certs/ ships with only a .gitkeep, so a default
# build imports nothing and is byte-for-byte the build it always was.
#
# Supply EITHER a ready-made PKCS12 truststore as certs/truststore.p12 (what a
# corporate or CI environment normally hands you, and the option to reach for
# first), OR individual PEM *.crt anchors, which are added to a copy of this
# JDK's cacerts. Whichever is present, Maven is pointed at the result below.
#
# Three traps, each of which makes an import look like it worked while Maven
# keeps failing PKIX — all three cost real debugging time, so they are recorded:
#
#  1. ONE CA PER PEM FILE. `keytool -importcert` reads only the FIRST
#     certificate in a PEM file and ignores every one after it, so a
#     concatenated 150-certificate ca-bundle.crt prints "Certificate was added
#     to keystore" while trusting only its first anchor. Split bundles first.
#
#  2. IMPORTING INTO THE JDK's OWN cacerts IS NOT ENOUGH. `keytool -cacerts`
#     reports success and `keytool -list` shows the alias, yet Maven still fails
#     PKIX. The store must be handed to the JVM explicitly, which is what the
#     ENV below does.
#
#  3. ONE LEAF CA MAY NOT BE THE WHOLE CHAIN. An inspecting proxy can present a
#     chain needing intermediates beyond its own root, so importing just that
#     root still fails. If single anchors do not work, supply the full
#     truststore your platform provides (option one above) rather than guessing
#     which anchor is missing.
#
# ~/.mavenrc is NOT a usable hook here: Maven 3.9's launcher does not source it.
ARG TRUSTSTORE_PASSWORD=changeit
COPY certs/ /tmp/extra-certs/
RUN set -eu; \
    if [ -f /tmp/extra-certs/truststore.p12 ]; then \
      echo "Using supplied PKCS12 truststore: certs/truststore.p12"; \
      cp /tmp/extra-certs/truststore.p12 /opt/maven-truststore.p12; \
    else \
      cp "$JAVA_HOME/lib/security/cacerts" /opt/maven-truststore.p12; \
    fi; \
    for cert in /tmp/extra-certs/*.crt; do \
      [ -e "$cert" ] || continue; \
      echo "Importing extra TLS trust anchor: $(basename "$cert")"; \
      keytool -importcert -noprompt -keystore /opt/maven-truststore.p12 \
              -storepass "$TRUSTSTORE_PASSWORD" \
              -alias "extra-$(basename "$cert" .crt)" -file "$cert"; \
    done

# Always points at a valid store: with an empty certs/ this is a straight copy of
# the JDK's own cacerts, so the default build trusts exactly what it always did.
ENV MAVEN_OPTS="-Djavax.net.ssl.trustStore=/opt/maven-truststore.p12 -Djavax.net.ssl.trustStorePassword=${TRUSTSTORE_PASSWORD}"

# Resolve dependencies as a separate, cacheable layer before copying source, so an
# edit-only source change does not re-download the world.
COPY pom.xml .
RUN mvn -B -q dependency:go-offline || true

COPY src ./src
RUN mvn -B -q -DskipTests package

# Stage 2: minimal runtime image -- JRE only, no build tooling.
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /workspace/target/payments.jar ./payments.jar

# Non-root, mirroring the inventory-python sample's pattern: a dedicated unprivileged
# user rather than the image's default root user. Spring Boot binds to 8080, an
# unprivileged port, so dropping root does not affect the app's ability to serve traffic.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser \
    && chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "/app/payments.jar"]
