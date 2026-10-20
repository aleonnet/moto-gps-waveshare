import { isInChinaMainland } from "./china-mainland.js";

export class RegionalProviderError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "RegionalProviderError";
    this.code = code;
    this.retryable = false;
  }
}

const REGIONS = ["china", "global"];

/**
 * Presents one provider to the gateway and picks, per request, the mainland-China adapter (AMap)
 * or the global one. Each region is { name, liveTraffic, adapter } or null. A failing provider is
 * never replaced by the other one; only an empty search result is retried once elsewhere.
 */
export function createRegionalProvider({ china = null, global = null, defaultRegion = "global" } = {}) {
  if (!REGIONS.includes(defaultRegion)) throw new TypeError("defaultRegion must be china or global");
  const regions = { china, global };
  const other = (region) => (region === "china" ? "global" : "china");

  function adapterFor(region, method) {
    const adapter = regions[region]?.adapter;
    if (typeof adapter?.[method] !== "function") {
      throw new RegionalProviderError("SERVER_MISCONFIGURED", `${region} provider is not configured`);
    }
    return adapter;
  }

  // Cloudflare reports XX for an unknown country and T1 for Tor.
  function clientRegion(clientCountry) {
    const country = String(clientCountry ?? "").toUpperCase();
    if (!/^[A-Z][A-Z0-9]$/.test(country) || country === "XX" || country === "T1") return defaultRegion;
    return country === "CN" ? "china" : "global";
  }

  function routeRegion(request) {
    const origin = isInChinaMainland(request.origin);
    if (origin !== isInChinaMainland(request.destination)) {
      throw new RegionalProviderError("CROSS_REGION_ROUTE_UNSUPPORTED",
        "origin and destination are served by different map providers");
    }
    return origin ? "china" : "global";
  }

  // A Geoapify place id means nothing to AMap; any other id reaches AMap exactly as before.
  function routeRequestFor(region, request) {
    if (region !== "china" || !request.destination_poi_id?.startsWith("g:")) return request;
    const withoutPoi = { ...request };
    delete withoutPoi.destination_poi_id;
    return withoutPoi;
  }

  async function searchWithFallback(region, method, query, options, retryWhenEmpty, resultsOf) {
    const first = await adapterFor(region, method)[method](query, options);
    const fallback = regions[other(region)]?.adapter;
    if (!retryWhenEmpty || resultsOf(first).length > 0 || typeof fallback?.[method] !== "function") return first;
    try {
      return await fallback[method](query, options);
    } catch {
      return first;
    }
  }

  return {
    regions: Object.fromEntries([["default", defaultRegion], ...REGIONS.map((region) => [region, regions[region]
      ? { provider: regions[region].name, route_traffic: Boolean(regions[region].liveTraffic) } : null])]),
    capabilities: {
      route_planning: REGIONS.some((region) => typeof regions[region]?.adapter?.planRoute === "function"),
      route_traffic: REGIONS.some((region) => regions[region]?.liveTraffic === true),
    },

    async planRoute(request, options = {}) {
      const region = routeRegion(request);
      return adapterFor(region, "planRoute").planRoute(routeRequestFor(region, request), options);
    },

    async planRouteOptions(request, options = {}) {
      const region = routeRegion(request);
      const adapter = adapterFor(region, "planRoute");
      const routed = routeRequestFor(region, request);
      return typeof adapter.planRouteOptions === "function"
        ? adapter.planRouteOptions(routed, options) : [await adapter.planRoute(routed, options)];
    },

    async searchPlaces(query, options = {}) {
      let region;
      if (query.origin) region = isInChinaMainland(query.origin) ? "china" : "global";
      else if (query.region) region = "china"; // AMap's city/adcode filter.
      else region = clientRegion(options.clientCountry);
      // A position-biased search already asked the right provider about the right place.
      return searchWithFallback(region, "searchPlaces", query, options, !query.origin, (result) => result.places);
    },

    async searchCities(query, options = {}) {
      return searchWithFallback(clientRegion(options.clientCountry), "searchCities", query, options, true,
        (result) => result.cities);
    },
  };
}
