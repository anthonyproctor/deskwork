// Turning away a flood.
//
// A real install checks once a day. Anything asking many times a minute from
// one address is a script, and until now each of those requests cost Redis
// commands and could make a new key, so a loop could run up the bill or make
// the stats page time out. This is a fixed window per address, counted in
// Redis so it holds across instances. With no Redis there is nothing to
// protect and nothing to count, so everything is allowed through.

/** One address's bucket for this minute. Vercel sets x-forwarded-for. */
export function clientKey(request, now = new Date()) {
  const h = request.headers;
  const forwarded = h.get("x-real-ip") || h.get("x-forwarded-for") || "";
  const ip = forwarded.split(",")[0].trim() || "unknown";
  const minute = Math.floor(now.getTime() / 60000);
  return `rl:${minute}:${ip}`;
}

/**
 * Whether this request may proceed: at most `max` per key, the key expiring
 * after `windowSec` so buckets clean themselves up. A Redis error allows the
 * request: counting must never stop the answer.
 */
export async function allow(redis, key, max = 20, windowSec = 120) {
  if (!redis) return true;
  try {
    const n = await redis.incr(key);
    if (n === 1) await redis.expire(key, windowSec);
    return n <= max;
  } catch {
    return true;
  }
}
