// Counts plugin downloads on the website's own domain (ported from
// scenario-labs/blender-plugin). It runs before vercel.json forwards the request
// to GitHub Pages and never changes the response: the event is sent after the
// request continues, and any failure only loses that count. Nothing identifies
// the visitor: no IP address, no stable identifier, only the fields built below.
// A zip keeps its version only when download/latest.json names it; any other
// name, which Pages cannot serve, counts as "unknown".
//
// It also relays what the plugin sends under /telemetry/v1/ when the person
// opted in (usage events) or pressed Send (feedback): those requests get their
// own answer and never reach Pages. Only allowlisted events and fields pass,
// and the PostHog token stays here, in the project's environment.

export const config = { matcher: ["/download/:path*", "/telemetry/:path*"], runtime: "nodejs" };
// The GitHub Pages copy of the site: vercel.json forwards every request there.
export const ORIGIN = "https://scenario-labs.github.io/godot-plugin";

interface RequestContext {
  waitUntil(promise: Promise<unknown>): void;
}

// The editor (Asset Library, HTTPRequest) sends "GodotEngine/4.7.2.stable.official (macOS)".
const GODOT = /^GodotEngine\/(\d+\.\d+(?:\.\d+)?)\.([a-z]+[0-9]*)[^ ]* \(([^)]+)\)/;
// Crawlers, link checkers and previews, matched before browsers because many
// announce themselves as "Mozilla/5.0 (compatible; ...bot...)".
const BOT = /bot|crawl|spider|slurp|facebookexternalhit|preview|lychee|linkcheck|headless|lighthouse/i;
// Scripts and command-line tools; an empty User-Agent counts as one too.
const TOOL = /^(curl|wget|python|go-http-client|node|undici|axios|okhttp|java|libwww|httpie|aiohttp)|powershell/i;
const ARCHIVE = /^\/download\/scenario-godot-plugin-(\d+\.\d+\.\d+)\.zip$/;
const TIMEOUT_MS = 2000;
// The published version is cached; an unseen version rereads at most once a minute.
const LATEST_TTL_MS = 5 * 60_000;
const LATEST_RETRY_MS = 60_000;
const published = new Map<string, { version: string; at: number }>();

