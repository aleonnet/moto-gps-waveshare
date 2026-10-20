#include "phone_nav_bridge.h"
#include "phone_nav_bridge_test_probe.hpp"
#include "demo_fixture/jinan_big_data_demo.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {

int failures = 0;

void pump(PhoneNavBridge& bridge) {
  bridge.render_pending_for_test();
}

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::cerr << __FILE__ << ':' << __LINE__                             \
                << " CHECK failed: " #condition << '\n';                  \
      ++failures;                                                          \
    }                                                                      \
  } while (false)

moto::ble::ReassembledMessage make_message(
    const moto::ble::Message& message,
    std::uint16_t sequence) {
  const moto::ble::BytesResult encoded = moto::ble::encode_message(message);
  if (!encoded.ok()) {
    std::cerr << "Could not encode bridge test message\n";
    ++failures;
    return {};
  }
  moto::ble::ReassembledMessage result;
  result.type = moto::ble::message_type(message);
  result.sequence = sequence;
  result.payload = encoded.value;
  return result;
}

struct ReentrantSenderContext {
  PhoneNavBridge* bridge = nullptr;
  int calls = 0;
  moto::ble::DisplayPage last_page = moto::ble::DisplayPage::Navigation;
};

bool reentrant_sender(const moto::ble::Message& message,
                      std::uint8_t,
                      void* context) {
  auto* sender = static_cast<ReentrantSenderContext*>(context);
  const auto* command = std::get_if<moto::ble::DeviceCommand>(&message);
  if (command == nullptr) {
    return false;
  }
  ++sender->calls;
  sender->last_page = command->page;

  // A real transport can synchronously reject a send or cause a link callback.
  // This re-entry deadlocks if PhoneNavBridge keeps state_mutex_ while sending.
  sender->bridge->on_link_state(false);
  return true;
}

struct MusicSenderContext {
  std::vector<moto::ble::DeviceCommand> commands;
  std::vector<std::uint8_t> flags;
};

bool record_music_sender(const moto::ble::Message& message,
                         std::uint8_t flags,
                         void* context) {
  auto* sender = static_cast<MusicSenderContext*>(context);
  const auto* command = std::get_if<moto::ble::DeviceCommand>(&message);
  if (command == nullptr) return false;
  sender->commands.push_back(*command);
  sender->flags.push_back(flags);
  return true;
}

void test_sender_is_called_without_bridge_state_lock() {
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);
  ReentrantSenderContext sender{&bridge};
  bridge.set_sender(reentrant_sender, &sender);
  bridge.install_ui_callbacks();
  bridge.on_link_state(true);

  moto::test::emit_page_change(MOTO_UI_PAGE_SPEED);
  CHECK(sender.calls == 1);
  CHECK(sender.last_page == moto::ble::DisplayPage::Speed);
}

void test_navigation_and_touch_updates_are_serialized() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);
  bridge.install_ui_callbacks();
  bridge.on_link_state(true);

  constexpr int kIterations = 2'000;
  std::atomic<bool> begin{false};
  std::thread phone([&]() {
    while (!begin.load()) {
      std::this_thread::yield();
    }
    for (int index = 0; index < kIterations; ++index) {
      moto::ble::NavigationSnapshot snapshot;
      snapshot.state = moto::ble::NavigationState::Navigating;
      snapshot.network = moto::ble::NetworkState::Online;
      snapshot.flags = moto::ble::NavigationHasNextManeuver;
      snapshot.maneuver = (index % 2 == 0)
                              ? moto::ble::Maneuver::Left
                              : moto::ble::Maneuver::Right;
      snapshot.route_token = 17;
      snapshot.route_generation = 3;
      snapshot.road_name = "并发道路-" + std::to_string(index) +
                           std::string(32, static_cast<char>('a' + index % 26));
      snapshot.distance_to_maneuver_m = static_cast<std::uint32_t>(index);
      const auto message = make_message(
          moto::ble::Message{snapshot},
          static_cast<std::uint16_t>(index % 65'535 + 1));
      CHECK(bridge.on_message(message) == moto::ble::AckStatus::Ok);
    }
  });

  std::thread touch([&]() {
    while (!begin.load()) {
      std::this_thread::yield();
    }
    for (int index = 0; index < kIterations; ++index) {
      moto::test::emit_page_change(
          index % 2 == 0 ? MOTO_UI_PAGE_SPEED : MOTO_UI_PAGE_COMPASS);
    }
  });

  begin.store(true);
  phone.join();
  touch.join();

  // Thousands of producer updates collapse into the latest complete state;
  // none of the producer threads enters LVGL.
  CHECK(moto::test::phone_nav_bridge_apply_count() == 0);
  CHECK(moto::test::phone_nav_bridge_board_lock_count() == 0);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_apply_count() == 1);
  const std::string final_name = moto::test::phone_nav_bridge_last_road_name();
  CHECK(final_name.rfind("并发道路-", 0) == 0);
}

