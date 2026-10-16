// Run from the repository root: node --test tests/site/middleware.test.ts (make site-test)
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, test } from "node:test";

import middleware, { config, ORIGIN } from "../../tools/site_proxy/middleware.ts";

// What the editor's HTTPRequest sends, read from Godot 4.7.2 on macOS.
const GODOT = "GodotEngine/4.7.2.stable.official (macOS)";
const BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Firefox/140.0";

type Captured = { path: string; body: Record<string, unknown> };
type Latest = { status: number; version: string };

let server: Server;
let base: string;
let received: Captured[] = [];
let respond: (request: IncomingMessage, reply: (status: number) => void) => void;
// download/latest.json served by the stand-in for GitHub Pages, one per test origin.
const latest = new Map<string, Latest>();
const latestReads = new Map<string, number>();
let origins = 0;

function read(request: IncomingMessage): Promise<string> {
  return new Promise((resolve) => {
    let text = "";
    request.on("data", (chunk) => (text += chunk));
    request.on("end", () => resolve(text));
  });
}

before(async () => {
  server = createServer(async (request, response) => {
    const path = request.url ?? "";
    const prefix = path.replace(/\/download\/latest\.json$/, "");
    if (request.method === "GET" && latest.has(prefix)) {
      latestReads.set(prefix, (latestReads.get(prefix) ?? 0) + 1);
      const file = latest.get(prefix) as Latest;
      response.writeHead(file.status, { "content-type": "application/json" }).end(JSON.stringify({ version: file.version }));
      return;
    }
    received.push({ path, body: JSON.parse(await read(request)) });
    respond(request, (status) => response.writeHead(status).end());
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  process.env.POSTHOG_HOST = base;
});

after(() => {
  server.closeAllConnections();
  server.close();
});

// Point the middleware at a new origin, so its cached version starts empty.
function publish(version: string, status = 200) {
  const prefix = `/pages-${++origins}`;
  latest.set(prefix, { status, version });
  process.env.SITE_ORIGIN = base + prefix;
  return prefix;
}

beforeEach(() => {
  received = [];
  respond = (_request, reply) => reply(200);
  process.env.POSTHOG_PROJECT_TOKEN = "phc_test";
  publish("0.2.0");
});

async function visit(path: string, headers: Record<string, string> = {}, method = "GET") {
  const pending: Promise<unknown>[] = [];
  const result = middleware(new Request(`https://godot.scenario.com${path}`, { method, headers }), {
    waitUntil: (promise) => pending.push(promise),
  });
  await Promise.all(pending);
  return result;
}

const propertiesOf = (index: number) => received[index].body.properties as Record<string, unknown>;

test("runs only for the download directory", () => {
  assert.equal(config.matcher, "/download/:path*");
  assert.equal(config.runtime, "nodejs");
});

test("records a download from the Godot editor with its plugin, versions, platform and country only", async () => {
  const result = await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT, "x-vercel-ip-country": "FR" });

  assert.equal(result, undefined);
  assert.equal(received.length, 1);
  const [{ path, body }] = received;
  assert.equal(path, "/i/v0/e/");
  assert.equal(body.api_key, "phc_test");
  assert.equal(body.event, "extension_downloaded");
  assert.match(String(body.distinct_id), /^[0-9a-f-]{36}$/);
  assert.deepEqual(body.properties, {
    plugin: "godot",
    client: "godot",
    godot_version: "4.7.2",
    godot_status: "stable",
    os: "macOS",
    country: "FR",
    $process_person_profile: false,
    $geoip_disable: true,
    extension_version: "0.2.0",
  });
});

test("reads a Godot pre-release version", async () => {
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": "GodotEngine/4.8.beta1.official (Windows)" });

  assert.equal(propertiesOf(0).godot_version, "4.8");
  assert.equal(propertiesOf(0).godot_status, "beta1");
  assert.equal(propertiesOf(0).os, "Windows");
});

test("uses a new anonymous identifier for every request", async () => {
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT });
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT });

  assert.equal(received.length, 2);
  assert.notEqual(received[0].body.distinct_id, received[1].body.distinct_id);
});

test("deploys only the middleware and its routing", () => {
  // Vercel serves any other file in the project directory instead of forwarding that path.
  assert.deepEqual(readdirSync("tools/site_proxy").sort(), ["middleware.ts", "vercel.json"]);
});

test("forwards to the same GitHub Pages address as vercel.json", () => {
  const settings = JSON.parse(readFileSync("tools/site_proxy/vercel.json", "utf8"));

  assert.equal(settings.rewrites.at(-1).destination, `${ORIGIN}/$1`);
});

