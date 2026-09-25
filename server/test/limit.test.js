import { test } from "node:test";
import assert from "node:assert/strict";
import { clientKey, allow } from "../lib/limit.js";

const at = new Date("2026-09-25T12:34:56Z");
const minute = Math.floor(at.getTime() / 60000);

test("a bucket is one address for one minute", () => {
  const r = new Request("http://x/api/check", { headers: { "x-forwarded-for": "203.0.113.9, 10.0.0.1" } });
  assert.equal(clientKey(r, at), `rl:${minute}:203.0.113.9`);
  const real = new Request("http://x/api/check", { headers: { "x-real-ip": "198.51.100.2", "x-forwarded-for": "9.9.9.9" } });
  assert.equal(clientKey(real, at), `rl:${minute}:198.51.100.2`, "the platform's own header wins");
  assert.equal(clientKey(new Request("http://x/api/check"), at), `rl:${minute}:unknown`);
});

/** A Redis that only counts. */
function fakeRedis() {
  const n = new Map(), ttl = new Map();
  return {
    n, ttl,
    async incr(k) { n.set(k, (n.get(k) ?? 0) + 1); return n.get(k); },
    async expire(k, s) { ttl.set(k, s); },
  };
}

test("the twenty-first request in a minute is refused, and the bucket expires", async () => {
  const redis = fakeRedis();
  let allowed = 0;
  for (let i = 0; i < 25; i++) if (await allow(redis, "rl:1:a", 20, 120)) allowed++;
  assert.equal(allowed, 20);
  assert.equal(redis.ttl.get("rl:1:a"), 120, "set once, on the first request");
  assert.equal(await allow(redis, "rl:1:b", 20, 120), true, "another address is another bucket");
});

test("no Redis, or a failing one, never blocks a check", async () => {
  assert.equal(await allow(null, "rl:1:a"), true);
  const broken = { async incr() { throw new Error("down"); }, async expire() {} };
  assert.equal(await allow(broken, "rl:1:a"), true);
});