void test_ble_submission_never_waits_for_lvgl_and_retries_latest_state() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);

  moto::ble::NavigationSnapshot first;
  first.state = moto::ble::NavigationState::Navigating;
  first.network = moto::ble::NetworkState::Online;
  first.flags = moto::ble::NavigationHasNextManeuver;
  first.route_token = 29;
  first.route_generation = 1;
  first.maneuver = moto::ble::Maneuver::Left;
  first.road_name = "旧状态";

  moto::test::phone_nav_bridge_set_board_lock_available(false);
  CHECK(bridge.on_message(make_message(first, 1)) ==
        moto::ble::AckStatus::Ok);
  CHECK(moto::test::phone_nav_bridge_board_lock_count() == 0);
  CHECK(moto::test::phone_nav_bridge_apply_count() == 0);

  // Only the render consumer attempts LVGL. Failure keeps the dirty bit and
  // the producer remains completely decoupled from that unavailable lock.
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_board_lock_count() == 1);
  CHECK(moto::test::phone_nav_bridge_apply_count() == 0);

  auto latest = first;
  latest.maneuver = moto::ble::Maneuver::Right;
  latest.road_name = "保留的最新状态";
  CHECK(bridge.on_message(make_message(latest, 2)) ==
        moto::ble::AckStatus::Ok);
  CHECK(moto::test::phone_nav_bridge_board_lock_count() == 1);

  moto::test::phone_nav_bridge_set_board_lock_available(true);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_apply_count() == 1);
  CHECK(moto::test::phone_nav_bridge_last_road_name() == "保留的最新状态");
  CHECK(moto::test::phone_nav_bridge_last_maneuver() ==
        MOTO_MANEUVER_RIGHT);
}

void test_phone_connection_lifecycle_reaches_the_ui() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);

  bridge.on_link_state(true);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_phone_connection() ==
        MOTO_UI_PHONE_CONNECTING);

  moto::ble::ConnectionStatus starting;
  starting.role = moto::ble::EndpointRole::Phone;
  starting.state = moto::ble::ConnectionState::Starting;
  starting.minimum_version = moto::ble::kProtocolVersion;
  starting.maximum_version = moto::ble::kProtocolVersion;
  starting.session_id = 1234;
  CHECK(bridge.on_message(make_message(starting, 10)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_phone_connection() ==
        MOTO_UI_PHONE_CONNECTING);

  starting.state = moto::ble::ConnectionState::Ready;
  CHECK(bridge.on_message(make_message(starting, 11)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_phone_connection() ==
        MOTO_UI_PHONE_ONLINE);

  bridge.on_link_state(false);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_phone_connection() ==
        MOTO_UI_PHONE_OFFLINE);
}

