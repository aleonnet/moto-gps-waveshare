import { createHash } from "node:crypto";

import { distanceMetres } from "./amap-places.js";
import { readLimitedBody } from "./map-http.js";
import { fetchGetWithTransientRetry, isTransientUpstreamStatus } from "./upstream-retry.js";

const DEFAULT_ENDPOINT = "https://api.geoapify.com/v1/geocode/search";
const MAX_RESULTS = 12;
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;
// The app offers English, Portuguese and Simplified Chinese. Chinese riders outside the mainland
// get English OSM names rather than an unverified Geoapify Chinese rendering.
const LANGUAGES = new Set(["en", "pt"]);

export class GeoapifyError extends Error {
  constructor(code, message, { retryable = true } = {}) {
    super(message);
    this.name = "GeoapifyError";
    this.code = code;
    this.retryable = retryable;
  }
}

export function geoapifyLanguage(acceptLanguage) {
  const primary = String(acceptLanguage ?? "").split(/[,;]/)[0].trim().toLowerCase().split("-")[0];
  return LANGUAGES.has(primary) ? primary : "en";
}

export function compactText(value, maximumLength) {
  return String(value ?? "").trim().slice(0, maximumLength);
}

// Geoapify place_id values measured 68 to 132 characters; the route request accepts 64.
export function geoapifyId(placeId) {
  return `g:${createHash("sha256").update(String(placeId)).digest("hex").slice(0, 32)}`;
}

export function requireGeoapifyKey(key) {
  if (typeof key !== "string" || key.trim() === "") {
    throw new GeoapifyError("SERVER_MISCONFIGURED", "Geoapify key is not configured", { retryable: false });
  }
}

/**
 * One bounded GET. Error messages are written here and never carry the request URL, because the
 * URL holds the API key.
 */
export async function fetchGeoapifyJson(fetchImpl, url, { timeoutMs, maxAttempts, retryDelayMs, signal, label,
  maximumBytes = MAX_RESPONSE_BYTES }) {
  const deadlineSignal = AbortSignal.timeout(timeoutMs);
  const requestSignal = signal ? AbortSignal.any([deadlineSignal, signal]) : deadlineSignal;
  let response;
  try {
    response = await fetchGetWithTransientRetry(fetchImpl, url, {
      headers: { Accept: "application/json" }, signal: requestSignal, maxAttempts, retryDelayMs,
    });
  } catch (error) {
    const code = deadlineSignal.aborted || error?.name === "TimeoutError" ? "PROVIDER_TIMEOUT" : "PROVIDER_UNAVAILABLE";
    throw new GeoapifyError(code, `Geoapify ${label} is unavailable`);
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new GeoapifyError("PROVIDER_HTTP_ERROR", `Geoapify returned HTTP ${response.status}`, {
      retryable: isTransientUpstreamStatus(response.status) || response.status === 429,
    });
  }
  try {
    return JSON.parse((await readLimitedBody(response, maximumBytes)).toString("utf8"));
  } catch {
    throw new GeoapifyError("PROVIDER_INVALID_JSON", "Geoapify returned invalid or oversized JSON");
  }
}

function wgs84Point(longitudeDeg, latitudeDeg) {
  const longitude = Number(longitudeDeg);
  const latitude = Number(latitudeDeg);
  if (!Number.isFinite(longitude) || !Number.isFinite(latitude) ||
      Math.abs(longitude) > 180 || Math.abs(latitude) > 90) return null;
  return { coordinate_system: "WGS84", longitude_deg: Number(longitude.toFixed(7)), latitude_deg: Number(latitude.toFixed(7)) };
}

export function buildGeoapifyPlacesUrl(query, { key, endpoint = DEFAULT_ENDPOINT, language = "en" } = {}) {
  requireGeoapifyKey(key);
  const keywords = compactText(query?.keywords, 80);
  if (keywords.length < 2) {
    throw new GeoapifyError("INVALID_REQUEST", "keywords must contain at least 2 characters", { retryable: false });
  }
  const url = new URL(endpoint);
  url.searchParams.set("text", keywords);
  url.searchParams.set("limit", String(MAX_RESULTS));
  url.searchParams.set("lang", language);
  url.searchParams.set("format", "json");
  const origin = query?.origin && wgs84Point(query.origin.longitude_deg, query.origin.latitude_deg);
  if (origin) url.searchParams.set("bias", `proximity:${origin.longitude_deg},${origin.latitude_deg}`);
  url.searchParams.set("apiKey", key);
  return url;
}

export function transformGeoapifyPlaces(payload, query) {
  if (!payload || !Array.isArray(payload.results)) {
    throw new GeoapifyError("INVALID_RESPONSE", "Geoapify place results are invalid");
  }
  const origin = query?.origin ? wgs84Point(query.origin.longitude_deg, query.origin.latitude_deg) : null;
  const places = [];
  for (const result of payload.results) {
    const location = wgs84Point(result?.lon, result?.lat);
    if (!location || !result.place_id) continue;
    const city = compactText(result.city ?? result.county ?? result.state, 32);
    const district = compactText(result.suburb ?? result.district, 32);
    const place = {
      id: geoapifyId(result.place_id),
      name: compactText(result.name ?? result.address_line1 ?? result.formatted, 96),
      address: compactText(result.address_line2 ?? result.formatted, 160),
      city,
      district,
      display_area: [city, district].filter(Boolean).join(" · "),
      location,
    };
    if (origin) place.distance_m = distanceMetres(origin, location);
    places.push(place);
    if (places.length >= MAX_RESULTS) break;
  }
  return { protocol_version: 1, query: compactText(query?.keywords, 80), places };
}

export function createGeoapifyPlacesProvider({ key, fetchImpl = globalThis.fetch, endpoint = DEFAULT_ENDPOINT,
  timeoutMs = 6000, maxAttempts = 3, retryDelayMs = 100 } = {}) {
  return {
    async searchPlaces(query, { signal, acceptLanguage } = {}) {
      const url = buildGeoapifyPlacesUrl(query, { key, endpoint, language: geoapifyLanguage(acceptLanguage) });
      const payload = await fetchGeoapifyJson(fetchImpl, url, { timeoutMs, maxAttempts, retryDelayMs, signal, label: "place search" });
      return transformGeoapifyPlaces(payload, query);
    },
  };
}
