// Counts plugin downloads on the website's own domain (ported from
// scenario-labs/blender-plugin). It runs before vercel.json forwards the request
// to GitHub Pages and never changes the response: the event is sent after the
// request continues, and any failure only loses that count. Nothing identifies
// the visitor: no IP address, no stable identifier, only the fields built below.
// A zip keeps its version only when download/latest.json names it; any other
// name, which Pages cannot serve, counts as "unknown".

export const config = { matcher: "/download/:path*", runtime: "nodejs" };
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

export default function middleware(request: Request, context: RequestContext): undefined {
  const token = env("POSTHOG_PROJECT_TOKEN");
  const described = token ? describe(request) : undefined;
  if (token && described) context.waitUntil(send(token, described.version, described.properties));
  return undefined;
}
