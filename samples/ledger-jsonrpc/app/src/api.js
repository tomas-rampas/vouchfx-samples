// src/api.js — JSON-RPC 2.0, implemented by hand for role=api.
//
// Deliberately not delegated to a JSON-RPC library: this sample exists to
// show the protocol's rules explicitly (request-shape validation, the
// standard error codes, notification semantics) rather than hide them
// behind a dependency. Batch requests (a top-level JSON array) are NOT
// supported — a single-request-object body is all this sample needs — and
// are rejected the same way any other malformed top-level shape is.
//
// HTTP-transport convention used here: every well-formed JSON-RPC exchange
// (success or JSON-RPC-level error) answers HTTP 200 with a JSON-RPC
// response envelope in the body — the transport itself succeeded, so only
// the JSON-RPC "error" member carries the failure. A NOTIFICATION (id is
// null or absent) instead answers HTTP 204 with an empty body, including
// when the notification's own method fails — per spec, notifications are
// never confirmed. A body that isn't valid JSON at all answers 200 with a
// Parse error envelope (id: null) — the one case JSON-RPC 2.0 requires a
// response for even when the id could not be determined.

import crypto from 'node:crypto';
import * as db from './db.js';
import { TOPIC_LEDGER_EVENTS } from './kafka.js';

const JSONRPC_VERSION = '2.0';

// --- JSON-RPC 2.0 standard error codes (https://www.jsonrpc.org/specification#error_object) ---
const PARSE_ERROR = -32700;
const INVALID_REQUEST = -32600;
const METHOD_NOT_FOUND = -32601;
const INVALID_PARAMS = -32602;
const INTERNAL_ERROR = -32603; // not explicitly requested, but standard — the safety net below.

// --- Domain-specific errors, from the -32000..-32099 range the spec reserves for implementations ---
const INSUFFICIENT_FUNDS = -32001;
const ACCOUNT_NOT_FOUND = -32004;

function rpcResult(id, result) {
  return { jsonrpc: JSONRPC_VERSION, id, result };
}

function rpcError(id, code, message, data) {
  const error = data === undefined ? { code, message } : { code, message, data };
  return { jsonrpc: JSONRPC_VERSION, id, error };
}

