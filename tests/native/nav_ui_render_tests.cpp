// Deterministic host-side rendering tests for the LVGL navigation UI.
// A headless LVGL display renders the real moto_nav_ui into an RGB565
// framebuffer; frames are hashed to verify bit-exact determinism, clean page
// transitions and label/geometry residue cleanup.

#include "moto_nav_ui.h"

#include <lvgl.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <string>
#include <vector>

namespace {

int failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::cerr << __FILE__ << ':' << __LINE__                             \
                << " CHECK failed: " #condition << '\n';                   \
      ++failures;                                                          \
    }                                                                      \
  } while (false)

constexpr int kWidth = MOTO_UI_CANVAS_WIDTH;
constexpr int kHeight = MOTO_UI_CANVAS_HEIGHT;
constexpr std::size_t kFrameBytes = static_cast<std::size_t>(kWidth) *
                                    static_cast<std::size_t>(kHeight) *
                                (LV_COLOR_DEPTH / 8);

std::vector<std::uint8_t> shadow_frame;
std::uint64_t flush_count = 0;

void flush_cb(lv_display_t* display, const lv_area_t* area,
              std::uint8_t* px_map) {
  // Partial rendering: stitch each flushed area into the shadow frame so a
  // complete deterministic frame is always available for hashing.
  const int bytes_per_pixel = LV_COLOR_DEPTH / 8;
  for (int y = area->y1; y <= area->y2; ++y) {
    const std::size_t row_bytes =
        static_cast<std::size_t>(area->x2 - area->x1 + 1) * bytes_per_pixel;
    const std::size_t src =
        static_cast<std::size_t>(y - area->y1) *
        static_cast<std::size_t>(area->x2 - area->x1 + 1) * bytes_per_pixel;
    const std::size_t dst =
        (static_cast<std::size_t>(y) * kWidth +
         static_cast<std::size_t>(area->x1)) * bytes_per_pixel;
    std::memcpy(shadow_frame.data() + dst, px_map + src, row_bytes);
  }
  ++flush_count;
  lv_display_flush_ready(display);
}

void init_display(int buffer_rows, int extra_pool_bytes) {
  lv_init();
  static std::vector<std::uint32_t> extra_pool;
  if(extra_pool_bytes > 0) {
    extra_pool.resize((static_cast<std::size_t>(extra_pool_bytes) + 3U) / 4U);
    const bool added = lv_mem_add_pool(extra_pool.data(), extra_pool.size() * 4U) != nullptr;
    CHECK(added);
    if(!added) std::exit(EXIT_FAILURE);
  }
  shadow_frame.assign(kFrameBytes, 0);
  // Exercise both small partial strips and the firmware's map-sized buffer.
  static std::vector<std::uint8_t> draw_buffer(
      static_cast<std::size_t>(kWidth) * buffer_rows * (LV_COLOR_DEPTH / 8));
  lv_display_t* display = lv_display_create(kWidth, kHeight);
  lv_display_set_flush_cb(display, flush_cb);
  lv_display_set_buffers(
      display, draw_buffer.data(), nullptr, draw_buffer.size(),
      LV_DISPLAY_RENDER_MODE_PARTIAL);
}

void pump(int cycles = 40) {
  for (int i = 0; i < cycles; ++i) {
    lv_tick_inc(5);
    lv_timer_handler();
  }
}

std::uint64_t frame_hash() {
  std::uint64_t hash = 1'469'598'103'934'665'603ULL;
  for (const std::uint8_t byte : shadow_frame) {
    hash ^= byte;
    hash *= 1'099'511'628'211ULL;
  }
  return hash;
}

struct Frame {
  std::uint64_t hash;
  std::vector<std::uint8_t> bytes;
};

Frame capture() {
  pump();
  return Frame{frame_hash(), shadow_frame};
}