test("serves the analytics script at the page's own path", () => {
  // Blocker lists (EasyPrivacy) block /_vercel/insights/script.js, not the endpoints it reports to;
  // vercel.json reaches /_vercel/ paths only through a full URL: a bare path falls through to Pages.
  const settings = JSON.parse(readFileSync("tools/site_proxy/vercel.json", "utf8"));
  const page = readFileSync("docs/site/template.html", "utf8");
  const src = /<script defer src="([^"]+)"><\/script>/.exec(page)?.[1];

  assert.deepEqual(settings.rewrites[0], {
    source: src,
    destination: "https://godot.scenario.com/_vercel/insights/script.js",
  });
});

test("records a version that is not the published one as unknown", async () => {
  await visit("/download/scenario-godot-plugin-9.9.9.zip", { "user-agent": GODOT });

  assert.equal(received.length, 1);
  assert.equal(propertiesOf(0).extension_version, "unknown");
});

test("records the version as unknown when latest.json cannot be read", async () => {
  publish("0.2.0", 503);

  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT });

  assert.equal(received.length, 1);
  assert.equal(propertiesOf(0).extension_version, "unknown");
});

test("reads latest.json once for several downloads", async () => {
  const prefix = publish("0.2.0");

  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT });
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": BROWSER });

  assert.equal(latestReads.get(prefix), 1);
  assert.deepEqual([propertiesOf(0).extension_version, propertiesOf(1).extension_version], ["0.2.0", "0.2.0"]);
});

test("reads latest.json again for an unseen version once a minute has passed", async (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: 0 });
  const prefix = publish("0.2.0");
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT });
  (latest.get(prefix) as Latest).version = "0.3.0";

  t.mock.timers.tick(30_000);
  await visit("/download/scenario-godot-plugin-0.3.0.zip", { "user-agent": GODOT });
  t.mock.timers.tick(31_000);
  await visit("/download/scenario-godot-plugin-0.3.0.zip", { "user-agent": GODOT });

  assert.equal(latestReads.get(prefix), 2);
  assert.deepEqual([propertiesOf(1).extension_version, propertiesOf(2).extension_version], ["unknown", "0.3.0"]);
});

test("records a browser download without Godot details", async () => {
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": BROWSER, "x-vercel-ip-country": "not a code" });

  assert.deepEqual(received[0].body.properties, {
    plugin: "godot",
    client: "browser",
    $process_person_profile: false,
    $geoip_disable: true,
    extension_version: "0.2.0",
  });
});

test("sorts other clients into crawlers, scripts, browsers and the rest", async () => {
  const cases: [string, string][] = [
    ["Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)", "bot"],
    ["facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)", "bot"],
    ["Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/141.0 Safari/537.36", "bot"],
    ["lychee/0.24.2", "bot"],
    ["curl/8.7.1", "tool"],
    ["python-requests/2.32.3", "tool"],
    ["", "tool"],
    ["Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36", "browser"],
    ["SomethingElse/1.0", "other"],
  ];

  for (const [agent, client] of cases) {
    received = [];
    await visit("/download/scenario-godot-plugin-0.2.0.zip", agent ? { "user-agent": agent } : {});

    assert.equal(propertiesOf(0).client, client, agent || "(no User-Agent)");
  }
});

test("ignores other download files, HEAD requests and resumed downloads", async () => {
  await visit("/download/");
  await visit("/download/latest.json");
  await visit("/download/SHA256SUMS");
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT }, "HEAD");
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": BROWSER, range: "bytes=1048576-" });

  assert.deepEqual(received, []);
});

test("counts a download that requests its range from the first byte", async () => {
  await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": BROWSER, range: "bytes=0-" });

  assert.equal(received.length, 1);
});

test("records nothing without a project token", async () => {
  delete process.env.POSTHOG_PROJECT_TOKEN;

  assert.equal(await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT }), undefined);
  assert.deepEqual(received, []);
});

test("never fails the download when the analytics service rejects the event", async () => {
  respond = (_request, reply) => reply(500);

  assert.equal(await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT }), undefined);
  assert.equal(received.length, 1);
});

test("gives up on an analytics service that does not answer", async () => {
  respond = () => {};
  const started = Date.now();

  assert.equal(await visit("/download/scenario-godot-plugin-0.2.0.zip", { "user-agent": GODOT }), undefined);
  assert.equal(received.length, 1);
  assert.ok(Date.now() - started < 5000);
});
