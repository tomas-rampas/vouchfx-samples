# app/Dockerfile — ledger-jsonrpc sample service image.
#
# One image, two roles: the same src/server.js entrypoint serves either the
# hand-rolled JSON-RPC 2.0 API (ROLE=api, default) or the Kafka
# ledger-adjustments worker (ROLE=worker), selected purely by the ROLE
# environment variable at `docker run` / suite `environment.services.*`
# time — see src/server.js. Plain JavaScript, no build step (Node 22 runs
# the ESM source directly), matching this repo's runnable-source ethos.
#
# Built as the vouchfx system under test, non-root, with the npm-managed
# dependency layer separated from the (much more frequently changing)
# application source so `docker build` reuses it across source-only changes.

FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src

RUN addgroup -S ledger && adduser -S ledger -G ledger
USER ledger

EXPOSE 8080

CMD ["node", "src/server.js"]
