(function () {
  "use strict";

  // Messages come from i18n/messages.js, generated from shared/i18n/catalog.json.
  const STORAGE_KEY = "moto-gps.language";
  const SUPPORTED = ["en-US", "pt-BR", "zh-Hans"];
  const PSEUDO = "qps-ploc";
  const FALLBACK = "en-US";
  const messages = window.MotoMessages ?? {};

  /** Maps any BCP 47 tag to a supported language, or null. */
  function supportedLanguage(tag) {
    if (!tag) return null;
    if (tag === PSEUDO) return PSEUDO;
    let locale;
    try {
      locale = new Intl.Locale(tag).maximize();
    } catch {
      return null;
    }
    if (locale.language === "pt") return "pt-BR";
    if (locale.language === "zh") return "zh-Hans";
    if (locale.language === "en") return "en-US";
    return null;
  }

  /** ?lang= wins, then the choice saved in Settings, then the browser. */
  function negotiate(query, stored, preferred) {
    return supportedLanguage(query) ??
      supportedLanguage(stored) ??
      (preferred ?? []).map(supportedLanguage).find(Boolean) ??
      FALLBACK;
  }

  function readChoice() {
    try {
      return window.localStorage.getItem(STORAGE_KEY);
    } catch {
      return null;
    }
  }

  const browserLanguages = navigator.languages?.length ? navigator.languages : [navigator.language];
  const storedChoice = readChoice();
  const query = new URLSearchParams(window.location.search).get("lang");
  const browserLanguage = negotiate(null, null, browserLanguages);
  let choice = supportedLanguage(storedChoice) ? storedChoice : "system";
  let language;
  let formatLocale;
  let pluralRules;

  function use(tag) {
    language = tag;
    // The pseudo-locale only changes text; numbers keep English conventions.
    formatLocale = language === PSEUDO ? FALLBACK : language;
    pluralRules = new Intl.PluralRules(formatLocale);
  }

  use(negotiate(query, storedChoice, browserLanguages));

  function lookup(key) {
    return messages[language]?.[key] ?? messages[FALLBACK]?.[key] ?? key;
  }

  /**
   * Values are rendered in the language in use: numbers are formatted here and
   * a value { key, values } is itself a message.
   */
  function t(key, values = {}) {
    return lookup(key).replace(/\{([a-z_]+)\}/g, (match, name) => {
      if (!Object.prototype.hasOwnProperty.call(values, name)) return match;
      const value = values[name];
      if (typeof value === "number") return number(value);
      if (value?.key) return t(value.key, value.values);
      return String(value);
    });
  }

  function number(value, options) {
    return new Intl.NumberFormat(formatLocale, options).format(value);
  }

  /** Picks key.one / key.many / key.other by the language's CLDR rules. */
  function plural(key, count, values = {}) {
    const specific = `${key}.${pluralRules.select(count)}`;
    const exists = (messages[language]?.[specific] ?? messages[FALLBACK]?.[specific]) !== undefined;
    const chosen = exists ? specific : `${key}.other`;
    return t(chosen, { ...values, count: number(count) });
  }

  function distance(meters) {
    const value = Number(meters);
    if (!Number.isFinite(value)) return "--";
    if (value >= 1000) {
      return number(value / 1000, {
        style: "unit", unit: "kilometer", unitDisplay: "short",
        maximumFractionDigits: value >= 10000 ? 0 : 1,
      });
    }
    return number(Math.max(0, Math.round(value)), { style: "unit", unit: "meter", unitDisplay: "short" });
  }

  function duration(seconds) {
    const minutes = Math.max(0, Math.round(Number(seconds ?? 0) / 60));
    const hours = Math.floor(minutes / 60);
    const rest = minutes % 60;
    if (typeof Intl.DurationFormat === "function") {
      return new Intl.DurationFormat(formatLocale, { style: "short" })
        .format(hours ? { hours, minutes: rest } : { minutes: rest });
    }
    return hours
      ? t("web.duration.hours_minutes", { hours: number(hours), minutes: number(rest) })
      : t("web.duration.minutes", { minutes: number(rest) });
  }

  function time(date) {
    return date.toLocaleTimeString(formatLocale, { hour: "2-digit", minute: "2-digit" });
  }

  /** A language's own name, e.g. "português (Brasil)". */
  function languageName(tag) {
    const name = new Intl.DisplayNames([tag], { type: "language", languageDisplay: "standard" }).of(tag) ?? tag;
    return name.charAt(0).toLocaleUpperCase(tag) + name.slice(1);
  }

  function render(element) {
    const values = element.dataset.i18nValues ? JSON.parse(element.dataset.i18nValues) : {};
    element.textContent = element.dataset.i18nPlural === undefined
      ? t(element.dataset.i18n, values)
      : plural(element.dataset.i18n, Number(element.dataset.i18nPlural), values);
  }

  /**
   * Shows a message and keeps its key and values on the element, so apply()
   * renders it again in a new language. A falsy key clears the element.
   */
  function show(element, key, values) {
    delete element.dataset.i18nPlural;
    if (!key) {
      showVerbatim(element, "");
      return;
    }
    element.dataset.i18n = key;
    if (values) element.dataset.i18nValues = JSON.stringify(values);
    else delete element.dataset.i18nValues;
    render(element);
  }

  function showPlural(element, key, count) {
    show(element, key);
    element.dataset.i18nPlural = String(count);
    render(element);
  }

  /** Data such as a place name, which no language change touches. */
  function showVerbatim(element, text) {
    delete element.dataset.i18n;
    delete element.dataset.i18nValues;
    delete element.dataset.i18nPlural;
    element.textContent = text;
  }

  /**
   * Renders every message in the page: data-i18n (with data-i18n-values and
   * data-i18n-plural from show()) sets the text, data-i18n-attr lists
   * "attribute:key" pairs separated by ";".
   */
  function apply(root = document) {
    for (const element of root.querySelectorAll("[data-i18n]")) render(element);
    for (const element of root.querySelectorAll("[data-i18n-attr]")) {
      for (const pair of element.dataset.i18nAttr.split(";")) {
        const [attribute, key] = pair.split(":");
        element.setAttribute(attribute.trim(), t(key.trim()));
      }
    }
    if (root === document) {
      document.documentElement.lang = formatLocale;
      document.title = t("web.title");
      document.querySelector('meta[name="description"]')?.setAttribute("content", t("web.description"));
    }
  }

  /**
   * "system" follows the browser. Applies at once without reloading: the page
   * is rendered again and "moto-languagechange" lets the app redraw what it
   * formats itself (numbers, the round display).
   */
  function setChoice(next) {
    choice = next === "system" || !supportedLanguage(next) ? "system" : next;
    try {
      if (choice === "system") window.localStorage.removeItem(STORAGE_KEY);
      else window.localStorage.setItem(STORAGE_KEY, choice);
    } catch {
      // Not saved (private mode); the choice still applies to this page.
    }
    use(negotiate(null, choice === "system" ? null : choice, browserLanguages));
    apply();
    window.dispatchEvent(new CustomEvent("moto-languagechange", { detail: { language } }));
  }

  window.MotoI18n = Object.freeze({
    get language() { return language; },
    browserLanguage,
    get choice() { return choice; },
    supported: SUPPORTED,
    /** For the round display (BCP 47) and speech synthesis. */
    get deviceLanguage() { return formatLocale; },
    get speechLanguage() { return formatLocale === "zh-Hans" ? "zh-CN" : formatLocale; },
    t,
    show,
    showPlural,
    showVerbatim,
    plural,
    distance,
    duration,
    time,
    languageName,
    apply,
    setChoice,
  });
})();
