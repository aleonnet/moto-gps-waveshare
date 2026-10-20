import { createHash } from "node:crypto";

import { wgs84ToGcj02 } from "./coordinates.js";
import {
  compactText,
  fetchGeoapifyJson,
  geoapifyLanguage,
  GeoapifyError,
  requireGeoapifyKey,
} from "./geoapify-places.js";

const DEFAULT_ENDPOINT = "https://api.geoapify.com/v1/routing";
const MAX_POLYLINE_POINTS = 8192;
const MAX_MANEUVERS = 512;
// A 5,737-point SP-Rio answer measured 151 KB; long trips with instruction details stay far below.
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;

// Geoapify instruction_details.type, as listed in its Routing API reference.
const MANEUVER_TYPES = new Map([
  ["Straight", "continue"], ["Merge", "continue"], ["MergeRight", "continue"], ["MergeLeft", "continue"],
  ["SlightRight", "slight_right"], ["Right", "right"], ["SharpRight", "sharp_right"],
  ["SlightLeft", "slight_left"], ["Left", "left"], ["SharpLeft", "sharp_left"],
  ["TurnAroundRight", "u_turn_right"], ["TurnAroundLeft", "u_turn_left"],
  ["ExitRight", "slight_right"], ["StayRight", "slight_right"],
  ["ExitLeft", "slight_left"], ["StayLeft", "slight_left"],
  ["Roundabout", "roundabout"],
]);

export function mapGeoapifyManeuver(type) {
  const value = String(type ?? "");
  if (value.startsWith("DestinationReached")) return "arrive";
  return MANEUVER_TYPES.get(value) ?? "unknown";
}

function rounded(value, digits = 2) {
  return Number(value.toFixed(digits));
}

export function buildGeoapifyRouteUrl(request, { key, endpoint = DEFAULT_ENDPOINT, language = "en" } = {}) {
  requireGeoapifyKey(key);
  const url = new URL(endpoint);
  const point = ({ latitude_deg, longitude_deg }) => `${Number(latitude_deg).toFixed(7)},${Number(longitude_deg).toFixed(7)}`;
  url.searchParams.set("waypoints", `${point(request.origin)}|${point(request.destination)}`);
  url.searchParams.set("mode", "motorcycle");
  url.searchParams.set("details", "instruction_details");
  url.searchParams.set("lang", language);
  url.searchParams.set("apiKey", key);
  return url;
}

/**
 * Converts a Geoapify routing response into protocol v1. Geoapify answers in WGS84; the route
 * crosses the same wgs84ToGcj02 boundary as map tiles, so the bundle keeps its GCJ-02 frame (the
 * transform is the identity outside the GCJ-02 rectangle).
 */
