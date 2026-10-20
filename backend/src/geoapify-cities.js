import { validateCityKeywords } from "./amap-cities.js";
import {
  compactText,
  fetchGeoapifyJson,
  geoapifyId,
  geoapifyLanguage,
  GeoapifyError,
  requireGeoapifyKey,
} from "./geoapify-places.js";

const DEFAULT_ENDPOINT = "https://api.geoapify.com/v1/geocode/search";

export function buildGeoapifyCitiesUrl(keywords, { key, endpoint = DEFAULT_ENDPOINT, language = "en" } = {}) {
  requireGeoapifyKey(key);
  const url = new URL(endpoint);
  url.searchParams.set("text", validateCityKeywords(keywords));
  url.searchParams.set("type", "city");
  url.searchParams.set("limit", "10");
  url.searchParams.set("lang", language);
  url.searchParams.set("format", "json");
  url.searchParams.set("apiKey", key);
  return url;
}

export function transformGeoapifyCities(payload) {
  if (!payload || !Array.isArray(payload.results)) {
    throw new GeoapifyError("INVALID_RESPONSE", "Geoapify city results are invalid");
  }
  const cities = [], seen = new Set();
  for (const result of payload.results) {
    const box = result?.bbox;
    const bounds = [box?.lon1, box?.lat1, box?.lon2, box?.lat2].map(Number);
    const name = compactText(result?.city ?? result?.name, 80);
    // A city without a returned bounding box is dropped: its download area is never invented.
    if (!result?.place_id || !name || bounds.some((value) => !Number.isFinite(value)) ||
        !(bounds[0] < bounds[2] && bounds[1] < bounds[3]) ||
        Math.abs(bounds[0]) > 180 || Math.abs(bounds[2]) > 180 ||
        Math.abs(bounds[1]) > 85 || Math.abs(bounds[3]) > 85) continue;
    const id = geoapifyId(result.place_id);
    if (seen.has(id)) continue;
    seen.add(id);
    cities.push({ id, name, scope: "city", bounds_wgs84: bounds });
  }
  return { cities };
}

export function createGeoapifyCitiesProvider({ key, fetchImpl = globalThis.fetch, endpoint = DEFAULT_ENDPOINT,
  timeoutMs = 8000, maxAttempts = 3, retryDelayMs = 100 } = {}) {
  return {
    async searchCities({ keywords } = {}, { signal, acceptLanguage } = {}) {
      const url = buildGeoapifyCitiesUrl(keywords, { key, endpoint, language: geoapifyLanguage(acceptLanguage) });
      const payload = await fetchGeoapifyJson(fetchImpl, url, { timeoutMs, maxAttempts, retryDelayMs, signal, label: "city search" });
      return transformGeoapifyCities(payload);
    },
  };
}
