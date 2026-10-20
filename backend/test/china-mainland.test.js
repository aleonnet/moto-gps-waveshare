import assert from "node:assert/strict";
import test from "node:test";

import { isInChinaMainland } from "../src/china-mainland.js";

const at = (longitude_deg, latitude_deg) => ({ coordinate_system: "WGS84", longitude_deg, latitude_deg });

test("mainland China picks AMap; its neighbours and special regions do not", () => {
  const mainland = {
    Jinan: at(117.1224488, 36.6748039), Shanghai: at(121.47, 31.23), Urumqi: at(87.62, 43.83),
    // A country outline alone leaves these in the sea or across a border (measured 2026-10-20).
    "Xiamen airport": at(118.128, 24.544), Zhuhai: at(113.58, 22.27), Zhoushan: at(122.207, 29.985),
    "Shenzhen Futian": at(114.06, 22.54), "Pudong airport": at(121.805, 31.144), Dandong: at(124.38, 40.13),
  };
  const elsewhere = {
    "Hong Kong": at(114.17, 22.32), "Hong Kong airport": at(113.92, 22.31), Macau: at(113.54, 22.19),
    Taipei: at(121.56, 25.03), Matsu: at(119.95, 26.16), Seoul: at(126.98, 37.57), Hanoi: at(105.85, 21.03),
    "New Delhi": at(77.21, 28.61), Ulaanbaatar: at(106.92, 47.92), Sinuiju: at(124.4, 40.1),
    Blagoveshchensk: at(127.53, 50.27), "Sao Paulo": at(-46.6333, -23.5505),
  };
  for (const [name, point] of Object.entries(mainland)) assert.equal(isInChinaMainland(point), true, name);
  for (const [name, point] of Object.entries(elsewhere)) assert.equal(isInChinaMainland(point), false, name);
});

test("invalid points are never routed to the mainland provider", () => {
  for (const point of [null, {}, at(Number.NaN, 30), at(117, Number.POSITIVE_INFINITY)]) {
    assert.equal(isInChinaMainland(point), false);
  }
});
