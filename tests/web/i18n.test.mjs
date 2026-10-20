// Runs the Web shell's i18n.js with its generated messages in a sandbox that
// stands in for the browser: navigator languages, ?lang= and saved choice.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import vm from "node:vm";

const shell = new URL("../../platforms/web/shell/", import.meta.url);
const sources = ["i18n/messages.js", "i18n.js"].map((file) => readFileSync(new URL(file, shell), "utf8"));

/** Stands in for a DOM element: only what show() and apply() touch. */
function element() {
  return { dataset: {}, textContent: "" };
}

function load({ languages = ["en-US"], search = "", stored = null } = {}) {
  const storage = new Map(stored ? [["moto-gps.language", stored]] : []);
  const events = [];
  const elements = [];
  const window = {
    location: {
      search,
      reload() { throw new Error("the page reloaded"); },
    },
    localStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: (key) => storage.delete(key),
    },
    dispatchEvent: (event) => events.push(event),
  };
  const document = {
    documentElement: {},
    title: "",
    querySelector: () => null,
    querySelectorAll: (selector) => selector === "[data-i18n]"
      ? elements.filter((item) => item.dataset.i18n !== undefined)
      : [],
  };
  const context = vm.createContext({
    window, document, CustomEvent, navigator: { languages, language: languages[0] },
    URLSearchParams, Intl, Object, String, Math, Number, JSON,
  });
  for (const source of sources) vm.runInContext(source, context);
  const add = () => {
    const item = element();
    elements.push(item);
    return item;
  };
  return { i18n: window.MotoI18n, storage, events, document, add };
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

test("choosing a language applies at once and redraws shown messages", () => {
  const { i18n, events, document, add } = load({ languages: ["en-US"] });
  const located = add();
  const found = add();
  const runtime = add();
  const place = add();
  i18n.show(located, "web.status.located", { meters: 1234 });
  i18n.showPlural(found, "web.search.found", 2);
  i18n.show(runtime, "web.status.lvgl_state", { state: { key: "web.state.navigating" } });
  i18n.showVerbatim(place, "Praça da Sé");
  assert.equal(located.textContent, "Located · ±1,234 m");
  assert.equal(runtime.textContent, "LVGL running · Navigating");

  i18n.setChoice("pt-BR");
  assert.equal(i18n.language, "pt-BR");
  assert.equal(i18n.choice, "pt-BR");
  assert.equal(i18n.deviceLanguage, "pt-BR");
  assert.equal(located.textContent, "Localizado · ±1.234 m");
  assert.equal(found.textContent, "2 lugares encontrados");
  assert.equal(runtime.textContent, "LVGL em execução · Navegando");
  assert.equal(place.textContent, "Praça da Sé");
  assert.equal(document.title, "MOTO GPS · Navegação no celular");
  assert.equal(document.documentElement.lang, "pt-BR");
  assert.equal(events.length, 1);
  assert.equal(events[0].type, "moto-languagechange");
  assert.equal(events[0].detail.language, "pt-BR");

  i18n.setChoice("system");
  assert.equal(i18n.language, "en-US");
  assert.equal(found.textContent, "2 places found");
});

test("clearing a message leaves nothing for a language change to restore", () => {
  const { i18n, add } = load({ languages: ["en-US"] });
  const alert = add();
  i18n.show(alert, "web.ride.offline");
  i18n.show(alert, null);
  i18n.setChoice("zh-Hans");
  assert.equal(alert.textContent, "");
});