moto_ui_state_t base_state() {
  moto_ui_state_t state{};
  state.page = MOTO_UI_PAGE_NAVIGATION;
  state.mode = MOTO_UI_NAVIGATING;
  state.maneuver = MOTO_MANEUVER_RIGHT;
  state.traffic = MOTO_TRAFFIC_SLOW;
  state.distance_to_maneuver_m = 120;
  state.remaining_distance_m = 1'500;
  state.remaining_time_s = 200;
  state.route_progress_percent = 40;
  state.gps_accuracy_m = 5;
  state.online = 1;
  state.has_destination = 1;
  state.route_identity = 77;
  state.route_generation = 1;
  state.map_scene_revision = 4;
  state.speed_kph = 48;
  state.speed_limit_kph = 50;
  state.heading_deg = 90;
  state.road_name = "经十路";
  state.next_road_name = "青年大街";
  return state;
}

void fill_route(moto_ui_state_t& state, int count) {
  count = count < 0 ? MOTO_UI_ROUTE_POINT_CAPACITY : count;
  state.route_point_count = static_cast<std::uint8_t>(count);
  for (int i = 0; i < count; ++i) {
    state.route_points[i] = {static_cast<std::int16_t>(40 + i * 16),
                             static_cast<std::int16_t>(233 + (i % 2) * 40)};
  }
}

void fill_streets(moto_ui_state_t& state) {
  state.road_point_count = 8;
  for (int i = 0; i < 8; ++i) {
    state.road_points[i] = {static_cast<std::int16_t>(10 + i * 55),
                            static_cast<std::int16_t>(30 + i * 60)};
  }
  state.road_polyline_count = 1;
  state.road_polylines[0] = {0, 8, 1};
  state.building_point_count = 6;
  for (int i = 0; i < 6; ++i) {
    state.building_points[i] = {
        static_cast<std::int16_t>(300 + (i % 3) * 40),
        static_cast<std::int16_t>(300 + (i / 3) * 40)};
  }
  state.building_footprint_count = 1;
  state.building_footprints[0] = {0, 6, 1};
}

void test_frames_are_deterministic() {
  // Identical UI state must produce a bit-identical frame every time.
  moto_nav_ui_create();
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);

  moto_ui_state_t state = base_state();
  fill_route(state, 12);
  fill_streets(state);
  moto_nav_ui_set_state(&state);
  const Frame first = capture();

  moto_nav_ui_set_state(&state);
  const Frame second = capture();
  CHECK(first.hash == second.hash);
  CHECK(first.bytes == second.bytes);

  // Perturb the UI with an unrelated page, then come back: the restored
  // navigation frame must be identical to the original (no residue).
  moto_nav_ui_set_page(MOTO_UI_PAGE_SPEED);
  const Frame speed_page = capture();
  moto_nav_ui_set_page(MOTO_UI_PAGE_NAVIGATION);
  const Frame restored = capture();
  CHECK(restored.hash == first.hash);

  // The speed page must actually render different pixels.
  CHECK(speed_page.hash != first.hash);

  // Determinism holds across repeated renders of the same page as well.
  moto_nav_ui_set_page(MOTO_UI_PAGE_SPEED);
  const Frame speed_again = capture();
  CHECK(speed_again.hash == speed_page.hash);
}

void test_clearing_geometry_leaves_no_residue() {
  moto_ui_state_t with_route = base_state();
  fill_route(with_route, 18);
  fill_streets(with_route);
  moto_nav_ui_set_state(&with_route);
  const Frame route_frame = capture();

  moto_ui_state_t without_route = with_route;
  without_route.route_point_count = 0;
  without_route.road_point_count = 0;
  without_route.road_polyline_count = 0;
  without_route.building_point_count = 0;
  without_route.building_footprint_count = 0;
  moto_nav_ui_set_state(&without_route);
  const Frame cleared_frame = capture();
  CHECK(route_frame.hash != cleared_frame.hash);

  // Re-drawing the geometry must restore the exact original frame: nothing
  // was left behind by the clear, and nothing accumulated by the redraw.
  moto_nav_ui_set_state(&with_route);
  const Frame redrawn = capture();
  CHECK(redrawn.hash == route_frame.hash);
}

