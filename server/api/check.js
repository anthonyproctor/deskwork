// POST /api/check  { id, v, os }  ->  { latest, url }
import { parse, day, keys, release } from "../lib/check.js";
import { redis } from "../lib/redis.js";

const REPO = "anthonyproctor/project-coldfall";
const FALLBACK = { latest: "v0.0.0", url: `https://github.com/${REPO}/releases/latest` };

// The latest release, fetched from GitHub at most once an hour per instance,
// so a busy day does not run into GitHub's rate limit.
let cached = null;
async function latest() {
  if (cached && Date.now() - cached.at < 3600_000) return cached.value;
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { "user-agent": "coldfall-updates", accept: "application/vnd.github+json" },
    });
    const value = r.ok ? release(await r.json()) : null;
    if (value) { cached = { value, at: Date.now() }; return value; }
  } catch {}
  return cached?.value ?? FALLBACK;
}

export async function POST(request) {
  let body;
  try { body = await request.json(); } catch { return new Response("bad request", { status: 400 }); }
  const c = parse(body);
  if (!c) return new Response("bad request", { status: 400 });

  // Counting must never stop the answer.
  if (redis) {
    try {
      const p = redis.pipeline();
      for (const k of keys(c, day())) p.pfadd(k, c.id);
      await p.exec();
    } catch {}
  }
  return Response.json(await latest(), { headers: { "cache-control": "no-store" } });
}
