// GET /api/stats?key=<STATS_KEY>  ->  a small page of install counts.
//
// Every number is an estimate from HyperLogLog (within about 1%), because
// there is no list of installs to count exactly.
import { timingSafeEqual } from "node:crypto";
import { lastDays } from "../lib/check.js";
import { redis } from "../lib/redis.js";

function allowed(given) {
  const want = process.env.STATS_KEY ?? "";
  if (!want || typeof given !== "string") return false;
  const a = Buffer.from(given), b = Buffer.from(want);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** At most this many keys per breakdown, so the page cannot be made to time out. */
const MAX_KEYS = 200;

async function breakdown(prefix, today) {
  const names = [];
  let cursor = "0";
  do {
    const [next, found] = await redis.scan(cursor, { match: `${prefix}:${today}:*`, count: 100 });
    cursor = String(next);
    for (const k of found) { if (names.length < MAX_KEYS) names.push(k); }
  } while (cursor !== "0" && names.length < MAX_KEYS);
  if (names.length === 0) return [];
  // One round trip for all the counts, not one per key.
  const p = redis.pipeline();
  for (const k of names) p.pfcount(k);
  const counts = await p.exec();
  return names.map((k, i) => [k.slice(`${prefix}:${today}:`.length), Number(counts[i]) || 0])
    .sort((a, b) => b[1] - a[1]);
}

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

export async function GET(request) {
  // The key may come in a header, which keeps it out of request logs; the
  // query form still works for a bookmark.
  const given = request.headers.get("x-stats-key") ?? new URL(request.url).searchParams.get("key");
  if (!allowed(given)) return new Response("not found", { status: 404 });
  if (!redis) return new Response("no database connected", { status: 503 });

  const days = lastDays(30);
  const daily = await Promise.all(days.map(async (d) => [d, await redis.pfcount(`d:${d}`)]));
  const week = await redis.pfcount(...days.slice(0, 7).map((d) => `d:${d}`));
  const month = await redis.pfcount(...days.map((d) => `d:${d}`));
  const versions = await breakdown("v", days[0]);
  const systems = await breakdown("os", days[0]);

  const rows = (pairs) => pairs.map(([k, n]) => `<tr><td>${esc(k)}</td><td>${n}</td></tr>`).join("");
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Coldfall installs</title>
<style>body{font:14px -apple-system,system-ui,sans-serif;max-width:560px;margin:32px auto;padding:0 16px;color:#222}
h1{font-size:18px}h2{font-size:14px;margin-top:28px}td{padding:2px 16px 2px 0}.big{font-size:28px;font-weight:600}
@media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}}</style>
<h1>Project Coldfall installs</h1>
<p><span class="big">${daily[0][1]}</span> today &nbsp; <span class="big">${week}</span> last 7 days &nbsp; <span class="big">${month}</span> last 30 days</p>
<p>Unique installs that checked for updates, UTC days. Estimates, within about 1%.</p>
<h2>By version, today</h2><table>${rows(versions) || "<tr><td>none yet</td></tr>"}</table>
<h2>By macOS, today</h2><table>${rows(systems.map(([k, n]) => [`macOS ${k}`, n])) || "<tr><td>none yet</td></tr>"}</table>
<h2>Each day</h2><table>${rows(daily)}</table>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}
