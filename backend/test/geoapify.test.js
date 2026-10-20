import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { wgs84ToGcj02 } from "../src/coordinates.js";
import { createGeoapifyCitiesProvider, transformGeoapifyCities } from "../src/geoapify-cities.js";
import { createGeoapifyPlacesProvider, geoapifyLanguage, transformGeoapifyPlaces } from "../src/geoapify-places.js";
import {
  buildGeoapifyRouteUrl,
  createGeoapifyRouteProvider,
  mapGeoapifyManeuver,
  transformGeoapifyRoute,
} from "../src/geoapify-routes.js";

// Real answers recorded 2026-10-19 with the owner's key (removed): motorcycle route Se -> Ibirapuera,
// place search "Ibirapuera" biased to Se, city search "Campinas".
const load = async (name) => JSON.parse(await readFile(new URL(`../fixtures/${name}`, import.meta.url), "utf8"));
const route = await load("geoapify-route-saopaulo.json");
const places = await load("geoapify-places-ibirapuera.json");
const cities = await load("geoapify-cities-campinas.json");
const KEY = "secret-geoapify-key";
const se = { coordinate_system: "WGS84", longitude_deg: -46.6333, latitude_deg: -23.5505 };
const request = { protocol_version: 1, request_id: 9, route_mode: "driving", is_reroute: false,
  origin: se, destination: { coordinate_system: "WGS84", longitude_deg: -46.6585214, latitude_deg: -23.5877126 } };

function seoulRoute() {
  const coordinates = [[126.978, 37.5665], [126.982, 37.5665], [126.982, 37.57]];
  return { type: "FeatureCollection", features: [{ type: "Feature",
    geometry: { type: "MultiLineString", coordinates: [coordinates] },
    properties: { distance: 740, time: 120, legs: [{ steps: [
      { from_index: 0, to_index: 1, distance: 352, instruction: { type: "StartAt", text: "Head east", streets: ["Sejong-daero"] } },
      { from_index: 1, to_index: 2, distance: 388, instruction: { type: "Left", text: "Turn left", streets: ["Taepyeong-ro"] } },
      { from_index: 2, to_index: 2, distance: 0, instruction: { type: "DestinationReached", text: "Arrive" } },
    ] }] } }] };
}

test("route geometry leaves in the GCJ-02 frame: shifted inside the rectangle, unchanged in Sao Paulo", () => {
  const seoul = transformGeoapifyRoute(seoulRoute(), { generatedAtMs: 1 });
  assert.equal(seoul.coordinate_system, "GCJ-02");
  for (const [index, [longitude_deg, latitude_deg]] of seoulRoute().features[0].geometry.coordinates[0].entries()) {
    const expected = wgs84ToGcj02({ longitude_deg, latitude_deg });
    assert.ok(Math.abs(seoul.polyline[index].longitude_deg - expected.longitude_deg) < 1e-7);
    assert.ok(Math.abs(seoul.polyline[index].latitude_deg - expected.latitude_deg) < 1e-7);
    assert.ok(Math.abs(seoul.polyline[index].longitude_deg - longitude_deg) > 1e-3, "Seoul sits inside the GCJ-02 rectangle");
  }
  const saoPaulo = transformGeoapifyRoute(route, { generatedAtMs: 1 });
  const source = route.features[0].geometry.coordinates.flat();
  assert.equal(saoPaulo.polyline.length, source.length);
  saoPaulo.polyline.forEach((point, index) => {
    assert.ok(Math.abs(point.longitude_deg - source[index][0]) < 1e-7);
    assert.ok(Math.abs(point.latitude_deg - source[index][1]) < 1e-7);
  });
});

test("a maneuver sits where its step starts; the departure is not a maneuver", () => {
  const value = transformGeoapifyRoute(route, { generatedAtMs: 1700000000000 });
  const steps = route.features[0].properties.legs[0].steps;
  assert.equal(value.provider, "geoapify");
  assert.deepEqual(value.traffic, []);
  assert.equal(value.maneuvers.length, steps.length - 1);
  assert.equal(value.maneuvers[0].route_offset_m, steps[0].distance, "first turn after the 67 m departure");
  assert.ok(value.maneuvers.every((maneuver) => maneuver.route_offset_m > 0));
  let before = 0;
  steps.forEach((step, index) => {
    if (index > 0) assert.equal(value.maneuvers[index - 1].route_offset_m, before);
    before += step.distance;
  });
  const arrive = value.maneuvers.at(-1);
  assert.equal(arrive.type, "arrive");
  assert.ok(Math.abs(arrive.route_offset_m - value.total_distance_m) <= 1);
  assert.deepEqual(value.maneuvers.slice(0, 3).map(({ type, road_name }) => [type, road_name]),
    [["left", "Rua Venceslau Brás"], ["right", "Praça da Sé"], ["right", "Praça Doutor João Mendes"]]);
  assert.equal(value.total_distance_m, 8579);
  assert.equal(value.total_duration_s, 634);
  assert.match(value.route_id, /^geoapify-[a-f0-9]{20}$/);
});