// Read through globalThis: Vercel type-checks this file without Node's types.
function env(name: string): string | undefined {
  return (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env?.[name];
}

/** Who made a request that is not the Godot editor: a crawler, a script, a browser or something else. */
function classify(agent: string): string {
  if (BOT.test(agent)) return "bot";
  if (!agent || TOOL.test(agent)) return "tool";
  if (agent.startsWith("Mozilla/")) return "browser";
  return "other";
}

function describe(request: Request): { version: string; properties: Record<string, unknown> } | undefined {
  if (request.method !== "GET") return undefined;
  // A resumed download already counted when it started.
  const range = request.headers.get("range");
  if (range && !range.startsWith("bytes=0-")) return undefined;
  const archive = ARCHIVE.exec(new URL(request.url).pathname);
  if (!archive) return undefined;

  // The PostHog project is shared with other Scenario plugins.
  const properties: Record<string, unknown> = { plugin: "godot" };
  const agent = request.headers.get("user-agent") ?? "";
  const godot = GODOT.exec(agent);
  properties.client = godot ? "godot" : classify(agent);
  if (godot) {
    properties.godot_version = godot[1];
    properties.godot_status = godot[2];
    properties.os = godot[3];
  }
  const country = request.headers.get("x-vercel-ip-country") ?? "";
  if (/^[A-Z]{2}$/.test(country)) properties.country = country;
  // Anonymous events: no person profile, and no location from the proxy's own address.
  properties.$process_person_profile = false;
  properties.$geoip_disable = true;
  return { version: archive[1], properties };
}

async function isPublished(version: string): Promise<boolean> {
  // Read latest.json from Pages directly: through this site it would pass this middleware again.
  const origin = env("SITE_ORIGIN") || ORIGIN;
  const now = Date.now();
  const cached = published.get(origin);
  const age = cached ? now - cached.at : Infinity;
  if (cached && age < LATEST_TTL_MS && (cached.version === version || age < LATEST_RETRY_MS)) {
    return cached.version === version;
  }
  let latest = cached?.version ?? "";
  try {
    const response = await fetch(`${origin}/download/latest.json`, { signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (response.ok) latest = String(((await response.json()) as { version?: unknown }).version ?? "");
  } catch {
    // Keep the last version read; an unreadable file only makes this count unknown.
  }
  published.set(origin, { version: latest, at: now });
  return latest === version;
}

async function send(token: string, version: string, properties: Record<string, unknown>): Promise<void> {
  properties.extension_version = (await isPublished(version)) ? version : "unknown";
  const host = env("POSTHOG_HOST") || "https://us.i.posthog.com";
  try {
    const response = await fetch(`${host}/i/v0/e/`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ api_key: token, event: "extension_downloaded", distinct_id: crypto.randomUUID(), properties }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!response.ok) console.warn(`Download count not recorded: HTTP ${response.status}`);
  } catch (error) {
    console.warn(`Download count not recorded: ${(error as Error).name}`);
  }
}

// --- Telemetry relay ----------------------------------------------------------
// The request shapes are a contract with addons/scenario/core/usage.gd and
// feedback.gd: change both together.

type Json = Record<string, unknown>;
type Endpoint = "events" | "feedback";
type Check = (value: unknown) => boolean;

const MAX_BODY = 64 * 1024;
const MAX_EVENTS = 100;
// Per instance and per client address, for a minute; a Vercel Firewall rule is the durable limit.
const RATE_LIMITS: Record<Endpoint, number> = { events: 60, feedback: 5 };
const RATE_WINDOW_MS = 60_000;
const MAX_CLIENTS = 10_000;
const MAX_EVENT_AGE_MS = 7 * 24 * 3600_000;
const MAX_EVENT_AHEAD_MS = 3600_000;
const HEX_ID = /^[0-9a-f]{32}$/;
const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$/;

const oneOf = (...values: string[]): Check => (value) => typeof value === "string" && values.includes(value);
const count = (max: number): Check => (value) => Number.isInteger(value) && (value as number) >= 0 && (value as number) <= max;
const amount: Check = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1_000_000;
const text = (pattern: RegExp): Check => (value) => typeof value === "string" && pattern.test(value);

const LANES = oneOf("image", "model3d", "material", "skybox", "sound", "workflow");
const ERROR_KINDS = oneOf("auth", "forbidden", "quota", "moderated", "rate_limit", "not_found", "invalid", "transport",
  "timeout", "http_5xx", "protocol", "local", "estimate_job", "scenario");
// Each event the plugin may send, with the only properties kept and their checks.
export const EVENTS: Record<string, Record<string, Check>> = {
  extension_started: {},
  connected: { method: oneOf("sign_in", "api_key", "environment") },
  scenario_request: {
    request: oneOf("price_check", "generate", "cancel", "import", "upload_reference", "recommend", "list_teams",
      "list_jobs", "check_key", "model_settings", "list_workflows", "list_project_models", "browse_library"),
    outcome: oneOf("ok", "error"),
    error_kind: ERROR_KINDS,
    duration_ms: count(3_600_000),
  },
  generation_sent: { lane: LANES, cu: amount },
  generation_finished: { lane: LANES, state: oneOf("success", "failed", "blocked", "canceled", "rejected", "dismissed"), cu: amount },
};
// Sent with every batch and feedback: where the plugin runs, never who uses it.
const CONTEXT: Record<string, Check> = {
  plugin_version: text(/^\d+\.\d+\.\d+$/),
  godot_version: text(/^\d+\.\d+(\.\d+)?$/),
  os: text(/^[A-Za-z][A-Za-z0-9 ]{0,23}$/),
  arch: text(/^[a-z0-9_]{1,16}$/),
};

const rateWindows = new Map<string, { start: number; count: number }>();

const isObject = (value: unknown): value is Json => typeof value === "object" && value !== null && !Array.isArray(value);

function reply(status: number, body: Json = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

/** The fields of value that pass their checks; anything else is dropped. */
function pick(value: unknown, checks: Record<string, Check>): Json {
  const kept: Json = {};
  if (!isObject(value)) return kept;
  for (const [name, check] of Object.entries(checks)) {
    if (Object.hasOwn(value, name) && check(value[name])) kept[name] = value[name];
  }
  return kept;
}

/** The client's address, kept only in memory as the rate-limit key. */
function clientKey(request: Request): string {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return forwarded || request.headers.get("x-real-ip") || "unknown";
}

function allowed(endpoint: Endpoint, request: Request, now: number): boolean {
  const key = `${endpoint} ${clientKey(request)}`;
  const entry = rateWindows.get(key);
  if (entry && now - entry.start < RATE_WINDOW_MS) {
    entry.count += 1;
    return entry.count <= RATE_LIMITS[endpoint];
  }
  if (!entry && rateWindows.size >= MAX_CLIENTS) {
    for (const [old, window] of rateWindows) if (now - window.start >= RATE_WINDOW_MS) rateWindows.delete(old);
    if (rateWindows.size >= MAX_CLIENTS) return false;
  }
  rateWindows.set(key, { start: now, count: 1 });
  return true;
}

/** Forgets every rate-limit window, for tests. */
export function resetRateLimits(): void {
  rateWindows.clear();
}

async function readJson(request: Request): Promise<Json | undefined> {
  if (Number(request.headers.get("content-length") ?? "0") > MAX_BODY) return undefined;
  const body = await request.text();
  if (body.length > MAX_BODY) return undefined;
  try {
    const parsed: unknown = JSON.parse(body);
    return isObject(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

/** What every relayed event carries: the plugin, where it runs, a coarse country, and no person or location from this relay. */
function common(request: Request, context: unknown): Json {
  const properties: Json = { plugin: "godot", ...pick(context, CONTEXT) };
  const country = request.headers.get("x-vercel-ip-country") ?? "";
  if (/^[A-Z]{2}$/.test(country)) properties.country = country;
  properties.$process_person_profile = false;
  properties.$geoip_disable = true;
  return properties;
}

async function forward(path: string, body: Json): Promise<boolean> {
  const host = env("POSTHOG_HOST") || "https://us.i.posthog.com";
  try {
    const response = await fetch(`${host}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!response.ok) console.warn(`Telemetry not recorded: HTTP ${response.status}`);
    return response.ok;
  } catch (error) {
    console.warn(`Telemetry not recorded: ${(error as Error).name}`);
    return false;
  }
}

function relayEvents(request: Request, body: Json, token: string, context: RequestContext): Response {
  const { install_id: installId, events } = body;
  if (typeof installId !== "string" || !HEX_ID.test(installId) || !Array.isArray(events) || events.length > MAX_EVENTS) {
    return reply(400, { error: "bad_request" });
  }
  const shared = common(request, body.context);
  const now = Date.now();
  const batch: Json[] = [];
  for (const event of events) {
    if (!isObject(event) || typeof event.event !== "string" || !Object.hasOwn(EVENTS, event.event)) continue;
    const at = typeof event.timestamp === "string" ? Date.parse(event.timestamp) : NaN;
    if (!(at >= now - MAX_EVENT_AGE_MS && at <= now + MAX_EVENT_AHEAD_MS)) continue;
    const properties = { ...pick(event.properties, EVENTS[event.event]), ...shared };
    batch.push({ event: event.event, distinct_id: installId, timestamp: new Date(at).toISOString(), properties });
  }
  if (batch.length > 0) context.waitUntil(forward("/batch/", { api_key: token, batch }));
  return reply(202, { accepted: batch.length, dropped: events.length - batch.length });
}

async function relayFeedback(request: Request, body: Json, token: string): Promise<Response> {
  const surveyId = env("POSTHOG_FEEDBACK_SURVEY_ID");
  if (!surveyId) return reply(503, { error: "unavailable" });
  const { submission_id: submissionId, rating, message, email } = body;
  // An address is never tied to the install ID of the usage data.
  const installId = typeof email === "string" && email !== "" ? undefined : body.install_id;
  const valid =
    typeof submissionId === "string" && HEX_ID.test(submissionId) &&
    (installId === undefined || (typeof installId === "string" && HEX_ID.test(installId))) &&
    Number.isInteger(rating) && (rating as number) >= 1 && (rating as number) <= 5 &&
    typeof message === "string" && message.length <= 4000 &&
    (email === undefined || email === "" || (typeof email === "string" && email.length <= 254 && EMAIL.test(email)));
  if (!valid) return reply(400, { error: "bad_request" });
  // The survey's questions, in order: the rating, the message, the reply address.
  const properties: Json = {
    $survey_id: surveyId,
    $survey_submission_id: submissionId,
    $survey_response: String(rating),
    $survey_response_1: message,
    $survey_response_2: typeof email === "string" ? email : "",
    ...common(request, body.context),
  };
  const recorded = await forward("/i/v0/e/", {
    api_key: token,
    event: "survey sent",
    distinct_id: typeof installId === "string" ? installId : submissionId,
    properties,
  });
  return recorded ? reply(200, { recorded: true }) : reply(502, { error: "not_recorded" });
}

async function telemetry(request: Request, context: RequestContext): Promise<Response> {
  const endpoint = new URL(request.url).pathname.replace(/^\/telemetry\/v1\//, "");
  if (endpoint !== "events" && endpoint !== "feedback") return reply(404, { error: "not_found" });
  if (request.method !== "POST") return reply(405, { error: "method_not_allowed" });
  if (!allowed(endpoint, request, Date.now())) return reply(429, { error: "rate_limited" });
  const token = env("POSTHOG_PROJECT_TOKEN");
  if (!token) return reply(503, { error: "unavailable" });
  const body = await readJson(request);
  if (!body) return reply(400, { error: "bad_request" });
  return endpoint === "events" ? relayEvents(request, body, token, context) : relayFeedback(request, body, token);
}

export default function middleware(request: Request, context: RequestContext): Promise<Response> | undefined {
  if (new URL(request.url).pathname.startsWith("/telemetry/")) return telemetry(request, context);
  const token = env("POSTHOG_PROJECT_TOKEN");
  const described = token ? describe(request) : undefined;
  if (token && described) context.waitUntil(send(token, described.version, described.properties));
  return undefined;
}