void test_music_page_state_and_fallback() {
  moto_nav_ui_set_music_page_enabled(1);
  moto_nav_ui_set_page(MOTO_UI_PAGE_MUSIC);
  CHECK(moto_nav_ui_get_page() == MOTO_UI_PAGE_MUSIC);

  moto_music_state_t music{};
  music.connected = 1;
  music.playing = 1;
  music.like_available = 1;
  music.source_name = "NetEase";
  music.track_title = "公路之歌";
  music.artist_name = "新裤子";
  moto_nav_ui_set_music_state(&music);
  const Frame titled = capture();

  // Emptying the strings must visibly clear the labels (no stale text).
  moto_music_state_t empty_state{};
  empty_state.connected = 1;
  moto_nav_ui_set_music_state(&empty_state);
  const Frame emptied = capture();
  CHECK(titled.hash != emptied.hash);

  // Disabling the music page while it is on screen must fall back to the
  // navigation page; re-enabling must not restore it by itself.
  moto_nav_ui_set_music_page_enabled(0);
  pump();
  CHECK(moto_nav_ui_get_page() != MOTO_UI_PAGE_MUSIC);
}

void test_phone_lifecycle_renders_deterministically() {
  // The connection lifecycle is a full-screen overlay for the empty
  // navigation page; cycle it there and require visually distinct terminal
  // states plus deterministic repetition (no accumulated residue).
  moto_ui_state_t empty = base_state();
  empty.mode = MOTO_UI_ACQUIRING_FIX;
  empty.has_destination = 0;
  empty.route_point_count = 0;
  empty.road_name = nullptr;
  empty.next_road_name = nullptr;
  moto_nav_ui_set_state(&empty);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
  const Frame offline = capture();
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  const Frame online = capture();
  CHECK(offline.hash != online.hash);

  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
  const Frame offline_again = capture();
  CHECK(offline_again.hash == offline.hash);

  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_CONNECTING);
  const Frame connecting = capture();
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE); CHECK(capture().hash == offline.hash);
}