void test_music_capability_state_and_touch_commands() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);
  MusicSenderContext sender;
  bridge.set_sender(record_music_sender, &sender);
  bridge.install_ui_callbacks();
  bridge.on_link_state(true);

  moto::ble::ConnectionStatus ready;
  ready.role = moto::ble::EndpointRole::Phone;
  ready.state = moto::ble::ConnectionState::Starting;
  ready.minimum_version = moto::ble::kProtocolVersion;
  ready.maximum_version = moto::ble::kProtocolVersion;
  ready.capabilities = moto::ble::CapabilityMediaState |
                       moto::ble::CapabilityMusicCommands |
                       moto::ble::CapabilityCommandAck;
  ready.session_id = 4321;
  CHECK(bridge.on_message(make_message(ready, 20)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(!moto::test::phone_nav_bridge_music_page_enabled());
  ready.state = moto::ble::ConnectionState::Ready;
  CHECK(bridge.on_message(make_message(ready, 21)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_music_page_enabled());

  moto::ble::MediaState media;
  media.flags = moto::ble::MediaConnected |
                moto::ble::MediaPlaying |
                moto::ble::MediaLikeAvailable;
  media.track_token = 88;
  media.position_s = 12;
  media.duration_s = 240;
  media.source_name = "APPLE MUSIC";
  media.track_title = "夜间骑行";
  media.artist_name = "MOTO GPS";
  CHECK(bridge.on_message(make_message(media, 22)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_media_connected());
  CHECK(moto::test::phone_nav_bridge_media_playing());
  CHECK(moto::test::phone_nav_bridge_media_like_available());
  CHECK(moto::test::phone_nav_bridge_media_source() == "APPLE MUSIC");
  CHECK(moto::test::phone_nav_bridge_media_title() == "夜间骑行");
  CHECK(moto::test::phone_nav_bridge_media_artist() == "MOTO GPS");

  moto::test::emit_music_command(MOTO_MUSIC_PREVIOUS);
  moto::test::emit_music_command(MOTO_MUSIC_TOGGLE_PLAYBACK);
  moto::test::emit_music_command(MOTO_MUSIC_NEXT);
  moto::test::emit_music_command(MOTO_MUSIC_LIKE);
  CHECK(sender.commands.size() == 4);
  const moto::ble::DeviceCommandKind expected[] = {
      moto::ble::DeviceCommandKind::MusicPrevious,
      moto::ble::DeviceCommandKind::MusicTogglePlayback,
      moto::ble::DeviceCommandKind::MusicNext,
      moto::ble::DeviceCommandKind::MusicLike,
  };
  for (std::size_t index = 0; index < sender.commands.size(); ++index) {
    CHECK(sender.commands[index].kind == expected[index]);
    CHECK(sender.commands[index].page == moto::ble::DisplayPage::Music);
    CHECK(sender.commands[index].command_id == index + 1);
    CHECK((sender.flags[index] & moto::ble::AckRequested) != 0U);
    CHECK((sender.flags[index] & moto::ble::Urgent) != 0U);
  }
}

struct LanguageStore {
  PhoneNavBridge* bridge = nullptr;
  std::vector<std::string> writes;
  bool called_under_board_lock = false;
  bool called_under_state_lock = false;
};

// The store writes flash; it must run with neither the display lock nor the
// bridge state held, or BLE reception and drawing would wait on NVS.
void record_language(const char* language, void* context) {
  auto* store = static_cast<LanguageStore*>(context);
  store->writes.emplace_back(language);
  if (moto::test::phone_nav_bridge_board_lock_depth() != 0) {
    store->called_under_board_lock = true;
  }
  // on_link_state takes state_mutex_ first; from another thread it can only
  // finish while this callback runs if the callback does not hold it. A
  // detached thread finishes later either way, so a defect cannot hang tests.
  auto done = std::make_shared<std::promise<void>>();
  std::future<void> finished = done->get_future();
  std::thread([bridge = store->bridge, done] {
    bridge->on_link_state(true);
    done->set_value();
  }).detach();
  if (finished.wait_for(std::chrono::seconds(1)) != std::future_status::ready) {
    store->called_under_state_lock = true;
  }
}

void test_phone_language_reaches_the_ui_and_is_stored_once() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);
  LanguageStore store;
  store.bridge = &bridge;
  // The device booted in the language it stored last time.
  bridge.set_language_store(record_language, &store, "pt-BR");
  bridge.on_link_state(true);

  moto::ble::LocaleSelection locale;
  locale.language_tag = "pt-BR";
  CHECK(bridge.on_message(make_message(locale, 30)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_ui_language() == "pt-BR");
  // Unchanged language: no flash write on every reconnect.
  CHECK(store.writes.empty());

  locale.language_tag = "zh-Hans";
  CHECK(bridge.on_message(make_message(locale, 31)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_ui_language() == "zh-Hans");
  CHECK(store.writes == std::vector<std::string>{"zh-Hans"});
  CHECK(!store.called_under_board_lock);
  CHECK(!store.called_under_state_lock);
  CHECK(!moto::test::phone_nav_bridge_language_set_outside_board_lock());

  // Losing the phone keeps the display in its last language.
  const int sets_before_disconnect =
      moto::test::phone_nav_bridge_language_set_count();
  bridge.on_link_state(false);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_language_set_count() ==
        sets_before_disconnect);
  CHECK(moto::test::phone_nav_bridge_ui_language() == "zh-Hans");
  // The display, not the bridge, supplies the translated "waiting" text.
  CHECK(moto::test::phone_nav_bridge_media_title().empty());
  CHECK(!moto::test::phone_nav_bridge_media_connected());

  locale.language_tag = "en-US";
  bridge.on_link_state(true);
  CHECK(bridge.on_message(make_message(locale, 32)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(store.writes == (std::vector<std::string>{"zh-Hans", "en-US"}));
}

void test_demo_uses_the_production_presenter_path() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);
  bridge.install_ui_callbacks();

  moto::test::emit_demo_change(true);
  pump(bridge);
  const auto now_ms = static_cast<std::uint64_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now().time_since_epoch()).count());

  // Approach and cross the first junction in the real OSM route. The symbol
  // and distance switch together: right into 新泺大街, then left into 崇华路.
  // Distances come from cumulative route geometry, not UI timer thresholds.
  bridge.update_demo(now_ms + 6'200);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_maneuver() ==
        MOTO_MANEUVER_RIGHT);
  CHECK(moto::test::phone_nav_bridge_last_distance_to_maneuver_m() > 3);
  CHECK(moto::test::phone_nav_bridge_last_distance_to_maneuver_m() < 8);
  bridge.update_demo(now_ms + 7'000);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_maneuver() ==
        MOTO_MANEUVER_LEFT);
  CHECK(moto::test::phone_nav_bridge_last_distance_to_maneuver_m() > 135);
  CHECK(moto::test::phone_nav_bridge_last_distance_to_maneuver_m() < 141);

  bridge.update_demo(now_ms + 12'000);
  pump(bridge);

  CHECK(moto::test::phone_nav_bridge_last_demo_active());
  CHECK(moto::test::phone_nav_bridge_last_route_point_count() >= 2);
  CHECK(moto::test::phone_nav_bridge_last_road_point_count() ==
        moto::demo::jinan_big_data::kRoadPoints.size());
  CHECK(moto::test::phone_nav_bridge_last_road_polyline_count() ==
        moto::demo::jinan_big_data::kRoads.size());
  CHECK(moto::test::phone_nav_bridge_apply_count() >= 2);

  bridge.update_demo(now_ms + 6'200);
  pump(bridge);
  const uint16_t heading_before =
      moto::test::phone_nav_bridge_last_heading_deg();
  bridge.update_demo(now_ms + 8'500);
  pump(bridge);
  const uint16_t heading_after =
      moto::test::phone_nav_bridge_last_heading_deg();
  CHECK(heading_before != heading_after);

  moto::test::emit_demo_change(false);
  pump(bridge);
  CHECK(!moto::test::phone_nav_bridge_last_demo_active());
}

void test_ios_demo_token_attaches_context_and_live_route_clears_it() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);

  const std::uint32_t demo_token =
      moto::ble::route_token(moto::demo::jinan_big_data::kRouteId);
  moto::ble::NavigationSnapshot snapshot;
  snapshot.state = moto::ble::NavigationState::Navigating;
  snapshot.network = moto::ble::NetworkState::Online;
  snapshot.flags = moto::ble::NavigationHasRouteView;
  snapshot.route_token = demo_token;
  snapshot.route_generation = 1;
  moto::ble::RouteGeometry geometry;
  geometry.route_token = demo_token;
  geometry.route_generation = 1;
  geometry.total_point_count = 2;
  geometry.view_origin = {36'674'773, 117'128'056};
  geometry.points = {
      {36'674'773, 117'128'056},
      {36'674'145, 117'128'489},
  };
  // The phone queues changed geometry before the snapshot that references it.
  // Geometry updates state only; the following snapshot is the single LVGL
  // presentation boundary for the pair.
  const int before_pair = moto::test::phone_nav_bridge_apply_count();
  CHECK(bridge.on_message(make_message(geometry, 40)) ==
        moto::ble::AckStatus::Ok);
  CHECK(moto::test::phone_nav_bridge_apply_count() == before_pair);
  CHECK(bridge.on_message(make_message(snapshot, 41)) ==
        moto::ble::AckStatus::Ok);
  CHECK(moto::test::phone_nav_bridge_apply_count() == before_pair);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_apply_count() == before_pair + 1);
  CHECK(moto::test::phone_nav_bridge_last_road_point_count() ==
        moto::demo::jinan_big_data::kRoadPoints.size());
  CHECK(moto::test::phone_nav_bridge_last_road_polyline_count() ==
        moto::demo::jinan_big_data::kRoads.size());

  snapshot.flags = 0;
  snapshot.route_token = moto::ble::route_token("amap-live-route");
  snapshot.route_generation = 2;
  CHECK(bridge.on_message(make_message(snapshot, 42)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_road_point_count() == 0);
  CHECK(moto::test::phone_nav_bridge_last_road_polyline_count() == 0);
}

void test_phone_map_zoom_scales_the_display_and_ends_with_the_link() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);
  MusicSenderContext sender;
  bridge.set_sender(record_music_sender, &sender);
  bridge.install_ui_callbacks();
  bridge.on_link_state(true);

  std::uint16_t sequence = 70;
  const auto send_route = [&](std::uint32_t generation) {
    moto::ble::RouteGeometry geometry;
    geometry.route_token = moto::ble::route_token("zoom-route");
    geometry.route_generation = generation;
    geometry.total_point_count = 2;
    geometry.view_origin = {36'670'000, 117'130'000};
    geometry.points = {{36'670'000, 117'130'000}, {36'672'500, 117'130'000}};
    moto::ble::NavigationSnapshot snapshot;
    snapshot.state = moto::ble::NavigationState::Navigating;
    snapshot.network = moto::ble::NetworkState::Online;
    snapshot.flags = moto::ble::NavigationHasRouteView;
    snapshot.route_token = geometry.route_token;
    snapshot.route_generation = generation;
    CHECK(bridge.on_message(make_message(geometry, sequence++)) ==
          moto::ble::AckStatus::Ok);
    CHECK(bridge.on_message(make_message(snapshot, sequence++)) ==
          moto::ble::AckStatus::Ok);
    pump(bridge);
  };
  send_route(1);
  const moto_ui_point_t rider = moto::test::phone_nav_bridge_last_route_start();
  const moto_ui_point_t street = moto::test::phone_nav_bridge_last_route_end();
  CHECK(rider.y - street.y > 100);  // 278 m due north, ahead of the rider.

  moto::ble::MapZoom zoom;
  zoom.zoom_level = 14;
  CHECK(bridge.on_message(make_message(zoom, sequence++)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  const moto_ui_point_t wide = moto::test::phone_nav_bridge_last_route_end();
  CHECK(std::abs(2 * (rider.y - wide.y) - (rider.y - street.y)) <= 2);
  CHECK(wide.x == street.x);

  // A new phone session starts at the street scale until it says otherwise.
  bridge.on_link_state(false);
  bridge.on_link_state(true);
  send_route(2);
  CHECK(moto::test::phone_nav_bridge_last_route_end().y == street.y);

  // A tap on the map asks the phone; the display does not rescale by itself.
  moto::test::emit_map_tap(233, 120);
  CHECK(!sender.commands.empty() &&
        sender.commands.back().kind == moto::ble::DeviceCommandKind::Tap &&
        sender.commands.back().page == moto::ble::DisplayPage::Navigation &&
        sender.commands.back().x == 233 && sender.commands.back().y == 120);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_route_end().y == street.y);
}

