// src/worker.js — the role=worker Kafka consumer: applies ledger-adjustments
// messages to account balances, with an audit trail.
//
// Idempotence is deliberately NOT implemented, per this sample's brief: a
// message redelivered after a crash between applying the delta and
// committing the consumer offset will be applied twice. A production
// worker would de-duplicate on a message/event id before applying — left
// out here to keep the Kafka-consumer shape legible for a demo.

import { applyAdjustment } from './db.js';

function isValidAdjustment(payload) {
  return (
    typeof payload === 'object' &&
    payload !== null &&
    typeof payload.accountId === 'string' &&
    payload.accountId.trim().length > 0 &&
    typeof payload.delta === 'number' &&
    Number.isInteger(payload.delta) &&
    payload.delta !== 0 &&
    typeof payload.reason === 'string' &&
    payload.reason.trim().length > 0
  );
}

/**
 * Builds the per-message handler for the ledger-worker consumer group on
 * the ledger-adjustments topic. A malformed message (invalid JSON, or JSON
 * missing/mistyping accountId/delta/reason) is logged and skipped — it does
 * NOT throw, so it does not crash the consumer or block later messages. A
 * genuine infrastructure failure (e.g. Postgres unreachable mid-query) is
 * intentionally left to propagate out of applyAdjustment and out of this
 * handler: kafkajs then does not commit that message's offset, so it is
 * redelivered once the consumer recovers, rather than being silently lost.
 */
export function createAdjustmentProcessor(pool) {
  return async function processAdjustment(message) {
    const offset = message.offset;
    let payload;
    try {
      payload = JSON.parse(message.value?.toString('utf8') ?? '');
    } catch {
      console.log(`[worker] skipping malformed message (invalid JSON) offset=${offset}`);
      return;
    }

    if (!isValidAdjustment(payload)) {
      console.log(
        `[worker] skipping malformed message ` +
          `(expected {accountId:string, delta:non-zero-int, reason:string}) offset=${offset}`,
      );
      return;
    }

    const { accountId, delta, reason } = payload;
    const newBalance = await applyAdjustment(pool, { accountId, delta, reason });
    if (newBalance === null) {
      console.log(`[worker] skipping adjustment for unknown account '${accountId}' offset=${offset}`);
      return;
    }

    console.log(
      `[worker] applied adjustment accountId=${accountId} delta=${delta} reason="${reason}" balance=${newBalance} offset=${offset}`,
    );
  };
}