test("maneuver names map onto the protocol's closed list", () => {
  for (const [type, expected] of [["Straight", "continue"], ["SlightRight", "slight_right"], ["SharpLeft", "sharp_left"],
    ["TurnAroundLeft", "u_turn_left"], ["StayRight", "slight_right"], ["ExitLeft", "slight_left"],
    ["MergeRight", "continue"], ["Roundabout", "exit"], ["DestinationReachedLeft", "arrive"],
    ["FerryEnter", "unknown"], ["", "unknown"]]) {
    assert.equal(mapGeoapifyManeuver(type), expected, type);
  }
});

test("a recorded roundabout keeps its exit number and its leaving step", async () => {
  // Real answer recorded 2026-10-20 (key removed): through Praca Panamericana, Sao Paulo.
  const value = transformGeoapifyRoute(await load("geoapify-route-saopaulo-roundabout.json"));
  const roundabout = value.maneuvers.filter((maneuver) => ["roundabout", "exit"].includes(maneuver.type));
  assert.deepEqual(roundabout.map(({ type, roundabout_exit, road_name }) => [type, roundabout_exit, road_name]), [
    ["roundabout", 6, "Praça Panamericana"],
    ["exit", 0, "Avenida Dona Elisa de Moraes Mendes"],
  ]);
});

test("route requests ask for a motorcycle, latitude first, in the rider's language", () => {
  const url = buildGeoapifyRouteUrl(request, { key: KEY, language: geoapifyLanguage("pt-BR,pt;q=0.9") });
  assert.equal(url.searchParams.get("waypoints"), "-23.5505000,-46.6333000|-23.5877126,-46.6585214");
  assert.equal(url.searchParams.get("mode"), "motorcycle");
  assert.equal(url.searchParams.get("lang"), "pt");
  for (const [header, language] of [["en-US", "en"], ["zh-Hans-CN", "en"], ["", "en"], [undefined, "en"]]) {
    assert.equal(geoapifyLanguage(header), language);
  }
});

test("place results keep WGS84, fit the 64-character route field and measure from the rider", () => {
  const value = transformGeoapifyPlaces(places, { keywords: "Ibirapuera", origin: se });
  assert.equal(value.places.length, places.results.length);
  value.places.forEach((place, index) => {
    assert.match(place.id, /^g:[a-f0-9]{32}$/);
    assert.ok(place.id.length <= 64);
    assert.deepEqual(place.location, { coordinate_system: "WGS84",
      longitude_deg: places.results[index].lon, latitude_deg: places.results[index].lat });
    assert.ok(Number.isInteger(place.distance_m) && place.distance_m > 0);
  });
  assert.equal(value.places[0].name, "Vila Jardim Ibirapuera");
  assert.equal(transformGeoapifyPlaces(places, { keywords: "Ibirapuera" }).places[0].distance_m, undefined);
});

test("city results carry Geoapify's own bounding box and drop one without it", () => {
  const value = transformGeoapifyCities(cities);
  assert.deepEqual(value.cities, [{ id: value.cities[0].id, name: "Campinas", scope: "city",
    bounds_wgs84: [-47.2463023, -23.0612161, -46.8152838, -22.7290463] }]);
  const withoutBox = structuredClone(cities);
  delete withoutBox.results[0].bbox;
  assert.deepEqual(transformGeoapifyCities(withoutBox).cities, []);
});

test("no Geoapify failure leaks the key", async () => {
  const failures = [
    async () => new Response(`{"error":"Unauthorized","message":"Invalid apiKey ${KEY}"}`, { status: 401 }),
    async () => new Response("busy", { status: 503 }),
    async (url) => { throw new TypeError(`fetch failed: ${url}`); },
    async () => new Response(`not json ${KEY}`),
  ];
  for (const fetchImpl of failures) {
    const options = { key: KEY, fetchImpl, maxAttempts: 1 };
    for (const call of [
      () => createGeoapifyRouteProvider(options).planRoute(request),
      () => createGeoapifyPlacesProvider(options).searchPlaces({ keywords: "Ibirapuera", origin: se }),
      () => createGeoapifyCitiesProvider(options).searchCities({ keywords: "Campinas" }),
    ]) {
      const error = await call().catch((reason) => reason);
      assert.ok(error instanceof Error);
      assert.match(error.code, /^[A-Z_]+$/);
      assert.doesNotMatch(`${error.message} ${error.stack}`, new RegExp(KEY));
    }
  }
  const unauthorized = await createGeoapifyRouteProvider({ key: KEY, fetchImpl: failures[0], maxAttempts: 1 })
    .planRoute(request).catch((reason) => reason);
  assert.deepEqual([unauthorized.code, unauthorized.retryable], ["PROVIDER_HTTP_ERROR", false]);
});

test("the recorded route goes through the provider unchanged", async () => {
  let asked;
  const provider = createGeoapifyRouteProvider({ key: KEY, clock: () => 5,
    fetchImpl: async (url) => { asked = new URL(url); return Response.json(route); } });
  const options = await provider.planRouteOptions(request, { acceptLanguage: "pt-BR" });
  assert.equal(options.length, 1, "Geoapify ignores alternatives: one honest candidate");
  assert.deepEqual(options[0], transformGeoapifyRoute(route, { generatedAtMs: 5 }));
  assert.equal(asked.searchParams.get("apiKey"), KEY);
  assert.equal(asked.searchParams.get("lang"), "pt");
});