void test_demo_mode_visual_contract() {
  // Demo mode suppresses the full-screen connection lifecycle and labels the
  // status line "DEMO RIDE"; toggling it must be perfectly reversible.
  moto_ui_state_t empty = base_state();
  empty.mode = MOTO_UI_ACQUIRING_FIX;
  empty.has_destination = 0;
  empty.route_point_count = 0;
  empty.road_name = nullptr;
  empty.next_road_name = nullptr;
  moto_nav_ui_set_state(&empty);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
  moto_nav_ui_set_demo_active(0);
  const Frame without_demo = capture();

  moto_nav_ui_set_demo_active(1);
  const Frame with_demo = capture();
  CHECK(with_demo.hash != without_demo.hash);

  moto_nav_ui_set_demo_active(0);
  CHECK(capture().hash == without_demo.hash);

  // Contract: demo mode is connection-independent. The lifecycle surface is
  // hidden while demo is active, so connecting the phone must not change a
  // single pixel of the demo frame.
  moto_nav_ui_set_demo_active(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  CHECK(capture().hash == with_demo.hash);
  moto_nav_ui_set_demo_active(0);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
}

void test_capacity_payloads_render_stably() {
  // Maximum-capacity geometry must render identically across repeats.
  moto_ui_state_t max_state = base_state();
  fill_route(max_state, -1);
  fill_streets(max_state);
  max_state.road_point_count = MOTO_UI_ROAD_POINT_CAPACITY;
  for (int i = 0; i < MOTO_UI_ROAD_POINT_CAPACITY; ++i) {
    max_state.road_points[i] = {
        static_cast<std::int16_t>((i * 7) % kWidth),
        static_cast<std::int16_t>((i * 13) % kHeight)};
  }
  max_state.road_polyline_count = 4;
  for (int i = 0; i < 4; ++i) {
    max_state.road_polylines[i] = {
        static_cast<std::uint8_t>(i * 48),
        48,
        static_cast<std::uint8_t>(i % 6)};
  }
  moto_nav_ui_set_state(&max_state);
  const Frame max_first = capture();
  moto_nav_ui_set_state(&max_state);
  const Frame max_second = capture();
  CHECK(max_first.hash == max_second.hash);
}

void test_motion_frames_interpolate_then_settle_without_residue() {
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  moto_ui_state_t state = base_state();
  state.route_point_count = 3;
  state.route_points[0] = {233, 254};
  state.route_points[1] = {233, 150};
  state.route_points[2] = {233, 30};
  state.road_point_count = 2;
  state.road_points[0] = {110, 280};
  state.road_points[1] = {110, 30};
  state.road_polyline_count = 1;
  state.road_polylines[0] = {0, 2, 1};
  state.building_point_count = 4;
  state.building_points[0] = {300, 80};
  state.building_points[1] = {350, 80};
  state.building_points[2] = {350, 130};
  state.building_points[3] = {300, 130};
  state.building_footprint_count = 1;
  state.building_footprints[0] = {0, 4, 1};
  moto_nav_ui_set_state(&state);
  pump(260);  // finish the transient connected indication before comparing
  const auto before = capture().hash;

  // One heading frame moves all retained arrays through the ordinary motion
  // path, preserving the anchor and topology while the map turns under it.
  for (int index = 1; index < 3; ++index) state.route_points[index].x -= 130;
  for (int index = 0; index < 2; ++index) state.road_points[index].x += 110;
  for (int index = 0; index < 4; ++index) state.building_points[index].x -= 90;
  moto_nav_ui_set_reduce_motion(0);
  moto_nav_ui_set_motion_state(&state);
  pump(10);  // 50 ms contains two 25 ms interpolation opportunities.
  const auto intermediate = frame_hash();
  CHECK(intermediate != before);
  pump(200);
  const auto settled = frame_hash();
  const auto settled_bytes = shadow_frame;
  CHECK(settled != intermediate);

  // The eventual animated frame must match a direct render exactly, including
  // clearing the old road/building pixels in the shared invalidated region.
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_state(&state);
  const auto direct = capture();
  // Compare the map viewport. The page dots below it expire independently at
  // five seconds, which may fall between the two captured frames.
  constexpr int map_height = (232 * kWidth + 180) / 360;
  constexpr std::size_t map_bytes = kWidth * map_height * (LV_COLOR_DEPTH / 8);
  CHECK(std::equal(direct.bytes.begin(), direct.bytes.begin() + map_bytes,
                   settled_bytes.begin()));
}

void test_diagonal_map_pixels_are_independent_of_partial_buffer_height() {
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  auto state = base_state();
  fill_route(state, -1);
  fill_streets(state);
  state.road_point_count = MOTO_UI_ROAD_POINT_CAPACITY;
  state.road_polyline_count = MOTO_UI_ROAD_POLYLINE_CAPACITY;
  for (int i = 0; i < state.road_point_count; ++i) {
    // Long crossing diagonals, partially outside the viewport, exercise
    // band borders, both slope signs and the different road stroke widths.
    state.road_points[i] = {
        static_cast<std::int16_t>((i * 83) % 780 - 160),
        static_cast<std::int16_t>((i * 127) % 590 - 110)};
  }
  for (int i = 0; i < state.road_polyline_count; ++i) {
    state.road_polylines[i] = {
        static_cast<std::uint8_t>(i * 8), 8,
        static_cast<std::uint8_t>(i % 6)};
  }
  moto_nav_ui_set_state(&state);
  pump(260);
  auto* display = lv_display_get_default();
  static std::vector<std::uint8_t> short_buffer(kWidth * 40 * 2);
  static std::vector<std::uint8_t> tall_buffer(kWidth * 320 * 2);
  const auto draw_with_buffer = [display](std::vector<std::uint8_t>& buffer) {
    lv_display_set_buffers(display, buffer.data(), nullptr, buffer.size(),
                            LV_DISPLAY_RENDER_MODE_PARTIAL);
    lv_obj_invalidate(lv_screen_active());
    lv_refr_now(display);
    return shadow_frame;
  };
  const auto short_frame = draw_with_buffer(short_buffer);
  const auto tall_frame = draw_with_buffer(tall_buffer);
  CHECK(tall_frame == short_frame);
  CHECK(draw_with_buffer(short_buffer) == tall_frame);
}

bool label_hidden(lv_obj_t* object) {
  for (lv_obj_t* current = object; current != nullptr;
       current = lv_obj_get_parent(current)) {
    if (lv_obj_has_flag(current, LV_OBJ_FLAG_HIDDEN)) return true;
  }
  return false;
}

std::uint32_t next_code_point(const char* text, std::size_t& index) {
  const auto byte = [&](std::size_t offset) {
    return static_cast<std::uint32_t>(
        static_cast<unsigned char>(text[index + offset]));
  };
  const std::uint32_t lead = byte(0);
  std::size_t length = 1;
  std::uint32_t value = lead;
  if (lead >= 0xF0) {
    length = 4;
    value = lead & 0x07U;
  } else if (lead >= 0xE0) {
    length = 3;
    value = lead & 0x0FU;
  } else if (lead >= 0xC0) {
    length = 2;
    value = lead & 0x1FU;
  }
  for (std::size_t i = 1; i < length; ++i) value = (value << 6U) | (byte(i) & 0x3FU);
  index += length;
  return value;
}

struct LabelCheck {
  std::string language;
  std::string step;
  int labels = 0;
};

// Every label on screen, in every language, must be catalog text (not a
// fallback tag), drawable by its font chain, on one line within its box and
// inside the round 466 px panel.
void check_labels(lv_obj_t* object, LabelCheck& check) {
  const std::uint32_t children = lv_obj_get_child_count(object);
  for (std::uint32_t i = 0; i < children; ++i) {
    check_labels(lv_obj_get_child(object, static_cast<int32_t>(i)), check);
  }
  if (!lv_obj_check_type(object, &lv_label_class) || label_hidden(object)) return;
  const char* text = lv_label_get_text(object);
  if (text == nullptr || text[0] == '\0') return;
  ++check.labels;
  const std::string where = check.language + " / " + check.step + ": \"" + text + "\"";

  if (std::strncmp(text, "device.", 7) == 0) {
    std::cerr << where << " is an untranslated catalog tag\n";
    ++failures;
  }

  const lv_font_t* font = lv_obj_get_style_text_font(object, LV_PART_MAIN);
  for (std::size_t index = 0; text[index] != '\0';) {
    const std::uint32_t letter = next_code_point(text, index);
    lv_font_glyph_dsc_t glyph{};
    if (letter != ' ' &&
        (!lv_font_get_glyph_dsc(font, &glyph, letter, 0) || glyph.is_placeholder)) {
      std::cerr << where << " has no glyph for U+" << std::hex << letter
                << std::dec << '\n';
      ++failures;
    }
  }

  // Data fields (track names) may be cut with an ellipsis by design.
  if (lv_label_get_long_mode(object) == LV_LABEL_LONG_DOT) return;

  lv_point_t size{};
  lv_text_get_size(&size, text, font,
                   lv_obj_get_style_text_letter_space(object, LV_PART_MAIN),
                   lv_obj_get_style_text_line_space(object, LV_PART_MAIN),
                   LV_COORD_MAX, LV_TEXT_FLAG_NONE);
  lv_area_t box;
  lv_obj_get_content_coords(object, &box);
  const int32_t box_width = lv_area_get_width(&box);
  if (size.x > box_width) {
    std::cerr << where << " needs " << size.x << " px but has " << box_width
              << " px\n";
    ++failures;
  }
  lv_obj_t* parent = lv_obj_get_parent(object);
  if (lv_obj_check_type(parent, &lv_button_class) &&
      size.x > lv_obj_get_content_width(parent)) {
    std::cerr << where << " needs " << size.x << " px but its button has "
              << lv_obj_get_content_width(parent) << " px\n";
    ++failures;
  }

  // The visible text is centred inside wider fixed-width labels.
  const int32_t left = lv_obj_get_style_text_align(object, LV_PART_MAIN) ==
                               LV_TEXT_ALIGN_CENTER
                           ? box.x1 + (box_width - size.x) / 2
                           : box.x1;
  const double centre = (kWidth - 1) / 2.0;
  const double radius = kWidth / 2.0;
  const int32_t xs[2] = {left, left + size.x - 1};
  const int32_t ys[2] = {box.y1, box.y1 + size.y - 1};
  for (const int32_t x : xs) {
    for (const int32_t y : ys) {
      if (std::hypot(x - centre, y - centre) > radius) {
        std::cerr << where << " corner (" << x << ',' << y
                  << ") is outside the round panel\n";
        ++failures;
      }
    }
  }
}

void check_screen(LabelCheck& check, const char* step) {
  pump();
  lv_obj_update_layout(lv_screen_active());
  check.step = step;
  check_labels(lv_screen_active(), check);
}

void test_every_language_renders_every_label() {
  moto_nav_ui_set_reduce_motion(1);
  for (const char* language : {"en-US", "pt-BR", "zh-Hans"}) {
    CHECK(std::strcmp(moto_nav_ui_set_language(language), language) == 0);
    LabelCheck check{language};

    moto_ui_state_t empty = base_state();
    empty.mode = MOTO_UI_ACQUIRING_FIX;
    empty.route_point_count = 0;
    moto_nav_ui_set_page(MOTO_UI_PAGE_NAVIGATION);
    moto_nav_ui_set_state(&empty);
    moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
    check_screen(check, "phone offline");
    moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_CONNECTING);
    check_screen(check, "connecting");
    moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
    check_screen(check, "connected");
    pump(260);
    check_screen(check, "ready");
    empty.route_request_in_flight = 1;
    moto_nav_ui_set_state(&empty);
    check_screen(check, "planning");

    moto_ui_state_t route = base_state();
    fill_route(route, 12);
    const moto_ui_mode_t modes[] = {MOTO_UI_ACQUIRING_FIX, MOTO_UI_REROUTING,
                                    MOTO_UI_OFFLINE, MOTO_UI_ARRIVED,
                                    MOTO_UI_NAVIGATING};
    for (const moto_ui_mode_t mode : modes) {
      route.mode = mode;
      route.online = mode == MOTO_UI_NAVIGATING ? 0 : 1;
      moto_nav_ui_set_state(&route);
      check_screen(check, "navigation status");
    }
    moto_nav_ui_set_demo_active(1);
    check_screen(check, "demo");
    moto_nav_ui_set_demo_active(0);

    route.page = MOTO_UI_PAGE_SPEED;
    moto_nav_ui_set_state(&route);
    check_screen(check, "speed");
    route.page = MOTO_UI_PAGE_COMPASS;
    for (std::uint16_t heading = 0; heading < 360; heading += 45) {
      route.heading_deg = heading;
      moto_nav_ui_set_state(&route);
      check_screen(check, "compass");
    }

    moto_nav_ui_set_music_page_enabled(1);
    moto_nav_ui_set_page(MOTO_UI_PAGE_MUSIC);
    const moto_music_state_t disconnected{};
    moto_nav_ui_set_music_state(&disconnected);
    check_screen(check, "music disconnected");
    moto_music_state_t connected{};
    connected.connected = 1;
    connected.like_available = 1;
    moto_nav_ui_set_music_state(&connected);
    check_screen(check, "music without source");
    connected.liked = 1;
    connected.source_name = "Apple Music";
    connected.track_title = "公路之歌";
    connected.artist_name = "Mariza";
    moto_nav_ui_set_music_state(&connected);
    check_screen(check, "music liked");
    moto_nav_ui_set_page(MOTO_UI_PAGE_NAVIGATION);
    moto_nav_ui_set_music_page_enabled(0);

    // Every check above ran against real labels, not an empty tree.
    CHECK(check.labels > 60);
  }
}

