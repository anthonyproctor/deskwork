import { test } from "node:test";
import assert from "node:assert/strict";
import { parse, day, keys, lastDays, release } from "../lib/check.js";

const id = "0f8b6c1e-3a2d-4c5b-9e7f-1a2b3c4d5e6f";

test("accepts exactly what the app sends", () => {
  assert.deepEqual(parse({ id, v: "v0.3.0", os: "15.6.1" }), { id, v: "v0.3.0", osMajor: "15" });
  assert.deepEqual(parse({ id, v: "v0.3.0-dev", os: "26.0.0" })?.v, "v0.3.0-dev");
  assert.equal(parse({ id, v: "unknown", os: "15.0.0" })?.v, "unknown");
});

test("refuses anything else rather than storing it", () => {
  assert.equal(parse(null), null);
  assert.equal(parse({ id: "not-an-id", v: "v0.3.0", os: "15.6.1" }), null);
  assert.equal(parse({ id: id.toUpperCase(), v: "v0.3.0", os: "15.6.1" }), null);
  assert.equal(parse({ id, v: "v0.3.0-5-gabc1234", os: "15.6.1" }), null, "a commit hash is not a version");
  assert.equal(parse({ id, v: "v0.3.0", os: "15.6.1; rm -rf" }), null);
  assert.equal(parse({ id, v: "v0.3.0<script>", os: "15.6.1" }), null);
  assert.equal(parse({ id, v: 3, os: "15.6.1" }), null);
});

test("one check adds to three estimates and keeps nothing else", () => {
  assert.deepEqual(keys({ id, v: "v0.3.0", osMajor: "15" }, "2026-09-21"),
    ["d:2026-09-21", "v:2026-09-21:v0.3.0", "os:2026-09-21:15"]);
});

test("days are UTC and newest first", () => {
  assert.equal(day(new Date("2026-09-21T23:30:00-06:00")), "2026-09-22");
  assert.deepEqual(lastDays(3, new Date("2026-09-21T12:00:00Z")), ["2026-09-21", "2026-09-20", "2026-09-19"]);
});

test("reads the latest GitHub release", () => {
  assert.deepEqual(release({ tag_name: "v0.4.0", html_url: "https://github.com/o/r/releases/tag/v0.4.0" }),
    { latest: "v0.4.0", url: "https://github.com/o/r/releases/tag/v0.4.0" });
  assert.equal(release({ tag_name: "nightly" }), null);
  assert.equal(release({ tag_name: "v1.0.0", html_url: "http://x" }).url, null);
});
