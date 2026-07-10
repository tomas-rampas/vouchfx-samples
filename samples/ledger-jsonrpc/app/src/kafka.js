// src/kafka.js — Kafka access for the ledger-jsonrpc sample service.
//
// Both topics this service uses:
//   ledger-events       — published by role=api on every successful mutation.
//   ledger-adjustments  — consumed by role=worker (group "ledger-worker").
//
// Both roles ensure BOTH topics exist at startup (see server.js), so
// whichever container becomes ready first does not leave the other's topic
// missing — this de-risks container start ordering, which vouchfx's
// topology does not guarantee.

import { Kafka, logLevel } from 'kafkajs';

export const TOPIC_LEDGER_EVENTS = 'ledger-events';
export const TOPIC_LEDGER_ADJUSTMENTS = 'ledger-adjustments';
const TOPICS = [TOPIC_LEDGER_EVENTS, TOPIC_LEDGER_ADJUSTMENTS];

/**
 * Builds a Kafka client from the comma-separated KAFKA_BROKERS environment
 * variable (e.g. "kafka:9092" or "kafka:9092,kafka2:9092"). Throws
 * synchronously if the variable is missing.
 */
export function createKafkaClient(clientId) {
  const brokersEnv = process.env.KAFKA_BROKERS;
  if (!brokersEnv) {
    throw new Error('Missing required environment variable: KAFKA_BROKERS');
  }
  const brokers = brokersEnv
    .split(',')
    .map((broker) => broker.trim())
    .filter(Boolean);

  return new Kafka({
    clientId,
    brokers,
    // kafkajs' own logger is noisy at the default level (one line per
    // connection-workflow frame); this service logs its own one-liners for
    // every rpc call / consumed message instead — see api.js/worker.js.
    logLevel: logLevel.NOTHING,
    retry: { retries: 5 },
  });
}

/**
 * Creates any of TOPICS that do not already exist. Used as this service's
 * "Kafka is reachable" readiness probe as well as for real topic
 * provisioning — a failed admin connection throws, which the caller's
 * retry loop treats the same as any other not-yet-ready dependency.
 */
export async function ensureTopics(kafka) {
  const admin = kafka.admin();
  await admin.connect();
  try {
    const existing = await admin.listTopics();
    const missing = TOPICS.filter((topic) => !existing.includes(topic));
    if (missing.length > 0) {
      await admin.createTopics({
        topics: missing.map((topic) => ({ topic, numPartitions: 1, replicationFactor: 1 })),
        waitForLeaders: true,
      });
    }
  } finally {
    await admin.disconnect();
  }
}

export async function createProducer(kafka) {
  const producer = kafka.producer();
  await producer.connect();
  return producer;
}

export function createAdjustmentsConsumer(kafka, groupId = 'ledger-worker') {
  return kafka.consumer({ groupId });
}
