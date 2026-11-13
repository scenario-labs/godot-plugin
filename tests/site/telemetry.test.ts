// Run from the repository root: node --test tests/site/telemetry.test.ts (make site-test)
// The relay for opt-in usage events and feedback, against a stand-in for PostHog.
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, test } from "node:test";

import middleware, { resetRateLimits } from "../../tools/site_proxy/middleware.ts";

type Captured = { path: string; body: Record<string, unknown> };

let server: Server;
let received: Captured[] = [];
let status = 200;

const INSTALL = "0123456789abcdef0123456789abcdef";
const SUBMISSION = "fedcba9876543210fedcba9876543210";
const CONTEXT = { plugin_version: "0.3.0", godot_version: "4.7.2", os: "macOS", arch: "arm64" };

function read(request: IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let text = "";
    request.on("data", (chunk) => (text += chunk));
    request.on("end", () => resolve(text));
  });
}

before(async () => {
  server = createServer(async (request, response) => {
    received.push({ path: request.url ?? "", body: JSON.parse(await read(request)) });
    response.writeHead(status).end("{}");
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  process.env.POSTHOG_HOST = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});

after(() => {
  server.closeAllConnections();
  server.close();
});

beforeEach(() => {
  received = [];
  status = 200;
  resetRateLimits();
  process.env.POSTHOG_PROJECT_TOKEN = "phc_test";
  process.env.POSTHOG_FEEDBACK_SURVEY_ID = "survey_test";
});

async function send(path: string, body: unknown, init: { method?: string; headers?: Record<string, string> } = {}) {
  const pending: Promise<unknown>[] = [];
  const method = init.method ?? "POST";
  const request = new Request(`https://godot.scenario.com${path}`, {
    method,
    headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.7", ...init.headers },
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  });
  const response = (await middleware(request, { waitUntil: (promise) => pending.push(promise) })) as Response;
  await Promise.all(pending);
  return { status: response.status, body: (await response.json()) as Record<string, unknown> };
}

const now = () => new Date().toISOString();

test("relays allowlisted events to PostHog, tagged with the install id, plugin, context and country", async () => {
  const result = await send("/telemetry/v1/events", {
    install_id: INSTALL,
    context: CONTEXT,
    events: [
      { event: "extension_started", timestamp: now(), properties: {} },
      { event: "scenario_request", timestamp: now(), properties: { request: "generate", outcome: "error", error_kind: "quota", duration_ms: 812 } },
      { event: "generation_finished", timestamp: now(), properties: { lane: "image", state: "success", cu: 12.75 } },
    ],
  }, { headers: { "x-vercel-ip-country": "FR" } });

  assert.equal(result.status, 202);
  assert.deepEqual(result.body, { accepted: 3, dropped: 0 });
  assert.equal(received.length, 1);
  assert.equal(received[0].path, "/batch/");
  assert.equal(received[0].body.api_key, "phc_test");
  const batch = received[0].body.batch as Record<string, unknown>[];
  assert.deepEqual(batch.map((event) => event.event), ["extension_started", "scenario_request", "generation_finished"]);
  assert.ok(batch.every((event) => event.distinct_id === INSTALL));
  assert.deepEqual(batch[1].properties, {
    request: "generate", outcome: "error", error_kind: "quota", duration_ms: 812,
    plugin: "godot", ...CONTEXT, country: "FR", $process_person_profile: false, $geoip_disable: true,
  });
});

test("drops unknown events, unknown fields, bad values and stale timestamps", async () => {
  const old = new Date(Date.now() - 8 * 24 * 3600_000).toISOString();
  const result = await send("/telemetry/v1/events", {
    install_id: INSTALL,
    context: { ...CONTEXT, os: "macOS; rm -rf", user: "someone" },
    events: [
      { event: "prompt_typed", timestamp: now(), properties: { prompt: "a chest" } },
      { event: "generation_sent", timestamp: now(), properties: { lane: "image", cu: 4, prompt: "a chest", project_id: "proj_1" } },
      { event: "generation_sent", timestamp: now(), properties: { lane: "video", cu: -1 } },
      { event: "extension_started", timestamp: old },
      "not an event",
    ],
  });

  assert.deepEqual(result.body, { accepted: 2, dropped: 3 });
  const batch = received[0].body.batch as Record<string, Record<string, unknown>>[];
  assert.deepEqual(batch[0].properties, {
    lane: "image", cu: 4, plugin: "godot", plugin_version: "0.3.0", godot_version: "4.7.2", arch: "arm64",
    $process_person_profile: false, $geoip_disable: true,
  });
  assert.deepEqual(batch[1].properties.lane, undefined, "a lane outside the list is dropped");
});

test("refuses a batch without a valid install id, too many events or a body that is not JSON", async () => {
  assert.equal((await send("/telemetry/v1/events", { install_id: "user@example.com", events: [] })).status, 400);
  const many = Array.from({ length: 101 }, () => ({ event: "extension_started", timestamp: now() }));
  assert.equal((await send("/telemetry/v1/events", { install_id: INSTALL, events: many })).status, 400);
  assert.equal((await send("/telemetry/v1/events", "not json")).status, 400);
  assert.equal((await send("/telemetry/v1/events", "x".repeat(70 * 1024))).status, 400);
  assert.deepEqual(received, []);
});

test("sends nothing when no event survives", async () => {
  const result = await send("/telemetry/v1/events", { install_id: INSTALL, events: [{ event: "nope", timestamp: now() }] });

  assert.deepEqual(result.body, { accepted: 0, dropped: 1 });
  assert.deepEqual(received, []);
});

test("records feedback as a survey response and says whether PostHog took it", async () => {
  const result = await send("/telemetry/v1/feedback", {
    submission_id: SUBMISSION, install_id: INSTALL, context: CONTEXT, rating: 4, message: "Works well", email: "me@example.com",
  }, { headers: { "x-vercel-ip-country": "DE" } });

  assert.equal(result.status, 200);
  assert.equal(received[0].path, "/i/v0/e/");
  assert.equal(received[0].body.event, "survey sent");
  assert.equal(received[0].body.distinct_id, INSTALL);
  assert.deepEqual(received[0].body.properties, {
    $survey_id: "survey_test", $survey_submission_id: SUBMISSION,
    $survey_response: "4", $survey_response_1: "Works well", $survey_response_2: "me@example.com",
    plugin: "godot", ...CONTEXT, country: "DE", $process_person_profile: false, $geoip_disable: true,
  });

  status = 500;
  assert.equal((await send("/telemetry/v1/feedback", { submission_id: SUBMISSION, rating: 2, message: "" })).status, 502);
  assert.equal(received[1].body.distinct_id, SUBMISSION, "without usage data, the submission id stands in");
});

test("refuses feedback with a bad rating, address or id", async () => {
  for (const body of [
    { submission_id: SUBMISSION, rating: 6, message: "" },
    { submission_id: SUBMISSION, rating: 3.5, message: "" },
    { submission_id: SUBMISSION, rating: 3, message: "", email: "not an address" },
    { submission_id: SUBMISSION, rating: 3, message: "x".repeat(4001) },
    { submission_id: "short", rating: 3, message: "" },
    { submission_id: SUBMISSION, install_id: "nope", rating: 3, message: "" },
  ]) {
    resetRateLimits();
    assert.equal((await send("/telemetry/v1/feedback", body)).status, 400, JSON.stringify(body).slice(0, 60));
  }
  assert.deepEqual(received, []);
});

test("is unavailable without the project token or the survey id", async () => {
  delete process.env.POSTHOG_FEEDBACK_SURVEY_ID;
  assert.equal((await send("/telemetry/v1/feedback", { submission_id: SUBMISSION, rating: 3, message: "" })).status, 503);
  delete process.env.POSTHOG_PROJECT_TOKEN;
  assert.equal((await send("/telemetry/v1/events", { install_id: INSTALL, events: [] })).status, 503);
  assert.deepEqual(received, []);
});

test("answers only POST on the two endpoints", async () => {
  assert.equal((await send("/telemetry/v1/events", undefined, { method: "GET" })).status, 405);
  assert.equal((await send("/telemetry/v1/other", {})).status, 404);
  assert.equal((await send("/telemetry/", {})).status, 404);
});

test("limits each address per minute, feedback more strictly than events", async () => {
  const feedback = { submission_id: SUBMISSION, rating: 3, message: "" };
  const statuses: number[] = [];
  for (let i = 0; i < 6; i++) statuses.push((await send("/telemetry/v1/feedback", feedback)).status);
  assert.deepEqual(statuses, [200, 200, 200, 200, 200, 429]);
  const other = await send("/telemetry/v1/feedback", feedback, { headers: { "x-forwarded-for": "198.51.100.2" } });
  assert.equal(other.status, 200, "another address has its own limit");
  assert.equal((await send("/telemetry/v1/events", { install_id: INSTALL, events: [] })).status, 202);
});
