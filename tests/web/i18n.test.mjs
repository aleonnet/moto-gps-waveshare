// Runs the Web shell's i18n.js with its generated messages in a sandbox that
// stands in for the browser: navigator languages, ?lang= and saved choice.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const shell = new URL("../../platforms/web/shell/", import.meta.url);
const sources = ["i18n/messages.js", "i18n.js"].map((file) => readFileSync(new URL(file, shell), "utf8"));

function load({ languages = ["en-US"], search = "", stored = null } = {}) {
  const storage = new Map(stored ? [["moto-gps.language", stored]] : []);
  const window = {
    location: { search, reload() {} },
    localStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: (key) => storage.delete(key),
    },
  };
  const context = vm.createContext({
    window, navigator: { languages, language: languages[0] }, URLSearchParams, Intl, Object, String, Math, Number,
  });
  for (const source of sources) vm.runInContext(source, context);
  return { i18n: window.MotoI18n, storage };
}

test("browser languages map to the supported language of each family", () => {
  assert.equal(load({ languages: ["pt-PT", "en"] }).i18n.language, "pt-BR");
  assert.equal(load({ languages: ["zh-CN"] }).i18n.language, "zh-Hans");
  assert.equal(load({ languages: ["zh-TW"] }).i18n.language, "zh-Hans");
  assert.equal(load({ languages: ["de-DE", "en-GB"] }).i18n.language, "en-US");
  assert.equal(load({ languages: ["de-DE", "fr"] }).i18n.language, "en-US");
});

test("?lang= wins over the saved choice, which wins over the browser", () => {
  assert.equal(load({ languages: ["en-US"], stored: "zh-Hans" }).i18n.language, "zh-Hans");
  assert.equal(load({ languages: ["en-US"], stored: "zh-Hans", search: "?lang=pt-BR" }).i18n.language, "pt-BR");
  assert.equal(load({ languages: ["en-US"], stored: "nonsense" }).i18n.language, "en-US");
  assert.equal(load({ search: "?lang=qps-ploc" }).i18n.language, "qps-ploc");
});

test("messages fill parameters and fall back to English, then to the key", () => {
  const { i18n } = load({ languages: ["pt-BR"] });
  assert.equal(i18n.t("web.status.located", { meters: 5 }), "Localizado · ±5 m");
  assert.equal(i18n.t("web.does.not.exist"), "web.does.not.exist");
  assert.equal(load({ languages: ["zh-Hans"] }).i18n.t("web.setup.title"), "去哪儿？");
});

test("plural forms follow CLDR: 0 is 'one' in Portuguese, 'other' in English", () => {
  const pt = load({ languages: ["pt-BR"] }).i18n;
  assert.equal(pt.plural("web.search.found", 0), "0 lugar encontrado");
  assert.equal(pt.plural("web.search.found", 1), "1 lugar encontrado");
  assert.equal(pt.plural("web.search.found", 2), "2 lugares encontrados");
  const en = load({ languages: ["en-US"] }).i18n;
  assert.equal(en.plural("web.search.found", 0), "0 places found");
  assert.equal(en.plural("web.search.found", 1), "1 place found");
  assert.equal(load({ languages: ["zh-Hans"] }).i18n.plural("web.search.found", 1), "找到 1 个地点");
  assert.equal(en.plural("web.search.found", 1000000), "1,000,000 places found");
});

test("distances and durations use each language's conventions", () => {
  const pt = load({ languages: ["pt-BR"] }).i18n;
  const en = load({ languages: ["en-US"] }).i18n;
  const zh = load({ languages: ["zh-Hans"] }).i18n;
  assert.equal(pt.distance(1234), "1,2 km");
  assert.equal(en.distance(1234), "1.2 km");
  assert.equal(zh.distance(1234), "1.2公里");
  assert.equal(pt.distance(850), "850 m");
  assert.equal(pt.distance("x"), "--");
  assert.equal(zh.duration(65 * 60), "1小时5分钟");
  assert.equal(en.duration(13 * 60), "13 min");
  assert.equal(pt.speechLanguage, "pt-BR");
  assert.equal(zh.speechLanguage, "zh-CN");
});

test("the pseudo-locale keeps parameters and marks every message", () => {
  const { i18n } = load({ search: "?lang=qps-ploc" });
  const text = i18n.t("web.status.located", { meters: 5 });
  assert.match(text, /^\[.*5.*~+\]$/);
  assert.equal(i18n.deviceLanguage, "en-US");
});

test("choosing System removes the saved language", () => {
  const { i18n, storage } = load({ stored: "pt-BR" });
  assert.equal(i18n.choice, "pt-BR");
  i18n.setChoice("system");
  assert.equal(storage.has("moto-gps.language"), false);
  i18n.setChoice("zh-Hans");
  assert.equal(storage.get("moto-gps.language"), "zh-Hans");
});