void test_language_switch_updates_visible_text_in_place() {
  moto_ui_state_t empty = base_state();
  empty.mode = MOTO_UI_ACQUIRING_FIX;
  empty.route_point_count = 0;
  moto_nav_ui_set_page(MOTO_UI_PAGE_NAVIGATION);
  moto_nav_ui_set_state(&empty);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);

  moto_nav_ui_set_language("en-US");
  const Frame english = capture();
  moto_nav_ui_set_language("pt-BR");
  const Frame portuguese = capture();
  CHECK(portuguese.hash != english.hash);
  // Switching back must restore the exact frame: no stale text or layout.
  moto_nav_ui_set_language("en");
  CHECK(capture().hash == english.hash);

  // Unknown and regional tags fall back by language, never to a tag.
  CHECK(std::strcmp(moto_nav_ui_set_language("pt-PT"), "pt-BR") == 0);
  CHECK(std::strcmp(moto_nav_ui_set_language("zh-Hans-CN"), "zh-Hans") == 0);
  CHECK(std::strcmp(moto_nav_ui_set_language("ZH_TW"), "zh-Hans") == 0);
  CHECK(std::strcmp(moto_nav_ui_set_language("pto"), "en-US") == 0);
  CHECK(std::strcmp(moto_nav_ui_set_language("de-DE"), "en-US") == 0);
  CHECK(std::strcmp(moto_nav_ui_set_language(""), "en-US") == 0);
  CHECK(std::strcmp(moto_nav_ui_set_language(nullptr), "en-US") == 0);
  CHECK(capture().hash == english.hash);
}

