import { readFile } from "node:fs/promises";

import { createAmapProvider } from "./amap-provider.js";
import { createAmapPlacesProvider } from "./amap-places.js";
import { createAmapCitiesProvider } from "./amap-cities.js";
import { createGeoapifyCitiesProvider } from "./geoapify-cities.js";
import { createGeoapifyPlacesProvider } from "./geoapify-places.js";
import { createGeoapifyRouteProvider } from "./geoapify-routes.js";
import { createMapTileProvider } from "./map-tiles.js";
import { createFixtureProvider, FIXTURE_FILES } from "./fixture-provider.js";
import { createGateway } from "./gateway.js";
import { createRegionalProvider } from "./regional-provider.js";

async function loadFixturePayloads() {
  return Object.fromEntries(await Promise.all(Object.entries(FIXTURE_FILES).map(async ([name, file]) =>
    [name, JSON.parse(await readFile(new URL(`../fixtures/${file}`, import.meta.url), "utf8"))])));
}

function createAmapAdapter(key) {
  return { ...createAmapProvider({ key }), ...createAmapPlacesProvider({ key }), ...createAmapCitiesProvider({ key }) };
}

function createGeoapifyAdapter(key) {
  return { ...createGeoapifyRouteProvider({ key }), ...createGeoapifyPlacesProvider({ key }),
    ...createGeoapifyCitiesProvider({ key }) };
}

function present(value) {
  return typeof value === "string" && value.trim() !== "";
}

function createDisabledProvider() {
  const unavailable = () => {
    const error = new Error("AMap live navigation is not configured");
    error.code = "SERVER_MISCONFIGURED";
    error.retryable = false;
    throw error;
  };
  return {
    async planRoute() {
      unavailable();
    },
    async planRouteOptions() {
      unavailable();
    },
    async searchPlaces() {
      unavailable();
    },
  };
}

async function main() {
  const providerMode = process.env.MOTO_PROVIDER ?? "fixture";
  let provider;
  if (providerMode === "amap") {
    const key = process.env.AMAP_WEB_SERVICE_KEY;
    if (typeof key !== "string" || key.trim() === "") {
      throw new Error("AMAP_WEB_SERVICE_KEY is required when MOTO_PROVIDER=amap");
    }
    provider = createAmapAdapter(key);
  } else if (providerMode === "regional") {
    // Geoapify serves everything outside mainland China; AMap is optional until a key exists.
    if (!present(process.env.GEOAPIFY_API_KEY)) {
      throw new Error("GEOAPIFY_API_KEY is required when MOTO_PROVIDER=regional");
    }
    const amapKey = process.env.AMAP_WEB_SERVICE_KEY;
    provider = createRegionalProvider({
      china: present(amapKey) ? { name: "amap", liveTraffic: true, adapter: createAmapAdapter(amapKey) } : null,
      global: { name: "geoapify", liveTraffic: false, adapter: createGeoapifyAdapter(process.env.GEOAPIFY_API_KEY) },
      defaultRegion: process.env.MOTO_DEFAULT_REGION ?? "global",
    });
  } else if (providerMode === "fixture") {
    provider = createFixtureProvider(await loadFixturePayloads());
  } else if (providerMode === "disabled") {
    provider = createDisabledProvider();
  } else {
    throw new Error(`unsupported MOTO_PROVIDER: ${providerMode}`);
  }
  const port = Number(process.env.PORT ?? 8787);
  const allowedOrigin = process.env.WEB_ORIGIN ?? "http://localhost:5173";
  const mapProvider = createMapTileProvider({
    url: process.env.MOTO_MAP_PMTILES_URL ??
      (["amap", "regional"].includes(providerMode) ? "auto" : "disabled"),
    apiKey: process.env.PROTOMAPS_API_KEY,
    cacheDirectory: process.env.MOTO_MAP_CACHE_DIR,
    maximumCacheBytes: process.env.MOTO_MAP_CACHE_MAX_BYTES === undefined
      ? undefined : Number(process.env.MOTO_MAP_CACHE_MAX_BYTES),
  });
  await mapProvider?.initialize();
  const server = createGateway({ provider, mapProvider, allowedOrigin, providerMode });

  server.listen(port, "127.0.0.1", () => {
    console.log(`MOTO GPS gateway listening on http://127.0.0.1:${port} (${providerMode})`);
  });

  const close = () => { mapProvider?.close(); server.close(); };
  process.once("SIGINT", close);
  process.once("SIGTERM", close);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