void test_map_scene_atomically_replaces_roads_and_buildings_at_capacity() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);

  moto::ble::NavigationSnapshot navigation;
  navigation.state = moto::ble::NavigationState::Navigating;
  navigation.network = moto::ble::NetworkState::Online;
  navigation.flags = moto::ble::NavigationHasRouteView;
  navigation.route_token = 77;
  navigation.route_generation = 1;
  navigation.heading_cdeg = 9'000;
  CHECK(bridge.on_message(make_message(navigation, 50)) ==
        moto::ble::AckStatus::Ok);

  moto::ble::RouteGeometry geometry;
  geometry.route_token = 77;
  geometry.route_generation = 1;
  geometry.total_point_count = 2;
  geometry.view_origin = {36'670'000, 117'130'000};
  geometry.points = {
      geometry.view_origin,
      {36'670'000, 117'131'000},
  };
  CHECK(bridge.on_message(make_message(geometry, 51)) ==
        moto::ble::AckStatus::Ok);

  moto::ble::MapScene first;
  first.scene_revision = 1;
  first.view_origin = geometry.view_origin;
  first.radius_m = 500;
  first.roads = {
      {moto::ble::MapRoadClass::Primary,
       {{36'670'000, 117'130'000}, {36'670'000, 117'131'000}}},
  };
  first.buildings = {
      {moto::ble::MapBuildingClass::Landmark,
       {{36'670'100, 117'130'100},
        {36'670'100, 117'130'200},
        {36'670'200, 117'130'200}}},
  };
  const int before_first = moto::test::phone_nav_bridge_apply_count();
  CHECK(bridge.on_message(make_message(first, 52)) ==
        moto::ble::AckStatus::Ok);
  CHECK(moto::test::phone_nav_bridge_apply_count() == before_first);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_apply_count() == before_first + 1);
  CHECK(moto::test::phone_nav_bridge_last_road_point_count() == 2);
  CHECK(moto::test::phone_nav_bridge_last_road_polyline_count() == 1);
  CHECK(moto::test::phone_nav_bridge_last_road_class() ==
        static_cast<std::uint8_t>(moto::ble::MapRoadClass::Primary));
  CHECK(moto::test::phone_nav_bridge_last_building_point_count() == 3);
  CHECK(moto::test::phone_nav_bridge_last_building_footprint_count() == 1);
  CHECK(moto::test::phone_nav_bridge_last_building_class() ==
        static_cast<std::uint8_t>(moto::ble::MapBuildingClass::Landmark));

  moto::ble::MapScene maximum;
  maximum.scene_revision = 2;
  maximum.view_origin = geometry.view_origin;
  maximum.radius_m = 700;
  for (std::size_t road_index = 0;
       road_index < moto::ble::kMaxMapSceneRoads; ++road_index) {
    moto::ble::MapRoadPolyline road;
    road.road_class = road_index == 0
                          ? moto::ble::MapRoadClass::Service
                          : moto::ble::MapRoadClass::Residential;
    for (std::size_t point_index = 0; point_index < 8; ++point_index) {
      road.points.push_back({
          geometry.view_origin.latitude_e6 +
              static_cast<std::int32_t>(road_index * 20 + point_index),
          geometry.view_origin.longitude_e6 +
              static_cast<std::int32_t>(road_index * 25 + point_index * 3),
      });
    }
    maximum.roads.push_back(std::move(road));
  }
  for (std::size_t building_index = 0;
       building_index < moto::ble::kMaxMapSceneBuildings;
       ++building_index) {
    moto::ble::MapBuildingFootprint building;
    building.building_class = moto::ble::MapBuildingClass::Parking;
    for (std::size_t point_index = 0; point_index < 8; ++point_index) {
      building.points.push_back({
          geometry.view_origin.latitude_e6 +
              static_cast<std::int32_t>(building_index * 30 + point_index),
          geometry.view_origin.longitude_e6 +
              static_cast<std::int32_t>(building_index * 35 + point_index * 2),
      });
    }
    maximum.buildings.push_back(std::move(building));
  }

  const int before_maximum = moto::test::phone_nav_bridge_apply_count();
  CHECK(bridge.on_message(make_message(maximum, 53)) ==
        moto::ble::AckStatus::Ok);
  CHECK(moto::test::phone_nav_bridge_apply_count() == before_maximum);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_apply_count() == before_maximum + 1);
  CHECK(moto::test::phone_nav_bridge_last_road_point_count() ==
        moto::ble::kMaxMapSceneRoadPoints);
  CHECK(moto::test::phone_nav_bridge_last_road_polyline_count() ==
        moto::ble::kMaxMapSceneRoads);
  CHECK(moto::test::phone_nav_bridge_last_road_class() ==
        static_cast<std::uint8_t>(moto::ble::MapRoadClass::Service));
  CHECK(moto::test::phone_nav_bridge_last_building_point_count() ==
        moto::ble::kMaxMapSceneBuildingPoints);
  CHECK(moto::test::phone_nav_bridge_last_building_footprint_count() ==
        moto::ble::kMaxMapSceneBuildings);
  CHECK(moto::test::phone_nav_bridge_last_building_class() ==
        static_cast<std::uint8_t>(moto::ble::MapBuildingClass::Parking));

  const int before_stale = moto::test::phone_nav_bridge_apply_count();
  CHECK(bridge.on_message(make_message(first, 54)) ==
        moto::ble::AckStatus::Duplicate);
  CHECK(moto::test::phone_nav_bridge_apply_count() == before_stale);
  CHECK(moto::test::phone_nav_bridge_last_road_point_count() ==
        moto::ble::kMaxMapSceneRoadPoints);
  CHECK(moto::test::phone_nav_bridge_last_building_point_count() ==
        moto::ble::kMaxMapSceneBuildingPoints);

  moto::ble::MapScene empty;
  empty.scene_revision = 3;
  empty.view_origin = geometry.view_origin;
  empty.radius_m = 500;
  CHECK(bridge.on_message(make_message(empty, 55)) ==
        moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_road_point_count() == 0);
  CHECK(moto::test::phone_nav_bridge_last_road_polyline_count() == 0);
  CHECK(moto::test::phone_nav_bridge_last_building_point_count() == 0);
  CHECK(moto::test::phone_nav_bridge_last_building_footprint_count() == 0);
}