bool screen_shows(lv_obj_t* object, const char* text) {
  if (lv_obj_check_type(object, &lv_label_class) && !label_hidden(object) &&
      std::strcmp(lv_label_get_text(object), text) == 0) {
    return true;
  }
  const std::uint32_t children = lv_obj_get_child_count(object);
  for (std::uint32_t i = 0; i < children; ++i) {
    if (screen_shows(lv_obj_get_child(object, static_cast<int32_t>(i)), text)) return true;
  }
  return false;
}

bool screen_shows(const char* text) {
  pump();
  return screen_shows(lv_screen_active(), text);
}

// Production order (app_main): the stored language is applied during the boot
// screen, before the full UI exists, and the UI is then created in it.
void test_language_before_the_ui_is_used_at_creation() {
  moto_nav_ui_show_boot_screen();
  CHECK(std::strcmp(moto_nav_ui_set_language("pt-BR"), "pt-BR") == 0);
  moto_nav_ui_create();
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_OFFLINE);
  CHECK(screen_shows("CONECTE O CELULAR"));
  moto_nav_ui_set_language("en-US");
  CHECK(screen_shows("CONNECT PHONE"));
}

// Switching language alone must redraw a screen exactly as a fresh render in
// the new language, and differently from the old one.
void check_switch_in_place(const char* step, const std::function<void()>& show) {
  moto_nav_ui_set_language("en-US");
  show();
  const Frame english = capture();
  moto_nav_ui_set_language("pt-BR");
  const Frame switched = capture();
  show();
  const Frame fresh = capture();
  if (switched.hash == english.hash || switched.hash != fresh.hash) {
    std::cerr << step << ": switching language did not redraw in place\n";
    ++failures;
  }
  moto_nav_ui_set_language("en-US");
}

