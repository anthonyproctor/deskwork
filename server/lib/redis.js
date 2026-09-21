import { Redis } from "@upstash/redis";

// Vercel's Upstash integration names these KV_REST_API_*; Upstash's own docs
// use UPSTASH_REDIS_REST_*. Either works. With neither, checks still answer
// with the latest version; they just are not counted.
const url = process.env.UPSTASH_REDIS_REST_URL ?? process.env.KV_REST_API_URL;
const token = process.env.UPSTASH_REDIS_REST_TOKEN ?? process.env.KV_REST_API_TOKEN;

export const redis = url && token ? new Redis({ url, token }) : null;