void test_imu_presentation_preserves_40hz_phase_and_stale_course_is_ignored() {
  moto::test::reset_phone_nav_bridge_probe();
  moto::nav::NavPresenter presenter;
  PhoneNavBridge bridge(presenter);
  // The IMU is usually ready before BLE. Its relative zero cannot become the
  // absolute heading when the phone finally connects.
  bridge.on_imu_sample(0.0F, 1);
  moto::ble::NavigationSnapshot navigation;
  navigation.state = moto::ble::NavigationState::Navigating;
  navigation.display_page = moto::ble::DisplayPage::Compass;
  navigation.flags = moto::ble::NavigationHasFix;
  navigation.heading_cdeg = 9'000;
  navigation.speed_deci_kph = 360;
  CHECK(bridge.on_message(make_message(navigation, 1)) == moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_heading_deg() == 90);

  const int before = moto::test::phone_nav_bridge_apply_count();
  for (std::uint64_t time = 8; time <= 1'000; time += 8) {
    bridge.on_imu_sample(45.0F, time);
    pump(bridge);
  }
  const int motion_frames = moto::test::phone_nav_bridge_apply_count() - before;
  CHECK(motion_frames == 40);  // resetting the deadline yields only 31
  const auto before_stale = moto::test::phone_nav_bridge_last_heading_deg();
  navigation.heading_cdeg = 27'000;
  navigation.flags |= moto::ble::NavigationGnssStale;
  CHECK(bridge.on_message(make_message(navigation, 2)) == moto::ble::AckStatus::Ok);
  pump(bridge);
  CHECK(moto::test::phone_nav_bridge_last_heading_deg() == before_stale);
}

}  // namespace

int main() {
  test_sender_is_called_without_bridge_state_lock();
  test_navigation_and_touch_updates_are_serialized();
  test_ble_submission_never_waits_for_lvgl_and_retries_latest_state();
  test_phone_connection_lifecycle_reaches_the_ui();
  test_music_capability_state_and_touch_commands();
  test_phone_language_reaches_the_ui_and_is_stored_once();
  test_demo_uses_the_production_presenter_path();
  test_ios_demo_token_attaches_context_and_live_route_clears_it();
  test_phone_map_zoom_scales_the_display_and_ends_with_the_link();
  test_map_scene_atomically_replaces_roads_and_buildings_at_capacity();
  test_imu_presentation_preserves_40hz_phase_and_stale_course_is_ignored();

  if (failures != 0) {
    std::cerr << failures << " phone navigation bridge checks failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "All phone navigation bridge checks passed\n";
  return EXIT_SUCCESS;
}
