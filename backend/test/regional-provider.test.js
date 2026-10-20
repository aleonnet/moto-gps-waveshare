import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { createAmapCitiesProvider } from "../src/amap-cities.js";
import { createAmapPlacesProvider } from "../src/amap-places.js";
import { createAmapProvider } from "../src/amap-provider.js";
import { createFixtureProvider, FIXTURE_FILES } from "../src/fixture-provider.js";
import { createGateway } from "../src/gateway.js";
import { createRegionalProvider } from "../src/regional-provider.js";

const load = async (name) => JSON.parse(await readFile(new URL(`../fixtures/${name}`, import.meta.url), "utf8"));
const beijingRoute = await load("amap-route-v2.json");
const beijingRequest = await load("route-request-v1.json");
const point = (longitude_deg, latitude_deg) => ({ coordinate_system: "WGS84", longitude_deg, latitude_deg });
const jinan = point(117.1224488, 36.6748039);
const saoPaulo = point(-46.6333, -23.5505);

function recordingAdapter(name, calls, { places = [{ id: name }], cities = [{ id: name }] } = {}) {
  return {
    async planRoute(request, options) { calls.push([name, "planRoute", request, options]); return { route_id: name }; },
    async searchPlaces(query, options) { calls.push([name, "searchPlaces", query, options]); return { places }; },
    async searchCities(query, options) { calls.push([name, "searchCities", query, options]); return { cities }; },
  };
}

function regional(calls, { china = {}, global = {}, defaultRegion } = {}) {
  return createRegionalProvider({ defaultRegion,
    china: { name: "amap", liveTraffic: true, adapter: recordingAdapter("china", calls, china) },
    global: { name: "geoapify", liveTraffic: false, adapter: recordingAdapter("global", calls, global) } });
}

test("inside mainland China the answer is byte for byte the AMap adapter's", async () => {
  const amapAnswer = async (url) => {
    const { pathname } = new URL(url);
    if (pathname === "/v5/direction/driving") return Response.json(beijingRoute);
    if (pathname.startsWith("/v5/place/")) return Response.json({ status: "1", pois: [{ id: "B0", name: "北京站", location: "116.427,39.903" }] });
    return Response.json({ status: "1", districts: [{ adcode: "110000", level: "province", name: "北京市",
      polyline: "116.0,39.6;116.8,39.6;116.8,40.2;116.0,40.2;116.0,39.6" }] });
  };
  const options = { key: "amap-key", fetchImpl: amapAnswer, clock: () => 1700000000123 };
  const amap = { ...createAmapProvider(options), ...createAmapPlacesProvider(options), ...createAmapCitiesProvider(options) };
  const provider = createRegionalProvider({ china: { name: "amap", liveTraffic: true, adapter: amap },
    global: { name: "geoapify", adapter: { async planRoute() { assert.fail("global adapter used in China"); } } } });
  assert.deepStrictEqual(await provider.planRoute(beijingRequest), await amap.planRoute(beijingRequest));
  assert.deepStrictEqual(await provider.planRouteOptions(beijingRequest), await amap.planRouteOptions(beijingRequest));
  const query = { keywords: "北京站", region: "", origin: point(116.4, 39.9) };
  assert.deepStrictEqual(await provider.searchPlaces(query), await amap.searchPlaces(query));
  assert.deepStrictEqual(await provider.searchCities({ keywords: "北京" }, { clientCountry: "CN" }),
    await amap.searchCities({ keywords: "北京" }));
});

test("a route that crosses the mainland border is refused before any provider runs", async () => {
  const calls = [];
  const provider = regional(calls);
  for (const [origin, destination] of [[jinan, saoPaulo], [point(114.06, 22.54), point(114.17, 22.32)]]) {
    const error = await provider.planRoute({ origin, destination }).catch((reason) => reason);
    assert.deepEqual([error.code, error.retryable], ["CROSS_REGION_ROUTE_UNSUPPORTED", false]);
  }
  assert.deepEqual(calls, []);
  await provider.planRoute({ origin: saoPaulo, destination: point(-43.2, -22.9) });
  await provider.planRoute({ origin: jinan, destination: point(121.47, 31.23) });
  assert.deepEqual(calls.map(([name]) => name), ["global", "china"]);
});

test("searches without a position follow the client country, then the default, with one retry when empty", async () => {
  for (const [clientCountry, defaultRegion, first] of [["CN", "global", "china"], ["BR", "china", "global"],
    ["", "global", "global"], ["", "china", "china"], ["XX", "china", "china"], ["T1", "global", "global"]]) {
    const calls = [];
    await regional(calls, { defaultRegion }).searchPlaces({ keywords: "test" }, { clientCountry });
    assert.deepEqual(calls.map(([name]) => name), [first], `${clientCountry || "none"} / ${defaultRegion}`);
  }
  const calls = [];
  const emptyFirst = regional(calls, { global: { places: [], cities: [] } });
  const places = await emptyFirst.searchPlaces({ keywords: "奥体中心" }, { clientCountry: "BR" });
  const cities = await emptyFirst.searchCities({ keywords: "上海" }, { clientCountry: "BR" });
  assert.deepEqual(calls.map(([name, method]) => `${name}.${method}`),
    ["global.searchPlaces", "china.searchPlaces", "global.searchCities", "china.searchCities"]);
  assert.deepEqual([places.places, cities.cities], [[{ id: "china" }], [{ id: "china" }]]);

  const bothEmpty = [];
  await regional(bothEmpty, { china: { places: [] }, global: { places: [] } }).searchPlaces({ keywords: "zz" });
  assert.equal(bothEmpty.length, 2, "exactly one retry, never a loop");
});