export function transformGeoapifyRoute(payload, { generatedAtMs = Date.now() } = {}) {
  const feature = Array.isArray(payload?.features) ? payload.features[0] : null;
  const geometry = feature?.geometry;
  if (!feature || !geometry) throw new GeoapifyError("NO_ROUTE", "Geoapify returned no usable route", { retryable: false });
  const lines = geometry.type === "LineString" ? [geometry.coordinates]
    : geometry.type === "MultiLineString" ? geometry.coordinates : null;
  if (!Array.isArray(lines)) throw new GeoapifyError("INVALID_POLYLINE", "Geoapify route geometry is invalid");

  const polyline = [];
  for (const line of lines) {
    for (const coordinate of Array.isArray(line) ? line : []) {
      const [longitudeDeg, latitudeDeg] = Array.isArray(coordinate) ? coordinate.map(Number) : [];
      if (!Number.isFinite(longitudeDeg) || !Number.isFinite(latitudeDeg) ||
          Math.abs(longitudeDeg) > 180 || Math.abs(latitudeDeg) > 90) {
        throw new GeoapifyError("INVALID_POLYLINE", "Geoapify returned an invalid route point");
      }
      const { longitude_deg, latitude_deg } = wgs84ToGcj02({ longitude_deg: longitudeDeg, latitude_deg: latitudeDeg });
      const previous = polyline.at(-1);
      if (previous?.longitude_deg !== longitude_deg || previous?.latitude_deg !== latitude_deg) {
        polyline.push({ longitude_deg, latitude_deg });
      }
    }
  }
  if (polyline.length < 2) throw new GeoapifyError("INVALID_POLYLINE", "Geoapify route has fewer than two points");

  const maneuvers = [];
  let routeOffsetM = 0;
  const legs = Array.isArray(feature.properties?.legs) ? feature.properties.legs : [];
  for (const leg of legs) {
    for (const step of Array.isArray(leg?.steps) ? leg.steps : []) {
      const instruction = step?.instruction ?? {};
      const type = String(instruction.type ?? "");
      // Geoapify describes a step as "perform this action, then travel the step": the maneuver
      // sits at the step's start. The departure itself is not a maneuver.
      if (!type.startsWith("StartAt")) {
        const roundaboutExit = Math.trunc(Number(instruction.roundabout_exit));
        maneuvers.push({
          id: maneuvers.length + 1,
          type: mapGeoapifyManeuver(type),
          route_offset_m: rounded(routeOffsetM),
          road_name: compactText(Array.isArray(instruction.streets) ? instruction.streets[0] : "", 96),
          instruction: compactText(instruction.text, 256),
          roundabout_exit: roundaboutExit >= 1 && roundaboutExit <= 32 ? roundaboutExit : 0,
        });
      }
      routeOffsetM += Math.max(0, Number(step?.distance) || 0);
    }
  }
  if (polyline.length > MAX_POLYLINE_POINTS || maneuvers.length > MAX_MANEUVERS) {
    throw new GeoapifyError("ROUTE_TOO_LARGE", "Geoapify route exceeds protocol v1 limits", { retryable: false });
  }

  const totalDistanceM = Number(feature.properties?.distance) > 0 ? Number(feature.properties.distance) : routeOffsetM;
  if (!(totalDistanceM > 0)) throw new GeoapifyError("NO_ROUTE", "Geoapify returned a zero-length route", { retryable: false });
  const totalDurationS = Math.round(Math.max(0, Number(feature.properties?.time) || 0));
  const signature = JSON.stringify({ totalDistanceM, totalDurationS, polyline });
  return {
    schema_version: 1,
    route_id: `geoapify-${createHash("sha256").update(signature).digest("hex").slice(0, 20)}`,
    provider: "geoapify",
    coordinate_system: "GCJ-02",
    generated_at_ms: Math.max(0, Math.trunc(Number(generatedAtMs) || 0)),
    total_distance_m: rounded(totalDistanceM),
    total_duration_s: totalDurationS,
    polyline,
    maneuvers,
    // Geoapify has no live traffic; its "approximated" model is a static guess.
    traffic: [],
  };
}

export function createGeoapifyRouteProvider({ key, fetchImpl = globalThis.fetch, endpoint = DEFAULT_ENDPOINT,
  timeoutMs = 8000, maxAttempts = 3, retryDelayMs = 100, clock = Date.now } = {}) {
  async function planRoute(request, { signal, acceptLanguage } = {}) {
    const url = buildGeoapifyRouteUrl(request, { key, endpoint, language: geoapifyLanguage(acceptLanguage) });
    const payload = await fetchGeoapifyJson(fetchImpl, url, { timeoutMs, maxAttempts, retryDelayMs, signal,
      label: "routing", maximumBytes: MAX_RESPONSE_BYTES });
    return transformGeoapifyRoute(payload, { generatedAtMs: clock() });
  }
  return {
    planRoute,
    // Geoapify ignores the alternatives parameters (measured): one candidate, honestly.
    async planRouteOptions(request, options = {}) { return [await planRoute(request, options)]; },
  };
}
