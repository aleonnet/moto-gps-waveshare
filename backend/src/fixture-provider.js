import { createAmapCitiesProvider } from "./amap-cities.js";
import { createAmapPlacesProvider } from "./amap-places.js";
import { createAmapProvider } from "./amap-provider.js";
import { createGeoapifyCitiesProvider } from "./geoapify-cities.js";
import { createGeoapifyPlacesProvider } from "./geoapify-places.js";
import { createGeoapifyRouteProvider } from "./geoapify-routes.js";
import { createRegionalProvider } from "./regional-provider.js";

// Offline test gateway: the real adapters and the real regional choice, fed with recorded answers.
// AMap answers are synthetic (Jinan, Shanghai); Geoapify answers were recorded in Sao Paulo.
export const FIXTURE_FILES = {
  amapRoute: "amap-route-jinan-fixture.json",
  amapPlaces: "amap-places-jinan-fixture.json",
  amapCities: "amap-cities-shanghai-fixture.json",
  geoapifyRoute: "geoapify-route-saopaulo.json",
  geoapifyPlaces: "geoapify-places-ibirapuera.json",
  geoapifyCities: "geoapify-cities-campinas.json",
};

const FIXTURE_KEY = "fixture-not-a-key";

function recordedAnswer(payloads, url) {
  const text = String(url.searchParams.get("text") ?? url.searchParams.get("keywords") ?? "").toLowerCase();
  if (url.hostname === "restapi.amap.com") {
    if (url.pathname === "/v5/direction/driving") return payloads.amapRoute;
    if (url.pathname.startsWith("/v5/place/")) {
      return text.includes("奥体") ? payloads.amapPlaces : { status: "1", info: "OK", infocode: "10000", count: "0", pois: [] };
    }
    if (url.pathname === "/v3/config/district") {
      return text.includes("上海") ? payloads.amapCities : { status: "1", info: "OK", infocode: "10000", districts: [] };
    }
  }
  if (url.hostname === "api.geoapify.com") {
    if (url.pathname === "/v1/routing") return payloads.geoapifyRoute;
    if (url.pathname === "/v1/geocode/search") {
      if (url.searchParams.get("type") === "city") return text.includes("campinas") ? payloads.geoapifyCities : { results: [] };
      return text.includes("ibirapuera") ? payloads.geoapifyPlaces : { results: [] };
    }
  }
  return null;
}

export function createFixtureFetch(payloads) {
  return async (input) => {
    const body = recordedAnswer(payloads, new URL(String(input)));
    return body ? Response.json(body) : new Response("no recorded answer", { status: 404 });
  };
}

export function createFixtureProvider(payloads, { clock = Date.now } = {}) {
  const fetchImpl = createFixtureFetch(payloads);
  const options = { key: FIXTURE_KEY, fetchImpl, maxAttempts: 1 };
  const regional = createRegionalProvider({
    china: { name: "amap-fixture", liveTraffic: true, adapter: {
      ...createAmapProvider({ ...options, clock }), ...createAmapPlacesProvider(options), ...createAmapCitiesProvider(options),
    } },
    global: { name: "geoapify-fixture", liveTraffic: false, adapter: {
      ...createGeoapifyRouteProvider({ ...options, clock }), ...createGeoapifyPlacesProvider(options),
      ...createGeoapifyCitiesProvider(options),
    } },
    defaultRegion: "global",
  });
  // Recorded answers are not live navigation, whatever the adapters behind them could do.
  return { ...regional, capabilities: { route_planning: false, route_traffic: false } };
}
