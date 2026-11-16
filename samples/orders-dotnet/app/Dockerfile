#
# Multi-stage build for the "orders-dotnet" sample SUT — the ASP.NET Core 10 minimal API
# exercised end-to-end by ../tests/orders.e2e.yaml under vouchfx.

# The defaults are the digest-pinned .NET 10 SDK and ASP.NET runtime images (the same
# pair as scripts/dotnet-images.properties). The runners can override either.
ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0@sha256:747cbade5bfd918a175ac32f8f1d931edec2c7d0d5397a3de72eaef1ac1f66d2
ARG DOTNET_RUNTIME_IMAGE=mcr.microsoft.com/dotnet/aspnet:10.0@sha256:8af87eba5e7cdafb1514d7388be287365da97c132509e84dfe252ffd552398ca
FROM ${DOTNET_SDK_IMAGE} AS build
WORKDIR /src

# Restore first, isolated from the rest of the source, so `docker build` reuses the
# restore layer for source-only changes.
COPY Orders.Api.csproj ./
RUN dotnet restore Orders.Api.csproj

COPY . .
RUN dotnet publish Orders.Api.csproj -c Release -o /app/publish --no-restore

FROM ${DOTNET_RUNTIME_IMAGE} AS final
WORKDIR /app
COPY --from=build /app/publish .

# Run as the non-root 'app' user the aspnet:10.0 base image already ships (via the
# $APP_UID build arg/env var it defines) rather than the image's default root user.
# Orders.Api binds Kestrel to 0.0.0.0:8080, an unprivileged port, so nothing about
# dropping root affects its ability to serve traffic.
USER $APP_UID

EXPOSE 8080

ENTRYPOINT ["dotnet", "Orders.Api.dll"]