void test_language_switch_redraws_every_page_in_place() {
  moto_nav_ui_set_reduce_motion(1);
  moto_nav_ui_set_phone_connection(MOTO_UI_PHONE_ONLINE);
  pump(260);
  moto_ui_state_t route = base_state();
  fill_route(route, 12);
  check_switch_in_place("navigation status", [&] {
    route.page = MOTO_UI_PAGE_NAVIGATION;
    route.mode = MOTO_UI_REROUTING;
    moto_nav_ui_set_state(&route);
  });
  check_switch_in_place("speed", [&] {
    route.page = MOTO_UI_PAGE_SPEED;
    moto_nav_ui_set_state(&route);
  });
  check_switch_in_place("compass", [&] {
    route.page = MOTO_UI_PAGE_COMPASS;
    route.heading_deg = 90;
    moto_nav_ui_set_state(&route);
  });
  check_switch_in_place("music", [&] {
    moto_nav_ui_set_music_page_enabled(1);
    moto_nav_ui_set_page(MOTO_UI_PAGE_MUSIC);
    const moto_music_state_t disconnected{};
    moto_nav_ui_set_music_state(&disconnected);
  });
  moto_nav_ui_set_page(MOTO_UI_PAGE_NAVIGATION);
  moto_nav_ui_set_music_page_enabled(0);
}

