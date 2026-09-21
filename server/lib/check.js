// What the update check accepts, and what it keeps.
//
// The app sends { id, v, os }: a random ID made on the Mac, the app version
// ("v0.3.0" or "v0.3.0-dev") and the macOS version ("15.6.1"). Anything that
// does not look exactly like that is refused rather than stored.
//
// Nothing here stores an ID. Each one is added to a HyperLogLog, a structure
// that estimates how many DIFFERENT values it has seen and cannot give any of
// them back. There is no list of installs to leak, sell or be asked for.

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const VERSION = /^(v\d{1,4}(\.\d{1,4}){0,3}(-dev)?|unknown)$/;
const OS = /^(\d{1,3})\.\d{1,3}\.\d{1,3}$/;

/** The three fields, checked, or null. */
export function parse(body) {
  if (!body || typeof body !== "object") return null;
  const { id, v, os } = body;
  if (typeof id !== "string" || !ID.test(id)) return null;
  if (typeof v !== "string" || !VERSION.test(v)) return null;
  if (typeof os !== "string" || !OS.test(os)) return null;
  return { id, v, osMajor: os.match(OS)[1] };
}

/** "2026-09-21", in UTC, so a day means the same thing for everyone. */
export function day(d = new Date()) {
  return d.toISOString().slice(0, 10);
}

/** The estimates one check adds to: installs that day, by version, by macOS. */
export function keys(c, today) {
  return [`d:${today}`, `v:${today}:${c.v}`, `os:${today}:${c.osMajor}`];
}

/** The last `n` days, newest first. */
export function lastDays(n, from = new Date()) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(day(new Date(from.getTime() - i * 86400000)));
  return out;
}

/** The GitHub release as the app wants it, or null if it is not one. */
export function release(json) {
  if (!json || typeof json.tag_name !== "string" || !/^v\d/.test(json.tag_name)) return null;
  const url = typeof json.html_url === "string" && json.html_url.startsWith("https://") ? json.html_url : null;
  return { latest: json.tag_name, url };
}
