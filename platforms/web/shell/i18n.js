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
  const language = negotiate(query, storedChoice, browserLanguages);
  const browserLanguage = negotiate(null, null, browserLanguages);
  // The pseudo-locale only changes text; numbers keep English conventions.
  const formatLocale = language === PSEUDO ? FALLBACK : language;
  const pluralRules = new Intl.PluralRules(formatLocale);

  function lookup(key) {
    return messages[language]?.[key] ?? messages[FALLBACK]?.[key] ?? key;
  }

  function t(key, values = {}) {
    return lookup(key).replace(/\{([a-z_]+)\}/g, (match, name) =>
      Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : match);
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

  /**
   * Fills static HTML: data-i18n sets the text, data-i18n-attr lists
   * "attribute:key" pairs separated by ";".
   */
  function apply(root = document) {
    for (const element of root.querySelectorAll("[data-i18n]")) {
      element.textContent = t(element.dataset.i18n);
    }
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

  /** "system" follows the browser; reloads so every text uses one language. */
  function setChoice(choice) {
    try {
      if (choice === "system") window.localStorage.removeItem(STORAGE_KEY);
      else window.localStorage.setItem(STORAGE_KEY, choice);
    } catch {
      return;
    }
    window.location.reload();
  }

  window.MotoI18n = Object.freeze({
    language,
    browserLanguage,
    choice: supportedLanguage(storedChoice) ? storedChoice : "system",
    supported: SUPPORTED,
    /** For the round display (BCP 47) and speech synthesis. */
    deviceLanguage: formatLocale,
    speechLanguage: formatLocale === "zh-Hans" ? "zh-CN" : formatLocale,
    t,
    plural,
    number,
    distance,
    duration,
    time,
    languageName,
    apply,
    setChoice,
    negotiate,
  });
})();