function generateAccountId() {
  return `acc-${crypto.randomBytes(4).toString('hex')}`;
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isPositiveInteger(value) {
  return typeof value === 'number' && Number.isInteger(value) && value > 0;
}

function isPlainParamsObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Publishes one ledger-events message. Failures are logged and swallowed —
 * mirroring samples/orders-dotnet's "an event-pipeline hiccup must not fail
 * an otherwise successful mutation" design choice — because by the time
 * this is called the Postgres write has already committed; only the
 * best-effort event notification is at risk.
 */
async function publishEvent(producer, event) {
  try {
    await producer.send({
      topic: TOPIC_LEDGER_EVENTS,
      messages: [{ key: event.accountId, value: JSON.stringify(event) }],
    });
  } catch (err) {
    console.log(`[api] failed to publish ${event.type} for ${event.accountId}: ${err.message}`);
  }
}

// --- JSON-RPC methods -------------------------------------------------------
// Each handler receives the request's (unvalidated) `params` and the shared
// `deps` (pool + producer), and returns either { result } or
// { error: { code, message, data? } }. A handler never throws for a
// domain-level failure — only a genuine unexpected exception (e.g. the
// database connection drops mid-query) escapes, and is turned into
// INTERNAL_ERROR by dispatch()'s try/catch below.

async function handleCreateAccount(params, { pool, producer }) {
  if (!isPlainParamsObject(params)) {
    return { error: { code: INVALID_PARAMS, message: "'params' must be an object" } };
  }
  const { ownerName } = params;
  if (!isNonEmptyString(ownerName)) {
    return { error: { code: INVALID_PARAMS, message: "'ownerName' must be a non-empty string" } };
  }

  const accountId = generateAccountId();
  await db.createAccount(pool, accountId);

  await publishEvent(producer, {
    type: 'account.created',
    accountId,
    balance: 0,
    at: new Date().toISOString(),
  });

  return { result: { accountId } };
}

async function handleDeposit(params, { pool, producer }) {
  if (!isPlainParamsObject(params)) {
    return { error: { code: INVALID_PARAMS, message: "'params' must be an object" } };
  }
  const { accountId, amount } = params;
  if (!isNonEmptyString(accountId)) {
    return { error: { code: INVALID_PARAMS, message: "'accountId' must be a non-empty string" } };
  }
  if (!isPositiveInteger(amount)) {
    return { error: { code: INVALID_PARAMS, message: "'amount' must be a positive integer" } };
  }

  const updated = await db.deposit(pool, accountId, amount);
  if (updated === null) {
    return { error: { code: ACCOUNT_NOT_FOUND, message: `account '${accountId}' not found` } };
  }

  await publishEvent(producer, {
    type: 'funds.deposited',
    accountId,
    amount,
    balance: updated.balance,
    at: new Date().toISOString(),
  });

  return { result: { accountId, balance: updated.balance } };
}

async function handleWithdraw(params, { pool, producer }) {
  if (!isPlainParamsObject(params)) {
    return { error: { code: INVALID_PARAMS, message: "'params' must be an object" } };
  }
  const { accountId, amount } = params;
  if (!isNonEmptyString(accountId)) {
    return { error: { code: INVALID_PARAMS, message: "'accountId' must be a non-empty string" } };
  }
  if (!isPositiveInteger(amount)) {
    return { error: { code: INVALID_PARAMS, message: "'amount' must be a positive integer" } };
  }

  const outcome = await db.withdraw(pool, accountId, amount);
  if (outcome.status === 'not-found') {
    return { error: { code: ACCOUNT_NOT_FOUND, message: `account '${accountId}' not found` } };
  }
  if (outcome.status === 'insufficient-funds') {
    return {
      error: {
        code: INSUFFICIENT_FUNDS,
        message: 'insufficient funds',
        data: { balance: outcome.balance },
      },
    };
  }

  await publishEvent(producer, {
    type: 'funds.withdrawn',
    accountId,
    amount,
    balance: outcome.balance,
    at: new Date().toISOString(),
  });

  return { result: { balance: outcome.balance } };
}

async function handleGetAccount(params, { pool }) {
  if (!isPlainParamsObject(params)) {
    return { error: { code: INVALID_PARAMS, message: "'params' must be an object" } };
  }
  const { accountId } = params;
  if (!isNonEmptyString(accountId)) {
    return { error: { code: INVALID_PARAMS, message: "'accountId' must be a non-empty string" } };
  }

  const account = await db.getAccount(pool, accountId);
  if (account === null) {
    return { error: { code: ACCOUNT_NOT_FOUND, message: `account '${accountId}' not found` } };
  }

  return { result: { accountId: account.id, balance: account.balance } };
}

const METHODS = {
  createAccount: handleCreateAccount,
  deposit: handleDeposit,
  withdraw: handleWithdraw,
  getAccount: handleGetAccount,
};

/**
 * Dispatches one already-JSON-parsed value as a JSON-RPC request. Returns
 * either a response envelope to serialise back to the caller, or `null` for
 * a notification (id is null/absent) — the caller answers 204 with no body
 * in that case, per this service's notification convention (see file
 * header). Malformed top-level shapes (not an object, wrong/missing
 * "jsonrpc", non-string "method", or a batch array) are Invalid Request —
 * unless their id is also null/absent, in which case they get the same
 * silent-204 notification treatment as a well-formed notification.
 */
async function dispatch(request, deps) {
  const isValidEnvelope =
    isPlainParamsObject(request) &&
    request.jsonrpc === JSONRPC_VERSION &&
    typeof request.method === 'string';

  const id = isPlainParamsObject(request) && 'id' in request ? request.id : null;
  const isNotification = id === null || id === undefined;

  if (!isValidEnvelope) {
    return isNotification ? null : rpcError(id, INVALID_REQUEST, 'Invalid Request');
  }

  const { method, params } = request;
  const handler = METHODS[method];
  if (!handler) {
    return isNotification ? null : rpcError(id, METHOD_NOT_FOUND, `method '${method}' not found`);
  }

  let outcome;
  try {
    outcome = await handler(params, deps);
  } catch (err) {
    console.log(`[api] unhandled error in method '${method}': ${err.stack ?? err}`);
    return isNotification ? null : rpcError(id, INTERNAL_ERROR, 'Internal error');
  }

  if (isNotification) {
    return null;
  }
  return 'error' in outcome
    ? rpcError(id, outcome.error.code, outcome.error.message, outcome.error.data)
    : rpcResult(id, outcome.result);
}

function sendJson(res, statusCode, body) {
  const payload = JSON.stringify(body);
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(payload);
}

/**
 * Builds the POST /rpc handler for role=api. `deps` bundles the long-lived
 * Postgres pool and Kafka producer created once at startup.
 */
export function createRpcHandler(deps) {
  return async function handleRpc(req, res, rawBody) {
    let parsed;
    try {
      parsed = JSON.parse(rawBody);
    } catch {
      sendJson(res, 200, rpcError(null, PARSE_ERROR, 'Parse error'));
      console.log('[api] rpc parse error');
      return;
    }

    const response = await dispatch(parsed, deps);

    if (response === null) {
      res.writeHead(204);
      res.end();
      console.log(`[api] rpc notification method=${isPlainParamsObject(parsed) ? parsed.method : '?'}`);
      return;
    }

    sendJson(res, 200, response);
    const methodName = isPlainParamsObject(parsed) ? parsed.method : '?';
    const outcomeLabel = response.error ? `error=${response.error.code}` : 'ok';
    console.log(`[api] rpc method=${methodName} id=${JSON.stringify(response.id)} ${outcomeLabel}`);
  };
}
