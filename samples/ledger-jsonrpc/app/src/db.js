// src/db.js — Postgres access for the ledger-jsonrpc sample service.
//
// One `pg.Pool` shared by whichever role (api/worker) the process is running
// as. Both roles call `ensureSchema` at startup — it is idempotent
// (`CREATE TABLE IF NOT EXISTS`), so whichever role's container reaches
// readiness first provisions the schema for the other.

import pg from 'pg';

const { Pool } = pg;

const REQUIRED_ENV_VARS = ['PGHOST', 'PGUSER', 'PGPASSWORD', 'PGDATABASE'];

/**
 * Builds a connection pool from the individual PG* environment variables
 * (PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE) — never a single connection
 * string — so the suite can wire each part independently via
 * `${conn:ledgerdb.<part>}`. Throws synchronously if a required variable is
 * missing, matching this sample's fail-fast-at-startup convention.
 */
export function createPool() {
  const missing = REQUIRED_ENV_VARS.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(`Missing required Postgres environment variable(s): ${missing.join(', ')}`);
  }

  return new Pool({
    host: process.env.PGHOST,
    port: Number(process.env.PGPORT || 5432),
    user: process.env.PGUSER,
    password: process.env.PGPASSWORD,
    database: process.env.PGDATABASE,
    max: 10,
    connectionTimeoutMillis: 5_000,
  });
}

const CREATE_ACCOUNTS_TABLE_SQL = `
  CREATE TABLE IF NOT EXISTS accounts (
    id TEXT PRIMARY KEY,
    balance INTEGER NOT NULL,
    created_at timestamptz DEFAULT now()
  )
`;

const CREATE_ADJUSTMENTS_TABLE_SQL = `
  CREATE TABLE IF NOT EXISTS adjustments (
    id SERIAL PRIMARY KEY,
    account_id TEXT NOT NULL,
    delta INTEGER NOT NULL,
    reason TEXT NOT NULL,
    applied_at timestamptz DEFAULT now()
  )
`;

/** Creates both tables if they do not already exist. Safe to call repeatedly. */
export async function ensureSchema(pool) {
  await pool.query(CREATE_ACCOUNTS_TABLE_SQL);
  await pool.query(CREATE_ADJUSTMENTS_TABLE_SQL);
}

/** Inserts a brand-new account with a zero balance. `accountId` must not already exist. */
export async function createAccount(pool, accountId) {
  await pool.query('INSERT INTO accounts (id, balance) VALUES ($1, 0)', [accountId]);
}

/** Reads one account by id, or `null` if it does not exist. */
export async function getAccount(pool, accountId) {
  const { rows } = await pool.query('SELECT id, balance FROM accounts WHERE id = $1', [accountId]);
  return rows[0] ?? null;
}

/**
 * Adds `amount` (a positive integer, validated by the caller) to an
 * account's balance. A single `UPDATE ... RETURNING` is already atomic, so
 * this needs no explicit transaction. Returns `{ balance }` on success, or
 * `null` if the account does not exist.
 */
export async function deposit(pool, accountId, amount) {
  const { rows } = await pool.query(
    'UPDATE accounts SET balance = balance + $1 WHERE id = $2 RETURNING balance',
    [amount, accountId],
  );
  return rows[0] ?? null;
}

/**
 * Withdraws `amount` (a positive integer, validated by the caller) from an
 * account's balance, enforcing "balance must never go negative" atomically
 * via `SELECT ... FOR UPDATE` inside a transaction — without the row lock, a
 * second concurrent withdrawal could read the same stale balance and both
 * pass the insufficient-funds check.
 *
 * Returns one of:
 *   { status: 'not-found' }
 *   { status: 'insufficient-funds', balance }   — balance is the CURRENT (unchanged) balance
 *   { status: 'ok', balance }                   — balance is the balance AFTER the withdrawal
 */
export async function withdraw(pool, accountId, amount) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      'SELECT balance FROM accounts WHERE id = $1 FOR UPDATE',
      [accountId],
    );
    if (rows.length === 0) {
      await client.query('ROLLBACK');
      return { status: 'not-found' };
    }

    const currentBalance = rows[0].balance;
    if (currentBalance < amount) {
      await client.query('ROLLBACK');
      return { status: 'insufficient-funds', balance: currentBalance };
    }

    const updated = await client.query(
      'UPDATE accounts SET balance = balance - $1 WHERE id = $2 RETURNING balance',
      [amount, accountId],
    );
    await client.query('COMMIT');
    return { status: 'ok', balance: updated.rows[0].balance };
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

/**
 * Applies a ledger-adjustments Kafka message: adds `delta` (may be negative)
 * to the account's balance AND inserts its audit row, in one transaction —
 * a crash between the two must never leave a balance change without its
 * audit trail, or vice versa. Returns the new balance, or `null` if the
 * account does not exist (the caller logs and skips; see worker.js).
 */
export async function applyAdjustment(pool, { accountId, delta, reason }) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      'UPDATE accounts SET balance = balance + $1 WHERE id = $2 RETURNING balance',
      [delta, accountId],
    );
    if (rows.length === 0) {
      await client.query('ROLLBACK');
      return null;
    }

    await client.query(
      'INSERT INTO adjustments (account_id, delta, reason) VALUES ($1, $2, $3)',
      [accountId, delta, reason],
    );
    await client.query('COMMIT');
    return rows[0].balance;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}
