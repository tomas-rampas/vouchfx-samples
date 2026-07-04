# syntax=docker/dockerfile:1
#
# Multi-stage build for the "orders-dotnet" sample SUT — the ASP.NET Core 8 minimal API
# exercised end-to-end by ../tests/orders.e2e.yaml under vouchfx.

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Restore first, isolated from the rest of the source, so `docker build` reuses the
# restore layer for source-only changes.
COPY Orders.Api.csproj ./
RUN dotnet restore Orders.Api.csproj

COPY . .
RUN dotnet publish Orders.Api.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=build /app/publish .

# Run as the non-root 'app' user the aspnet:8.0 base image already ships (via the
# $APP_UID build arg/env var it defines) rather than the image's default root user.
# Orders.Api binds Kestrel to 0.0.0.0:8080, an unprivileged port, so nothing about
# dropping root affects its ability to serve traffic.
USER $APP_UID

EXPOSE 8080

ENTRYPOINT ["dotnet", "Orders.Api.dll"]
