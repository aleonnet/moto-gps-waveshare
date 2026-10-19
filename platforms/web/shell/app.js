(function () {
  "use strict";

  const i18n = window.MotoI18n;
  const { t } = i18n;
  const NAV_STATE = ["web.state.idle", "web.state.acquiring", "web.state.planning",
    "web.state.navigating", "web.state.rerouting", "web.state.arrived"];
  const TRAFFIC_LABEL = ["web.traffic.unknown", "web.traffic.free_flow", "web.traffic.slow",
    "web.traffic.congested", "web.traffic.severe"];
  const MANEUVER = {
    unknown: 0,
    continue: 1,
    slight_left: 2,
    left: 3,
    sharp_left: 4,
    u_turn_left: 5,
    slight_right: 6,
    right: 7,
    sharp_right: 8,
    u_turn_right: 9,
    roundabout: 10,
    exit: 11,
    arrive: 12,
  };
  const TRAFFIC = { unknown: 0, free_flow: 1, slow: 2, congested: 3, severe: 4 };
  const API_BASE = (() => {
    const override = new URLSearchParams(location.search).get("api");
    if (override) return new URL(override, location.href);
    if (["127.0.0.1", "localhost"].includes(location.hostname)) {
      return new URL("http://127.0.0.1:8787/");
    }
    return new URL("./api/", location.href);
  })();
  const LOCAL_DEMO =
    ["127.0.0.1", "localhost"].includes(location.hostname) &&
    new URLSearchParams(location.search).get("demo") === "1";
  const DEVICE_STATE_PREVIEW = (() => {
    const requested = new URLSearchParams(location.search).get("deviceState");
    const states = { offline: 0, connecting: 1, success: 2, ready: 3, planning: 4 };
    return Object.prototype.hasOwnProperty.call(states, requested)
      ? { name: requested, value: states[requested] }
      : null;
  })();
  const LOCAL_TEST_POSITION = (() => {
    if (!["127.0.0.1", "localhost"].includes(location.hostname)) return null;
    const encoded = new URLSearchParams(location.search).get("testPosition");
    if (!encoded) return null;
    const [latitude, longitude] = encoded.split(",").map(Number);
    return Number.isFinite(latitude) && Number.isFinite(longitude)
      ? { latitude, longitude }
      : null;
  })();

  const state = {
    runtime: null,
    runtimeReady: false,
    backendReady: false,
    backendProvider: "unknown",
    currentPosition: null,
    orientationHeading: null,
    destination: null,
    route: null,
    view: "setup",
    navigating: false,
    arrivedAnnounced: false,
    watchId: null,
    wakeLock: null,
    searchController: null,
    searchTimer: 0,
    locationPending: false,
    lastRouteGeneration: 0,
    lastVisibilityPause: false,
    activeRouteRequestId: null,
    activeTrafficRequestId: null,
    mapSceneOverlay: null,
  };

  const elements = {
    setupView: document.querySelector("#setup-view"),
    routeView: document.querySelector("#route-view"),
    navigationView: document.querySelector("#navigation-view"),
    homeButton: document.querySelector("#home-button"),
    systemState: document.querySelector("#system-state"),
    systemStateLabel: document.querySelector("#system-state-label"),
    systemStateDetail: document.querySelector("#system-state-detail"),
    locationCard: document.querySelector("#location-card"),
    locationTitle: document.querySelector("#location-title"),
    locationCopy: document.querySelector("#location-copy"),
    locationButton: document.querySelector("#location-button"),
    searchForm: document.querySelector("#search-form"),
    destinationQuery: document.querySelector("#destination-query"),
    clearSearch: document.querySelector("#clear-search"),
    searchFeedback: document.querySelector("#search-feedback"),
    placeResults: document.querySelector("#place-results"),
    routeBack: document.querySelector("#route-back"),
    routeDestination: document.querySelector("#route-destination"),
    routeDuration: document.querySelector("#route-duration"),
    routeDistance: document.querySelector("#route-distance"),
    routeTraffic: document.querySelector("#route-traffic"),
    routeStatus: document.querySelector("#route-status"),
    startNavigation: document.querySelector("#start-navigation"),
    rideInstrument: document.querySelector("#ride-instrument"),
    previewInstrument: document.querySelector(".instrument--preview"),
    rideDestination: document.querySelector("#ride-destination"),
    rideAlert: document.querySelector("#ride-alert"),
    endNavigation: document.querySelector("#end-navigation"),
    remainingDistance: document.querySelector("#remaining-distance"),
    arrivalTime: document.querySelector("#arrival-time"),
    rideConnection: document.querySelector("#ride-connection"),
    wakeState: document.querySelector("#wake-state"),
    locationAccuracy: document.querySelector("#location-accuracy"),
    statusDialog: document.querySelector("#status-dialog"),
    dialogBackend: document.querySelector("#dialog-backend"),
    dialogRuntime: document.querySelector("#dialog-runtime"),
    dialogLocation: document.querySelector("#dialog-location"),
    dialogNetwork: document.querySelector("#dialog-network"),
    toast: document.querySelector("#toast"),
    canvas: document.querySelector("#canvas"),
    languageSelect: document.querySelector("#language-select"),
    languageNote: document.querySelector("#language-note"),
    credits: document.querySelector("#credits"),
  };

  let placeholderContext = elements.canvas.getContext("2d");
  let toastTimer = 0;

  function drawPlaceholder() {
    if (!placeholderContext) return;
    const context = placeholderContext;
    const scale = elements.canvas.width / 360;
    context.fillStyle = "#050607";
    context.fillRect(0, 0, elements.canvas.width, elements.canvas.height);
    context.save();
    context.scale(scale, scale);
    context.strokeStyle = "#27302f";
    context.lineWidth = 18;
    context.lineCap = "round";
    context.beginPath();
    context.moveTo(180, 260);
    context.lineTo(180, 202);
    context.lineTo(146, 165);
    context.lineTo(213, 96);
    context.stroke();
    context.strokeStyle = "#f4f5ef";
    context.lineWidth = 9;
    context.stroke();
    context.fillStyle = "#f4f5ef";
    context.beginPath();
    context.moveTo(180, 177);
    context.lineTo(165, 208);
    context.lineTo(195, 208);
    context.closePath();
    context.fill();
    context.fillStyle = "#74817e";
    context.textAlign = "center";
    context.font = "700 11px ui-monospace, monospace";
    context.fillText(t("web.runtime.placeholder"), 180, 312);
    context.restore();
  }

  function showToast(message, duration = 2600) {
    window.clearTimeout(toastTimer);
    elements.toast.textContent = message;
    elements.toast.hidden = false;
    toastTimer = window.setTimeout(() => {
      elements.toast.hidden = true;
    }, duration);
  }

  function setFeedback(message, tone = "info") {
    elements.searchFeedback.dataset.tone = tone;
    elements.searchFeedback.textContent = message;
  }

  function setRouteStatus(message, tone = "info") {
    elements.routeStatus.dataset.tone = tone;
    elements.routeStatus.textContent = message;
  }

  function setRideAlert(message) {
    elements.rideAlert.textContent = message;
    elements.rideAlert.hidden = !message;
  }

  function setWakeState(key) {
    const dot = document.createElement("i");
    elements.wakeState.replaceChildren(dot, ` ${t(key)}`);
  }

  function networkText() {
    return t(navigator.onLine ? "web.network.online" : "web.network.offline");
  }

  /** Fills a message whose {name} parameters are DOM nodes (links). */
  function renderTemplate(element, key, nodes) {
    const parts = t(key).split(/\{([a-z_]+)\}/);
    element.replaceChildren(...parts.map((part, index) =>
      index % 2 === 1 && nodes[part] ? nodes[part] : part));
  }

  function link(href, text) {
    const anchor = document.createElement("a");
    anchor.href = href;
    anchor.textContent = text;
    return anchor;
  }

  function setupLanguageSettings() {
    const options = ["system", ...i18n.supported].map((value) => {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value === "system"
        ? t("web.status.language_system", { language: i18n.languageName(i18n.browserLanguage) })
        : i18n.languageName(value);
      option.selected = value === i18n.choice;
      return option;
    });
    elements.languageSelect.replaceChildren(...options);
    elements.languageSelect.addEventListener("change", () => {
      if (!state.navigating) i18n.setChoice(elements.languageSelect.value);
    });
    const repository = "https://github.com/mx3353672833-debug/moto-gps-waveshare";
    renderTemplate(elements.credits, "web.status.author", {
      author: link(repository, "Maler X"),
      license: link(`${repository}/blob/main/LICENSE.md`, t("web.status.license")),
    });
  }

  function setView(view) {
    state.view = view;
    document.body.dataset.view = view;
    elements.setupView.hidden = view !== "setup";
    elements.routeView.hidden = view !== "route";
    elements.navigationView.hidden = view !== "navigation";
    const ring = document.querySelector(".screen-ring");
    if (ring && view === "navigation") elements.rideInstrument.append(ring);
    if (ring && view === "route") elements.previewInstrument.append(ring);
    window.scrollTo({ top: 0, behavior: "instant" });
    // A language change reloads the page, so it waits until the ride ends.
    elements.languageSelect.disabled = state.navigating;
    elements.languageNote.hidden = !state.navigating;
  }

  function updateSystemState() {
    let label = t("web.system.ready");
    let detail = t("web.system.ready_detail");
    let tone = "ready";

    if (!state.backendReady) {
      label = t("web.system.no_service");
      detail = t(["fixture", "disabled"].includes(state.backendProvider)
        ? "web.system.needs_key" : "web.system.route_api_down");
      tone = "error";
    } else if (!state.runtimeReady) {
      label = t("web.system.loading_screen");
      detail = t("web.system.loading_screen_detail");
      tone = "loading";
    } else if (!state.currentPosition) {
      label = t(state.locationPending ? "web.system.locating" : "web.system.waiting_location");
      detail = t("web.system.enable_location");
      tone = "loading";
    }

    elements.systemState.dataset.tone = tone;
    elements.systemStateLabel.textContent = label;
    elements.systemStateDetail.textContent = detail;
    elements.dialogBackend.textContent = t(state.backendReady ? "web.status.amap_connected" : "web.status.amap_unusable");
    elements.dialogRuntime.textContent = t(state.runtimeReady ? "web.status.lvgl_running" : "web.status.loading");
    elements.dialogLocation.textContent = state.currentPosition
      ? t("web.status.located", { meters: i18n.number(Math.round(state.currentPosition.coords.accuracy)) })
      : t("web.status.not_allowed");
    elements.dialogNetwork.textContent = networkText();

    const canSearch = state.backendReady && state.runtimeReady && Boolean(state.currentPosition);
    elements.destinationQuery.disabled = !canSearch;
    if (canSearch && document.activeElement !== elements.destinationQuery && state.view === "setup") {
      elements.destinationQuery.placeholder = t("web.search.placeholder");
    }
  }

  async function fetchJson(url, options = {}) {
    const response = await fetch(url, {
      cache: "no-store",
      ...options,
      headers: { Accept: "application/json", ...(options.headers ?? {}) },
    });
    let body;
    try {
      body = await response.json();
    } catch {
      throw new Error(t("web.error.unreadable", { status: response.status }));
    }
    if (!response.ok) {
      const error = new Error(body?.error?.message || t("web.error.request_failed", { status: response.status }));
      error.code = body?.error?.code;
      error.retryable = body?.error?.retryable;
      throw error;
    }
    return body;
  }

  async function checkBackend() {
    if (LOCAL_DEMO) {
      state.backendProvider = "fixture";
      state.backendReady = true;
      updateSystemState();
      return;
    }
    try {
      const health = await fetchJson(new URL("healthz", API_BASE));
      state.backendProvider = String(health.provider ?? "unknown");
      state.backendReady = health.ready_for_live_navigation === true;
      if (!state.backendReady) {
        setFeedback(t("web.backend.needs_key"), "error");
      }
    } catch {
      state.backendProvider = "offline";
      state.backendReady = false;
      setFeedback(t("web.backend.offline"), "error");
    }
    updateSystemState();
  }

  function normalizeHeading(coords) {
    if (Number.isFinite(coords.heading) && Number(coords.speed ?? 0) >= 1) {
      return Number(coords.heading);
    }
    if (Number.isFinite(state.orientationHeading)) return state.orientationHeading;
    return 0;
  }

  function feedPosition(position) {
    state.currentPosition = position;
    state.locationPending = false;
    const accuracy = Math.round(position.coords.accuracy);
    elements.locationCard.classList.add("is-ready");
    elements.locationTitle.textContent = t(accuracy <= 25 ? "web.location.locked" : "web.location.low_accuracy");
    elements.locationCopy.textContent = t(accuracy > 50 ? "web.location.accuracy_wait" : "web.location.accuracy_live",
      { meters: i18n.number(accuracy) });
    elements.locationButton.textContent = t("web.location.again");
    elements.locationAccuracy.textContent = `GPS ${i18n.distance(accuracy)}`;
    elements.dialogLocation.textContent = t("web.status.located", { meters: i18n.number(accuracy) });

    if (state.runtimeReady) {
      const coords = position.coords;
      state.runtime.fix(
        coords.latitude,
        coords.longitude,
        coords.accuracy,
        Number.isFinite(coords.speed) ? coords.speed : 0,
        normalizeHeading(coords),
        position.timestamp || Date.now(),
      );
    }
    updateSystemState();
  }

  function locationErrorMessage(error) {
    if (error?.code === 1) return t("web.location.denied");
    if (error?.code === 2) return t("web.location.unavailable");
    if (error?.code === 3) return t("web.location.timeout");
    return t("web.location.failed");
  }

  function onLocationError(error) {
    state.locationPending = false;
    elements.locationCard.classList.remove("is-ready");
    elements.locationTitle.textContent = t("web.location.failed_title");
    elements.locationCopy.textContent = locationErrorMessage(error);
    elements.locationButton.textContent = t("web.location.retry");
    setFeedback(locationErrorMessage(error), "error");
    updateSystemState();
  }

  function positionOptions() {
    return { enableHighAccuracy: true, maximumAge: 1000, timeout: 12000 };
  }

  function startPositionWatch() {
    if (state.watchId !== null) navigator.geolocation.clearWatch(state.watchId);
    state.watchId = navigator.geolocation.watchPosition(feedPosition, onLocationError, positionOptions());
  }

  function requestLocation() {
    if (LOCAL_TEST_POSITION) {
      const position = {
        coords: {
          latitude: LOCAL_TEST_POSITION.latitude,
          longitude: LOCAL_TEST_POSITION.longitude,
          accuracy: 4,
          speed: 12,
          heading: 35,
        },
        timestamp: Date.now(),
      };
      feedPosition(position);
      setFeedback(t("web.location.test_ready"), "info");
      elements.destinationQuery.focus({ preventScroll: true });
      return;
    }
    if (!window.isSecureContext || !navigator.geolocation) {
      onLocationError({ code: 0 });
      elements.locationCopy.textContent = t("web.location.needs_https");
      return;
    }
    state.locationPending = true;
    elements.locationTitle.textContent = t("web.location.locking");
    elements.locationCopy.textContent = t("web.location.allow_precise");
    elements.locationButton.textContent = t("web.location.locating_button");
    updateSystemState();
    navigator.geolocation.getCurrentPosition(
      (position) => {
        feedPosition(position);
        startPositionWatch();
        if (state.backendReady && state.runtimeReady) {
          setFeedback(t("web.location.ready"), "info");
          elements.destinationQuery.focus({ preventScroll: true });
        }
      },
      onLocationError,
      positionOptions(),
    );
  }

  function renderPlaces(places) {
    elements.placeResults.replaceChildren();
    for (const [index, place] of places.entries()) {
      const item = document.createElement("li");
      item.className = "place-result";
      const button = document.createElement("button");
      button.type = "button";
      const indexLabel = document.createElement("span");
      indexLabel.className = "result-index";
      indexLabel.textContent = String(index + 1).padStart(2, "0");
      const copy = document.createElement("span");
      copy.className = "result-copy";
      const name = document.createElement("b");
      name.textContent = place.name || t("web.place.unnamed");
      const address = document.createElement("span");
      address.textContent = [place.display_area, place.address].filter(Boolean).join(" · ") || t("web.place.no_address");
      const arrow = document.createElement("span");
      arrow.className = "result-arrow";
      arrow.textContent = "›";
      copy.append(name, address);
      button.append(indexLabel, copy, arrow);
      button.addEventListener("click", () => selectDestination(place));
      item.append(button);
      elements.placeResults.append(item);
    }
  }

  async function searchPlaces(rawQuery) {
    const query = String(rawQuery ?? "").trim();
    elements.clearSearch.hidden = query.length === 0;
    if (query.length < 2) {
      if (state.searchController) state.searchController.abort();
      elements.placeResults.replaceChildren();
      setFeedback(t(query.length ? "web.search.min_chars" : "web.search.prompt"), "info");
      return;
    }
    if (!state.backendReady) {
      setFeedback(t("web.search.no_service"), "error");
      return;
    }

    if (state.searchController) state.searchController.abort();
    state.searchController = new AbortController();
    setFeedback(t("web.search.searching"), "loading");
    try {
      const url = new URL("v1/places", API_BASE);
      url.searchParams.set("keywords", query);
      const result = await fetchJson(url, { signal: state.searchController.signal });
      renderPlaces(Array.isArray(result.places) ? result.places : []);
      setFeedback(result.places?.length
        ? i18n.plural("web.search.found", result.places.length)
        : t("web.search.none"), "info");
    } catch (error) {
      if (error?.name === "AbortError") return;
      elements.placeResults.replaceChildren();
      setFeedback(t(error?.code === "SERVER_MISCONFIGURED" ? "web.search.no_key" : "web.search.failed"), "error");
    }
  }

  function currentFix() {
    if (!state.currentPosition) return null;
    return {
      coordinate_system: "WGS84",
      longitude_deg: state.currentPosition.coords.longitude,
      latitude_deg: state.currentPosition.coords.latitude,
    };
  }

  function selectedDestinationPoint() {
    return state.destination?.location ?? null;
  }

  function routeRequestBody(command) {
    const destination = selectedDestinationPoint();
    return {
      protocol_version: 1,
      request_id: command.requestId,
      route_mode: "driving",
      origin: {
        coordinate_system: "WGS84",
        longitude_deg: command.origin.longitude,
        latitude_deg: command.origin.latitude,
      },
      destination: {
        coordinate_system: "WGS84",
        longitude_deg: command.destination.longitude,
        latitude_deg: command.destination.latitude,
      },
      is_reroute: Boolean(command.isReroute),
      ...(state.route?.route_id ? { previous_route_id: state.route.route_id } : {}),
      ...(state.destination?.id ? { destination_poi_id: state.destination.id } : {}),
    };
  }

  function feedRouteToRuntime(requestId, route) {
    state.runtime.routeBegin(
      requestId,
      String(route.route_id ?? ""),
      Number(route.total_distance_m ?? 0),
      Number(route.total_duration_s ?? 0),
      Number(route.generated_at_ms ?? Date.now()),
    );
    for (const point of route.polyline ?? []) {
      state.runtime.routeAddPoint(Number(point.latitude_deg), Number(point.longitude_deg));
    }
    for (const maneuver of route.maneuvers ?? []) {
      state.runtime.routeAddManeuver(
        Number(maneuver.id ?? 0),
        MANEUVER[maneuver.type] ?? MANEUVER.unknown,
        Number(maneuver.route_offset_m ?? 0),
        String(maneuver.road_name ?? ""),
        String(maneuver.instruction ?? ""),
        Number(maneuver.roundabout_exit ?? 0),
      );
    }
    for (const segment of route.traffic ?? []) {
      state.runtime.routeAddTraffic(
        Number(segment.start_offset_m ?? 0),
        Number(segment.end_offset_m ?? 0),
        TRAFFIC[segment.level] ?? TRAFFIC.unknown,
      );
    }
    state.runtime.routeCommit(Date.now());
  }

  function trafficLabel(route) {
    let severity = 0;
    for (const segment of route?.traffic ?? []) {
      severity = Math.max(severity, TRAFFIC[segment.level] ?? 0);
    }
    return t(TRAFFIC_LABEL[severity]);
  }

  function updateRouteSummary(route) {
    elements.routeDuration.textContent = i18n.duration(route.total_duration_s);
    elements.routeDistance.textContent = i18n.distance(route.total_distance_m);
    elements.routeTraffic.textContent = trafficLabel(route);
  }

  async function handleRouteRequest(command) {
    if (!state.destination || !state.runtime) return;
    state.activeRouteRequestId = Number(command.requestId);
    if (command.isReroute) {
      if (state.navigating) setRideAlert(t("web.route.off_route"));
      setRouteStatus(t("web.route.rerouting_status"));
    } else {
      setRouteStatus(t("web.route.planning_traffic"));
    }

    try {
      const envelope = await fetchJson(new URL("v1/routes", API_BASE), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(routeRequestBody(command)),
      });
      if (state.activeRouteRequestId !== Number(command.requestId)) return;
      if (Number(envelope.request_id) !== Number(command.requestId)) {
        throw new Error("route response request_id mismatch");
      }
      state.activeRouteRequestId = null;
      state.route = envelope.route;
      feedRouteToRuntime(command.requestId, envelope.route);
      updateRouteSummary(envelope.route);
      elements.startNavigation.disabled = false;
      setRouteStatus(t(command.isReroute ? "web.route.replanned" : "web.route.generated"), "info");
      if (state.navigating) {
        setRideAlert("");
        showToast(t(command.isReroute ? "web.route.switched" : "web.route.updated"));
      }
    } catch (error) {
      if (state.activeRouteRequestId !== Number(command.requestId)) return;
      state.activeRouteRequestId = null;
      state.runtime.routeFailed(command.requestId, error?.retryable === false ? 0 : 1, Date.now());
      const message = t(error?.code === "SERVER_MISCONFIGURED" ? "web.route.no_key" : "web.route.failed");
      setRouteStatus(message, "error");
      if (state.navigating) setRideAlert(t("web.route.reroute_failed"));
    }
  }

  async function handleTrafficRequest(command) {
    const origin = currentFix();
    const destination = selectedDestinationPoint();
    if (!origin || !destination || !state.runtime) {
      state.runtime?.trafficFailed(command.requestId, Date.now());
      return;
    }
    state.activeTrafficRequestId = Number(command.requestId);
    try {
      const body = {
        protocol_version: 1,
        request_id: command.requestId,
        route_mode: "driving",
        origin,
        destination,
        is_reroute: false,
        previous_route_id: command.routeId,
        ...(state.destination?.id ? { destination_poi_id: state.destination.id } : {}),
      };
      const envelope = await fetchJson(new URL("v1/routes", API_BASE), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (state.activeTrafficRequestId !== Number(command.requestId)) return;
      state.activeTrafficRequestId = null;
      const progress = Math.max(0, Number(state.runtime.getRouteProgress()));
      state.runtime.trafficBegin(
        command.requestId,
        command.routeId,
        Number(envelope.route.total_duration_s ?? 0),
        Date.now(),
      );
      for (const segment of envelope.route.traffic ?? []) {
        state.runtime.trafficAddSegment(
          progress + Number(segment.start_offset_m ?? 0),
          progress + Number(segment.end_offset_m ?? 0),
          TRAFFIC[segment.level] ?? TRAFFIC.unknown,
        );
      }
      state.runtime.trafficCommit();
      elements.routeTraffic.textContent = trafficLabel(envelope.route);
    } catch {
      if (state.activeTrafficRequestId !== Number(command.requestId)) return;
      state.activeTrafficRequestId = null;
      state.runtime.trafficFailed(command.requestId, Date.now());
    }
  }

  function selectDestination(place) {
    if (!state.runtime || !state.currentPosition) {
      showToast(t("web.runtime.not_ready"));
      return;
    }
    state.destination = place;
    state.route = null;
    state.navigating = false;
    state.arrivedAnnounced = false;
    state.activeRouteRequestId = null;
    state.activeTrafficRequestId = null;
    elements.routeDestination.textContent = [place.name, place.display_area].filter(Boolean).join(" · ");
    elements.rideDestination.textContent = place.name || t("web.ride.destination");
    elements.routeDuration.textContent = "--";
    elements.routeDistance.textContent = "--";
    elements.routeTraffic.textContent = "--";
    elements.startNavigation.disabled = true;
    setRouteStatus(t("web.route.planning"));
    setView("route");
    state.runtime.setNetwork(navigator.onLine ? 1 : 0);
    state.runtime.start(place.location.latitude_deg, place.location.longitude_deg);
    feedPosition(state.currentPosition);
  }

  async function requestOrientationPermission() {
    if (typeof window.DeviceOrientationEvent === "undefined") return;
    if (typeof window.DeviceOrientationEvent.requestPermission === "function") {
      try {
        const result = await window.DeviceOrientationEvent.requestPermission();
        if (result !== "granted") return;
      } catch {
        return;
      }
    }
    window.addEventListener(
      "deviceorientation",
      (event) => {
        if (Number.isFinite(event.webkitCompassHeading)) {
          state.orientationHeading = Number(event.webkitCompassHeading);
        } else if (event.absolute && Number.isFinite(event.alpha)) {
          state.orientationHeading = (360 - Number(event.alpha)) % 360;
        }
      },
      { passive: true },
    );
  }

  async function acquireWakeLock() {
    if (!("wakeLock" in navigator) || document.visibilityState !== "visible") {
      setWakeState("web.ride.keep_awake");
      return false;
    }
    try {
      state.wakeLock = await navigator.wakeLock.request("screen");
      setWakeState("web.ride.awake");
      state.wakeLock.addEventListener("release", () => {
        state.wakeLock = null;
        setWakeState("web.ride.awake_released");
      });
      return true;
    } catch {
      setWakeState("web.ride.keep_awake_manually");
      return false;
    }
  }

  async function startNavigation() {
    if (!state.route || !state.currentPosition) return;
    state.navigating = true;
    state.arrivedAnnounced = false;
    await Promise.allSettled([requestOrientationPermission(), acquireWakeLock()]);
    setView("navigation");
    setRideAlert("");
    if ("speechSynthesis" in window) {
      const utterance = new SpeechSynthesisUtterance(t("web.ride.start_speech"));
      utterance.lang = i18n.speechLanguage;
      window.speechSynthesis.cancel();
      window.speechSynthesis.speak(utterance);
    }
  }

  async function cancelNavigation({ confirmEnd = false } = {}) {
    if (confirmEnd && state.navigating && !window.confirm(t("web.ride.confirm_end"))) return;
    state.navigating = false;
    state.destination = null;
    state.route = null;
    state.arrivedAnnounced = false;
    state.activeRouteRequestId = null;
    state.activeTrafficRequestId = null;
    state.runtime?.cancel();
    if (state.wakeLock) {
      try { await state.wakeLock.release(); } catch {}
      state.wakeLock = null;
    }
    if ("speechSynthesis" in window) window.speechSynthesis.cancel();
    setRideAlert("");
    setView("setup");
  }

  function updateRideReadouts() {
    if (!state.runtimeReady || !state.runtime) return;
    const navState = state.runtime.getNavState();
    const remainingDistance = state.runtime.getRemainingDistance();
    const remainingDuration = state.runtime.getRemainingDuration();
    elements.remainingDistance.textContent = i18n.distance(remainingDistance);
    const arrival = new Date(Date.now() + Math.max(0, remainingDuration) * 1000);
    elements.arrivalTime.textContent = remainingDuration > 0 ? i18n.time(arrival) : "--:--";
    elements.rideConnection.textContent = networkText();

    if (state.navigating && navState === 4) setRideAlert(t("web.route.off_route"));
    if (state.navigating && navState === 5 && !state.arrivedAnnounced) {
      state.arrivedAnnounced = true;
      setRideAlert(t("web.ride.arrived"));
      if ("speechSynthesis" in window) {
        const utterance = new SpeechSynthesisUtterance(t("web.ride.arrived"));
        utterance.lang = i18n.speechLanguage;
        window.speechSynthesis.speak(utterance);
      }
    }

    const generation = state.runtime.getRouteGeneration();
    if (generation !== state.lastRouteGeneration) state.lastRouteGeneration = generation;
    elements.dialogRuntime.textContent = t("web.status.lvgl_state",
      { state: t(NAV_STATE[navState] ?? "web.state.unknown") });
  }

  function attachRuntime(runtime) {
    state.runtime = runtime;
    state.runtimeReady = true;
    runtime.initialize();
    // Emscripten calls this just before main(); apply after moto_nav_ui_create().
    // SDL also renames the tab when it creates its window.
    window.setTimeout(() => {
      runtime.setLanguage(i18n.deviceLanguage);
      document.title = t("web.title");
    }, 0);
    if (DEVICE_STATE_PREVIEW) {
      state.currentPosition = {
        coords: {
          latitude: 36.6745,
          longitude: 117.1305,
          accuracy: 4,
          speed: 0,
          heading: 0,
        },
        timestamp: Date.now(),
      };
      state.destination = { name: t("web.preview.lifecycle"), location: {} };
      state.navigating = false;
      elements.routeDestination.textContent = t("web.preview.lifecycle");
      setRouteStatus(t("web.preview.lifecycle_status"), "ready");
      setView("route");
      updateSystemState();
      // Emscripten invokes onRuntimeInitialized immediately before entering
      // main(). Defer one browser task so moto_nav_ui_create() cannot reset
      // the requested lifecycle frame.
      window.setTimeout(
        () => runtime.previewPhoneLifecycle(DEVICE_STATE_PREVIEW.value),
        0,
      );
      return;
    }
    if (LOCAL_DEMO) {
      state.currentPosition = {
        coords: {
          latitude: 36.6748039,
          longitude: 117.1224488,
          accuracy: 4,
          speed: 12,
          heading: 180,
        },
        timestamp: Date.now(),
      };
      state.destination = {
        name: t("web.demo.route_name"),
        location: {},
      };
      state.navigating = true;
      elements.rideDestination.textContent = t("web.demo.short_name");
      setView("navigation");
      updateSystemState();
      // onRuntimeInitialized fires immediately before Emscripten enters
      // main(); wait one browser task so moto_nav_ui_create() cannot reset
      // the connected state and real-road fixture we are about to install.
      window.setTimeout(() => {
        runtime.setPhoneConnection(2);
        runtime.demoScenario(0);
      }, 0);
      state.mapSceneOverlay?.destroy();
      state.mapSceneOverlay = window.MotoMapSceneOverlay?.create({
        ring: document.querySelector(".screen-ring"),
        runtime,
        isVisible: () => state.view === "navigation",
      }) ?? null;
      return;
    }
    window.setTimeout(() => runtime.setPhoneConnection(2), 0);
    runtime.setNetwork(navigator.onLine ? 1 : 0);
    if (state.currentPosition) feedPosition(state.currentPosition);
    updateSystemState();
  }

  function claimCanvas() {
    if (!placeholderContext) return elements.canvas;
    const replacement = elements.canvas.cloneNode(false);
    elements.canvas.replaceWith(replacement);
    elements.canvas = replacement;
    placeholderContext = null;
    return replacement;
  }

  function runtimeFailed(message) {
    state.runtimeReady = false;
    elements.dialogRuntime.textContent = message;
    setFeedback(t("web.runtime.load_failed"), "error");
    updateSystemState();
  }

  function networkChanged() {
    state.runtime?.setNetwork(navigator.onLine ? 1 : 0);
    elements.dialogNetwork.textContent = networkText();
    elements.rideConnection.textContent = networkText();
    if (!navigator.onLine && state.navigating) {
      setRideAlert(t("web.ride.offline"));
    } else if (navigator.onLine && state.navigating) {
      setRideAlert("");
      state.runtime?.tick(Date.now());
    }
  }

  function visibilityChanged() {
    if (!state.navigating) return;
    if (document.visibilityState === "hidden") {
      state.lastVisibilityPause = true;
      return;
    }
    acquireWakeLock();
    if (state.lastVisibilityPause) {
      state.lastVisibilityPause = false;
      setRideAlert(t("web.ride.recalibrating"));
      navigator.geolocation?.getCurrentPosition(
        (position) => {
          feedPosition(position);
          state.runtime?.tick(Date.now());
          window.setTimeout(() => setRideAlert(""), 1800);
        },
        onLocationError,
        positionOptions(),
      );
    }
  }

  elements.locationButton.addEventListener("click", requestLocation);
  elements.searchForm.addEventListener("submit", (event) => {
    event.preventDefault();
    window.clearTimeout(state.searchTimer);
    searchPlaces(elements.destinationQuery.value);
  });
  elements.destinationQuery.addEventListener("input", () => {
    window.clearTimeout(state.searchTimer);
    const query = elements.destinationQuery.value;
    elements.clearSearch.hidden = query.length === 0;
    state.searchTimer = window.setTimeout(() => searchPlaces(query), 480);
  });
  elements.clearSearch.addEventListener("click", () => {
    elements.destinationQuery.value = "";
    elements.placeResults.replaceChildren();
    elements.clearSearch.hidden = true;
    setFeedback(t("web.search.prompt"), "info");
    elements.destinationQuery.focus();
  });
  elements.routeBack.addEventListener("click", () => cancelNavigation());
  elements.startNavigation.addEventListener("click", startNavigation);
  elements.endNavigation.addEventListener("click", () => cancelNavigation({ confirmEnd: true }));
  elements.homeButton.addEventListener("click", () => {
    if (state.view !== "setup") cancelNavigation({ confirmEnd: state.navigating });
  });
  elements.systemState.addEventListener("click", () => elements.statusDialog.showModal());
  window.addEventListener("online", networkChanged);
  window.addEventListener("offline", networkChanged);
  document.addEventListener("visibilitychange", visibilityChanged);

  window.MotoNavController = Object.freeze({
    attachRuntime,
    claimCanvas,
    runtimeFailed,
    handleRouteRequest,
    handleTrafficRequest,
  });

  i18n.apply();
  setupLanguageSettings();
  drawPlaceholder();
  setView("setup");
  updateSystemState();
  checkBackend();
  window.setInterval(() => {
    if (state.runtimeReady) state.runtime.tick(Date.now());
    updateRideReadouts();
  }, 1000);
})();
