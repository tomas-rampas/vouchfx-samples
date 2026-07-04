# payments-java — multi-stage build (Maven runs inside the build stage; no local
# Java/Maven install is required on the host to build this image).
#
# Stage 1: compile + package with Maven on Temurin 17.
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /workspace

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