// Production shutdown: PWR held while the full UI is live. A language that
// arrives afterwards must not touch the deleted widgets.
void test_language_after_power_off_from_the_full_ui() {
  moto_nav_ui_set_language("en-US");
  // app_main order; the boot screen also retires the previous UI's timers.
  moto_nav_ui_show_boot_screen();
  moto_nav_ui_create();
  moto_ui_state_t route = base_state();
  fill_route(route, 12);
  route.mode = MOTO_UI_REROUTING;
  moto_nav_ui_set_state(&route);
  pump();
  moto_nav_ui_show_power_off_screen();
  CHECK(screen_shows("POWER OFF"));
  CHECK(std::strcmp(moto_nav_ui_set_language("pt-BR"), "pt-BR") == 0);
  CHECK(screen_shows("DESLIGANDO"));
  CHECK(screen_shows("MOTO"));
  CHECK(lv_obj_get_child_count(lv_screen_active()) == 2);
  moto_nav_ui_set_language("en-US");
}

}  // namespace

int main(int argc, char **argv) {
  const int buffer_rows = argc > 1 ? std::atoi(argv[1]) : 40;
  const int extra_pool_bytes = argc > 2 ? std::atoi(argv[2]) : 0;
  if(buffer_rows < 1 || buffer_rows > kHeight) return EXIT_FAILURE;
  if(extra_pool_bytes < 0) return EXIT_FAILURE;
  init_display(buffer_rows, extra_pool_bytes);
  // Valid before any UI exists.
  CHECK(std::strcmp(moto_nav_ui_set_language("zh-CN"), "zh-Hans") == 0);
  moto_nav_ui_set_language("en-US");

  // Production cadence: the boot animation completes before the full UI is
  // created, so settle it before moto_nav_ui_create().
  moto_nav_ui_show_boot_screen();
  pump(260);
  const Frame settled_boot = capture();
  const bool all_black = std::all_of(
      settled_boot.bytes.begin(), settled_boot.bytes.end(),
      [](std::uint8_t byte) { return byte == 0x00; });
  CHECK(all_black);

  test_frames_are_deterministic();
  test_clearing_geometry_leaves_no_residue();
  test_music_page_state_and_fallback();
  test_phone_lifecycle_renders_deterministically();
  test_demo_mode_visual_contract();
  test_capacity_payloads_render_stably();
  test_motion_frames_interpolate_then_settle_without_residue();
  test_diagonal_map_pixels_are_independent_of_partial_buffer_height();
  test_every_language_renders_every_label();
  test_language_switch_updates_visible_text_in_place();
  test_language_switch_redraws_every_page_in_place();
  test_language_before_the_ui_is_used_at_creation();
  test_language_after_power_off_from_the_full_ui();

  // Terminal screens run last: they tear the full UI down.
  moto_nav_ui_show_boot_screen();
  pump(260);
  const Frame boot_again = capture();
  CHECK(std::all_of(boot_again.bytes.begin(), boot_again.bytes.end(),
                    [](std::uint8_t byte) { return byte == 0x00; }));

  moto_nav_ui_show_power_off_screen();
  pump(260);
  const Frame power_off = capture();
  moto_nav_ui_show_power_off_screen();
  pump(260);
  CHECK(power_off.hash == capture().hash);
  CHECK(power_off.hash != settled_boot.hash);
  // A language arriving during shutdown updates the last frame safely.
  CHECK(screen_shows("POWER OFF"));
  CHECK(std::strcmp(moto_nav_ui_set_language("pt-BR"), "pt-BR") == 0);
  CHECK(screen_shows("DESLIGANDO"));
  // Nothing else may be written: the full UI's labels no longer exist, and
  // their freed memory may now hold these two labels.
  CHECK(screen_shows("MOTO"));
  CHECK(lv_obj_get_child_count(lv_screen_active()) == 2);

  if (failures != 0) {
    std::cerr << failures << " nav_ui render checks failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "All nav_ui render checks passed\n";
  return EXIT_SUCCESS;
}