test("a rider's position decides the place provider and is never second-guessed", async () => {
  const calls = [];
  const provider = regional(calls, { china: { places: [] }, global: { places: [] } });
  await provider.searchPlaces({ keywords: "posto", origin: saoPaulo }, { clientCountry: "CN" });
  await provider.searchPlaces({ keywords: "奥体中心", origin: jinan }, { clientCountry: "BR" });
  await provider.searchPlaces({ keywords: "奥体中心", region: "济南" }, { clientCountry: "BR" });
  assert.deepEqual(calls.map(([name]) => name), ["global", "china", "china", "global"]);
});

test("request context and destination ids reach only the provider that understands them", async () => {
  const calls = [];
  const provider = regional(calls);
  const context = { acceptLanguage: "pt-BR", clientCountry: "BR" };
  await provider.planRoute({ origin: jinan, destination: point(117.13, 36.66), destination_poi_id: "g:abc" }, context);
  await provider.planRoute({ origin: jinan, destination: point(117.13, 36.66), destination_poi_id: "B0FFAMAP" }, context);
  await provider.planRoute({ origin: saoPaulo, destination: point(-46.65, -23.58), destination_poi_id: "g:abc" }, context);
  assert.deepEqual(calls.map(([, , request]) => request.destination_poi_id), [undefined, "B0FFAMAP", "g:abc"]);
  assert.ok(calls.every(([, , , options]) => options === context));
});

test("a failing provider is reported, never replaced by the other region", async () => {
  const calls = [];
  const provider = createRegionalProvider({
    china: { name: "amap", adapter: recordingAdapter("china", calls) },
    global: { name: "geoapify", adapter: { async searchPlaces() {
      throw Object.assign(new Error("Geoapify place search is unavailable"), { code: "PROVIDER_UNAVAILABLE" });
    } } } });
  await assert.rejects(provider.searchPlaces({ keywords: "posto" }, { clientCountry: "BR" }), { code: "PROVIDER_UNAVAILABLE" });
  assert.deepEqual(calls, []);
  const missing = createRegionalProvider({ global: { name: "geoapify", adapter: recordingAdapter("global", calls) } });
  await assert.rejects(missing.planRoute({ origin: jinan, destination: jinan }), { code: "SERVER_MISCONFIGURED" });
  assert.deepEqual(missing.regions, { default: "global", china: null, global: { provider: "geoapify", route_traffic: false } });
});

async function startGateway(t, provider, providerMode) {
  const server = createGateway({ provider, providerMode });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
}

test("the gateway hands language and the proxy's country to the regional provider", async (t) => {
  const calls = [];
  const base = await startGateway(t, regional(calls), "regional");
  const health = await (await fetch(`${base}/healthz`)).json();
  assert.equal(health.ready_for_live_navigation, true);
  assert.deepEqual([health.capabilities.route_planning, health.capabilities.route_traffic], [true, true]);
  assert.deepEqual(health.regions.china, { provider: "amap", route_traffic: true });
  await fetch(`${base}/v1/places?keywords=posto`, { headers: { "Accept-Language": "pt-BR", "X-Client-Country": "CN" } });
  assert.deepEqual(calls[0].slice(0, 2), ["china", "searchPlaces"]);
  assert.deepEqual(calls[0][3], { acceptLanguage: "pt-BR", clientCountry: "CN" });
});

test("the test gateway answers the app's real journeys from recorded responses", async (t) => {
  const payloads = Object.fromEntries(await Promise.all(Object.entries(FIXTURE_FILES)
    .map(async ([name, file]) => [name, await load(file)])));
  const base = await startGateway(t, createFixtureProvider(payloads, { clock: () => 1 }), "fixture");
  const health = await (await fetch(`${base}/healthz`)).json();
  assert.equal(health.ready_for_live_navigation, false, "recorded answers are not live navigation");
  const search = async (keywords, origin) => (await fetch(`${base}/v1/places?keywords=${encodeURIComponent(keywords)}` +
    (origin ? `&longitude_deg=${origin.longitude_deg}&latitude_deg=${origin.latitude_deg}` : ""))).json();
  const olympic = (await search("奥体中心", jinan)).places[0];
  assert.equal(olympic.name, "奥体中心");
  const route = async (origin, destination) => (await fetch(`${base}/v1/route-options`, { method: "POST",
    headers: { "Content-Type": "application/json" }, body: JSON.stringify({ protocol_version: 1, request_id: 3,
      route_mode: "driving", is_reroute: false, origin, destination: { ...destination, coordinate_system: "WGS84" } }) })).json();
  const jinanRoutes = (await route(jinan, olympic.location)).routes;
  assert.deepEqual(jinanRoutes.map((candidate) => candidate.provider), ["amap", "amap"]);
  assert.equal((await search("Ibirapuera", saoPaulo)).places[0].name, "Vila Jardim Ibirapuera");
  const saoPauloRoutes = (await route(saoPaulo, point(-46.6585214, -23.5877126))).routes;
  assert.deepEqual(saoPauloRoutes.map((candidate) => candidate.provider), ["geoapify"]);
  const shanghai = await (await fetch(`${base}/v1/map/cities?keywords=${encodeURIComponent("上海")}`)).json();
  assert.equal(shanghai.cities[0].id, "310000", "empty global answer falls back to AMap once");
  const campinas = await (await fetch(`${base}/v1/map/cities?keywords=Campinas`)).json();
  assert.equal(campinas.cities[0].name, "Campinas");
});
