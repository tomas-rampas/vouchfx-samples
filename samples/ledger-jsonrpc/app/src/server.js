// src/server.js — entrypoint. One image, two roles, selected by ROLE:
//
//   ROLE=api    (default) — serves GET / (health) and POST /rpc (JSON-RPC 2.0).
//   ROLE=worker            — serves GET / (health) only; runs the Kafka
//                             ledger-adjustments consumer in the background.
//
// The HTTP server starts listening immediately, before any dependency is
// verified — GET / answers 503 {"status":"starting"} until schema + Kafka
// topics are provisioned (and, for role=api, the producer is connected /
// for role=worker, the consumer is subscribed and running), then flips to
// 200. This is the exact contract the vouchfx health gate polls before
// running any suite step (see ../../orders-dotnet/README.md's identical
// convention for the .NET sample).
//
// If dependencies never become reachable within the startup budget, the
// service logs the failure and stays serving 503 forever rather than
// crash-looping — mirrors samples/inventory-python's choice (as opposed to
// samples/orders-dotnet's stop-the-host choice); either is defensible, and
// this one keeps a single long-lived process simple to reason about for
// both roles.

import http from 'node:http';
import { setTimeout as sleep } from 'node:timers/promises';
import { createPool, ensureSchema } from './db.js';
import {
  createKafkaClient,
  ensureTopics,
  createProducer,
  createAdjustmentsConsumer,
  TOPIC_LEDGER_ADJUSTMENTS,
} from './kafka.js';
import { createRpcHandler } from './api.js';
import { createAdjustmentProcessor } from './worker.js';

const ROLE = process.env.ROLE === 'worker' ? 'worker' : 'api';
const PORT = Number(process.env.PORT || 8080);
const READINESS_TIMEOUT_MS = 60_000;
const READINESS_RETRY_INTERVAL_MS = 2_000;
const MAX_BODY_BYTES = 1_000_000; // 1 MB — generous for a demo JSON-RPC payload.

function log(message) {
  console.log(`${new Date().toISOString()} [${ROLE}] ${message}`);
}

const state = { ready: false };

function sendJson(res, statusCode, body) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(payload);
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      throw new Error('request body too large');
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

/**
 * Retries schema-ensure + Kafka-topics-ensure until both succeed or the
 * startup budget elapses. Both roles ensure BOTH topics (see kafka.js) so
 * neither container depends on the other having started first.
 */
async function bootstrapReadiness({ pool, kafka }) {
  const deadline = Date.now() + READINESS_TIMEOUT_MS;
  let attempt = 0;
  while (Date.now() < deadline) {
    attempt += 1;
    try {
      await ensureSchema(pool);
      await ensureTopics(kafka);
      log(`dependencies (postgres schema + kafka topics) ready after ${attempt} attempt(s)`);
      return true;
    } catch (err) {
      log(`startup attempt ${attempt} failed (${err.message}); retrying in ${READINESS_RETRY_INTERVAL_MS}ms`);
      await sleep(READINESS_RETRY_INTERVAL_MS);
    }
  }
  log(`dependencies not reachable after ${READINESS_TIMEOUT_MS}ms; service stays not-ready`);
  return false;
}

async function main() {
  const pool = createPool();
  const kafka = createKafkaClient(`ledger-jsonrpc-${ROLE}`);

  const deps = { pool, producer: null };
  let rpcHandler = null;
  let consumer = null;

  const server = http.createServer(async (req, res) => {
    if (req.method === 'GET' && req.url === '/') {
      if (!state.ready) {
        sendJson(res, 503, { status: 'starting' });
      } else {
        sendJson(res, 200, { status: 'ready', role: ROLE });
      }
      return;
    }

    if (ROLE === 'api' && req.method === 'POST' && req.url === '/rpc') {
      if (!state.ready || !rpcHandler) {
        sendJson(res, 503, { status: 'starting' });
        return;
      }
      let rawBody;
      try {
        rawBody = await readBody(req);
      } catch (err) {
        sendJson(res, 413, { error: err.message });
        return;
      }
      await rpcHandler(req, res, rawBody);
      return;
    }

    sendJson(res, 404, { error: 'not found' });
  });

  server.listen(PORT, '0.0.0.0', () => {
    log(`listening on 0.0.0.0:${PORT} (role=${ROLE})`);
  });

  const dependenciesReady = await bootstrapReadiness({ pool, kafka });
  if (!dependenciesReady) {
    return;
  }

  if (ROLE === 'api') {
    deps.producer = await createProducer(kafka);
    rpcHandler = createRpcHandler(deps);
    log('producer connected; ready to serve /rpc');
  } else {
    consumer = createAdjustmentsConsumer(kafka);
    consumer.on(consumer.events.CRASH, ({ payload }) => {
      log(`consumer crashed: ${payload.error?.message ?? payload.error}`);
    });
    await consumer.connect();
    await consumer.subscribe({ topic: TOPIC_LEDGER_ADJUSTMENTS, fromBeginning: false });

    const processAdjustment = createAdjustmentProcessor(pool);
    await consumer.run({
      eachMessage: async ({ message }) => processAdjustment(message),
    });
    log(`consumer running (group=ledger-worker, topic=${TOPIC_LEDGER_ADJUSTMENTS})`);
  }

  state.ready = true;

  const shutdown = async (signal) => {
    log(`received ${signal}, shutting down`);
    server.close();
    try {
      if (consumer) await consumer.disconnect();
    } catch {
      /* best-effort */
    }
    try {
      if (deps.producer) await deps.producer.disconnect();
    } catch {
      /* best-effort */
    }
    try {
      await pool.end();
    } catch {
      /* best-effort */
    }
    process.exit(0);
  };
  process.once('SIGTERM', () => void shutdown('SIGTERM'));
  process.once('SIGINT', () => void shutdown('SIGINT'));
}

main().catch((err) => {
  console.error(`${new Date().toISOString()} [${ROLE}] fatal startup error: ${err.stack ?? err}`);
  process.exit(1);
});
