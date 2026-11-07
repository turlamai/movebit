// MoveBit Linux host — GTK4 windows over one embedded Racket CS backend.
// Port of the SwiftUI host (macos-host): every policy decision — tick,
// scheduling, break lifecycle, persistence — lives in the backend; this file
// renders state and forwards user actions. Boot the runtime off the UI
// thread, drive the product through the generated typed client
// (rivet_app::API), and dispatch every completion/event back to the main loop
// before touching widgets.
//
// Platform notes (documented gaps vs the macOS host):
//   • No tray: the StatusNotifierItem contract is upstream issue #118; the
//     main window is the hub (closing it flushes and quits).
//   • Toast/micro cards are frameless keep-above windows; GTK4 removed
//     toplevel positioning, so the WM chooses placement.
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/x11/gdkx.h>
#include <X11/Xlib.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/wayland/gdkwayland.h>
#endif
#include <pango/pangocairo.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

#include "GeneratedBackend.hpp"
#include "l10n.hpp"
#include "system_services.hpp"

namespace {

// ---- copy/format helpers (parity with the Swift CopyPool/CopyFormat) ------

std::int64_t now_ms() {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return static_cast<std::int64_t>(ts.tv_sec) * 1000 +
         static_cast<std::int64_t>(ts.tv_nsec) / 1000000;
}

bool late_night() {
  std::time_t t = std::time(nullptr);
  std::tm local{};
#if defined(_WIN32)
  localtime_s(&local, &t);
#else
  localtime_r(&t, &local);
#endif
  return local.tm_hour >= 22 || local.tm_hour < 6;
}

/// "45m" / "2h05m" (parity with MainViewModel.FormatMinutes).
std::string format_minutes(std::int64_t total) {
  total = std::max<std::int64_t>(0, total);
  if (total < 60) return std::to_string(total) + "m";
  std::string h = std::to_string(total / 60);
  std::string m = std::to_string(total % 60);
  if (m.size() < 2) m = "0" + m;
  return h + "h" + m + "m";
}

std::string pad2(std::int64_t n) {
  std::string s = std::to_string(n);
  if (s.size() < 2) s = "0" + s;
  return s;
}

/// Localized big-number duration ("2 hr 05 min" / "45 min").
std::string format_duration(std::int64_t total) {
  total = std::max<std::int64_t>(0, total);
  return total >= 60
             ? l10n::t("app.hourMin", {l10n::A(total / 60), l10n::A(pad2(total % 60))})
             : l10n::t("app.minutes", {l10n::A(total)});
}

/// Compact axis label: "·" for zero (parity with FormatMinutesCompact).
std::string format_compact(std::int64_t total) {
  if (total == 0) return "·";
  return total >= 60 ? std::to_string(total / 60) + "h"
                     : std::to_string(total) + "m";
}

std::string pick_water() {
  return late_night() ? l10n::pick("copy.lateNightWaterPool", 3)
                      : l10n::pick("copy.waterPool", 8);
}

std::string pick_micro() {
  return late_night() ? l10n::pick("copy.lateNightMicroPool", 3)
                      : l10n::pick("copy.microPool", 9);
}

std::string day_key(std::int64_t epoch_ms) {
  return l10n::format_epoch(epoch_ms, "%Y-%m-%d");
}

// ---- model ----------------------------------------------------------------

struct Model {
  // Pre-bootstrap placeholder = the shipped balanced default; the backend
  // overwrites it with the real persisted config right after init.
  rivet_app::ReminderConfig config{
      50, 60, 5, 10, true, 20, 20, true, false, true, false, "auto",
      "M", "subtle", "bottom-right", "cue", "balanced", true, true, false,
      1320, 420, -1, -1};
  rivet_app::DayStats today{"", 0, 0, 0, 0, 0};
  rivet_app::PauseState paused{false, std::nullopt};
  std::vector<rivet_app::LoopInfo> loops;
  // Cues currently pending or on screen (backend reconciliation view).
  std::vector<rivet_app::HealthCue> pending_cues;
  // Per-kind delivery/response truth for today (issue #88): shown and
  // self-reported done are separate from the fired-reminder counters, and
  // nothing here claims a verified break.
  std::vector<rivet_app::CueOutcomeTotals> outcomes;
  bool quiet = false;
  std::vector<rivet_app::DayStats> history;
  int history_days = 7;
  bool autostart = false;
  std::string data_dir;
  std::string config_status;

  std::optional<rivet_app::LoopInfo> loop(rivet_app::ReminderKind kind) const {
    for (auto const& l : loops) {
      if (l.kind == kind) return l;
    }
    return std::nullopt;
  }
  std::optional<rivet_app::CueOutcomeTotals> outcome(
      rivet_app::ReminderKind kind) const {
    for (auto const& o : outcomes) {
      if (o.kind == kind) return o;
    }
    return std::nullopt;
  }
  bool is_paused() const { return paused.paused; }
  /// Nearest enabled kind still counting down, in active minutes. Nil while
  /// paused or when every kind is off — the UI then says so instead of
  /// promising a cue that will not fire.
  std::optional<std::pair<rivet_app::ReminderKind, std::int64_t>> next_cue()
      const {
    if (is_paused()) return std::nullopt;
    std::optional<std::pair<rivet_app::ReminderKind, std::int64_t>> best;
    for (auto const& l : loops) {
      if (!l.due_in_active_mins.has_value()) continue;
      std::int64_t const due = std::max<std::int64_t>(0, *l.due_in_active_mins);
      if (!best.has_value() || due < best->second) {
        best = std::make_pair(l.kind, due);
      }
    }
    return best;
  }
  static std::string kind_label(rivet_app::ReminderKind kind) {
    switch (kind) {
      case rivet_app::ReminderKind::sit: return l10n::t("today.sit");
      case rivet_app::ReminderKind::water: return l10n::t("today.water");
      case rivet_app::ReminderKind::micro: return l10n::t("today.micro");
    }
    return "";
  }
  std::int64_t current_session_mins() const {
    auto sit = loop(rivet_app::ReminderKind::sit);
    return sit.has_value() ? sit->accumulated_mins : 0;
  }
};

struct AppState {
  GtkWindow* window{nullptr};
  GtkApplication* app{nullptr};
  // Headless packaged acceptance: skip the companion so the UIA/AT-SPI
  // probe sees exactly the main window (mirrors the macOS posture).
  bool acceptance{false};
  GtkButton* pause_button{nullptr};
  GtkButton* quit_button{nullptr};
  GtkButton* focus_button{nullptr};
  GtkButton* move_button{nullptr};  // tray-less desktop fallback
  GtkBox* content_root{nullptr};  // cleared + rebuilt on language change

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;
  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};

  Model model;
  std::string language{"zh"};
  bool updating_settings{false};

  // Toast (bottom reminder card). cue_id carries the v1 lifecycle payload;
  // 0 marks a plain informational toast without actions.
  GtkWindow* toast_window{nullptr};
  guint toast_timeout_id{0};
  rivet_app::ReminderKind toast_accent = rivet_app::ReminderKind::sit;
  std::int64_t toast_cue_id = 0;
  GtkLabel* toast_title_label{nullptr};
  GtkBox* toast_lines_box{nullptr};
  GtkButton* toast_snooze_button{nullptr};

  // Micro eye-rest card.
  GtkWindow* micro_window{nullptr};
  guint micro_timeout_id{0};
  double micro_progress = 1.0;
  std::int64_t micro_total_ms = 1000;
  std::int64_t micro_cue_id = 0;
  GtkProgressBar* micro_bar{nullptr};
  GtkLabel* micro_hint{nullptr};
  GtkButton* micro_start_button{nullptr};
  bool micro_started = false;

  // Mubi（沐比）companion (issue #56): X11-only presentation. On Wayland
  // the compositor owns placement, so the companion stays OFF there and
  // cues deliver as notifications (the documented #54/#56 fallback).
  GtkWindow* mubi_window{nullptr};
  GtkDrawingArea* mubi_canvas{nullptr};
  GtkLabel* mubi_capsule{nullptr};
  std::int64_t mubi_cue_id{0};
  guint mubi_expire_id{0};
  int mubi_state = 0;  // 0 idle, 1 water, 2 stand, 3 eyes, 4 ack, 5 focus
  std::string mubi_message;
  // Gesture animation (#56 §4): one expressive motion per cue, 33 ms ticks
  // redrawing the cairo canvas; still = static, lively = slightly slower.
  double mubi_anim_progress = 1.0;
  double mubi_anim_step = 0.0;
  guint mubi_anim_tick_id{0};
  std::string mubi_size = "M";
  std::string mubi_motion = "subtle";
  std::string mubi_dock = "bottom-right";
  // Issue #104: normalized directly placed home (-1 = named dock). The GTK
  // host honors a persisted position; direct manipulation is macOS-first.
  std::int64_t mubi_free_x = -1;
  std::int64_t mubi_free_y = -1;
  // Temporary direct-placement mode (issue #104). Input is captured only on
  // the character's own canvas rectangle while this is true; every exit
  // restores the empty X11 input region.
  bool mubi_placing = false;
  guint mubi_place_timer = 0;
  int mubi_drag_origin_x = 0;
  int mubi_drag_origin_y = 0;
  GtkButton* place_button{nullptr};
  bool mubi_labels_always = false;
  bool mubi_quiet = false;
  bool mubi_x11 = false;

  // Onboarding: one settle-in page, one Start button (issue #90).
  GtkWindow* onboarding_window{nullptr};

  void set_status(std::string const& text) {
    // Startup errors surface in the window subtitle position; once the main
    // content exists the status line doubles as the config-status footer.
    if (status_label != nullptr) {
      gtk_label_set_text(status_label, text.c_str());
    }
  }

  GtkLabel* status_label{nullptr};
};

AppState g_state;

std::string resolve_language(std::string const& configured) {
  if (configured != "auto") return configured;
  const char* lang = getenv("LANG");
  std::string l = lang != nullptr ? lang : "en";
  return l.rfind("zh", 0) == 0 ? "zh" : "en";
}

void apply_language() {
  l10n::g_language = g_state.language;
}

struct DaySlice {
  rivet_app::DayStats stats;
  std::int64_t day_start_ms;
  bool is_today;
};

/// Zero-filled day list ending today; today's entry is the live state.
std::vector<DaySlice> history_slice(int days) {
  std::vector<DaySlice> slices;
  std::string const today_key =
      g_state.model.today.date.empty() ? day_key(now_ms())
                                       : g_state.model.today.date;
  std::map<std::string, rivet_app::DayStats> by_date;
  for (auto const& d : g_state.model.history) {
    by_date.emplace(d.date, d);
  }
  // Local midnight of today, then walk back by whole days.
  std::time_t secs = static_cast<std::time_t>(now_ms() / 1000);
  std::tm local{};
#if defined(_WIN32)
  localtime_s(&local, &secs);
#else
  localtime_r(&secs, &local);
#endif
  local.tm_hour = 0;
  local.tm_min = 0;
  local.tm_sec = 0;
  std::int64_t const today_start =
      static_cast<std::int64_t>(std::mktime(&local)) * 1000;

  for (int offset = days - 1; offset >= 0; --offset) {
    std::int64_t const day_start =
        today_start - static_cast<std::int64_t>(offset) * 86400000;
    std::string const key = day_key(day_start);
    bool const is_today = key == today_key;
    auto it = by_date.find(key);
    rivet_app::DayStats stats =
        is_today ? g_state.model.today
                 : (it != by_date.end()
                        ? it->second
                        : rivet_app::DayStats{key, 0, 0, 0, 0, 0});
    slices.push_back(DaySlice{stats, day_start, is_today});
  }
  return slices;
}

struct InsightSummary {
  std::int64_t longest;
  std::int64_t average;
  rivet_app::DayStats busiest;  // date empty when none
  bool has_busiest;
};

/// 30-day aggregates over active days (parity with RebuildInsights).
InsightSummary insight_summary(int days) {
  auto slices = history_slice(days);
  InsightSummary s{0, 0, rivet_app::DayStats{}, false};
  std::int64_t active_total = 0;
  int active_days = 0;
  for (auto const& slice : slices) {
    s.longest = std::max(s.longest, slice.stats.longest_session_mins);
    if (slice.stats.active_mins > 0) {
      active_total += slice.stats.active_mins;
      ++active_days;
      if (!s.has_busiest || slice.stats.active_mins > s.busiest.active_mins) {
        s.busiest = slice.stats;
        s.has_busiest = true;
      }
    }
  }
  if (active_days > 0) {
    s.average = (active_total + active_days / 2) / active_days;
  }
  return s;
}

// ---- UI dispatch (completions/events arrive on the backend reader thread) --

struct UiTask {
  std::function<void()> run;
};

int run_ui_task(gpointer user_data) {
  auto* task = static_cast<UiTask*>(user_data);
  task->run();
  delete task;
  return G_SOURCE_REMOVE;
}

void dispatch_ui(std::function<void()> run) {
  g_idle_add(run_ui_task, new UiTask{std::move(run)});
}

template <typename T, typename Then>
void on_result(rivet_app::Result<T> result, Then then) {
  dispatch_ui([result = std::move(result), then = std::move(then)]() mutable {
    if (!result.succeeded()) {
      try {
        std::rethrow_exception(result.error);
      } catch (std::exception const& e) {
        g_state.set_status(e.what());
      }
      return;
    }
    try {
      then(result.get());
    } catch (std::exception const& e) {
      g_state.set_status(e.what());
    }
  });
}

/// Void-result variant: `then` takes no argument (there is nothing to unwrap).
template <typename Then>
void on_result(rivet_app::Result<void> result, Then then) {
  dispatch_ui([result = std::move(result), then = std::move(then)]() mutable {
    if (!result.succeeded()) {
      try {
        std::rethrow_exception(result.error);
      } catch (std::exception const& e) {
        g_state.set_status(e.what());
      }
      return;
    }
    try {
      then();
    } catch (std::exception const& e) {
      g_state.set_status(e.what());
    }
  });
}

// ---- main window rendering --------------------------------------------------

GtkWidget* make_card();
void build_main_content();
void refresh_pause_button();
void refresh_quit_button();
void refresh_header_buttons();
void refresh_today_card();
void refresh_history_card();
void refresh_insight_card();
void refresh_settings_widgets();
void refresh_status_label();
void schedule_chart_redraw();

// StatusNotifierItem tray (GNOME shows it through the AppIndicator
// extension; rivet's TrayIcon reports availability before we commit).
namespace tray {
void sync();
bool install();
bool installed();
}  // namespace tray

// One per-kind row in the today card's truthful outcome list.
struct OutcomeRowWidgets {
  GtkWidget* row{nullptr};
  GtkLabel* value{nullptr};
};

// Main-window widgets, rebuilt with the content.
struct MainWidgets {
  GtkLabel* today_duration{nullptr};
  GtkLabel* today_status{nullptr};
  GtkProgressBar* sit_bar{nullptr};
  GtkLabel* sit_cycle_text{nullptr};
  GtkLabel* today_next_cue{nullptr};
  OutcomeRowWidgets outcome_rows[3]{};
  GtkLabel* outcome_empty{nullptr};
  GtkLabel* hist_title{nullptr};
  GtkLabel* hist_total{nullptr};
  GtkDrawingArea* hist_chart{nullptr};
  GtkDropDown* hist_range{nullptr};
  GtkLabel* insight_metrics[4]{nullptr, nullptr, nullptr, nullptr};
  GtkLabel* insight_busiest{nullptr};
  GtkLabel* insight_sedentary{nullptr};
  GtkLabel* footer{nullptr};
  GtkLabel* about_version{nullptr};
  GtkButton* updates_button{nullptr};
  GtkLabel* updates_hint{nullptr};
  GtkLabel* config_status{nullptr};

  // Settings widgets (kept to apply config without re-signaling).
  GtkSpinButton* sit_spin{nullptr};
  GtkSpinButton* water_spin{nullptr};
  GtkSpinButton* away_spin{nullptr};
  GtkSpinButton* snooze_spin{nullptr};
  GtkSpinButton* micro_interval_spin{nullptr};
  GtkSpinButton* micro_duration_spin{nullptr};
  GtkSwitch* motion_switch{nullptr};
  GtkDropDown* mubi_size_drop{nullptr};
  GtkDropDown* mubi_motion_drop{nullptr};
  GtkDropDown* mubi_dock_drop{nullptr};
  GtkDropDown* mubi_labels_drop{nullptr};
  GtkSwitch* micro_switch{nullptr};
  GtkSwitch* sound_switch{nullptr};
  GtkSwitch* autostart_switch{nullptr};
  GtkSwitch* updates_switch{nullptr};
  GtkDropDown* language_drop{nullptr};
  // Rhythm presets (issues #87/#90): everyday surface above the disclosure.
  GtkToggleButton* preset_buttons[3]{nullptr, nullptr, nullptr};
  GtkLabel* preset_custom{nullptr};
  GtkLabel* preset_detail{nullptr};
  GtkLabel* settings_next_cue{nullptr};
  // Advanced (collapsed by default) controls.
  GtkWidget* advanced_box{nullptr};
  GtkSwitch* sit_switch{nullptr};
  GtkSwitch* water_switch{nullptr};
  GtkSwitch* quiet_switch{nullptr};
  GtkWidget* quiet_start_row{nullptr};
  GtkWidget* quiet_end_row{nullptr};
  GtkSpinButton* quiet_start_spin{nullptr};
  GtkSpinButton* quiet_end_spin{nullptr};
} mw;

/// Optimistic save with a targeted mutation; the backend clamps and
/// re-announces via config-changed.
template <typename F>
void mutate_config(F mutate) {
  if (g_state.api == nullptr) return;
  auto const previous = g_state.model.config;
  auto draft = previous;
  mutate(draft);
  g_state.model.config = draft;
  // The live language is NOT switched here: apply_config (the backend's
  // config-changed broadcast) owns it. An optimistic switch would make
  // apply_config's language_changed check miss the toggle — the host kept
  // rendering stale-language static text after switching (slice finding).
  (void)g_state.api->set_config_async(draft, [previous](rivet_app::Result<void> result) {
    dispatch_ui([result = std::move(result), previous]() mutable {
      if (result.succeeded()) {
        g_state.model.config_status =
            l10n::t("set.statusSaved", {l10n::T(now_ms())});
      } else {
        g_state.model.config = previous;  // roll back the optimistic draft
        g_state.model.config_status = l10n::t("set.statusSaveFailed");
      }
      refresh_status_label();
    });
  });
  refresh_status_label();
}

void set_autostart_host(bool enabled) {
  if (g_state.api == nullptr) return;
  g_state.model.autostart = enabled;
  (void)g_state.api->set_autostart_async(
      enabled, [](rivet_app::Result<void> result) {
        dispatch_ui([result = std::move(result)]() mutable {
          g_state.model.config_status =
              result.succeeded()
                  ? l10n::t("set.statusApplied", {l10n::T(now_ms())})
                  : l10n::t("set.statusSaveFailed");
          refresh_status_label();
        });
      });
}

GtkWidget* label_with(char const* text, char const* css) {
  auto* w = gtk_label_new(text);
  if (css != nullptr) gtk_widget_add_css_class(w, css);
  gtk_label_set_xalign(GTK_LABEL(w), 0.0f);
  return w;
}

/// GtkWidget*-friendly gtk_box_append: GTK classes are opaque, so upcasts
/// must go through the GTK_TYPE_CHECK_INSTANCE_CAST macros, which accept any
/// GTK pointer flavor.
template <typename Parent, typename Child>
void box_append(Parent* parent, Child* child) {
  gtk_box_append(GTK_BOX(parent), GTK_WIDGET(child));
}

GtkWidget* make_card() {
  auto* card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
  gtk_widget_add_css_class(card, "card");
  gtk_widget_set_margin_top(card, 18);
  gtk_widget_set_margin_bottom(card, 18);
  gtk_widget_set_margin_start(card, 18);
  gtk_widget_set_margin_end(card, 18);
  return card;
}

GtkSpinButton* add_stepper_row(GtkWidget* parent, char const* label, double value,
                               double min, double max, double step,
                               GCallback changed) {
  auto* row = GTK_BOX(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8));
  box_append(row, label_with(label, "row-label"));
  auto* spin = gtk_spin_button_new_with_range(min, max, step);
  gtk_spin_button_set_value(GTK_SPIN_BUTTON(spin), value);
  gtk_spin_button_set_numeric(GTK_SPIN_BUTTON(spin), TRUE);
  g_signal_connect(spin, "value-changed", changed, nullptr);
  box_append(row, spin);
  box_append(parent, GTK_WIDGET(row));
  return GTK_SPIN_BUTTON(spin);
}

GtkSwitch* add_toggle_row(GtkWidget* parent, char const* label, bool on,
                          GCallback toggled) {
  auto* row = GTK_BOX(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8));
  box_append(row, label_with(label, "row-label"));
  auto* sw = gtk_switch_new();
  gtk_switch_set_active(GTK_SWITCH(sw), on);
  g_signal_connect(sw, "state-set", toggled, nullptr);
  auto* box = GTK_BOX(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0));
  gtk_widget_set_hexpand(GTK_WIDGET(box), TRUE);
  gtk_widget_set_halign(GTK_WIDGET(box), GTK_ALIGN_END);
  box_append(box, sw);
  box_append(row, GTK_WIDGET(box));
  box_append(parent, GTK_WIDGET(row));
  return GTK_SWITCH(sw);
}

// ---- settings callbacks -----------------------------------------------------

void on_sit_changed(GtkSpinButton* spin, gpointer) {
  if (g_state.updating_settings) return;
  mutate_config([&](auto& d) {
    d.sit_reminder_minutes =
        static_cast<std::int64_t>(gtk_spin_button_get_value(spin));
  });
}
void on_water_changed(GtkSpinButton* spin, gpointer) {
  if (g_state.updating_settings) return;
  mutate_config([&](auto& d) {
    d.water_reminder_minutes =
        static_cast<std::int64_t>(gtk_spin_button_get_value(spin));
  });
}
void on_away_changed(GtkSpinButton* spin, gpointer) {
  if (g_state.updating_settings) return;
  mutate_config([&](auto& d) {
    d.away_reset_minutes =
        static_cast<std::int64_t>(gtk_spin_button_get_value(spin));
  });
}
void on_snooze_changed(GtkSpinButton* spin, gpointer) {
  if (g_state.updating_settings) return;
  mutate_config([&](auto& d) {
    d.snooze_minutes =
        static_cast<std::int64_t>(gtk_spin_button_get_value(spin));
  });
}
void on_micro_interval_changed(GtkSpinButton* spin, gpointer) {
  if (g_state.updating_settings) return;
  mutate_config([&](auto& d) {
    d.micro_break_interval_minutes =
        static_cast<std::int64_t>(gtk_spin_button_get_value(spin));
  });
}
void on_micro_duration_changed(GtkSpinButton* spin, gpointer) {
  if (g_state.updating_settings) return;
  mutate_config([&](auto& d) {
    d.micro_break_duration_seconds =
        static_cast<std::int64_t>(gtk_spin_button_get_value(spin));
  });
}
int on_motion_set(GtkSwitch*, gboolean state, gpointer) {
  if (!g_state.updating_settings) {
    mutate_config([&](auto& d) { d.motion_enabled = state != FALSE; });
  }
  return FALSE;
}

// Mubi presentation pickers: value tables mirror the backend's clamp
// choices; an out-of-range selection is impossible via the UI.
static char const* const kMubiSizes[] = {"S", "M", "L"};
static char const* const kMubiMotions[] = {"still", "subtle", "lively"};
static char const* const kMubiDocks[] = {"bottom-right", "bottom-left",
                                         "top-right", "top-left"};
static char const* const kMubiLabels[] = {"cue", "always"};
static char const* const kLanguages[] = {"auto", "zh", "en"};

template <std::size_t N>
bool dropdown_index_valid(GtkDropDown* drop, unsigned& index) {
  index = gtk_drop_down_get_selected(drop);
  return index < N;
}

void on_mubi_size_changed(GtkDropDown* drop, gpointer) {
  if (g_state.updating_settings) return;
  unsigned index = 0;
  if (!dropdown_index_valid<3>(drop, index)) return;
  mutate_config([&](auto& d) { d.companion_size = kMubiSizes[index]; });
}

void on_mubi_motion_changed(GtkDropDown* drop, gpointer) {
  if (g_state.updating_settings) return;
  unsigned index = 0;
  if (!dropdown_index_valid<3>(drop, index)) return;
  mutate_config([&](auto& d) { d.companion_motion = kMubiMotions[index]; });
}

void on_mubi_dock_changed(GtkDropDown* drop, gpointer) {
  if (g_state.updating_settings) return;
  unsigned index = 0;
  if (!dropdown_index_valid<4>(drop, index)) return;
  mutate_config([&](auto& d) { d.companion_dock = kMubiDocks[index]; });
}

void on_mubi_labels_changed(GtkDropDown* drop, gpointer) {
  if (g_state.updating_settings) return;
  unsigned index = 0;
  if (!dropdown_index_valid<2>(drop, index)) return;
  mutate_config([&](auto& d) { d.companion_labels = kMubiLabels[index]; });
}
int on_micro_set(GtkSwitch*, gboolean state, gpointer) {
  if (!g_state.updating_settings) {
    mutate_config([&](auto& d) { d.micro_break_enabled = state != FALSE; });
  }
  return FALSE;
}
int on_sound_set(GtkSwitch*, gboolean state, gpointer) {
  if (!g_state.updating_settings) {
    mutate_config([&](auto& d) { d.sound_enabled = state != FALSE; });
  }
  return FALSE;
}
int on_autostart_set(GtkSwitch*, gboolean state, gpointer) {
  if (!g_state.updating_settings) set_autostart_host(state != FALSE);
  return FALSE;
}
int on_updates_set(GtkSwitch*, gboolean state, gpointer) {
  if (!g_state.updating_settings) {
    mutate_config([&](auto& d) { d.auto_check_updates = state != FALSE; });
  }
  return FALSE;
}

// Named rhythm presets: the host only sends the name. The backend owns the
// cadence values and re-derives the stored preset label from them, so the
// host never sends "custom" itself.
static char const* const kPresets[] = {"balanced", "gentle", "active"};
static char const* const kPresetLabels[] = {"preset.balanced",
                                            "preset.gentle",
                                            "preset.active"};

void apply_rhythm_preset(std::string const& name) {
  if (g_state.api == nullptr) return;
  (void)g_state.api->set_rhythm_preset_async(
      name, [](rivet_app::Result<void> result) {
        dispatch_ui([result = std::move(result)]() mutable {
          g_state.model.config_status =
              result.succeeded()
                  ? l10n::t("set.statusSaved", {l10n::T(now_ms())})
                  : l10n::t("set.statusSaveFailed");
          // A failed call leaves model.config.preset unchanged: re-sync the
          // chips so the optimistic highlight cannot claim a saved rhythm.
          if (!result.succeeded()) refresh_settings_widgets();
          refresh_status_label();
        });
      });
}

void on_preset_toggled(GtkToggleButton* button, gpointer) {
  if (g_state.updating_settings) return;
  // Clicking the selected chip again must not deselect it (nor re-apply
  // anything): a segmented control always keeps one choice highlighted.
  if (!gtk_toggle_button_get_active(button)) {
    g_state.updating_settings = true;
    gtk_toggle_button_set_active(button, TRUE);
    g_state.updating_settings = false;
    return;
  }
  auto const* name =
      static_cast<char const*>(g_object_get_data(G_OBJECT(button), "preset"));
  if (name == nullptr) return;
  // Re-select happens in refresh_settings_widgets once the backend's
  // config-changed broadcast lands; deselect siblings immediately so the
  // row never shows two selected chips in the meantime.
  g_state.updating_settings = true;
  for (auto*& preset_button : mw.preset_buttons) {
    if (preset_button != button) {
      gtk_toggle_button_set_active(preset_button, FALSE);
      gtk_widget_remove_css_class(GTK_WIDGET(preset_button),
                                  "rhythm-chip-selected");
    }
  }
  g_state.updating_settings = false;
  gtk_widget_add_css_class(GTK_WIDGET(button), "rhythm-chip-selected");
  apply_rhythm_preset(name);
}

int on_sit_enabled_set(GtkSwitch*, gboolean state, gpointer) {
  if (!g_state.updating_settings) {
    mutate_config([&](auto& d) { d.sit_enabled = state != FALSE; });
  }
  return FALSE;
}

int on_water_enabled_set(GtkSwitch*, gboolean state, gpointer) {
  if (!g_state.updating_settings) {
    mutate_config([&](auto& d) { d.water_enabled = state != FALSE; });
  }
  return FALSE;
}

int on_quiet_hours_set(GtkSwitch*, gboolean state, gpointer) {
  if (!g_state.updating_settings) {
    mutate_config([&](auto& d) {
      d.quiet_hours_enabled = state != FALSE;
    });
  }
  return FALSE;
}

void on_quiet_start_changed(GtkSpinButton* spin, gpointer) {
  if (g_state.updating_settings) return;
  auto const hour = static_cast<std::int64_t>(
      gtk_spin_button_get_value(spin));
  mutate_config([&](auto& d) { d.quiet_hours_start_minutes = hour * 60; });
}

void on_quiet_end_changed(GtkSpinButton* spin, gpointer) {
  if (g_state.updating_settings) return;
  auto const hour = static_cast<std::int64_t>(
      gtk_spin_button_get_value(spin));
  mutate_config([&](auto& d) { d.quiet_hours_end_minutes = hour * 60; });
}

void on_customize_clicked(GtkButton* button, gpointer) {
  if (mw.advanced_box == nullptr) return;
  bool const show = !gtk_widget_get_visible(mw.advanced_box);
  gtk_widget_set_visible(mw.advanced_box, show);
  gtk_button_set_label(button,
                       l10n::t(show ? "set.collapse" : "set.customize").c_str());
}

void on_language_changed(GtkDropDown* drop, GParamSpec*, gpointer) {
  if (g_state.updating_settings) return;
  unsigned selected = 0;
  if (!dropdown_index_valid<3>(drop, selected)) return;
  mutate_config([&](auto& d) { d.language = kLanguages[selected]; });
}
void on_hist_range_changed(GtkDropDown* drop, GParamSpec*, gpointer) {
  auto const selected = gtk_drop_down_get_selected(drop);
  g_state.model.history_days = selected == 1 ? 30 : 7;
  refresh_history_card();
}

// ---- history chart ----------------------------------------------------------

void draw_history_chart(GtkDrawingArea*, cairo_t* cr, int width, int height,
                        gpointer) {
  auto slices = history_slice(g_state.model.history_days);
  bool const is_month = g_state.model.history_days >= 30;
  std::int64_t max_minutes = 60;
  std::vector<std::int64_t> active;
  for (auto const& s : slices) {
    max_minutes = std::max(max_minutes, s.stats.active_mins);
    if (s.stats.active_mins > 0) active.push_back(s.stats.active_mins);
  }

  auto set_color = [&](char const* hex, double alpha = 1.0) {
    unsigned r = 0, g = 0, b = 0;
    sscanf(hex, "#%02x%02x%02x", &r, &g, &b);
    cairo_set_source_rgba(cr, r / 255.0, g / 255.0, b / 255.0, alpha);
  };
  auto const label_h = 16.0;
  auto const baseline = height - label_h;
  auto const bar_area = baseline - 6.0;
  auto const bar_min = 5.0;
  auto const bar_max = bar_area - 14.0;
  auto const col_w = static_cast<double>(width) / slices.size();

  auto draw_text = [&](char const* text, double x, double y,
                       char const* color, bool bold, double size) {
    PangoLayout* layout = pango_cairo_create_layout(cr);
    PangoAttrList* attrs = pango_attr_list_new();
    pango_attr_list_insert(attrs, pango_attr_size_new_absolute(
                                      static_cast<int>(size * PANGO_SCALE)));
    if (bold) {
      pango_attr_list_insert(attrs, pango_attr_weight_new(PANGO_WEIGHT_SEMIBOLD));
    }
    pango_layout_set_attributes(layout, attrs);
    pango_attr_list_unref(attrs);
    PangoFontDescription* font =
        pango_font_description_from_string("Sans");
    pango_layout_set_font_description(layout, font);
    pango_font_description_free(font);
    pango_layout_set_text(layout, text, -1);
    int tw = 0, th = 0;
    pango_layout_get_pixel_size(layout, &tw, &th);
    set_color(color);
    cairo_move_to(cr, x - tw / 2.0, y - th);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
  };

  // Bars.
  for (std::size_t i = 0; i < slices.size(); ++i) {
    auto const& slice = slices[i];
    double const h = bar_min + (bar_max - bar_min) *
                                   static_cast<double>(slice.stats.active_mins) /
                                   static_cast<double>(max_minutes);
    double const bar_w = is_month ? 8.0 : 26.0;
    double const x = i * col_w + (col_w - bar_w) / 2.0;
    set_color(slice.is_today ? "#C25E3E" : "#D2C8B2");
    double const radius = 4.0;
    double const y = baseline - h;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + radius, y + radius, radius, M_PI, 1.5 * M_PI);
    cairo_line_to(cr, x + bar_w - radius, y);
    cairo_arc(cr, x + bar_w - radius, y + radius, radius, 1.5 * M_PI, 2 * M_PI);
    cairo_line_to(cr, x + bar_w, y + h);
    cairo_line_to(cr, x, y + h);
    cairo_close_path(cr);
    cairo_fill(cr);

    if (!is_month) {
      draw_text(format_compact(slice.stats.active_mins).c_str(),
                i * col_w + col_w / 2.0, y - 4,
                slice.is_today ? "#C25E3E" : "#A39B8D", slice.is_today, 10);
    }
    std::string day_label;
    if (slice.is_today) {
      day_label = l10n::t("hist.today");
    } else if (!is_month) {
      std::time_t t = static_cast<std::time_t>(slice.day_start_ms / 1000);
      std::tm lt{};
#if defined(_WIN32)
      localtime_s(&lt, &t);
#else
      localtime_r(&t, &lt);
#endif
      static char const* zh_days[] = {"日", "一", "二", "三", "四", "五", "六"};
      static char const* en_days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
      day_label = g_state.language == "en" ? en_days[lt.tm_wday]
                                           : zh_days[lt.tm_wday];
    } else if (!slice.stats.date.empty()) {
      int day = std::atoi(slice.stats.date.c_str() + 8);
      if (day % 5 == 0) day_label = std::to_string(day);
    }
    if (!day_label.empty()) {
      draw_text(day_label.c_str(), i * col_w + col_w / 2.0, height - 2,
                slice.is_today ? "#C25E3E" : "#6E6A5E", slice.is_today, 10.5);
    }
  }

  // Dashed daily-average line over active days.
  if (!active.empty()) {
    std::int64_t sum = 0;
    for (auto v : active) sum += v;
    std::int64_t const average = (sum + static_cast<std::int64_t>(active.size()) / 2) /
                                 static_cast<std::int64_t>(active.size());
    double const y = baseline - (bar_min + (bar_max - bar_min) *
                                            static_cast<double>(average) /
                                            static_cast<double>(max_minutes));
    set_color("#A39B8D", 0.55);
    cairo_set_line_width(cr, 1.0);
    double const dash[2] = {4.0, 3.0};
    cairo_set_dash(cr, dash, 2, 0);
    cairo_move_to(cr, 0, y);
    cairo_line_to(cr, width, y);
    cairo_stroke(cr);
    cairo_set_dash(cr, nullptr, 0, 0);
    draw_text(
        l10n::t("hist.avg", {l10n::A(format_compact(average))}).c_str(),
        width - 4, y - 2, "#A39B8D", false, 10);
  }

  // Baseline.
  set_color("#EAE2D6");
  cairo_set_line_width(cr, 1.0);
  cairo_move_to(cr, 0, baseline);
  cairo_line_to(cr, width, baseline);
  cairo_stroke(cr);
}

void schedule_chart_redraw() {
  if (mw.hist_chart != nullptr) {
    gtk_widget_queue_draw(GTK_WIDGET(mw.hist_chart));
  }
}

// ---- refresh ----------------------------------------------------------------

void refresh_status_label() {
  if (mw.config_status != nullptr) {
    gtk_label_set_text(
        mw.config_status,
        (g_state.model.config_status.empty()
             ? l10n::t("set.statusDefault")
             : g_state.model.config_status)
            .c_str());
  }
}

void refresh_pause_button() {
  if (g_state.pause_button != nullptr) {
    gtk_button_set_label(
        g_state.pause_button,
        g_state.model.is_paused() ? l10n::t("tray.resume").c_str()
                                  : l10n::t("tray.pause").c_str());
  }
  tray::sync();
}

void refresh_quit_button() {
  if (g_state.quit_button != nullptr) {
    gtk_button_set_label(g_state.quit_button, l10n::t("tray.exit").c_str());
  }
}

void refresh_focus_button() {
  if (g_state.focus_button != nullptr) {
    gtk_button_set_label(
        g_state.focus_button,
        l10n::t(g_state.model.quiet ? "tray.focusOff" : "tray.focusOn").c_str());
  }
  tray::sync();
}

// The header lives outside content_root, so the language-change rebuild
// never touches it; the buttons are retranslated explicitly instead
// (issue #72).
void refresh_header_buttons() {
  refresh_pause_button();
  refresh_focus_button();
  if (g_state.move_button != nullptr) {
    gtk_button_set_label(g_state.move_button, l10n::t("tray.moveAside").c_str());
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.move_button), g_state.mubi_x11);
  }
  if (g_state.place_button != nullptr) {
    gtk_button_set_label(
        g_state.place_button,
        l10n::t(g_state.mubi_placing ? "tray.placeMubiDone"
                                     : "tray.placeMubi")
            .c_str());
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.place_button),
                             g_state.mubi_x11);
  }
  refresh_quit_button();
}

void refresh_next_cue_line() {
  auto const& model = g_state.model;
  if (mw.today_next_cue != nullptr) {
    if (model.is_paused()) {
      // Paused says so in the status badge; a countdown would be a promise
      // that cannot fire.
      gtk_label_set_text(mw.today_next_cue, "");
      gtk_widget_set_visible(GTK_WIDGET(mw.today_next_cue), FALSE);
    } else {
      gtk_widget_set_visible(GTK_WIDGET(mw.today_next_cue), TRUE);
      auto const next = model.next_cue();
      gtk_label_set_text(
          mw.today_next_cue,
          next.has_value()
              ? l10n::t("today.nextCue", {l10n::A(next->second)}).c_str()
              : l10n::t("set.nextCueOff").c_str());
    }
  }
  if (mw.settings_next_cue != nullptr) {
    // "Reminders are off" would be a lie while merely paused; the status
    // badge already explains the pause.
    if (model.is_paused()) {
      gtk_label_set_text(mw.settings_next_cue, "");
    } else {
      auto const next = model.next_cue();
      gtk_label_set_text(
          mw.settings_next_cue,
          next.has_value()
              ? l10n::t("set.nextCue", {l10n::A(next->second)}).c_str()
              : l10n::t("set.nextCueOff").c_str());
    }
  }
}

void refresh_today_card() {
  auto const& model = g_state.model;
  if (mw.today_duration != nullptr) {
    gtk_label_set_text(mw.today_duration, format_duration(model.today.active_mins).c_str());
  }
  if (mw.today_status != nullptr) {
    std::string status;
    if (model.is_paused() && model.paused.until_ms.has_value()) {
      status = l10n::t("tpl.pausedUntil", {l10n::T(*model.paused.until_ms)});
    } else if (model.is_paused()) {
      status = l10n::t("tpl.pausedUntil", {l10n::T(now_ms())});
    } else {
      status = l10n::t("tpl.running");
    }
    gtk_label_set_text(mw.today_status, status.c_str());
    gtk_widget_remove_css_class(GTK_WIDGET(mw.today_status), "ok");
    gtk_widget_remove_css_class(GTK_WIDGET(mw.today_status), "paused");
    gtk_widget_add_css_class(GTK_WIDGET(mw.today_status),
                             model.is_paused() ? "paused" : "ok");
  }
  if (mw.sit_bar != nullptr) {
    double fraction = 0;
    if (!model.is_paused() && model.config.sit_reminder_minutes > 0) {
      fraction = std::min(
          1.0, std::max(0.0, static_cast<double>(model.current_session_mins()) /
                                 static_cast<double>(model.config.sit_reminder_minutes)));
    }
    gtk_progress_bar_set_fraction(mw.sit_bar, fraction);
  }
  if (mw.sit_cycle_text != nullptr) {
    std::string text = "—";
    if (!model.is_paused()) {
      text = l10n::t("tpl.sitCycleMin", {l10n::A(model.current_session_mins()),
                                        l10n::A(model.config.sit_reminder_minutes)});
    }
    gtk_label_set_text(mw.sit_cycle_text, text.c_str());
  }
  refresh_next_cue_line();

  // Truthful per-kind numbers (issue #88): shown vs the user's own "Done".
  // Kinds with no recorded event are omitted rather than rendered as 0.
  static constexpr rivet_app::ReminderKind kKinds[] = {
      rivet_app::ReminderKind::sit, rivet_app::ReminderKind::water,
      rivet_app::ReminderKind::micro};
  bool any_outcome = false;
  for (std::size_t i = 0; i < 3; ++i) {
    auto& slot = mw.outcome_rows[i];
    if (slot.row == nullptr) continue;
    auto const totals = model.outcome(kKinds[i]);
    gtk_widget_set_visible(slot.row, totals.has_value());
    if (!totals.has_value()) continue;
    any_outcome = true;
    if (slot.value != nullptr) {
      gtk_label_set_text(
          slot.value,
          l10n::t("today.outcome",
                  {l10n::A(totals->presented),
                   l10n::A(totals->self_reported_done)})
              .c_str());
    }
  }
  if (mw.outcome_empty != nullptr) {
    gtk_widget_set_visible(GTK_WIDGET(mw.outcome_empty), !any_outcome);
  }
}

void refresh_history_card() {
  if (mw.hist_title != nullptr) {
    gtk_label_set_text(mw.hist_title,
                       (g_state.model.history_days >= 30 ? l10n::t("hist.range30")
                                                         : l10n::t("hist.range7"))
                           .c_str());
  }
  if (mw.hist_total != nullptr) {
    auto slices = history_slice(g_state.model.history_days);
    std::int64_t total = 0;
    for (auto const& s : slices) total += s.stats.active_mins;
    std::string text =
        total >= 60 ? l10n::t("hist.totalLong", {l10n::A(total / 60), l10n::A(total % 60)})
                    : l10n::t("hist.totalShort", {l10n::A(total)});
    gtk_label_set_text(mw.hist_total, text.c_str());
  }
  schedule_chart_redraw();
}

void refresh_insight_card() {
  if (mw.insight_metrics[0] == nullptr) return;
  auto const& model = g_state.model;
  auto summary = insight_summary(30);
  gtk_label_set_text(mw.insight_metrics[0], format_minutes(model.current_session_mins()).c_str());
  gtk_label_set_text(mw.insight_metrics[1], format_minutes(model.today.longest_session_mins).c_str());
  gtk_label_set_text(mw.insight_metrics[2], format_minutes(summary.longest).c_str());
  gtk_label_set_text(mw.insight_metrics[3], format_minutes(summary.average).c_str());
  if (mw.insight_busiest != nullptr) {
    std::string text = l10n::t("insight.none");
    if (summary.has_busiest && summary.busiest.date.size() >= 10) {
      text = summary.busiest.date.substr(5, 5) + " · " +
             format_minutes(summary.busiest.active_mins);
    }
    gtk_label_set_text(mw.insight_busiest, text.c_str());
  }
  if (mw.insight_sedentary != nullptr) {
    std::int64_t const longest = summary.longest;
    std::int64_t const sit = model.config.sit_reminder_minutes;
    std::string text;
    if (longest <= 0) {
      text = l10n::t("insight.noData");
    } else if (longest >= sit * 2) {
      text = l10n::t("insight.long2", {l10n::A(format_minutes(longest))});
    } else if (longest >= sit) {
      text = l10n::t("insight.long1", {l10n::A(format_minutes(longest))});
    } else {
      text = l10n::t("insight.long0", {l10n::A(format_minutes(longest))});
    }
    gtk_label_set_text(mw.insight_sedentary, text.c_str());
  }
}

void refresh_settings_widgets() {
  auto const& c = g_state.model.config;
  g_state.updating_settings = true;
  if (mw.sit_spin != nullptr) {
    gtk_spin_button_set_value(mw.sit_spin, c.sit_reminder_minutes);
    gtk_spin_button_set_value(mw.water_spin, c.water_reminder_minutes);
    gtk_spin_button_set_value(mw.away_spin, c.away_reset_minutes);
    gtk_spin_button_set_value(mw.snooze_spin, c.snooze_minutes);
    gtk_spin_button_set_value(mw.micro_interval_spin, c.micro_break_interval_minutes);
    gtk_spin_button_set_value(mw.micro_duration_spin, c.micro_break_duration_seconds);
    gtk_switch_set_active(mw.motion_switch, c.motion_enabled);
    gtk_drop_down_set_selected(mw.mubi_size_drop,
                               c.companion_size == "S" ? 0
                               : c.companion_size == "L" ? 2 : 1);
    gtk_drop_down_set_selected(mw.mubi_motion_drop,
                               c.companion_motion == "still" ? 0
                               : c.companion_motion == "lively" ? 2 : 1);
    gtk_drop_down_set_selected(mw.mubi_dock_drop,
                               c.companion_dock == "bottom-left" ? 1
                               : c.companion_dock == "top-right" ? 2
                               : c.companion_dock == "top-left" ? 3 : 0);
    gtk_drop_down_set_selected(mw.mubi_labels_drop,
                               c.companion_labels == "always" ? 1 : 0);
    gtk_switch_set_active(mw.micro_switch, c.micro_break_enabled);
    gtk_switch_set_active(mw.sound_switch, c.sound_enabled);
    gtk_switch_set_active(mw.autostart_switch, g_state.model.autostart);
    gtk_switch_set_active(mw.updates_switch, c.auto_check_updates);
    gtk_drop_down_set_selected(
        mw.language_drop,
        c.language == "zh" ? 1 : c.language == "en" ? 2 : 0);
    gtk_switch_set_active(mw.sit_switch, c.sit_enabled);
    gtk_switch_set_active(mw.water_switch, c.water_enabled);
    gtk_switch_set_active(mw.quiet_switch, c.quiet_hours_enabled);
    gtk_spin_button_set_value(mw.quiet_start_spin,
                              c.quiet_hours_start_minutes / 60);
    gtk_spin_button_set_value(mw.quiet_end_spin,
                              c.quiet_hours_end_minutes / 60);
    gtk_widget_set_visible(mw.quiet_start_row, c.quiet_hours_enabled);
    gtk_widget_set_visible(mw.quiet_end_row, c.quiet_hours_enabled);
    for (std::size_t i = 0; i < 3; ++i) {
      bool const selected = c.preset == kPresets[i];
      gtk_toggle_button_set_active(mw.preset_buttons[i], selected);
      if (selected) {
        gtk_widget_add_css_class(GTK_WIDGET(mw.preset_buttons[i]),
                                 "rhythm-chip-selected");
      } else {
        gtk_widget_remove_css_class(GTK_WIDGET(mw.preset_buttons[i]),
                                    "rhythm-chip-selected");
      }
    }
    gtk_widget_set_visible(GTK_WIDGET(mw.preset_custom),
                           c.preset == "custom");
    gtk_label_set_text(
        mw.preset_detail,
        l10n::t("preset.detail",
                {l10n::A(c.sit_reminder_minutes),
                 l10n::A(c.water_reminder_minutes),
                 l10n::A(c.micro_break_interval_minutes),
                 l10n::A(c.micro_break_duration_seconds)})
            .c_str());
  }
  g_state.updating_settings = false;
  refresh_next_cue_line();
  refresh_status_label();
}

void refresh_footer() {
  if (mw.footer != nullptr) {
    gtk_label_set_text(
        mw.footer,
        g_state.model.data_dir.empty()
            ? ""
            : l10n::t("main.configPath", {l10n::A(g_state.model.data_dir)}).c_str());
  }
  if (mw.about_version != nullptr) {
    gtk_label_set_text(mw.about_version,
                       l10n::t("upd.currentVersion", {l10n::A(rivet_app::kVersion)}).c_str());
  }
}

void refresh_all() {
  refresh_pause_button();
  refresh_today_card();
  refresh_history_card();
  refresh_insight_card();
  refresh_settings_widgets();
  refresh_footer();
}

// ---- build main content ------------------------------------------------------

void flush_now_sync();
void reload_history();

// Defined in the mubi presentation namespace below; the Focus toggle may
// run before the companion window exists (the pose call no-ops there).
namespace mubi {
void set_quiet(bool enabled);
void move_aside();
void toggle_placement();
void begin_placement();
}

void on_pause_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) return;
  if (g_state.model.is_paused()) {
    (void)g_state.api->resume_async([](rivet_app::Result<void> r) {
      on_result(std::move(r), []() {});
    });
  } else {
    (void)g_state.api->pause_1h_async([](rivet_app::Result<void> r) {
      on_result(std::move(r), []() {});
    });
  }
}

void on_quit_clicked(GtkButton*, gpointer) {
  flush_now_sync();
  if (g_state.window != nullptr) gtk_window_destroy(g_state.window);
  g_state.window = nullptr;
}

// Focus (presentation silence): the backend queues cues and returns one
// bounded summary; the character settles into its quiet pose. The pose
// update is local so the toggle works even while the backend is down (#54).
void on_move_clicked(GtkButton*, gpointer) {
  if (g_state.mubi_x11) mubi::move_aside();
}

void on_place_clicked(GtkButton*, gpointer) {
  if (g_state.mubi_x11) mubi::toggle_placement();
}

void on_focus_clicked(GtkButton*, gpointer) {
  auto const next = !g_state.model.quiet;
  g_state.model.quiet = next;
  mubi::set_quiet(next);
  refresh_focus_button();
  if (g_state.api != nullptr) {
    (void)g_state.api->set_quiet_async(next, [](rivet_app::Result<void>) {});
  }
}

// ---- updates (UPDATE.md) ----------------------------------------------------
//
// The backend verifies the signed feed and downloads the artifact; this host
// owns consent, progress, and the install shape's final dialog. Three shapes
// (parity with the taskly host): AppImage — the backend has already swapped
// the sibling .AppImage over the running image, so the dialog only offers
// the re-exec; deb/rpm — package-manager guidance, never downloads; portable
// tarball — manual swap hint plus the file's folder. Failure text is always
// selectable: a bug report starts from that string.

struct UpdateFlowState {
  guint poll_source{0};        // 400 ms update_state poll
  GtkWindow* progress_dialog{nullptr};
  GtkProgressBar* progress_bar{nullptr};
  GtkLabel* progress_label{nullptr};
  std::string pending_version;  // captured at consent for the progress title
  // Last polled backend phase: the cancel gesture fires only when the
  // backend really is still downloading (a cancel fired after "downloaded"
  // would START a new download — the toggle doubles as the start).
  std::string last_phase;
  std::int64_t download_started_ms{0};  // monotonic ms; 30-min backstop
  bool check_in_flight{false};
  bool download_in_flight{false};
  bool reflected_pending{false};  // one-shot silent-check surfacing
};

UpdateFlowState g_update;

// Install shape for the update flow: the AppImage runtime exports APPIMAGE
// pointing at the running image; deb/rpm payloads land under /opt/movebit
// (symlinked from /usr/bin) — those upgrade through the package manager;
// everything else is the portable tarball layout.
std::string install_shape() {
  char const* appimage = getenv("APPIMAGE");
  if (appimage != nullptr && appimage[0] != '\0') return "appimage";
  std::error_code ec;
  auto const exe = std::filesystem::read_symlink("/proc/self/exe", ec);
  if (!ec) {
    auto const path = exe.string();
    if (path.rfind("/opt/movebit/", 0) == 0 || path.rfind("/usr/", 0) == 0) {
      return "package";
    }
  }
  return "tarball";
}

void stop_update_poll() {
  if (g_update.poll_source != 0) {
    g_source_remove(g_update.poll_source);
    g_update.poll_source = 0;
  }
}

void close_update_progress() {
  if (g_update.progress_dialog != nullptr) {
    gtk_window_destroy(g_update.progress_dialog);
    g_update.progress_dialog = nullptr;
    g_update.progress_bar = nullptr;
    g_update.progress_label = nullptr;
  }
}

// GTK4 deprecated GtkDialog (4.10) and gtk_show_uri. The replacements:
// GtkAlertDialog for plain confirmations (async choose, button-index
// responses), plain windows for rich content (selectable error text, live
// progress, the path row), and GtkUriLauncher for links. The update flow's
// handlers keep their exact semantics — only the window construction
// changed.

// A plain modal window: title + content box. For dialogs that need more
// than an alert body. Caller appends buttons.
GtkWindow* make_dialog_window(char const* title, GtkBox** content_out) {
  auto* window = GTK_WINDOW(gtk_application_window_new(g_state.app));
  gtk_window_set_title(window, title);
  if (g_state.window != nullptr) {
    gtk_window_set_transient_for(window, g_state.window);
  }
  gtk_window_set_modal(window, TRUE);
  gtk_window_set_resizable(window, FALSE);
  auto* content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(content, 12);
  gtk_widget_set_margin_bottom(content, 12);
  gtk_widget_set_margin_start(content, 12);
  gtk_widget_set_margin_end(content, 12);
  gtk_window_set_child(window, content);
  if (content_out != nullptr) *content_out = GTK_BOX(content);
  return window;
}

// One button on a dialog window; the click functor rides in object data.
void add_dialog_button(GtkWindow* window, GtkBox* content, char const* label,
                       bool suggested, std::function<void()> on_click) {
  auto* btn = gtk_button_new_with_label(label);
  if (suggested) {
    gtk_widget_add_css_class(GTK_WIDGET(btn), "suggested-action");
  }
  g_object_set_data_full(
      G_OBJECT(btn), "mb-onclick", new std::function<void()>(std::move(on_click)),
      +[](gpointer data) { delete static_cast<std::function<void()>*>(data); });
  g_signal_connect(
      btn, "clicked",
      G_CALLBACK(+[](GtkButton* button, gpointer) {
        auto* fn = static_cast<std::function<void()>*>(
            g_object_get_data(G_OBJECT(button), "mb-onclick"));
        if (fn != nullptr && *fn) (*fn)();
      }),
      nullptr);
  gtk_box_append(content, GTK_WIDGET(btn));
  (void)window;
}

void show_update_message(std::string const& title, std::string const& body) {
  GtkBox* content = nullptr;
  auto* window = make_dialog_window(title.c_str(), &content);
  auto* text = gtk_label_new(body.c_str());
  gtk_label_set_wrap(GTK_LABEL(text), TRUE);
  // Error text must be copyable — a bug report starts from this string.
  gtk_label_set_selectable(GTK_LABEL(text), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(text), 60);
  gtk_widget_set_margin_bottom(text, 6);
  gtk_box_append(content, text);
  add_dialog_button(window, content, l10n::t("dialog.close").c_str(), false,
                    [window] { gtk_window_destroy(window); });
  gtk_window_present(window);
}

void show_update_error(std::string const& message) {
  show_update_message(
      "MoveBit",
      message.empty() ? std::string(l10n::t("upd.checkFailed")) : message);
}

void set_updates_hint(std::string const& text) {
  if (mw.updates_hint != nullptr) {
    gtk_label_set_text(mw.updates_hint, text.c_str());
  }
}

// AppImage: the backend already swapped the sibling .AppImage over the
// running image atomically (sidecar-checksummed), so the only step left is
// the user's consent to re-exec. Declining keeps the current (old) process;
// the next launch is the new version regardless.
void show_appimage_restart_dialog() {
  GtkAlertDialog* alert = gtk_alert_dialog_new(
      "%s", l10n::t("upd.downloadedTitle").c_str());
  gtk_alert_dialog_set_detail(alert, l10n::t("upd.appImageHint").c_str());
  // l10n::t strings live for this statement; set_buttons copies them.
  char const* buttons[] = {l10n::t("dialog.cancel").c_str(),
                           l10n::t("upd.actionRestartInstall").c_str(),
                           nullptr};
  gtk_alert_dialog_set_buttons(alert, buttons);
  gtk_alert_dialog_choose(
      alert, g_state.window, nullptr,
      +[](GObject* src, GAsyncResult* res, gpointer) {
        int response = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(src),
                                                      res, nullptr);
        if (response != 1) return;  // 1 = Restart & Install
        char const* self = getenv("APPIMAGE");
        if (self == nullptr || self[0] == '\0') return;
        execl(self, self, static_cast<char*>(nullptr));
        // execl only returns on failure — surface it, the old image keeps
        // running either way.
        show_update_error(std::string("re-exec failed: ") +
                          std::strerror(errno));
      },
      nullptr);
  g_object_unref(alert);
}

// Tarball installs: hand off the verified archive. Installation stays manual
// (nothing is ever executed or moved by the host), so the dialog explains
// the step and points at the file's folder.
void show_downloaded_dialog(std::string const& path) {
  GtkBox* content = nullptr;
  auto* window = make_dialog_window(l10n::t("upd.downloadedTitle").c_str(),
                                    &content);

  auto* hint = gtk_label_new(l10n::t("upd.installHint").c_str());
  gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
  gtk_label_set_max_width_chars(GTK_LABEL(hint), 60);
  gtk_box_append(content, hint);

  // The backend stages the archive under <data-dir>/updates/.
  if (!path.empty()) {
    auto* path_label = gtk_label_new(path.c_str());
    gtk_label_set_selectable(GTK_LABEL(path_label), TRUE);
    gtk_label_set_wrap(GTK_LABEL(path_label), TRUE);
    gtk_widget_add_css_class(path_label, "caption");
    gtk_box_append(content, path_label);

    auto* open = gtk_button_new_with_label(l10n::t("upd.openFolder").c_str());
    g_object_set_data_full(G_OBJECT(open), "update-open-path",
                           new std::string(path),
                           +[](gpointer data) {
                             delete static_cast<std::string*>(data);
                           });
    g_signal_connect(
        open, "clicked",
        G_CALLBACK(+[](GtkButton* button, gpointer) {
          auto const* p = static_cast<std::string const*>(
              g_object_get_data(G_OBJECT(button), "update-open-path"));
          if (p == nullptr || g_state.window == nullptr) return;
          // Parent directory of the file, POSIX paths only: plain string
          // arithmetic keeps this noexcept inside a GTK callback.
          auto const slash = p->find_last_of('/');
          if (slash == std::string::npos || slash == 0) return;
          std::string const dir = p->substr(0, slash);
          GFile* folder = g_file_new_for_path(dir.c_str());
          gchar* uri = g_file_get_uri(folder);
          // GtkUriLauncher replaced gtk_show_uri (deprecated); the launcher
          // releases itself in the finish callback.
          GtkUriLauncher* launcher = gtk_uri_launcher_new(uri);
          gtk_uri_launcher_launch(
              launcher, g_state.window, nullptr,
              +[](GObject* src, GAsyncResult* res, gpointer) {
                GError* error = nullptr;
                gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(src), res,
                                               &error);
                if (error != nullptr) g_error_free(error);
                g_object_unref(src);
              },
              nullptr);
          g_free(uri);
          g_object_unref(folder);
        }),
        nullptr);
    gtk_box_append(content, open);
  }

  add_dialog_button(window, content, l10n::t("dialog.close").c_str(), false,
                    [window] { gtk_window_destroy(window); });
  gtk_window_present(window);
}

int on_update_poll_tick(gpointer) {
  if (g_state.api == nullptr || g_update.progress_dialog == nullptr) {
    g_update.poll_source = 0;
    return G_SOURCE_REMOVE;
  }
  // Host-side backstop: the backend's own watchdog (stall 120 s / total
  // 30 min) normally lands the terminal state first; if the backend itself
  // is wedged, break out of an endless progress bar — fire the cancel
  // toggle so a half-alive backend resets too, then surface the failure.
  if (g_update.download_started_ms != 0 &&
      g_get_monotonic_time() / 1000 - g_update.download_started_ms >
          30LL * 60 * 1000) {
    if (g_state.api != nullptr && g_update.last_phase == "downloading") {
      (void)g_state.api->start_update_download_async(
          [](rivet_app::Result<void>) {});
    }
    stop_update_poll();
    close_update_progress();
    g_update.download_in_flight = false;
    g_update.download_started_ms = 0;
    g_update.poll_source = 0;
    set_updates_hint(l10n::t("upd.checkFailed"));
    show_update_error(l10n::t("upd.checkFailed"));
    return G_SOURCE_REMOVE;
  }
  (void)g_state.api->get_update_state_async(
      [](rivet_app::Result<rivet_app::UpdateState> result) {
        dispatch_ui([result = std::move(result)]() mutable {
          if (g_update.progress_dialog == nullptr) return;  // detached UI
          if (!result.succeeded()) return;  // keep polling through hiccups
          rivet_app::UpdateState const& state = result.get();
          g_update.last_phase = state.phase;
          auto const percent =
              std::clamp<std::int64_t>(state.percent, 0, 100);
          if (g_update.progress_bar != nullptr) {
            gtk_progress_bar_set_fraction(g_update.progress_bar,
                                          static_cast<double>(percent) /
                                              100.0);
          }
          if (g_update.progress_label != nullptr) {
            gtk_label_set_text(
                g_update.progress_label,
                l10n::t("upd.downloadingPct",
                        {l10n::A(g_update.pending_version),
                         l10n::A(percent)})
                    .c_str());
          }
          if (state.phase != "downloaded" && state.phase != "error" &&
              state.phase != "idle") {
            return;
          }
          stop_update_poll();
          close_update_progress();
          g_update.download_in_flight = false;
          g_update.download_started_ms = 0;
          if (state.phase == "idle") {
            // The cancel gesture landed: a cancel is not a failure — the
            // hint says so and the update stays one click away.
            set_updates_hint(l10n::t("upd.cancelled"));
            return;
          }
          if (state.phase == "error") {
            set_updates_hint(state.message.value_or("").empty()
                                 ? std::string(l10n::t("upd.checkFailed"))
                                 : state.message.value_or(""));
            show_update_error(state.message.value_or(""));
            return;
          }
          if (install_shape() == "appimage") {
            show_appimage_restart_dialog();
            return;
          }
          show_downloaded_dialog(state.downloaded_path.value_or(""));
        });
      });
  return G_SOURCE_CONTINUE;
}

void start_update_download() {
  if (g_state.api == nullptr || g_update.download_in_flight) return;
  g_update.download_in_flight = true;
  g_update.download_started_ms = g_get_monotonic_time() / 1000;
  g_update.last_phase = "downloading";

  GtkBox* content = nullptr;
  auto* dialog = make_dialog_window(
      l10n::t("upd.downloading", {l10n::A(g_update.pending_version)})
          .c_str(),
      &content);
  auto* bar = gtk_progress_bar_new();
  gtk_widget_set_size_request(bar, 300, -1);
  gtk_box_append(content, bar);
  auto* label =
      gtk_label_new(l10n::t("upd.downloading",
                            {l10n::A(g_update.pending_version)})
                        .c_str());
  gtk_box_append(content, label);

  // Cancel really cancels now: the start RPC doubles as the cancel gesture
  // (the backend's toggle contract). Fire it while the backend is still
  // downloading, detach the progress UI, and show the cancelled hint — the
  // update itself stays one click away (the offer was never withdrawn).
  add_dialog_button(dialog, content, l10n::t("dialog.cancel").c_str(), false,
                    [dialog] {
                      if (g_state.api != nullptr &&
                          g_update.last_phase == "downloading") {
                        (void)g_state.api->start_update_download_async(
                            [](rivet_app::Result<void>) {});
                      }
                      stop_update_poll();
                      g_update.progress_dialog = nullptr;
                      g_update.progress_bar = nullptr;
                      g_update.progress_label = nullptr;
                      g_update.download_in_flight = false;
                      g_update.download_started_ms = 0;
                      set_updates_hint(l10n::t("upd.cancelled"));
                      gtk_window_destroy(dialog);
                    });
  // If the main window goes away this window dies with it (transient) —
  // clear the raw pointers and the poll so no tick touches dead widgets.
  g_signal_connect(
      dialog, "destroy",
      G_CALLBACK(+[](GtkWidget*, gpointer) {
        g_update.progress_dialog = nullptr;
        g_update.progress_bar = nullptr;
        g_update.progress_label = nullptr;
        stop_update_poll();
      }),
      nullptr);
  gtk_window_present(dialog);
  g_update.progress_dialog = dialog;
  g_update.progress_bar = GTK_PROGRESS_BAR(bar);
  g_update.progress_label = GTK_LABEL(label);
  g_update.poll_source = g_timeout_add(400, on_update_poll_tick, nullptr);

  (void)g_state.api->start_update_download_async(
      [](rivet_app::Result<void> result) {
        dispatch_ui([result = std::move(result)]() mutable {
          if (g_update.progress_dialog == nullptr) return;  // detached UI
          if (result.succeeded()) return;  // the poll owns the rest
          // The download never started; stop staring at a 0% bar.
          stop_update_poll();
          close_update_progress();
          g_update.download_in_flight = false;
          g_update.download_started_ms = 0;
          std::string message = "unknown failure";
          try {
            std::rethrow_exception(result.error);
          } catch (std::exception const& e) {
            message = e.what();
          } catch (...) {
          }
          set_updates_hint(message);
          show_update_error(message);
        });
      });
}

void show_update_consent(rivet_app::UpdateCheck const& check) {
  std::string const version = check.available_version.value_or("?");
  if (install_shape() == "package") {
    // deb/rpm upgrade through the package manager; never download or exec.
    show_update_message(l10n::t("upd.availableTitle"),
                        l10n::t("upd.usePackageManager"));
    return;
  }
  g_update.pending_version = version;
  GtkAlertDialog* alert =
      gtk_alert_dialog_new("%s", l10n::t("upd.availableTitle").c_str());
  gtk_alert_dialog_set_detail(
      alert, l10n::t("upd.found", {l10n::A(version)}).c_str());
  // l10n::t strings live for this statement; set_buttons copies them.
  char const* buttons[] = {l10n::t("dialog.cancel").c_str(),
                           l10n::t("upd.actionUpdate").c_str(), nullptr};
  gtk_alert_dialog_set_buttons(alert, buttons);
  gtk_alert_dialog_choose(
      alert, g_state.window, nullptr,
      +[](GObject* src, GAsyncResult* res, gpointer) {
        int response = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(src),
                                                      res, nullptr);
        if (response == 1) {  // 1 = Update
          start_update_download();
        }
      },
      nullptr);
  g_object_unref(alert);
}

void on_check_updates_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr || g_update.check_in_flight ||
      g_update.download_in_flight) {
    return;
  }
  g_update.check_in_flight = true;
  if (mw.updates_button != nullptr) {
    gtk_button_set_label(mw.updates_button, l10n::t("upd.checkingShort").c_str());
    gtk_widget_set_sensitive(GTK_WIDGET(mw.updates_button), FALSE);
  }
  set_updates_hint(l10n::t("upd.checking"));
  (void)g_state.api->check_updates_async(
      [](rivet_app::Result<rivet_app::UpdateCheck> result) {
        dispatch_ui([result = std::move(result)]() mutable {
          g_update.check_in_flight = false;
          if (mw.updates_button != nullptr) {
            gtk_button_set_label(mw.updates_button,
                                 l10n::t("about.checkUpdates").c_str());
            gtk_widget_set_sensitive(GTK_WIDGET(mw.updates_button), TRUE);
          }
          if (!result.succeeded()) {
            std::string message = "unknown failure";
            try {
              std::rethrow_exception(result.error);
            } catch (std::exception const& e) {
              message = e.what();
            } catch (...) {
            }
            set_updates_hint(message);
            show_update_error(message);
            return;
          }
          rivet_app::UpdateCheck const& check = result.get();
          if (check.status == "available") {
            set_updates_hint(
                l10n::t("upd.found",
                        {l10n::A(check.available_version.value_or(""))}));
            show_update_consent(check);
            return;
          }
          if (check.status == "up-to-date") {
            set_updates_hint(l10n::t("upd.currentUpToDate",
                                     {l10n::A(check.current_version)}));
            return;
          }
          // "error": show the real reason — check failures are network or
          // signing conditions, not user mistakes.
          std::string const message = check.error.value_or("");
          set_updates_hint(message.empty()
                               ? std::string(l10n::t("upd.checkFailed"))
                               : message);
          show_update_error(message);
        });
      });
}

// One-shot surfacing of the backend's silent auto-check (startup + every
// 6 h): a pending update turns into the About hint; everything else stays
// invisible.
void reflect_pending_update() {
  if (g_update.reflected_pending || g_state.api == nullptr) return;
  g_update.reflected_pending = true;
  (void)g_state.api->get_update_state_async(
      [](rivet_app::Result<rivet_app::UpdateState> result) {
        dispatch_ui([result = std::move(result)]() mutable {
          if (!result.succeeded()) return;
          rivet_app::UpdateState const& state = result.get();
          if (state.phase == "idle" && state.available_version.has_value()) {
            set_updates_hint(l10n::t(
                "upd.found", {l10n::A(state.available_version.value_or(""))}));
          }
        });
      });
}

void build_main_content() {
  if (g_state.content_root == nullptr) return;

  // Clear previous content (language switch rebuilds everything).
  while (GtkWidget* child = gtk_widget_get_first_child(GTK_WIDGET(g_state.content_root))) {
    gtk_box_remove(g_state.content_root, child);
  }
  mw = MainWidgets{};

  auto* scroll = gtk_scrolled_window_new();
  gtk_widget_set_vexpand(scroll, TRUE);
  auto* columns = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 14);
  gtk_widget_set_margin_top(columns, 18);
  gtk_widget_set_margin_bottom(columns, 18);
  gtk_widget_set_margin_start(columns, 20);
  gtk_widget_set_margin_end(columns, 20);
  auto* left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
  gtk_widget_set_hexpand(left, TRUE);
  gtk_widget_set_valign(left, GTK_ALIGN_START);
  auto* right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
  gtk_widget_set_hexpand(right, TRUE);
  gtk_widget_set_valign(right, GTK_ALIGN_START);

  // --- today card ---
  {
    auto* card = make_card();
    auto* head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(head), label_with(l10n::t("today.title").c_str(), "section"));
    auto* status = gtk_label_new("");
    gtk_widget_add_css_class(status, "status");
    gtk_widget_set_hexpand(status, TRUE);
    gtk_label_set_xalign(GTK_LABEL(status), 1.0f);
    box_append(GTK_BOX(head), status);
    mw.today_status = GTK_LABEL(status);
    box_append(GTK_BOX(card), head);

    auto* duration = gtk_label_new("0m");
    gtk_widget_add_css_class(duration, "big-number");
    gtk_label_set_xalign(GTK_LABEL(duration), 0.0f);
    box_append(GTK_BOX(card), duration);
    mw.today_duration = GTK_LABEL(duration);

    auto* bar = gtk_progress_bar_new();
    gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(bar), 0.0);
    gtk_widget_add_css_class(bar, "sit-bar");
    box_append(GTK_BOX(card), bar);
    mw.sit_bar = GTK_PROGRESS_BAR(bar);

    auto* cycle = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    auto* cycle_left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    auto* cycle_text = gtk_label_new("—");
    gtk_widget_add_css_class(cycle_text, "row-strong");
    gtk_label_set_xalign(GTK_LABEL(cycle_text), 0.0f);
    box_append(GTK_BOX(cycle_left), cycle_text);
    box_append(GTK_BOX(cycle_left), label_with(l10n::t("today.sitCycle").c_str(), "caption"));
    gtk_widget_set_hexpand(cycle_left, TRUE);
    box_append(GTK_BOX(cycle), cycle_left);
    auto* next_cue = gtk_label_new("");
    gtk_widget_add_css_class(next_cue, "row-label");
    gtk_label_set_xalign(GTK_LABEL(next_cue), 1.0f);
    gtk_label_set_wrap(GTK_LABEL(next_cue), TRUE);
    gtk_label_set_justify(GTK_LABEL(next_cue), GTK_JUSTIFY_RIGHT);
    box_append(GTK_BOX(cycle), next_cue);
    mw.today_next_cue = GTK_LABEL(next_cue);
    box_append(GTK_BOX(card), cycle);

    // Shown vs self-reported done per kind (issue #88). No fired-counter
    // tiles: one number model only.
    static constexpr rivet_app::ReminderKind kOutcomeKinds[] = {
        rivet_app::ReminderKind::sit, rivet_app::ReminderKind::water,
        rivet_app::ReminderKind::micro};
    for (std::size_t i = 0; i < 3; ++i) {
      auto* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
      auto* name = label_with(Model::kind_label(kOutcomeKinds[i]).c_str(),
                              "caption");
      gtk_widget_set_hexpand(name, TRUE);
      box_append(GTK_BOX(row), name);
      auto* value = gtk_label_new("");
      gtk_widget_add_css_class(value, "row-label");
      gtk_label_set_xalign(GTK_LABEL(value), 1.0f);
      box_append(GTK_BOX(row), value);
      gtk_widget_set_visible(row, FALSE);
      box_append(GTK_BOX(card), row);
      mw.outcome_rows[i].row = row;
      mw.outcome_rows[i].value = GTK_LABEL(value);
    }
    auto* outcome_empty = label_with(l10n::t("today.outcomeEmpty").c_str(), "caption");
    box_append(GTK_BOX(card), outcome_empty);
    mw.outcome_empty = GTK_LABEL(outcome_empty);
    auto* outcome_legend =
        label_with(l10n::t("today.outcomeLegend").c_str(), "caption");
    gtk_label_set_wrap(GTK_LABEL(outcome_legend), TRUE);
    gtk_label_set_xalign(GTK_LABEL(outcome_legend), 0.0f);
    box_append(GTK_BOX(card), outcome_legend);
    box_append(left, card);
  }

  // --- history card ---
  {
    auto* card = make_card();
    auto* head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    auto* head_left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    auto* title = gtk_label_new(l10n::t("hist.range7").c_str());
    gtk_widget_add_css_class(title, "section");
    gtk_label_set_xalign(GTK_LABEL(title), 0.0f);
    box_append(GTK_BOX(head_left), title);
    auto* total = gtk_label_new("");
    gtk_widget_add_css_class(total, "row-strong");
    gtk_label_set_xalign(GTK_LABEL(total), 0.0f);
    box_append(GTK_BOX(head_left), total);
    gtk_widget_set_hexpand(head_left, TRUE);
    box_append(GTK_BOX(head), head_left);
    std::string const range7 = l10n::t("hist.toggle7");
    std::string const range30 = l10n::t("hist.toggle30");
    const char* const range_items[] = {range7.c_str(), range30.c_str(), nullptr};
    auto* range = gtk_drop_down_new_from_strings(range_items);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(range), 0);
    g_signal_connect(range, "notify::selected", G_CALLBACK(on_hist_range_changed), nullptr);
    box_append(GTK_BOX(head), range);
    mw.hist_range = GTK_DROP_DOWN(range);
    mw.hist_title = GTK_LABEL(title);
    mw.hist_total = GTK_LABEL(total);
    box_append(GTK_BOX(card), head);

    auto* chart = gtk_drawing_area_new();
    gtk_widget_set_size_request(chart, -1, 140);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(chart), draw_history_chart,
                                   nullptr, nullptr);
    box_append(GTK_BOX(card), chart);
    mw.hist_chart = GTK_DRAWING_AREA(chart);
    box_append(left, card);
  }

  // --- insight card ---
  {
    auto* card = make_card();
    box_append(GTK_BOX(card), label_with(l10n::t("insight.title").c_str(), "section"));
    auto* grid = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    std::string const titles[4] = {l10n::t("insight.current"),
                                   l10n::t("insight.todayLongest"),
                                   l10n::t("insight.recentLongest"),
                                   l10n::t("insight.recentAvg")};
    for (int i = 0; i < 4; ++i) {
      auto* tile = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
      gtk_widget_add_css_class(tile, "metric-tile");
      box_append(GTK_BOX(tile), label_with(titles[i].c_str(), "caption"));
      auto* value = gtk_label_new("0m");
      gtk_widget_add_css_class(value, "metric-value");
      gtk_label_set_xalign(GTK_LABEL(value), 0.0f);
      box_append(GTK_BOX(tile), value);
      gtk_grid_attach(GTK_GRID(grid), tile, i % 2, i / 2, 1, 1);
      mw.insight_metrics[i] = GTK_LABEL(value);
    }
    box_append(GTK_BOX(card), grid);
    auto* busiest = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(busiest), label_with(l10n::t("insight.busiest").c_str(), "caption"));
    auto* busiest_value = gtk_label_new("");
    box_append(GTK_BOX(busiest), busiest_value);
    mw.insight_busiest = GTK_LABEL(busiest_value);
    box_append(GTK_BOX(card), busiest);
    auto* sedentary = gtk_label_new("");
    gtk_widget_add_css_class(sedentary, "caption");
    gtk_label_set_wrap(GTK_LABEL(sedentary), TRUE);
    gtk_label_set_xalign(GTK_LABEL(sedentary), 0.0f);
    box_append(GTK_BOX(card), sedentary);
    mw.insight_sedentary = GTK_LABEL(sedentary);
    box_append(left, card);
  }

  // --- settings card ---
  {
    auto* card = make_card();
    auto* head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(head), label_with(l10n::t("set.title").c_str(), "section"));
    auto* status = gtk_label_new("");
    gtk_widget_add_css_class(status, "accent-label");
    gtk_widget_set_hexpand(status, TRUE);
    gtk_label_set_xalign(GTK_LABEL(status), 1.0f);
    gtk_label_set_wrap(GTK_LABEL(status), TRUE);
    box_append(GTK_BOX(head), status);
    mw.config_status = GTK_LABEL(status);
    box_append(GTK_BOX(card), head);

    // Everyday surface (issues #87/#90): rhythm, sound, one disclosure.
    box_append(GTK_BOX(card), label_with(l10n::t("set.rhythm").c_str(), "row-strong"));
    auto* rhythm_hint =
        label_with(l10n::t("set.rhythmHint").c_str(), "caption");
    gtk_label_set_wrap(GTK_LABEL(rhythm_hint), TRUE);
    box_append(GTK_BOX(card), rhythm_hint);

    auto& c = g_state.model.config;
    auto* preset_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    for (std::size_t i = 0; i < 3; ++i) {
      auto* chip = gtk_toggle_button_new_with_label(
          l10n::t(kPresetLabels[i]).c_str());
      gtk_widget_add_css_class(chip, "rhythm-chip");
      gtk_widget_set_hexpand(chip, TRUE);
      g_object_set_data(G_OBJECT(chip), "preset",
                        const_cast<char*>(kPresets[i]));
      g_signal_connect(chip, "toggled", G_CALLBACK(on_preset_toggled),
                       nullptr);
      box_append(GTK_BOX(preset_row), chip);
      mw.preset_buttons[i] = GTK_TOGGLE_BUTTON(chip);
    }
    box_append(GTK_BOX(card), preset_row);

    auto* preset_custom = label_with(l10n::t("preset.custom").c_str(), "caption");
    gtk_widget_set_visible(preset_custom, FALSE);
    box_append(GTK_BOX(card), preset_custom);
    mw.preset_custom = GTK_LABEL(preset_custom);

    // Exact values, derived from the stored config so the label can never
    // promise numbers the app does not use.
    auto* preset_detail = label_with("", "caption");
    gtk_label_set_wrap(GTK_LABEL(preset_detail), TRUE);
    box_append(GTK_BOX(card), preset_detail);
    mw.preset_detail = GTK_LABEL(preset_detail);

    auto* settings_next_cue = gtk_label_new("");
    gtk_widget_add_css_class(settings_next_cue, "row-label");
    gtk_label_set_xalign(GTK_LABEL(settings_next_cue), 0.0f);
    gtk_label_set_wrap(GTK_LABEL(settings_next_cue), TRUE);
    box_append(GTK_BOX(card), settings_next_cue);
    mw.settings_next_cue = GTK_LABEL(settings_next_cue);

    mw.sound_switch = add_toggle_row(card, l10n::t("set.sound").c_str(),
                                     c.sound_enabled, G_CALLBACK(on_sound_set));
    auto* sound_hint = label_with(l10n::t("set.soundHint").c_str(), "caption");
    gtk_label_set_wrap(GTK_LABEL(sound_hint), TRUE);
    box_append(GTK_BOX(card), sound_hint);

    auto* customize =
        gtk_button_new_with_label(l10n::t("set.customize").c_str());
    gtk_widget_add_css_class(customize, "flat");
    gtk_widget_set_halign(customize, GTK_ALIGN_START);
    g_signal_connect(customize, "clicked",
                     G_CALLBACK(on_customize_clicked), nullptr);
    box_append(GTK_BOX(card), customize);

    // Advanced controls, collapsed by default (rare technical needs).
    auto* advanced = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_visible(advanced, FALSE);
    mw.advanced_box = advanced;
    box_append(GTK_BOX(card), advanced);

    box_append(GTK_BOX(advanced),
               label_with(l10n::t("set.intro").c_str(), "caption"));
    box_append(GTK_BOX(advanced),
               label_with(l10n::t("set.kinds").c_str(), "section"));

    mw.sit_switch = add_toggle_row(advanced, l10n::t("set.sitEnabled").c_str(),
                                   c.sit_enabled,
                                   G_CALLBACK(on_sit_enabled_set));
    mw.sit_spin = add_stepper_row(advanced, l10n::t("set.sitInterval").c_str(),
                                  c.sit_reminder_minutes, 10, 240, 5,
                                  G_CALLBACK(on_sit_changed));
    mw.water_switch = add_toggle_row(advanced, l10n::t("set.waterEnabled").c_str(),
                                     c.water_enabled,
                                     G_CALLBACK(on_water_enabled_set));
    mw.water_spin = add_stepper_row(advanced, l10n::t("set.waterInterval").c_str(),
                                    c.water_reminder_minutes, 5, 180, 5,
                                    G_CALLBACK(on_water_changed));
    mw.micro_switch = add_toggle_row(advanced, l10n::t("set.eyesToggle").c_str(),
                                     c.micro_break_enabled,
                                     G_CALLBACK(on_micro_set));
    auto* micro_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(micro_row),
               label_with(l10n::t("set.eyesParams").c_str(), "row-label"));
    mw.micro_interval_spin = add_stepper_row(
        micro_row, "", c.micro_break_interval_minutes, 10, 60, 5,
        G_CALLBACK(on_micro_interval_changed));
    mw.micro_duration_spin = add_stepper_row(
        micro_row, "", c.micro_break_duration_seconds, 10, 60, 5,
        G_CALLBACK(on_micro_duration_changed));
    box_append(GTK_BOX(advanced), micro_row);

    mw.away_spin = add_stepper_row(advanced, l10n::t("set.awayReset").c_str(),
                                   c.away_reset_minutes, 1, 60, 1,
                                   G_CALLBACK(on_away_changed));
    mw.snooze_spin = add_stepper_row(advanced, l10n::t("set.snooze").c_str(),
                                     c.snooze_minutes, 5, 60, 5,
                                     G_CALLBACK(on_snooze_changed));

    mw.quiet_switch =
        add_toggle_row(advanced, l10n::t("set.quietHours").c_str(),
                       c.quiet_hours_enabled,
                       G_CALLBACK(on_quiet_hours_set));
    auto* quiet_hint =
        label_with(l10n::t("set.quietHoursHint").c_str(), "caption");
    gtk_label_set_wrap(GTK_LABEL(quiet_hint), TRUE);
    box_append(GTK_BOX(advanced), quiet_hint);

    auto* quiet_start_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(quiet_start_row),
               label_with(l10n::t("set.quietStart").c_str(), "row-label"));
    auto* quiet_start_spin = gtk_spin_button_new_with_range(0, 23, 1);
    gtk_spin_button_set_numeric(GTK_SPIN_BUTTON(quiet_start_spin), TRUE);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(quiet_start_spin),
                              c.quiet_hours_start_minutes / 60);
    g_signal_connect(quiet_start_spin, "value-changed",
                     G_CALLBACK(on_quiet_start_changed), nullptr);
    box_append(GTK_BOX(quiet_start_row), quiet_start_spin);
    gtk_widget_set_visible(quiet_start_row, c.quiet_hours_enabled);
    box_append(GTK_BOX(advanced), quiet_start_row);
    mw.quiet_start_row = quiet_start_row;
    mw.quiet_start_spin = GTK_SPIN_BUTTON(quiet_start_spin);

    auto* quiet_end_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(quiet_end_row),
               label_with(l10n::t("set.quietEnd").c_str(), "row-label"));
    auto* quiet_end_spin = gtk_spin_button_new_with_range(0, 23, 1);
    gtk_spin_button_set_numeric(GTK_SPIN_BUTTON(quiet_end_spin), TRUE);
    gtk_spin_button_set_value(GTK_SPIN_BUTTON(quiet_end_spin),
                              c.quiet_hours_end_minutes / 60);
    g_signal_connect(quiet_end_spin, "value-changed",
                     G_CALLBACK(on_quiet_end_changed), nullptr);
    box_append(GTK_BOX(quiet_end_row), quiet_end_spin);
    gtk_widget_set_visible(quiet_end_row, c.quiet_hours_enabled);
    box_append(GTK_BOX(advanced), quiet_end_row);
    mw.quiet_end_row = quiet_end_row;
    mw.quiet_end_spin = GTK_SPIN_BUTTON(quiet_end_spin);

    auto* mubi_size_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(mubi_size_row),
               label_with(l10n::t("set.mubiSize").c_str(), "row-label"));
    char const* size_items[] = {"S", "M", "L", nullptr};
    auto* size_drop = gtk_drop_down_new_from_strings(size_items);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(size_drop),
                               c.companion_size == "S" ? 0
                               : c.companion_size == "L" ? 2 : 1);
    g_signal_connect(size_drop, "notify::selected",
                     G_CALLBACK(on_mubi_size_changed), nullptr);
    box_append(GTK_BOX(mubi_size_row), size_drop);
    gtk_widget_set_halign(size_drop, GTK_ALIGN_END);
    gtk_widget_set_hexpand(size_drop, TRUE);
    box_append(GTK_BOX(advanced), mubi_size_row);
    mw.mubi_size_drop = GTK_DROP_DOWN(size_drop);

    auto* mubi_motion_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(mubi_motion_row),
               label_with(l10n::t("set.mubiMotion").c_str(), "row-label"));
    std::string const motion_still = l10n::t("mubi.motionStill");
    std::string const motion_subtle = l10n::t("mubi.motionSubtle");
    std::string const motion_lively = l10n::t("mubi.motionLively");
    char const* motion_items[] = {motion_still.c_str(), motion_subtle.c_str(),
                                  motion_lively.c_str(), nullptr};
    auto* motion_drop = gtk_drop_down_new_from_strings(motion_items);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(motion_drop),
                               c.companion_motion == "still" ? 0
                               : c.companion_motion == "lively" ? 2 : 1);
    g_signal_connect(motion_drop, "notify::selected",
                     G_CALLBACK(on_mubi_motion_changed), nullptr);
    box_append(GTK_BOX(mubi_motion_row), motion_drop);
    gtk_widget_set_halign(motion_drop, GTK_ALIGN_END);
    gtk_widget_set_hexpand(motion_drop, TRUE);
    box_append(GTK_BOX(advanced), mubi_motion_row);
    mw.mubi_motion_drop = GTK_DROP_DOWN(motion_drop);

    auto* mubi_dock_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(mubi_dock_row),
               label_with(l10n::t("set.mubiDock").c_str(), "row-label"));
    std::string const dock_br = l10n::t("mubi.dockBottomRight");
    std::string const dock_bl = l10n::t("mubi.dockBottomLeft");
    std::string const dock_tr = l10n::t("mubi.dockTopRight");
    std::string const dock_tl = l10n::t("mubi.dockTopLeft");
    char const* dock_items[] = {dock_br.c_str(), dock_bl.c_str(),
                                dock_tr.c_str(), dock_tl.c_str(), nullptr};
    auto* dock_drop = gtk_drop_down_new_from_strings(dock_items);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(dock_drop),
                               c.companion_dock == "bottom-left" ? 1
                               : c.companion_dock == "top-right" ? 2
                               : c.companion_dock == "top-left" ? 3 : 0);
    g_signal_connect(dock_drop, "notify::selected",
                     G_CALLBACK(on_mubi_dock_changed), nullptr);
    box_append(GTK_BOX(mubi_dock_row), dock_drop);
    gtk_widget_set_halign(dock_drop, GTK_ALIGN_END);
    gtk_widget_set_hexpand(dock_drop, TRUE);
    box_append(GTK_BOX(advanced), mubi_dock_row);
    mw.mubi_dock_drop = GTK_DROP_DOWN(dock_drop);

    auto* mubi_labels_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(mubi_labels_row),
               label_with(l10n::t("set.mubiLabels").c_str(), "row-label"));
    std::string const labels_cue = l10n::t("mubi.labelsCue");
    std::string const labels_always = l10n::t("mubi.labelsAlways");
    char const* labels_items[] = {labels_cue.c_str(), labels_always.c_str(),
                                  nullptr};
    auto* labels_drop = gtk_drop_down_new_from_strings(labels_items);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(labels_drop),
                               c.companion_labels == "always" ? 1 : 0);
    g_signal_connect(labels_drop, "notify::selected",
                     G_CALLBACK(on_mubi_labels_changed), nullptr);
    box_append(GTK_BOX(mubi_labels_row), labels_drop);
    gtk_widget_set_halign(labels_drop, GTK_ALIGN_END);
    gtk_widget_set_hexpand(labels_drop, TRUE);
    box_append(GTK_BOX(advanced), mubi_labels_row);
    mw.mubi_labels_drop = GTK_DROP_DOWN(labels_drop);

    mw.motion_switch = add_toggle_row(advanced, l10n::t("set.motion").c_str(),
                                      c.motion_enabled,
                                      G_CALLBACK(on_motion_set));
    mw.autostart_switch = add_toggle_row(
        advanced, l10n::t("set.autostart").c_str(), g_state.model.autostart,
        G_CALLBACK(on_autostart_set));

    auto* lang_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    box_append(GTK_BOX(lang_row), label_with(l10n::t("set.language").c_str(), "row-label"));
    std::string const lang_auto = l10n::t("lang.auto");
    const char* const lang_items[] = {lang_auto.c_str(), "\u4e2d\u6587",
                                      "English", nullptr};
    auto* lang = gtk_drop_down_new_from_strings(lang_items);
    gtk_drop_down_set_selected(
        GTK_DROP_DOWN(lang),
        c.language == "zh" ? 1 : c.language == "en" ? 2 : 0);
    g_signal_connect(lang, "notify::selected", G_CALLBACK(on_language_changed), nullptr);
    box_append(GTK_BOX(lang_row), lang);
    mw.language_drop = GTK_DROP_DOWN(lang);
    box_append(GTK_BOX(advanced), lang_row);
    box_append(right, card);
  }

  // --- about card ---
  {
    auto* card = make_card();
    auto* version = gtk_label_new("");
    gtk_widget_add_css_class(version, "row-strong");
    gtk_label_set_xalign(GTK_LABEL(version), 0.0f);
    box_append(GTK_BOX(card), version);
    mw.about_version = GTK_LABEL(version);
    // Updates: manual check entry + a hint line for the state machine's
    // outcome (progress lives in its own dialog). The hint is selectable —
    // it may carry a failure message a bug report starts from.
    {
      auto* row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
      auto* check_btn =
          gtk_button_new_with_label(l10n::t("about.checkUpdates").c_str());
      g_signal_connect(check_btn, "clicked",
                       G_CALLBACK(on_check_updates_clicked), nullptr);
      gtk_box_append(GTK_BOX(row), check_btn);
      mw.updates_button = GTK_BUTTON(check_btn);
      auto* hint = gtk_label_new("");
      gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
      gtk_label_set_selectable(GTK_LABEL(hint), TRUE);
      gtk_label_set_max_width_chars(GTK_LABEL(hint), 40);
      gtk_label_set_xalign(GTK_LABEL(hint), 0.0f);
      gtk_widget_add_css_class(hint, "caption");
      gtk_widget_set_hexpand(hint, TRUE);
      gtk_box_append(GTK_BOX(row), hint);
      mw.updates_hint = GTK_LABEL(hint);
      box_append(GTK_BOX(card), row);
    }
    mw.updates_switch = add_toggle_row(card, l10n::t("about.autoUpdate").c_str(),
                                       g_state.model.config.auto_check_updates,
                                       G_CALLBACK(on_updates_set));
    box_append(GTK_BOX(card),
                   label_with(l10n::t("about.autoUpdateHint").c_str(), "caption"));
    // Website / issue tracker / license — the family About rows.
    auto* links = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 16);
    gtk_box_append(
        GTK_BOX(links),
        gtk_link_button_new_with_label("https://movebit.jrtx.site",
                                       l10n::t("about.website").c_str()));
    gtk_box_append(
        GTK_BOX(links),
        gtk_link_button_new_with_label(
            "https://github.com/turlamai/movebit/issues",
            l10n::t("about.reportIssue").c_str()));
    box_append(GTK_BOX(card), links);
    box_append(GTK_BOX(card),
               label_with(l10n::t("about.license").c_str(), "caption"));
    box_append(right, card);
  }

  // --- footer (config path) ---
  {
    auto* footer = gtk_label_new("");
    gtk_widget_add_css_class(footer, "footer");
    gtk_label_set_xalign(GTK_LABEL(footer), 0.0f);
    box_append(right, footer);
    mw.footer = GTK_LABEL(footer);
  }

  box_append(GTK_BOX(columns), left);
  box_append(GTK_BOX(columns), right);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), columns);
  box_append(g_state.content_root, scroll);
  refresh_all();
}

void apply_global_css() {
  auto* provider = gtk_css_provider_new();
  gtk_css_provider_load_from_string(provider, R"CSS(
    .app-bg { background: #F5F2EB; }
    .card {
      background: #FFFFFF;
      border: 1px solid #EAE2D6;
      border-radius: 16px;
      padding: 6px 4px;
    }
    .section { font-size: 13px; color: #6E6A5E; }
    .caption { font-size: 11px; color: #6E6A5E; }
    .footer { font-size: 11px; color: #A39B8D; }
    .row-label { font-size: 13px; color: #26241F; }
    .row-strong { font-size: 14px; font-weight: 600; color: #26241F; }
    .big-number { font-size: 44px; font-weight: 700; color: #26241F; }
    .counter-value { font-size: 14px; font-weight: 600; color: #26241F; }
    .metric-tile { background: #EAE6DC; border-radius: 12px; padding: 12px; }
    .metric-value { font-size: 20px; font-weight: 600; color: #26241F; }
    .status { font-size: 12.5px; }
    .status.ok { color: #16A34A; }
    .status.paused { color: #EA580C; }
    .accent-label { font-size: 11.5px; color: #C25E3E; }
    .sit-bar { min-height: 9px; }
    .sit-bar progress { background: #C25E3E; border-radius: 4px; }
    .sit-bar trough { background: #EAE6DC; border-radius: 4px; }
    .toast-bg { background: #FFFDFB; border-radius: 14px; border: 1px solid #E2DCCC; }
    .mubi-bg { background: transparent; }
    .mubi-capsule { background: #FFFDFB; border-radius: 12px; }
    .mubi-capsule-text { font-size: 12px; font-weight: 600; color: #2D2A28; }
    .toast-title { font-size: 17px; font-weight: 600; color: #26241F; }
    .toast-line { font-size: 13.5px; color: #6E6A5E; }
    .toast-btn { font-size: 12.5px; color: #26241F; background: #F3EEE3;
                 border-radius: 7px; padding: 5px 10px; }
    .toast-btn-muted { font-size: 12.5px; color: #6E6A5E; background: transparent;
                       border: 1px solid #E2DCCC; border-radius: 7px; padding: 5px 10px; }
    .micro-bg { background: #FFFFFF; border-radius: 18px; border: 1px solid #EAE2D6; }
    .micro-title { font-size: 18px; font-weight: 600; color: #26241F; }
    .micro-hint { font-size: 11.5px; color: #A39B8D; }
    .micro-bar trough { background: #EAE6DC; border-radius: 2px; min-height: 4px; }
    .micro-bar progress { background: #C25E3E; border-radius: 2px; min-height: 4px; }
    .ob-bg { background: #F5F2EB; }
    .ob-card { background: #FFFFFF; border: 1px solid #EAE2D6;
               border-radius: 12px; padding: 14px; }
    .ob-card-selected { background: #FBEFE2; border: 1px solid #C25E3E;
                        border-radius: 12px; padding: 14px; }
    .ob-title { font-size: 22px; font-weight: 700; color: #26241F; }
    .ob-hello { font-size: 26px; font-weight: 700; color: #26241F; }
    .ob-text { font-size: 14.5px; color: #6E6A5E; }
    .ob-strong { font-size: 15px; font-weight: 600; color: #26241F; }
    .ob-caption { font-size: 11px; color: #A39B8D; }
    .ob-badge { font-size: 10.5px; color: #C25E3E; background: #FBEFE2;
                border-radius: 5px; padding: 2px 6px; }
    .ob-primary { font-size: 14px; color: #FFFFFF; background: #C25E3E;
                  border-radius: 8px; padding: 9px 18px; }
    .rhythm-chip { font-size: 12.5px; color: #26241F; background: #F3EEE3;
                   border-radius: 8px; padding: 8px 12px; }
    .rhythm-chip-selected { font-size: 12.5px; color: #C25E3E;
                            background: #FBEFE2; border: 1px solid #C25E3E;
                            border-radius: 8px; padding: 8px 12px; }
    .dot { font-size: 18px; color: #EAE6DC; }
    .dot-active { font-size: 18px; color: #C25E3E; }
  )CSS");
  gtk_style_context_add_provider_for_display(
      gdk_display_get_default(), GTK_STYLE_PROVIDER(provider),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_object_unref(provider);
}


// Mubi presentation states (mirrors the backend's cue actions; the numeric
// order matches mubi::draw_state and the companion's idle/focus poses).
enum class MubiCompanionState { Idle = 0, Water = 1, Stand = 2, Eyes = 3,
                                Ack = 4, Focus = 5 };

// Cue action handlers live below (next to the toast ones); the companion
// window wires them at creation time.
void on_mubi_done(GtkButton*, gpointer);
void on_mubi_later(GtkButton*, gpointer);
void on_mubi_hide(GtkButton*, gpointer);

// ---- Mubi（沐比）companion (issue #56, X11 leg) ---------------------------------
// Canonical character from assets/mubi/tokens.json (generator:
// scripts/gen-mubi-art.mjs) drawn with cairo from the master path data.
// The window is placed via gtk_window_move (honored on X11) and is fully
// pointer-through via gtk_widget_set_can_target(FALSE) — the #54 fallback.

void show_toast_plain(std::string const& title,
                      std::vector<std::string> const& lines,
                      rivet_app::ReminderKind accent, GtkApplication* app);

namespace mubi {

using PathIter = std::string::const_iterator;

void skip_separators(PathIter& it, PathIter end) {
  while (it != end && (*it == ' ' || *it == ',')) ++it;
}

double read_number(PathIter& it, PathIter end) {
  skip_separators(it, end);
  std::string digits;
  if (it != end && *it == '-') {
    digits.push_back('-');
    ++it;
  }
  while (it != end && (isdigit(static_cast<unsigned char>(*it)) ||
                       *it == '.')) {
    digits.push_back(*it);
    ++it;
  }
  return std::atof(digits.c_str());
}

// Traces a canonical M/L/C/Z path onto a cairo context (absolute commands
// only, exactly the generator's alphabet).
void trace_path(cairo_t* cr, std::string const& d) {
  auto it = d.begin();
  auto const end = d.end();
  while (it != end) {
    skip_separators(it, end);
    if (it == end) break;
    char const command = *it;
    ++it;
    if (command == 'M') {
      double const x = read_number(it, end);
      double const y = read_number(it, end);
      cairo_move_to(cr, x, y);
    } else if (command == 'L') {
      double const x = read_number(it, end);
      double const y = read_number(it, end);
      cairo_line_to(cr, x, y);
    } else if (command == 'C') {
      double const x1 = read_number(it, end);
      double const y1 = read_number(it, end);
      double const x2 = read_number(it, end);
      double const y2 = read_number(it, end);
      double const x3 = read_number(it, end);
      double const y3 = read_number(it, end);
      cairo_curve_to(cr, x1, y1, x2, y2, x3, y3);
    } else if (command == 'Z') {
      cairo_close_path(cr);
    }
  }
}

void fill_path(cairo_t* cr, std::string const& d, char const* hex,
               double alpha = 1.0) {
  trace_path(cr, d);
  GdkRGBA rgba;
  gdk_rgba_parse(&rgba, hex);
  cairo_set_source_rgba(cr, rgba.red, rgba.green, rgba.blue,
                        rgba.alpha * alpha);
  cairo_fill(cr);
}

void stroke_path(cairo_t* cr, std::string const& d, char const* hex,
                 double width) {
  trace_path(cr, d);
  GdkRGBA rgba;
  gdk_rgba_parse(&rgba, hex);
  cairo_set_source_rgba(cr, rgba.red, rgba.green, rgba.blue, rgba.alpha);
  cairo_set_line_width(cr, width);
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
  cairo_stroke(cr);
}

constexpr char const* kBody =
    "M 58 16 C 82 18, 106 46, 109 82 C 111 104, 92 124, 60 124 "
    "C 33 124, 12.5 106, 11 84 C 9.5 52, 34 14, 58 16 Z";
constexpr char const* kFinLeft =
    "M 52 24 C 47 13, 40 7, 32 6 C 30 14, 36 23, 45 27 "
    "C 48 28.2, 51 26.5, 52 24 Z";
constexpr char const* kFinRight =
    "M 74 23 C 71 14, 66.5 8, 60.5 6 C 58.5 13, 62.5 21.5, 70 25 "
    "C 72.3 25.9, 73.8 25, 74 23 Z";
constexpr char const* kFinShade =
    "M 48 22 C 44.5 15.5, 39.5 10.5, 34.5 8.5 C 33.5 13.5, 38 20.5, 45 24.5 Z";
constexpr char const* kLowerShade =
    "M 16 96 C 24 118, 42 126, 60 126 C 80 126, 98 116, 105 94 "
    "C 100 116, 84 128, 60 128 C 38 128, 20 114, 16 96 Z";
constexpr char const* kEyeClosedL = "M 43 65 C 45 67.6, 48 67.6, 50 65";
constexpr char const* kEyeClosedR = "M 70 65 C 72 67.6, 75 67.6, 77 65";
constexpr char const* kMouthAck = "M 57.5 74 C 59 75.4, 61 75.4, 62.5 74";
constexpr char const* kGazeCrescent = "M 92 38 C 96.5 40.5, 99 45, 98 50";
constexpr char const* kStretchL = "M 42 11 C 47 4, 53 2, 58 4";
constexpr char const* kStretchR = "M 78 11 C 73 4, 67 2, 62 4";
constexpr char const* kAckGlint =
    "M 84 56 L 86 60.5 L 90.5 62 L 86 63.5 L 84 68 L 82 63.5 L 77.5 62 "
    "L 82 60.5 Z";
constexpr char const* kCupBody =
    "M -7 -9 L 7 -9 L 5.4 9 C 5.2 10.6, 4 11.5, 2.4 11.5 "
    "L -2.4 11.5 C -4 11.5, -5.2 10.6, -5.4 9 Z";
constexpr char const* kCupWater = "M -4.6 -6.5 L 4.4 -6.5 L 3.6 1.5 L -4 1.5 Z";

constexpr char const* kHexBody = "#F6EEDF";
constexpr char const* kHexBodyLight = "#FBF5E9";
constexpr char const* kHexBodyDeep = "#E8D7BE";
constexpr char const* kHexShadow = "#D8C8B5";
constexpr char const* kHexInk = "#2D2A28";
constexpr char const* kHexFin = "#F1E4CC";

void eye(cairo_t* cr, double cx, double cy) {
  cairo_save(cr);
  cairo_translate(cr, cx, cy);
  cairo_scale(cr, 3.0, 3.6);
  cairo_arc(cr, 0, 0, 1, 0, 2 * 3.14159265358979);
  cairo_restore(cr);
  GdkRGBA ink;
  gdk_rgba_parse(&ink, kHexInk);
  cairo_set_source_rgba(cr, ink.red, ink.green, ink.blue, ink.alpha);
  cairo_fill(cr);
}

void on_drag_begin(GtkGestureDrag*, double, double, gpointer);
void on_drag_update(GtkGestureDrag*, double, double, gpointer);
void on_drag_end(GtkGestureDrag*, double, double, gpointer);
void save_placement();

void draw_state(cairo_t* cr, int state) {
  double const p = g_state.mubi_anim_progress;
  // Stand: body lengthens upward, anchored at the docked bottom (y=124).
  if (state == 2) {
    cairo_save(cr);
    cairo_translate(cr, 0, 124);
    cairo_scale(cr, 1.0, 1.0 + 0.06 * p);
    cairo_translate(cr, 0, -124);
  }
  fill_path(cr, kFinLeft, kHexFin);
  fill_path(cr, kFinRight, kHexFin);
  fill_path(cr, kFinShade, kHexShadow, 0.35);

  // Body with the volume gradient (tokens: body.light -> body -> deep).
  trace_path(cr, kBody);
  cairo_pattern_t* body_grad = cairo_pattern_create_linear(20, 14, 95, 124);
  GdkRGBA top;
  gdk_rgba_parse(&top, kHexBodyLight);
  GdkRGBA mid;
  gdk_rgba_parse(&mid, kHexBody);
  GdkRGBA deep;
  gdk_rgba_parse(&deep, kHexBodyDeep);
  cairo_pattern_add_color_stop_rgba(body_grad, 0, top.red, top.green,
                                    top.blue, top.alpha);
  cairo_pattern_add_color_stop_rgba(body_grad, 0.45, mid.red, mid.green,
                                    mid.blue, mid.alpha);
  cairo_pattern_add_color_stop_rgba(body_grad, 1, deep.red, deep.green,
                                    deep.blue, deep.alpha);
  cairo_set_source(cr, body_grad);
  cairo_fill(cr);
  cairo_pattern_destroy(body_grad);

  // Lower form shade.
  trace_path(cr, kLowerShade);
  cairo_pattern_t* shade = cairo_pattern_create_linear(0, 94, 0, 128);
  GdkRGBA sh;
  gdk_rgba_parse(&sh, kHexShadow);
  cairo_pattern_add_color_stop_rgba(shade, 0, sh.red, sh.green, sh.blue, 0);
  cairo_pattern_add_color_stop_rgba(shade, 1, sh.red, sh.green, sh.blue,
                                    0.55);
  cairo_set_source(cr, shade);
  cairo_fill(cr);
  cairo_pattern_destroy(shade);

  // Rim light: soft radial blob, upper-left.
  cairo_pattern_t* rim = cairo_pattern_create_radial(38, 46, 2, 38, 46, 30);
  cairo_pattern_add_color_stop_rgba(rim, 0, 1, 1, 1, 0.45);
  cairo_pattern_add_color_stop_rgba(rim, 1, 1, 1, 1, 0);
  cairo_set_source(cr, rim);
  cairo_arc(cr, 38, 46, 28, 0, 2 * 3.14159265358979);
  cairo_fill(cr);
  cairo_pattern_destroy(rim);

  if (state == 3 || state == 5) {  // eyes closed / focus
    stroke_path(cr, kEyeClosedL, kHexInk, 2.2);
    stroke_path(cr, kEyeClosedR, kHexInk, 2.2);
  } else {
    eye(cr, 46.5, 65);
    eye(cr, 73.5, 65);
    // Glints.
    double const gy = state == 1 ? 63.2 : 63.8;
    cairo_set_source_rgba(cr, 1, 1, 1, 0.85);
    cairo_arc(cr, 47.6, gy, 1, 0, 2 * 3.14159265358979);
    cairo_fill(cr);
    cairo_arc(cr, 74.6, gy, 1, 0, 2 * 3.14159265358979);
    cairo_fill(cr);
    if (state == 4) stroke_path(cr, kMouthAck, kHexInk, 1.6);
  }

  if (state == 2) {
    cairo_restore(cr);  // end the stand stretch transform
  }

  if (state == 1) {  // water: cup rises 12 units at canvas (97,57)
    cairo_save(cr);
    cairo_translate(cr, 97, 57 - 12 * p);
    cairo_rotate(cr, -10 * 3.14159265358979 / 180.0);
    cairo_scale(cr, 0.9, 0.9);
    fill_path(cr, kCupBody, "#62B6FF");
    fill_path(cr, kCupWater, "#8FCBFF", 0.85);
    cairo_restore(cr);
  } else if (state == 2) {  // stand: coral stretch arcs fade in
    GdkRGBA move;
    gdk_rgba_parse(&move, "#FF8C6B");
    cairo_set_source_rgba(cr, move.red, move.green, move.blue,
                          move.alpha * (0.3 + 0.7 * p));
    cairo_set_line_width(cr, 3);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    trace_path(cr, kStretchL);
    cairo_stroke(cr);
    cairo_set_source_rgba(cr, move.red, move.green, move.blue,
                          move.alpha * (0.3 + 0.7 * p) * 0.65);
    trace_path(cr, kStretchR);
    cairo_stroke(cr);
  } else if (state == 3) {  // eyes: mint gaze-off
    stroke_path(cr, kGazeCrescent, "#65C8B8", 3);
  } else if (state == 4) {  // ack: warm glint brightens
    GdkRGBA done;
    gdk_rgba_parse(&done, "#F2C96B");
    cairo_set_source_rgba(cr, done.red, done.green, done.blue,
                          done.alpha * (0.4 + 0.6 * p));
    trace_path(cr, kAckGlint);
    cairo_fill(cr);
  } else if (state == 5) {  // focus: quiet moon
    GdkRGBA moon;
    gdk_rgba_parse(&moon, "#8DA1B5");
    cairo_set_source_rgba(cr, moon.red, moon.green, moon.blue, 0.75);
    cairo_arc(cr, 96, 38, 8, 0, 2 * 3.14159265358979);
    cairo_fill(cr);
    GdkRGBA body_over;
    gdk_rgba_parse(&body_over, kHexBody);
    cairo_set_source_rgba(cr, body_over.red, body_over.green, body_over.blue,
                          body_over.alpha);
    cairo_arc(cr, 99, 35.5, 6, 0, 2 * 3.14159265358979);
    cairo_fill(cr);
  }
}

double scale_for(std::string const& size);

void draw(GtkDrawingArea*, cairo_t* cr, int, int, gpointer) {
  // draw_state() paints in the 120x140 canonical design grid (the master
  // data every host shares); the canvas widget is sized to the user's Mubi
  // size, so map design units onto the allocation. Without this the right
  // ~27% of the character clips at the widget edge on M/L.
  double const s = scale_for(g_state.mubi_size);
  cairo_save(cr);
  cairo_scale(cr, s, s);
  draw_state(cr, g_state.mubi_state);
  cairo_restore(cr);
}

double scale_for(std::string const& size) {
  if (size == "S") return 60.0 / 108.0;
  if (size == "L") return 104.0 / 108.0;
  return 78.0 / 108.0;
}

void close_window() {
  if (g_state.mubi_expire_id != 0) {
    g_source_remove(g_state.mubi_expire_id);
    g_state.mubi_expire_id = 0;
  }
  if (g_state.mubi_window != nullptr) {
    gtk_window_destroy(g_state.mubi_window);
    g_state.mubi_window = nullptr;
    g_state.mubi_canvas = nullptr;
    g_state.mubi_capsule = nullptr;
  }
}

void refresh_label() {
  if (g_state.mubi_capsule == nullptr) return;
  if (g_state.mubi_labels_always || !g_state.mubi_message.empty()) {
    // Contextual state icon; the text carries the meaning (#56 §5).
    char const* icon = "";
    switch (g_state.mubi_state) {
      case 1: icon = "\u2703\uFE0F "; break;   // 💧
      case 2: icon = "\U0001F9CD "; break;      // 🧍
      case 3: icon = "\U0001F441 "; break;      // 👁
      case 4: icon = "\u2713 "; break;          // ✓
      case 5: icon = "\U0001F319 "; break;      // 🌙
      default: break;
    }
    std::string text = icon;
    text += g_state.mubi_message.empty() ? "MoveBit" : g_state.mubi_message;
    gtk_label_set_text(g_state.mubi_capsule, text.c_str());
    gtk_widget_set_visible(GTK_WIDGET(g_state.mubi_capsule), TRUE);
  } else {
    gtk_widget_set_visible(GTK_WIDGET(g_state.mubi_capsule), FALSE);
  }
}

void stop_anim() {
  if (g_state.mubi_anim_tick_id != 0) {
    g_source_remove(g_state.mubi_anim_tick_id);
    g_state.mubi_anim_tick_id = 0;
  }
}

// One expressive gesture per due moment; "still" stays static.
void start_anim(int state) {
  stop_anim();
  g_state.mubi_anim_progress = 1.0;
  std::int64_t ms = 0;
  switch (state) {
    case 1: ms = g_state.mubi_motion == "lively" ? 950 : 750; break;
    case 2: ms = g_state.mubi_motion == "lively" ? 1150 : 900; break;
    case 4: ms = 450; break;
    default: ms = 0; break;  // eyes/idle/focus are the quietest poses
  }
  if (ms == 0 || g_state.mubi_motion == "still") return;
  g_state.mubi_anim_progress = 0.0;
  g_state.mubi_anim_step = 33.0 / static_cast<double>(ms);
  g_state.mubi_anim_tick_id = g_timeout_add(
      33,
      +[](gpointer) -> int {
        g_state.mubi_anim_progress =
            std::min(1.0, g_state.mubi_anim_progress + g_state.mubi_anim_step);
        if (g_state.mubi_canvas != nullptr) {
          gtk_widget_queue_draw(GTK_WIDGET(g_state.mubi_canvas));
        }
        if (g_state.mubi_anim_progress >= 1.0) {
          g_state.mubi_anim_tick_id = 0;
          return G_SOURCE_REMOVE;
        }
        return G_SOURCE_CONTINUE;
      },
      nullptr);
}

void begin_placement();
void end_placement();
void save_placement();
void set_interactive(bool interactive);

void present(int state, std::string const& message, GtkApplication* app,
             std::int64_t cue_id = 0) {
  if (g_state.mubi_placing) end_placement();
  if (!g_state.mubi_x11) return;  // Wayland: notification fallback only
  if (g_state.acceptance) return;  // headless probe sees the main window only
  if (app == nullptr) app = g_state.app;
  if (app == nullptr) return;
  auto& s = g_state;
  s.mubi_state = state;
  s.mubi_message = message;
  s.mubi_cue_id = cue_id;
  start_anim(state);
  // Static poses (idle/eyes/focus) start no animation tick, so without an
  // explicit redraw the canvas keeps showing the previous pose forever.
  if (s.mubi_canvas != nullptr) {
    gtk_widget_queue_draw(GTK_WIDGET(s.mubi_canvas));
  }

  if (s.mubi_expire_id != 0) {
    g_source_remove(s.mubi_expire_id);
    s.mubi_expire_id = 0;
  }

  double const scale = scale_for(s.mubi_size);
  int const canvas_w = static_cast<int>(120 * scale + 24);
  int const canvas_h = static_cast<int>(140 * scale + 24);

  if (s.mubi_window == nullptr) {
    auto* window = gtk_application_window_new(app);
    gtk_widget_add_css_class(GTK_WIDGET(window), "mubi-bg");
    gtk_window_set_title(GTK_WINDOW(window), "Mubi");
    gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
    s.mubi_window = GTK_WINDOW(window);
    // Mac-parity presence: the character floats free on the desktop — no
    // card behind it (the opaque surface must not paint, and the
    // compositor has to know nothing is opaque for the ARGB alpha to show
    // through). The whole window stays pointer-through like the macOS
    // panel; cue actions live in the tray menu on every host now.
    gtk_widget_set_can_target(window, FALSE);
    gtk_widget_set_can_focus(window, FALSE);
    gtk_widget_set_focusable(window, FALSE);
#ifdef GDK_WINDOWING_X11
    // Dock placement requires bypassing the window manager: ICCCM managed
    // windows ignore client XMoveWindow under mutter, so the companion
    // must be an override-redirect OSD surface. Realize first so the X
    // surface exists, then flip the attribute before the window maps.
    // GDK 4.16 deprecates the X11 native accessors below with no
    // replacement — the entire feature stands on them — so the deprecation
    // is acknowledged here and silenced for this block only.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    {
      auto* surface = gtk_native_get_surface(GTK_NATIVE(window));
      if (surface == nullptr) {
        gtk_widget_realize(GTK_WIDGET(window));
        surface = gtk_native_get_surface(GTK_NATIVE(window));
      }
      auto* display = gtk_widget_get_display(GTK_WIDGET(window));
      if (surface != nullptr) {
        // Nothing in this window is opaque — clear the opaque region so
        // the compositor composes the character's alpha against the
        // desktop instead of a solid surface.
        gdk_surface_set_opaque_region(surface, nullptr);
        // GTK can-target is not native X11 click-through. Use an empty
        // input shape so clicks and selections reach background applications.
        cairo_region_t* empty_input = cairo_region_create();
        gdk_surface_set_input_region(surface, empty_input);
        cairo_region_destroy(empty_input);
      }
      if (surface != nullptr && GDK_IS_X11_SURFACE(surface) &&
          GDK_IS_X11_DISPLAY(display)) {
        Display* xdisplay =
            gdk_x11_display_get_xdisplay(GDK_X11_DISPLAY(display));
        Window xid = gdk_x11_surface_get_xid(GDK_X11_SURFACE(surface));
        XSetWindowAttributes attrs;
        attrs.override_redirect = True;
        XChangeWindowAttributes(xdisplay, xid, CWOverrideRedirect, &attrs);
      }
    }
#pragma GCC diagnostic pop
#endif

    auto* body_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_margin_top(body_box, 4);
    gtk_widget_set_margin_bottom(body_box, 4);
    gtk_widget_set_margin_start(body_box, 4);
    gtk_widget_set_margin_end(body_box, 4);

    auto* canvas = GTK_DRAWING_AREA(gtk_drawing_area_new());
    // gtk_drawing_area_set_content_size is 4.12+; a size request is the
    // portable form and identical here (no other children compete).
    gtk_widget_set_size_request(GTK_WIDGET(canvas),
                                static_cast<int>(120 * scale),
                                static_cast<int>(140 * scale));
    gtk_drawing_area_set_draw_func(canvas, draw, nullptr, nullptr);
    auto* drag = gtk_gesture_drag_new();
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_drag_begin), nullptr);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag_update), nullptr);
    g_signal_connect(drag, "drag-end", G_CALLBACK(on_drag_end), nullptr);
    gtk_widget_add_controller(GTK_WIDGET(canvas), GTK_EVENT_CONTROLLER(drag));
    box_append(GTK_BOX(body_box), GTK_WIDGET(canvas));
    s.mubi_canvas = canvas;

    auto* capsule = gtk_label_new("");
    gtk_widget_add_css_class(capsule, "mubi-capsule");
    gtk_widget_add_css_class(capsule, "mubi-capsule-text");
    gtk_widget_set_halign(capsule, GTK_ALIGN_CENTER);
    gtk_label_set_justify(GTK_LABEL(capsule), GTK_JUSTIFY_CENTER);
    gtk_label_set_wrap(GTK_LABEL(capsule), TRUE);
    box_append(GTK_BOX(body_box), capsule);
    s.mubi_capsule = GTK_LABEL(capsule);

    gtk_window_set_child(GTK_WINDOW(window), body_box);
  } else {
    gtk_widget_set_size_request(GTK_WIDGET(s.mubi_canvas),
                                static_cast<int>(120 * scale),
                                static_cast<int>(140 * scale));
  }

  refresh_label();
  // Explicit size: the window hugs the character (canvas + capsule area
  // while a label shows). Cue actions live in the tray menu, not here.
  bool const label_visible = s.mubi_labels_always || !s.mubi_message.empty();
  int const win_w = canvas_w;
  int const win_h = canvas_h + (label_visible ? 44 : 0);
  gtk_window_set_default_size(s.mubi_window, win_w, win_h);
  // Do not request window-manager keyboard focus for a floating pet.
  gtk_widget_set_visible(GTK_WIDGET(s.mubi_window), TRUE);

  // Dock inside the monitor work area. GTK4 has no gtk_window_move; on
  // X11 position through Xlib against the monitor's work area. Same story
  // as above: deprecated X11 accessors, no replacement.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
#ifdef GDK_WINDOWING_X11
  if (auto* surface = gtk_native_get_surface(GTK_NATIVE(s.mubi_window))) {
    if (GDK_IS_X11_SURFACE(surface)) {
      auto* display = gdk_display_get_default();
      Display* xdisplay = gdk_x11_display_get_xdisplay(display);
      Window xid = gdk_x11_surface_get_xid(surface);
      GdkMonitor* monitor =
          gdk_display_get_monitor_at_surface(display, surface);
      GdkRectangle work{};
      // GTK4 renamed the work-area accessor to the X11 variant.
      gdk_x11_monitor_get_workarea(monitor, &work);
      int const clearance = 16;
      // GDK reports the workarea and widget sizes in logical pixels, but
      // XMoveWindow speaks physical pixels; on a 2x monitor the naive mix
      // pushed the companion past the screen edge. Convert the workarea and
      // the card budget with the surface scale instead of measuring the X
      // window: the resize from set_default_size lands asynchronously and a
      // just-measured size would lag one frame behind.
      double const xs = gdk_surface_get_scale(surface);
      int const px_w = static_cast<int>(win_w * xs);
      int const px_h = static_cast<int>(win_h * xs);
      int const px_clear = static_cast<int>(clearance * xs);
      int const work_x = static_cast<int>(work.x * xs);
      int const work_y = static_cast<int>(work.y * xs);
      int const work_w = static_cast<int>(work.width * xs);
      int const work_h = static_cast<int>(work.height * xs);
      int x = work_x + work_w - px_w - px_clear;
      int y = work_y + work_h - px_h - px_clear;
      if (s.mubi_free_x >= 0 && s.mubi_free_y >= 0) {
        // Clamp to the usable travel range so a stale or synced position can
        // never leave the character off-screen.
        int const travel_w = std::max(0, work_w - px_w - 2 * px_clear);
        int const travel_h = std::max(0, work_h - px_h - 2 * px_clear);
        x = work_x + px_clear +
            static_cast<int>(travel_w * s.mubi_free_x / 1000);
        y = work_y + px_clear +
            static_cast<int>(travel_h * s.mubi_free_y / 1000);
      } else {
        if (s.mubi_dock == "bottom-left" || s.mubi_dock == "top-left") {
          x = work_x + px_clear;
        }
        if (s.mubi_dock == "top-right" || s.mubi_dock == "top-left") {
          y = work_y + px_clear;
        }
      }
      XMoveWindow(xdisplay, xid, x, y);
      XFlush(xdisplay);
    }
  }
#pragma GCC diagnostic pop
#endif

  // The label reads ~5 s, then the card returns to its calm pose. The cue
  // itself stays open in the backend ledger (#56: label fade is not Done).
  // An idle/focus character with no transient message needs NO timer.
  // Previously this callback rescheduled itself every five seconds forever.
  // Keep a short, self-ending 1.6s acknowledgment flourish; real due cues
  // continue to use their own bounded timeout and never imply "Done".
  if (!message.empty() || state == 4) {
    s.mubi_expire_id = g_timeout_add(
      (state == 4 ? 1600 : 5000),
      +[](gpointer) -> int {
        g_state.mubi_expire_id = 0;
        present(g_state.mubi_quiet ? 5 : 0, "", nullptr);
        return G_SOURCE_REMOVE;
      },
      nullptr);
  }
}

void show_idle() { present(g_state.mubi_quiet ? 5 : 0, "", nullptr); }

// Pointer-through stays the default: the empty input region is restored on
// every exit path. Placement mode temporarily makes only the character's
// canvas rectangle sensitive — never the whole window.
void set_interactive(bool interactive) {
  if (g_state.mubi_window == nullptr) return;
  gtk_widget_set_can_target(GTK_WIDGET(g_state.mubi_window), interactive);
  if (g_state.mubi_canvas != nullptr) {
    gtk_widget_set_can_target(GTK_WIDGET(g_state.mubi_canvas), interactive);
  }
#ifdef GDK_WINDOWING_X11
  auto* surface = gtk_native_get_surface(GTK_NATIVE(g_state.mubi_window));
  if (surface == nullptr) return;
  if (interactive) {
    graphene_rect_t bounds;
    if (!gtk_widget_compute_bounds(GTK_WIDGET(g_state.mubi_canvas),
                                   GTK_WIDGET(g_state.mubi_window),
                                   &bounds)) {
      return;
    }
    // The canvas allocation may not exist yet when placement is entered
    // (before the first frame). Fall back to the body area instead of
    // installing a useless 0×0 region.
    if (bounds.size.width < 1 || bounds.size.height < 1) {
      bounds.origin.x = 4;
      bounds.origin.y = 4;
      bounds.size.width =
          std::max(1, gtk_widget_get_width(GTK_WIDGET(g_state.mubi_window)) - 8);
      bounds.size.height =
          std::max(1, gtk_widget_get_height(GTK_WIDGET(g_state.mubi_window)) - 8);
    }
    double const scale = gdk_surface_get_scale(surface);
    cairo_rectangle_int_t rect;
    rect.x = static_cast<int>(std::floor(bounds.origin.x * scale)) - 2;
    rect.y = static_cast<int>(std::floor(bounds.origin.y * scale)) - 2;
    rect.width = static_cast<int>(std::ceil(bounds.size.width * scale)) + 4;
    rect.height = static_cast<int>(std::ceil(bounds.size.height * scale)) + 4;
    if (rect.width <= 0 || rect.height <= 0) return;
    cairo_region_t* region = cairo_region_create_rectangle(&rect);
    gdk_surface_set_input_region(surface, region);
    cairo_region_destroy(region);
  } else {
    cairo_region_t* empty_input = cairo_region_create();
    gdk_surface_set_input_region(surface, empty_input);
    cairo_region_destroy(empty_input);
  }
#endif
}

void begin_placement() {
  if (!g_state.mubi_x11 || g_state.mubi_quiet) return;
  show_idle();
  if (g_state.mubi_window == nullptr) return;
  g_state.mubi_placing = true;
  set_interactive(true);
  // Recompute once the window has been allocated this frame.
  g_timeout_add(
      60,
      +[](gpointer) -> int {
        if (g_state.mubi_placing) set_interactive(true);
        return G_SOURCE_REMOVE;
      },
      nullptr);
  if (g_state.mubi_place_timer != 0) g_source_remove(g_state.mubi_place_timer);
  g_state.mubi_place_timer = g_timeout_add_seconds(
      30,
      +[](gpointer) -> int {
        g_state.mubi_place_timer = 0;
        end_placement();
        return G_SOURCE_REMOVE;
      },
      nullptr);
  if (g_state.app != nullptr) {
    ::show_toast_plain(l10n::t("tray.placeMubi"),
                       {l10n::t("tray.placeHint")},
                       rivet_app::ReminderKind::water, g_state.app);
  }
  refresh_header_buttons();
}

void end_placement() {
  if (!g_state.mubi_placing) return;
  g_state.mubi_placing = false;
  if (g_state.mubi_place_timer != 0) {
    g_source_remove(g_state.mubi_place_timer);
    g_state.mubi_place_timer = 0;
  }
  save_placement();
  set_interactive(false);
  refresh_header_buttons();
}

void toggle_placement() {
  if (g_state.mubi_placing) {
    end_placement();
  } else {
    begin_placement();
  }
}

void save_placement() {
  if (g_state.mubi_window == nullptr) return;
#ifdef GDK_WINDOWING_X11
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  auto* surface = gtk_native_get_surface(GTK_NATIVE(g_state.mubi_window));
  if (surface == nullptr || !GDK_IS_X11_SURFACE(surface)) return;
  auto* display = gdk_surface_get_display(surface);
  Display* xdisplay = gdk_x11_display_get_xdisplay(display);
  Window xid = gdk_x11_surface_get_xid(GDK_X11_SURFACE(surface));
  Window root{};
  int x = 0;
  int y = 0;
  unsigned width = 0;
  unsigned height = 0;
  unsigned border = 0;
  unsigned depth = 0;
  if (!XGetGeometry(xdisplay, xid, &root, &x, &y, &width, &height, &border,
                    &depth)) {
    return;
  }
  auto* monitor = gdk_display_get_monitor_at_surface(display, surface);
  if (monitor == nullptr) return;
  GdkRectangle work{};
  gdk_x11_monitor_get_workarea(monitor, &work);
  double const scale = gdk_surface_get_scale(surface);
  int const px_clear = static_cast<int>(16 * scale);
  int const work_x = static_cast<int>(work.x * scale);
  int const work_y = static_cast<int>(work.y * scale);
  int const work_w = static_cast<int>(work.width * scale);
  int const work_h = static_cast<int>(work.height * scale);
  int const travel_w =
      std::max(1, work_w - static_cast<int>(width) - 2 * px_clear);
  int const travel_h =
      std::max(1, work_h - static_cast<int>(height) - 2 * px_clear);
  auto permille = [](int value, int travel) {
    double const f = static_cast<double>(value) / static_cast<double>(travel);
    return static_cast<std::int64_t>(
        std::llround(std::clamp(f, 0.0, 1.0) * 1000));
  };
  std::int64_t const nx = permille(x - work_x - px_clear, travel_w);
  std::int64_t const ny = permille(y - work_y - px_clear, travel_h);
  if (nx == g_state.mubi_free_x && ny == g_state.mubi_free_y) return;
  g_state.mubi_free_x = nx;
  g_state.mubi_free_y = ny;
  mutate_config([&](auto& cfg) {
    cfg.companion_free_x = nx;
    cfg.companion_free_y = ny;
  });
#pragma GCC diagnostic pop
#endif
}

void on_drag_begin(GtkGestureDrag*, double, double, gpointer) {
  if (!g_state.mubi_placing || g_state.mubi_window == nullptr) return;
#ifdef GDK_WINDOWING_X11
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  auto* surface = gtk_native_get_surface(GTK_NATIVE(g_state.mubi_window));
  if (surface == nullptr || !GDK_IS_X11_SURFACE(surface)) return;
  Display* xdisplay =
      gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
  Window xid = gdk_x11_surface_get_xid(GDK_X11_SURFACE(surface));
  Window root{};
  int x = 0;
  int y = 0;
  unsigned width = 0;
  unsigned height = 0;
  unsigned border = 0;
  unsigned depth = 0;
  if (XGetGeometry(xdisplay, xid, &root, &x, &y, &width, &height, &border,
                   &depth)) {
    g_state.mubi_drag_origin_x = x;
    g_state.mubi_drag_origin_y = y;
  }
#pragma GCC diagnostic pop
#endif
}

void on_drag_update(GtkGestureDrag*, double offset_x, double offset_y,
                    gpointer) {
  if (!g_state.mubi_placing || g_state.mubi_window == nullptr) return;
#ifdef GDK_WINDOWING_X11
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  auto* surface = gtk_native_get_surface(GTK_NATIVE(g_state.mubi_window));
  if (surface == nullptr || !GDK_IS_X11_SURFACE(surface)) return;
  double const scale = gdk_surface_get_scale(surface);
  Display* xdisplay =
      gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
  Window xid = gdk_x11_surface_get_xid(GDK_X11_SURFACE(surface));
  XMoveWindow(xdisplay, xid,
              g_state.mubi_drag_origin_x +
                  static_cast<int>(std::llround(offset_x * scale)),
              g_state.mubi_drag_origin_y +
                  static_cast<int>(std::llround(offset_y * scale)));
  XFlush(xdisplay);
#pragma GCC diagnostic pop
#endif
}

void on_drag_end(GtkGestureDrag*, double, double, gpointer) {
  if (g_state.mubi_placing) save_placement();
}

// Cycle a local, temporary corner to get out of the user's way.
// Do not update persisted settings or the Racket reminder ledger.
void move_aside() {
  if (!g_state.mubi_x11) return;
  g_state.mubi_free_x = -1;
  g_state.mubi_free_y = -1;
  if (g_state.mubi_dock == "bottom-right") g_state.mubi_dock = "bottom-left";
  else if (g_state.mubi_dock == "bottom-left") g_state.mubi_dock = "top-left";
  else if (g_state.mubi_dock == "top-left") g_state.mubi_dock = "top-right";
  else g_state.mubi_dock = "bottom-right";
  // Keep the same due cue and readable text when parking Mubi elsewhere.
  // Re-presenting is visual only: no backend acknowledge/snooze/dismiss.
  present(g_state.mubi_state, g_state.mubi_message, nullptr,
          g_state.mubi_cue_id);
}

void show_ack() {
  if (!g_state.mubi_quiet) present(4, "", nullptr);
}

void set_quiet(bool enabled) {
  g_state.mubi_quiet = enabled;
  present(enabled ? 5 : 0, "", nullptr);
}

void apply_config(std::string const& size, std::string const& motion,
                  std::string const& dock, std::string const& labels,
                  std::int64_t freeX, std::int64_t freeY) {
  g_state.mubi_size = size;
  g_state.mubi_motion = motion;  // static-state leg; budget tuning is #56 D3
  g_state.mubi_dock = dock;
  g_state.mubi_labels_always = labels == "always";
  g_state.mubi_free_x = freeX;
  g_state.mubi_free_y = freeY;
  show_idle();
}

}  // namespace mubi

// ---- toast --------------------------------------------------------------------

void on_toast_hide(GtkButton*, gpointer);
void cue_displayed(std::int64_t id);

void toast_dismiss() {
  g_state.toast_cue_id = 0;
  if (g_state.toast_timeout_id != 0) {
    g_source_remove(g_state.toast_timeout_id);
    g_state.toast_timeout_id = 0;
  }
  if (g_state.toast_window != nullptr) {
    gtk_window_destroy(g_state.toast_window);
    g_state.toast_window = nullptr;
    g_state.toast_title_label = nullptr;
    g_state.toast_lines_box = nullptr;
    g_state.toast_snooze_button = nullptr;
  }
}

void toast_restart_auto_close() {
  if (g_state.toast_timeout_id != 0) {
    g_source_remove(g_state.toast_timeout_id);
  }
  g_state.toast_timeout_id = g_timeout_add(
      9000,
      +[](gpointer) -> int {
        g_state.toast_timeout_id = 0;
        on_toast_hide(nullptr, nullptr);
        return G_SOURCE_REMOVE;
      },
      nullptr);
}

// Later: defers every kind merged into the cue by the snooze minutes.
void on_toast_snooze(GtkButton*, gpointer) {
  auto cue_id = g_state.toast_cue_id;
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->snooze_cue_async(cue_id, [](rivet_app::Result<void>) {});
    (void)g_state.api->get_loops_async([](rivet_app::Result<std::vector<rivet_app::LoopInfo>> r) {
      on_result(std::move(r), [](std::vector<rivet_app::LoopInfo> const& loops) {
        g_state.model.loops = loops;
        refresh_today_card();
      });
    });
    // #56 §4 `later`: a tiny quiet settle on the companion.
    mubi::present(0, l10n::t("mubi.laterNote"), g_state.app);
  }
  toast_dismiss();
}

// Done: self-reported acknowledgement — never proof of a real break.
void on_toast_done(GtkButton*, gpointer) {
  auto cue_id = g_state.toast_cue_id;
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->acknowledge_cue_async(cue_id,
                                             [](rivet_app::Result<void>) {});
  }
  toast_dismiss();
}

// Hide: no completion claimed, no deferral; the normal schedule continues.
void on_toast_hide(GtkButton*, gpointer) {
  auto cue_id = g_state.toast_cue_id;
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->abandon_cue_async(cue_id, [](rivet_app::Result<void>) {});
  }
  toast_dismiss();
}

// Companion card actions (#54): same semantics as the toast row, offered
// on the character itself while a cue is on screen.
void on_mubi_done(GtkButton*, gpointer) {
  auto cue_id = g_state.mubi_cue_id;
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->acknowledge_cue_async(cue_id,
                                             [](rivet_app::Result<void>) {});
  }
  mubi::present(g_state.mubi_quiet ? 5 : 0, "", nullptr);
}

void on_mubi_later(GtkButton*, gpointer) {
  auto cue_id = g_state.mubi_cue_id;
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->snooze_cue_async(cue_id, [](rivet_app::Result<void>) {});
    (void)g_state.api->get_loops_async(
        [](rivet_app::Result<std::vector<rivet_app::LoopInfo>> r) {
          on_result(std::move(r),
                    [](std::vector<rivet_app::LoopInfo> const& loops) {
                      g_state.model.loops = loops;
                      refresh_today_card();
                    });
        });
  }
  // #56 §4 `later`: a tiny quiet settle with the reassurance note.
  mubi::present(0, l10n::t("mubi.laterNote"), nullptr);
}

void on_mubi_hide(GtkButton*, gpointer) {
  auto cue_id = g_state.mubi_cue_id;
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->abandon_cue_async(cue_id, [](rivet_app::Result<void>) {});
  }
  mubi::present(g_state.mubi_quiet ? 5 : 0, "", nullptr);
}

// ---- tray (StatusNotifierItem, issue #54 parity with the mac/win hosts) ----
// The companion surface is fully pointer-through on X11, so Done / Later /
// Hide / pause / Focus live here too, acting on the newest open cue — the
// same menu shape as the other hosts. rivet's TrayIcon talks SNI +
// dbusmenu over the session bus; on GNOME that surfaces through the
// AppIndicator extension, and TrayIcon::available() is false without a
// watcher, in which case the header buttons stay the only controls.
void micro_show(std::int64_t duration_seconds, std::string const& title,
                std::string const& hint_text, std::int64_t cue_id,
                GtkApplication* app);

namespace tray {

std::unique_ptr<rivet::system::TrayIcon> g_icon;

rivet::system::TrayMenuItem menu_item(std::string label,
                                      std::function<void()> action) {
  return rivet::system::TrayMenuItem(std::move(label), std::move(action));
}

// "Done · Sip some water 💧" — the control names both the action and the
// advice, mirroring the mac host's cueActionLabel.
std::string cue_done_label(rivet_app::HealthCue const& cue) {
  char const* advice =
      cue.action == rivet_app::CueAction::drink_water
          ? "notif.waterTitle"
          : cue.action == rivet_app::CueAction::rest_eyes ? "micro.hint"
                                                          : "notif.sitTitle";
  return l10n::t("tray.cueDone") + " · " + l10n::t(advice);
}

void show_guided(std::int64_t duration_seconds, std::string const& title,
                 std::string const& hint) {
  if (g_state.app == nullptr || g_state.model.pending_cues.empty()) return;
  micro_show(duration_seconds, title, hint,
             g_state.model.pending_cues.back().id, g_state.app);
}

std::vector<rivet::system::TrayMenuItem> build_menu() {
  using rivet::system::TrayMenuItem;
  std::vector<TrayMenuItem> items;
  items.push_back(menu_item(l10n::t("tray.open"), [] {
    if (g_state.window != nullptr) {
      gtk_window_present(g_state.window);
    }
  }));
  if (!g_state.model.pending_cues.empty()) {
    items.push_back(TrayMenuItem(TrayMenuItem::Type::separator));
    // The card presents the newest open cue (the backend plans every X11
    // cue for character delivery), so the handlers below act on it.
    auto const& cue = g_state.model.pending_cues.back();
    items.push_back(menu_item(cue_done_label(cue), [] {
      on_mubi_done(nullptr, nullptr);
    }));
    items.push_back(menu_item(l10n::t("tray.cueLater"), [] {
      on_mubi_later(nullptr, nullptr);
    }));
    items.push_back(menu_item(l10n::t("tray.cueHide"), [] {
      on_mubi_hide(nullptr, nullptr);
    }));
    // Opt-in guided sessions (#94), only while a real cue is open.
    bool has_sit = false;
    bool has_micro = false;
    for (auto const& kind : g_state.model.pending_cues.back().kinds) {
      has_sit = has_sit || kind == rivet_app::ReminderKind::sit;
      has_micro = has_micro || kind == rivet_app::ReminderKind::micro;
    }
    if (has_micro) {
      items.push_back(menu_item(l10n::t("tray.eyeRest"), [] {
        show_guided(g_state.model.config.micro_break_duration_seconds,
                    l10n::t("tray.eyeRest"), l10n::t("micro.hint"));
      }));
    }
    if (has_sit) {
      items.push_back(menu_item(l10n::t("tray.stretch"), [] {
        show_guided(120, l10n::t("stretch.title"), l10n::t("stretch.hint"));
      }));
    }
  }
  items.push_back(TrayMenuItem(TrayMenuItem::Type::separator));
  if (g_state.mubi_x11) {
    items.push_back(menu_item(l10n::t("tray.moveAside"),
                              [] { mubi::move_aside(); }));
    items.push_back(menu_item(
        l10n::t(g_state.mubi_placing ? "tray.placeMubiDone"
                                     : "tray.placeMubi"),
        [] { mubi::toggle_placement(); }));
  }
  items.push_back(menu_item(l10n::t(g_state.model.is_paused() ? "tray.resume"
                                                              : "tray.pause"),
                            [] { on_pause_clicked(nullptr, nullptr); }));
  items.push_back(menu_item(l10n::t(g_state.model.quiet ? "tray.focusOff"
                                                        : "tray.focusOn"),
                            [] { on_focus_clicked(nullptr, nullptr); }));
  items.push_back(TrayMenuItem(TrayMenuItem::Type::separator));
  items.push_back(menu_item(l10n::t("tray.exit"), [] {
    on_quit_clicked(nullptr, nullptr);
  }));
  return items;
}

std::string tooltip_body() {
  auto const& model = g_state.model;
  if (model.is_paused() && model.paused.until_ms.has_value()) {
    return l10n::t("tpl.pausedUntil", {l10n::T(*model.paused.until_ms)});
  }
  return l10n::t("tpl.running");
}

// Rebuild the whole menu in place: cheap (a layout-revision bump on the
// dbusmenu), and it carries every state change — cue ledger, pause,
// Focus, language.
void sync() {
  if (g_icon == nullptr) return;
  g_icon->set_menu(build_menu());
  g_icon->set_tooltip("MoveBit", tooltip_body());
}

bool install() {
  if (!rivet::system::TrayIcon::available()) return false;
  // Themed icon name: packages install "movebit" into the icon theme
  // (rivet's deb/rpm assembly); the flatpak export only accepts icons
  // named after the app id, so pick the name by environment.
  char const* icon_name =
      std::filesystem::exists("/.flatpak-info") ? "site.jrtx.movebit"
                                                : "movebit";
  g_icon = std::make_unique<rivet::system::TrayIcon>("site.jrtx.movebit",
                                                     "MoveBit", icon_name);
  g_icon->set_activation_handler(
      [] { if (g_state.window != nullptr) gtk_window_present(g_state.window); });
  sync();
  return true;
}

bool installed() { return g_icon != nullptr; }

}  // namespace tray

GtkWindow* toast_window_new(GtkApplication* app) {
  auto* window = gtk_application_window_new(app);
  gtk_widget_add_css_class(GTK_WIDGET(window), "toast-bg");
  gtk_window_set_title(GTK_WINDOW(window), l10n::t("notif.windowTitle").c_str());
  gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
  gtk_window_set_default_size(GTK_WINDOW(window), 380, -1);
  return GTK_WINDOW(window);
}

void toast_show(std::string const& title, std::vector<std::string> const& lines,
                rivet_app::ReminderKind accent, std::int64_t cue_id,
                std::int64_t snooze_minutes, GtkApplication* app) {
  toast_dismiss();
  auto* window = toast_window_new(app);
  g_state.toast_window = window;
  g_state.toast_accent = accent;
  g_state.toast_cue_id = cue_id;

  auto* root = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  auto* accent_bar = gtk_label_new("");
  gtk_widget_set_size_request(accent_bar, 5, -1);
  gtk_widget_set_valign(accent_bar, GTK_ALIGN_FILL);
  char const* accent_css = accent == rivet_app::ReminderKind::water
                               ? "accent-water"
                               : accent == rivet_app::ReminderKind::micro
                                     ? "accent-micro"
                                     : "accent-sit";
  gtk_widget_add_css_class(accent_bar, accent_css);
  box_append(GTK_BOX(root), accent_bar);

  auto* body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_margin_top(body, 16);
  gtk_widget_set_margin_bottom(body, 14);
  gtk_widget_set_margin_start(body, 20);
  gtk_widget_set_margin_end(body, 20);

  auto* title_label = gtk_label_new(title.c_str());
  gtk_widget_add_css_class(title_label, "toast-title");
  gtk_label_set_xalign(GTK_LABEL(title_label), 0.0f);
  gtk_label_set_wrap(GTK_LABEL(title_label), TRUE);
  box_append(GTK_BOX(body), title_label);
  g_state.toast_title_label = GTK_LABEL(title_label);

  auto* lines_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
  for (auto const& line : lines) {
    auto* line_label = gtk_label_new(line.c_str());
    gtk_widget_add_css_class(line_label, "toast-line");
    gtk_label_set_xalign(GTK_LABEL(line_label), 0.0f);
    gtk_label_set_wrap(GTK_LABEL(line_label), TRUE);
    box_append(GTK_BOX(lines_box), line_label);
  }
  box_append(GTK_BOX(body), lines_box);
  g_state.toast_lines_box = GTK_BOX(lines_box);

  auto* buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  gtk_widget_set_halign(buttons, GTK_ALIGN_END);
  if (cue_id != 0) {
    auto* hide = gtk_button_new_with_label(l10n::t("notif.hide").c_str());
    gtk_widget_add_css_class(hide, "toast-btn-muted");
    g_signal_connect(hide, "clicked", G_CALLBACK(on_toast_hide), nullptr);
    box_append(GTK_BOX(buttons), hide);
    auto* snooze = gtk_button_new_with_label(
        l10n::t("notif.snooze", {l10n::A(snooze_minutes)}).c_str());
    gtk_widget_add_css_class(snooze, "toast-btn-muted");
    g_signal_connect(snooze, "clicked", G_CALLBACK(on_toast_snooze), nullptr);
    box_append(GTK_BOX(buttons), snooze);
    g_state.toast_snooze_button = GTK_BUTTON(snooze);
    auto* done = gtk_button_new_with_label(l10n::t("notif.done").c_str());
    gtk_widget_add_css_class(done, "toast-btn");
    g_signal_connect(done, "clicked", G_CALLBACK(on_toast_done), nullptr);
    box_append(GTK_BOX(buttons), done);
  } else {
    auto* got_it = gtk_button_new_with_label(l10n::t("notif.gotIt").c_str());
    gtk_widget_add_css_class(got_it, "toast-btn");
    g_signal_connect(
        got_it, "clicked",
        G_CALLBACK(+[](GtkButton*, gpointer) { toast_dismiss(); }), nullptr);
    box_append(GTK_BOX(buttons), got_it);
  }
  box_append(GTK_BOX(body), buttons);
  box_append(GTK_BOX(root), body);
  gtk_window_set_child(GTK_WINDOW(window), root);

  // Hovering holds the card open (restart the 9 s timer on enter/leave).
  auto* motion = gtk_event_controller_motion_new();
  g_signal_connect(motion, "enter", G_CALLBACK(+[](GtkEventControllerMotion*,
                                                    gdouble, gdouble, gpointer) {
                     toast_restart_auto_close();
                   }),
                   nullptr);
  g_signal_connect(motion, "leave", G_CALLBACK(+[](GtkEventControllerMotion*,
                                                    gpointer) {
                     toast_restart_auto_close();
                   }),
                   nullptr);
  gtk_widget_add_controller(GTK_WIDGET(window), motion);

  toast_restart_auto_close();
  gtk_window_present(GTK_WINDOW(window));
}

// ---- micro break ----------------------------------------------------------------

void micro_close() {
  if (g_state.micro_timeout_id != 0) {
    g_source_remove(g_state.micro_timeout_id);
    g_state.micro_timeout_id = 0;
  }
  if (g_state.micro_window != nullptr) {
    gtk_window_destroy(g_state.micro_window);
    g_state.micro_window = nullptr;
    g_state.micro_bar = nullptr;
    g_state.micro_hint = nullptr;
    g_state.micro_start_button = nullptr;
    g_state.micro_started = false;
  }
  g_state.micro_cue_id = 0;
}

// The eye rest ran its course: acknowledge the cue (self-reported).
void micro_finish() {
  auto cue_id = g_state.micro_cue_id;
  micro_close();
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->acknowledge_cue_async(cue_id,
                                             [](rivet_app::Result<void>) {});
  }
}

// Click / Esc / a newer cue: end early as a Hide — no completion claimed.
void micro_dismiss() {
  auto cue_id = g_state.micro_cue_id;
  micro_close();
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->abandon_cue_async(cue_id, [](rivet_app::Result<void>) {});
  }
}

// Explicit opt-in (#94): the countdown starts only when the user asks.
void micro_start() {
  if (g_state.micro_started || g_state.micro_window == nullptr) return;
  g_state.micro_started = true;
  if (g_state.micro_start_button != nullptr) {
    gtk_widget_set_visible(GTK_WIDGET(g_state.micro_start_button), FALSE);
  }
  g_state.micro_progress = 1.0;
  if (g_state.micro_bar != nullptr) {
    gtk_progress_bar_set_fraction(g_state.micro_bar, 1.0);
  }
  g_state.micro_timeout_id = g_timeout_add(
      250,
      +[](gpointer) -> int {
        g_state.micro_progress =
            std::max(0.0, g_state.micro_progress - 250.0 /
                                                     g_state.micro_total_ms);
        if (g_state.micro_bar != nullptr) {
          gtk_progress_bar_set_fraction(g_state.micro_bar, g_state.micro_progress);
        }
        if (g_state.micro_progress <= 0.0) {
          // Timer completion is not a self-report; Done is explicit.
          if (g_state.micro_hint != nullptr) {
            gtk_label_set_text(g_state.micro_hint,
                               l10n::t("micro.finishedHint").c_str());
          }
          // Hide the finished card later without claiming completion; the
          // cue stays open for the tray's explicit Done.
          g_state.micro_timeout_id = g_timeout_add_seconds(
              60,
              +[](gpointer) -> int {
                g_state.micro_timeout_id = 0;
                micro_dismiss();
                return G_SOURCE_REMOVE;
              },
              nullptr);
          return G_SOURCE_REMOVE;
        }
        return G_SOURCE_CONTINUE;
      },
      nullptr);
}

void micro_show(std::int64_t duration_seconds, std::string const& title,
                std::string const& hint_text, std::int64_t cue_id,
                GtkApplication* app) {
  // Replacing a session must not record the previous cue as abandoned.
  micro_close();
  g_state.micro_cue_id = cue_id;
  auto* window = gtk_application_window_new(app);
  gtk_widget_add_css_class(GTK_WIDGET(window), "micro-bg");
  gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
  gtk_window_set_default_size(GTK_WINDOW(window), 400, -1);
  g_state.micro_window = GTK_WINDOW(window);

  auto* body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5);
  gtk_widget_set_margin_top(body, 18);
  gtk_widget_set_margin_bottom(body, 18);
  gtk_widget_set_margin_start(body, 26);
  gtk_widget_set_margin_end(body, 26);
  auto* head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
  box_append(GTK_BOX(head), label_with("👀", nullptr));
  auto* title_label = gtk_label_new(title.c_str());
  gtk_widget_add_css_class(title_label, "micro-title");
  gtk_label_set_xalign(GTK_LABEL(title_label), 0.0f);
  box_append(GTK_BOX(head), title_label);
  box_append(GTK_BOX(body), head);
  auto* hint = gtk_label_new(hint_text.c_str());
  gtk_widget_add_css_class(hint, "micro-hint");
  gtk_label_set_xalign(GTK_LABEL(hint), 0.0f);
  box_append(GTK_BOX(body), hint);
  g_state.micro_hint = GTK_LABEL(hint);
  auto* bar = gtk_progress_bar_new();
  gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(bar), 0.0);
  gtk_widget_add_css_class(bar, "micro-bar");
  box_append(GTK_BOX(body), bar);
  g_state.micro_bar = GTK_PROGRESS_BAR(bar);
  auto* start = gtk_button_new_with_label(l10n::t("micro.start").c_str());
  gtk_widget_add_css_class(start, "micro-start");
  gtk_widget_set_halign(start, GTK_ALIGN_START);
  g_signal_connect(
      start, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_start(); }), nullptr);
  box_append(GTK_BOX(body), start);
  g_state.micro_start_button = GTK_BUTTON(start);
  auto* done = gtk_button_new_with_label(l10n::t("micro.done").c_str());
  gtk_widget_add_css_class(done, "micro-done");
  gtk_widget_set_halign(done, GTK_ALIGN_START);
  g_signal_connect(
      done, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_finish(); }), nullptr);
  box_append(GTK_BOX(body), done);
  auto* hide = gtk_button_new_with_label(l10n::t("notif.hide").c_str());
  gtk_widget_add_css_class(hide, "micro-hide");
  gtk_widget_set_halign(hide, GTK_ALIGN_START);
  g_signal_connect(
      hide, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_dismiss(); }), nullptr);
  box_append(GTK_BOX(body), hide);
  gtk_window_set_child(GTK_WINDOW(window), body);
  // Escape dismisses too.
  auto* key = gtk_event_controller_key_new();
  g_signal_connect(
      key, "key-pressed",
      G_CALLBACK(+[](GtkEventControllerKey*, guint keyval, guint, GdkModifierType,
                     gpointer) -> gboolean {
        if (keyval == GDK_KEY_Escape) {
          micro_dismiss();
          return TRUE;
        }
        return FALSE;
      }),
      nullptr);
  gtk_widget_add_controller(GTK_WIDGET(window), key);

  g_state.micro_progress = 0.0;
  g_state.micro_started = false;
  g_state.micro_total_ms = std::max<std::int64_t>(1, duration_seconds) * 1000;
  gtk_window_present(GTK_WINDOW(window));
}

// ---- reminders due ----------------------------------------------------------------

void handle_health_cue(rivet_app::HealthCue const& cue, GtkApplication* app) {
  // The backend planned the delivery; the host only renders it. On X11 the
  // Mubi companion is the v1 default; Wayland (and the notification route)
  // uses the non-blocking cards as the documented #54/#56 fallback.
  auto const& model = g_state.model;
  auto const& kinds = cue.kinds;
  if (cue.delivery == rivet_app::CueDelivery::character && g_state.mubi_x11) {
    using State = MubiCompanionState;
    State state = State::Idle;
    switch (cue.action) {
      case rivet_app::CueAction::stand_and_stretch: state = State::Stand; break;
      case rivet_app::CueAction::drink_water: state = State::Water; break;
      case rivet_app::CueAction::rest_eyes: state = State::Eyes; break;
      default: state = State::Idle; break;
    }
    std::string message;
    if (kinds.size() > 1) {
      // One reminder event may contain three independently due health kinds.
      // Preserve every meaning in the same small, readable character card.
      auto has = [&kinds](rivet_app::ReminderKind kind) {
        return std::find(kinds.begin(), kinds.end(), kind) != kinds.end();
      };
      std::vector<std::string> parts;
      if (has(rivet_app::ReminderKind::sit))
        parts.push_back(l10n::t("notif.sitTitle"));
      if (has(rivet_app::ReminderKind::water))
        parts.push_back(l10n::t("notif.waterTitle"));
      if (has(rivet_app::ReminderKind::micro))
        parts.push_back(l10n::t("micro.defaultTitle"));
      for (auto const& part : parts) {
        if (!message.empty()) message += " / ";
        message += part;
      }
    } else {
      switch (cue.action) {
        case rivet_app::CueAction::drink_water: message = pick_water(); break;
        case rivet_app::CueAction::rest_eyes:
          message = l10n::t("micro.defaultTitle"); break;
        case rivet_app::CueAction::stand_and_stretch:
          message = l10n::t("notif.sitTitle"); break;
        default: break;
      }
    }
    mubi::present(static_cast<int>(state), message, app, cue.id);
    cue_displayed(cue.id);
    return;
  }
  if (kinds.size() == 1 && kinds[0] == rivet_app::ReminderKind::micro) {
    micro_show(model.config.micro_break_duration_seconds, pick_micro(),
               l10n::t("micro.hint"), cue.id, app);
    cue_displayed(cue.id);
    return;
  }

  std::vector<std::string> lines;
  if (std::find(kinds.begin(), kinds.end(), rivet_app::ReminderKind::sit) !=
      kinds.end()) {
    lines.push_back(l10n::t("notif.sitBody",
                            {l10n::A(format_duration(model.today.active_mins)),
                             l10n::A(model.today.sit_breaks)}));
    lines.push_back(l10n::pick("copy.sitToastPool", 6));
  }
  if (std::find(kinds.begin(), kinds.end(), rivet_app::ReminderKind::water) !=
      kinds.end()) {
    lines.push_back(l10n::t("notif.waterCount", {l10n::A(model.today.water_reminders)}));
    lines.push_back(pick_water());
  }
  if (std::find(kinds.begin(), kinds.end(), rivet_app::ReminderKind::micro) !=
      kinds.end()) {
    lines.push_back(pick_micro());
  }

  std::string title = l10n::t("notif.sitTitle");
  rivet_app::ReminderKind accent = rivet_app::ReminderKind::sit;
  if (std::find(kinds.begin(), kinds.end(), rivet_app::ReminderKind::water) !=
      kinds.end()) {
    title = l10n::t("notif.waterTitle");
    accent = rivet_app::ReminderKind::water;
  }

  // Sound parity: the old Avalonia app was silent on non-Windows platforms,
  // so no bell here regardless of sound_enabled.
  toast_show(title, lines, accent, cue.id, model.config.snooze_minutes, app);
  cue_displayed(cue.id);
}

void show_toast_plain(std::string const& title, std::vector<std::string> const& lines,
                      rivet_app::ReminderKind accent, GtkApplication* app) {
  toast_show(title, lines, accent, 0, g_state.model.config.snooze_minutes, app);
}

void cue_displayed(std::int64_t id) {
  if (g_state.api != nullptr && id != 0) {
    (void)g_state.api->cue_displayed_async(id, [](rivet_app::Result<void>) {});
  }
}

// ---- events --------------------------------------------------------------------

void reload_history() {
  if (g_state.api == nullptr) return;
  // Always fetch 30 days; the 7/30 toggle is pure client-side slicing.
  (void)g_state.api->get_history_async(
      30, [](rivet_app::Result<std::vector<rivet_app::DayStats>> r) {
        on_result(std::move(r),
                  [](std::vector<rivet_app::DayStats> const& history) {
                    g_state.model.history = history;
                    refresh_history_card();
                    refresh_insight_card();
                  });
      });
}

void reload_outcomes() {
  if (g_state.api == nullptr) return;
  (void)g_state.api->get_cue_outcomes_async(
      [](rivet_app::Result<std::vector<rivet_app::CueOutcomeTotals>> r) {
        on_result(
            std::move(r),
            [](std::vector<rivet_app::CueOutcomeTotals> const& outcomes) {
              g_state.model.outcomes = outcomes;
              refresh_today_card();
            });
      });
}

void refresh_states_after_tick() {
  if (g_state.api == nullptr) return;
  (void)g_state.api->get_loops_async(
      [](rivet_app::Result<std::vector<rivet_app::LoopInfo>> r) {
        on_result(std::move(r),
                  [](std::vector<rivet_app::LoopInfo> const& loops) {
                    g_state.model.loops = loops;
                    refresh_today_card();
                  });
      });
  (void)g_state.api->get_paused_async(
      [](rivet_app::Result<rivet_app::PauseState> r) {
        on_result(std::move(r), [](rivet_app::PauseState const& paused) {
          g_state.model.paused = paused;
          refresh_today_card();
          refresh_pause_button();
        });
      });
  (void)g_state.api->get_pending_cues_async(
      [](rivet_app::Result<std::vector<rivet_app::HealthCue>> r) {
        on_result(std::move(r),
                  [](std::vector<rivet_app::HealthCue> const& cues) {
                    g_state.model.pending_cues = cues;
                    tray::sync();
                  });
      });
  reload_outcomes();
}

void apply_config(rivet_app::ReminderConfig const& changed,
                  bool announce, GtkApplication* app);

void handle_event(std::string const& name, rivet::Value const& value,
                  GtkApplication* app) {
  try {
    auto event = rivet_app::decode_event(name, value);
    std::visit(
        [&](auto const& e) {
          using T = std::decay_t<decltype(e)>;
          if constexpr (std::is_same_v<T, rivet_app::Tick_statsEvent>) {
            dispatch_ui([stats = e.value] {
              g_state.model.today = stats;
              refresh_today_card();
              refresh_insight_card();
              refresh_states_after_tick();
            });
          } else if constexpr (std::is_same_v<T, rivet_app::Health_cueEvent>) {
            dispatch_ui([app, cue = e.value] { handle_health_cue(cue, app); });
          } else if constexpr (std::is_same_v<T,
                                  rivet_app::Cue_acknowledgedEvent>) {
            dispatch_ui([acked = e.value, app] {
              // #56 §4 `ack`: a small nod + warm glint on the character
              // (no-op on Wayland, where the companion is absent).
              mubi::show_ack();
              if (acked.kind != rivet_app::ReminderKind::sit) return;
              if (acked.count_today != 3 && acked.count_today != 5 &&
                  acked.count_today != 8) {
                return;
              }
              show_toast_plain(
                  l10n::t("notif.cheerTitle"),
                  {l10n::t("notif.cheerBody",
                           {l10n::A(acked.count_today),
                            l10n::A(format_duration(
                                g_state.model.today.active_mins))})},
                  rivet_app::ReminderKind::sit, app);
            });
          } else if constexpr (std::is_same_v<T, rivet_app::Day_completedEvent>) {
            dispatch_ui([stats = e.value] {
              g_state.model.today = stats;
              refresh_today_card();
              refresh_insight_card();
              reload_history();
            });
          } else if constexpr (std::is_same_v<T, rivet_app::Config_changedEvent>) {
            dispatch_ui([app, changed = e.value] { apply_config(changed, false, app); });
          }
        },
        event);
  } catch (std::exception const&) {
    // Unknown events are ignored (forward compatibility).
  }
}

void apply_config(rivet_app::ReminderConfig const& changed, bool announce,
                  GtkApplication* app) {
  (void)app;
  // Compare against the host's LIVE language, not the cached config: the
  // settings UI writes optimistic drafts into model.config, so the cached
  // language can already match the incoming one before the host has ever
  // rebuilt in it.
  bool const language_changed =
      resolve_language(changed.language) != g_state.language;
  g_state.model.config = changed;
  mubi::apply_config(changed.companion_size, changed.companion_motion,
                     changed.companion_dock, changed.companion_labels,
                     changed.companion_free_x, changed.companion_free_y);
  g_state.language = resolve_language(changed.language);
  apply_language();
  refresh_header_buttons();
  if (language_changed || announce) {
    // Static texts bake the language in — rebuild the whole main content.
    build_main_content();
  } else {
    refresh_all();
  }
}

// ---- onboarding ------------------------------------------------------------------

void onboarding_persist(bool welcome_shown) {
  // The only first-run write is the "seen" marker: the shipped balanced
  // rhythm and silent-by-default sound need no confirmation.
  mutate_config([&](auto& d) { d.welcome_shown = welcome_shown; });
}

void onboarding_finish(GtkApplication* app) {
  onboarding_persist(true);
  if (g_state.onboarding_window != nullptr) {
    gtk_window_destroy(g_state.onboarding_window);
    g_state.onboarding_window = nullptr;
  }
  show_toast_plain(l10n::t("ob.settled"), {l10n::t("ob.settledBody")},
                   rivet_app::ReminderKind::water, app);
}

// One screen, under 30 seconds (issue #90): meet Mubi, read one sentence,
// press Start. No wizard, no cadence questions, nothing to configure first.
void onboarding_show(GtkApplication* app) {
  if (g_state.onboarding_window != nullptr) {
    gtk_window_present(g_state.onboarding_window);
    return;
  }

  auto* window = gtk_application_window_new(app);
  gtk_widget_add_css_class(GTK_WIDGET(window), "ob-bg");
  gtk_window_set_title(GTK_WINDOW(window), l10n::t("ob.title").c_str());
  gtk_window_set_default_size(GTK_WINDOW(window), 460, 520);
  g_state.onboarding_window = GTK_WINDOW(window);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_margin_top(root, 28);
  gtk_widget_set_margin_bottom(root, 28);
  gtk_widget_set_margin_start(root, 28);
  gtk_widget_set_margin_end(root, 28);

  // Reuse the canonical cairo Mubi art (no new character assets).
  auto* canvas = gtk_drawing_area_new();
  gtk_widget_set_size_request(canvas, -1, 150);
  gtk_drawing_area_set_draw_func(
      GTK_DRAWING_AREA(canvas),
      +[](GtkDrawingArea*, cairo_t* cr, int width, int, gpointer) {
        double const scale = 1.0;
        cairo_save(cr);
        cairo_translate(cr, (width - 120.0 * scale) / 2.0, 5.0);
        cairo_scale(cr, scale, scale);
        mubi::draw_state(cr, 0);
        cairo_restore(cr);
      },
      nullptr, nullptr);
  box_append(GTK_BOX(root), canvas);

  auto* hello = gtk_label_new(l10n::t("ob.hello").c_str());
  gtk_widget_add_css_class(hello, "ob-hello");
  gtk_label_set_xalign(GTK_LABEL(hello), 0.5f);
  gtk_label_set_justify(GTK_LABEL(hello), GTK_JUSTIFY_CENTER);
  box_append(GTK_BOX(root), hello);

  auto* line = gtk_label_new(l10n::t("ob.line").c_str());
  gtk_widget_add_css_class(line, "ob-text");
  gtk_label_set_wrap(GTK_LABEL(line), TRUE);
  gtk_label_set_justify(GTK_LABEL(line), GTK_JUSTIFY_CENTER);
  gtk_label_set_xalign(GTK_LABEL(line), 0.5f);
  gtk_widget_set_margin_top(line, 4);
  box_append(GTK_BOX(root), line);

  auto* spacer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_vexpand(spacer, TRUE);
  box_append(GTK_BOX(root), spacer);

  auto* privacy = gtk_label_new(l10n::t("ob.privacy").c_str());
  gtk_widget_add_css_class(privacy, "ob-caption");
  gtk_label_set_wrap(GTK_LABEL(privacy), TRUE);
  gtk_label_set_justify(GTK_LABEL(privacy), GTK_JUSTIFY_CENTER);
  gtk_label_set_xalign(GTK_LABEL(privacy), 0.5f);
  box_append(GTK_BOX(root), privacy);

  auto* start = gtk_button_new_with_label(l10n::t("ob.start").c_str());
  gtk_widget_add_css_class(start, "ob-primary");
  gtk_widget_set_hexpand(start, TRUE);
  gtk_widget_set_margin_top(start, 12);
  g_object_set_data(G_OBJECT(start), "app", app);
  g_signal_connect(
      start, "clicked",
      G_CALLBACK(+[](GtkButton* button, gpointer) {
        auto* app =
            GTK_APPLICATION(g_object_get_data(G_OBJECT(button), "app"));
        onboarding_finish(app);
      }),
      nullptr);
  box_append(GTK_BOX(root), start);

  auto* start_hint = gtk_label_new(l10n::t("ob.startHint").c_str());
  gtk_widget_add_css_class(start_hint, "ob-caption");
  gtk_label_set_wrap(GTK_LABEL(start_hint), TRUE);
  gtk_label_set_justify(GTK_LABEL(start_hint), GTK_JUSTIFY_CENTER);
  gtk_label_set_xalign(GTK_LABEL(start_hint), 0.5f);
  gtk_widget_set_margin_top(start_hint, 4);
  box_append(GTK_BOX(root), start_hint);

  gtk_window_set_child(GTK_WINDOW(window), root);
  gtk_window_present(GTK_WINDOW(window));
}

// ---- startup (same contract as the Rivet template) ------------------------------

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  std::filesystem::path const exe = executable_path();
  std::filesystem::path const roots[] = {exe.parent_path()};
  for (auto const& root : roots) {
    RuntimeLayout layout{
        root / "runtime" / "petite.boot",
        root / "runtime" / "scheme.boot",
        root / "runtime" / "racket.boot",
        root / "res" / "core.zo",
    };
    if (std::filesystem::exists(layout.petite_boot) &&
        std::filesystem::exists(layout.scheme_boot) &&
        std::filesystem::exists(layout.racket_boot) &&
        std::filesystem::exists(layout.core)) {
      return layout;
    }
  }
  return std::nullopt;
}

void flush_now_sync() {
  if (g_state.api == nullptr) return;
  // Best-effort flush with a 1 s budget (port of FlushToday-on-exit).
  auto future = g_state.api->flush_now();
  (void)future.wait_for(std::chrono::seconds(1));
}

void reload_autostart() {
  if (g_state.api == nullptr) return;
  (void)g_state.api->get_autostart_async(
      [](rivet_app::Result<bool> r) {
        dispatch_ui([r = std::move(r)]() mutable {
          if (r.succeeded()) {
            g_state.model.autostart = r.get();
            if (mw.autostart_switch != nullptr) {
              g_state.updating_settings = true;
              gtk_switch_set_active(mw.autostart_switch, g_state.model.autostart);
              g_state.updating_settings = false;
            }
          }
        });
      });
}

void reload_data_dir() {
  if (g_state.api == nullptr) return;
  (void)g_state.api->get_diagnostics_async(
      [](rivet_app::Result<std::string> r) {
        on_result(std::move(r), [](std::string const& text) {
          static std::string const prefix = "data-dir: ";
          std::size_t pos = 0;
          while ((pos = text.find(prefix, pos)) != std::string::npos) {
            auto end = text.find('\n', pos);
            g_state.model.data_dir = text.substr(
                pos + prefix.size(),
                end == std::string::npos ? std::string::npos : end - pos - prefix.size());
            break;
          }
          refresh_footer();
        });
      });
}

void bootstrap(GtkApplication* app) {
  auto const& config = g_state.model.config;
  g_state.language = resolve_language(config.language);
  apply_language();
  refresh_header_buttons();
  build_main_content();
  reload_history();
  reload_outcomes();
  reload_autostart();
  reload_data_dir();
  reflect_pending_update();
  if (!config.welcome_shown) {
    onboarding_show(app);
  }
  // Deterministic acceptance hook: packaged tests drive the real placement
  // mode under Xvfb without hunting for a tray/header button.
  char const* placement_test = g_getenv("MOVEBIT_PLACEMENT_TEST");
  if (placement_test != nullptr && std::string(placement_test) == "1" &&
      g_state.mubi_x11) {
    mubi::begin_placement();
  }
}

int on_backend_finished(gpointer user_data) {
  auto* app = GTK_APPLICATION(user_data);
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::string error;
  {
    std::lock_guard lock(g_state.startup_mutex);
    backend = std::move(g_state.startup_backend);
    error = std::move(g_state.startup_error);
  }

  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    if (backend != nullptr) {
      backend->stop();
    }
    return G_SOURCE_REMOVE;
  }
  if (!error.empty()) {
    g_state.set_status(std::string("Backend error: ") + error);
    return G_SOURCE_REMOVE;
  }
  if (backend == nullptr) {
    g_state.set_status("Backend error: startup completed without a backend");
    return G_SOURCE_REMOVE;
  }

  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);
  g_state.backend->set_event_handler(
      [app](std::string const& name, rivet::Value const& value) {
        handle_event(name, value, app);
      });

  // initialize seeds states and starts the 30 s backend tick. Each state read
  // lands in g_state.model as it arrives; the last one renders everything.
  auto chain = [app](rivet_app::Result<void> init) {
    on_result(std::move(init), [app]() {
      (void)g_state.api->get_active_config_async(
          [app](rivet_app::Result<rivet_app::ReminderConfig> c) {
            on_result(std::move(c), [app](rivet_app::ReminderConfig const& config) {
              g_state.model.config = config;
              (void)g_state.api->get_today_async(
                  [app](rivet_app::Result<rivet_app::DayStats> t) {
                    on_result(std::move(t), [app](rivet_app::DayStats const& today) {
                      g_state.model.today = today;
                      (void)g_state.api->get_paused_async(
                          [app](rivet_app::Result<rivet_app::PauseState> p) {
                            on_result(std::move(p), [app](rivet_app::PauseState const& paused) {
                              g_state.model.paused = paused;
                              (void)g_state.api->get_loops_async(
                                  [app](rivet_app::Result<std::vector<rivet_app::LoopInfo>> l) {
                                    on_result(std::move(l), [app](std::vector<rivet_app::LoopInfo> const& loops) {
                                      g_state.model.loops = loops;
                                      (void)g_state.api->get_pending_cues_async(
                                          [app](rivet_app::Result<std::vector<rivet_app::HealthCue>> q) {
                                            on_result(std::move(q), [app](std::vector<rivet_app::HealthCue> const& cues) {
                                              dispatch_ui([app, cues] {
                                                g_state.model.pending_cues = cues;
                                                mubi::apply_config(
                                                    g_state.model.config
                                                        .companion_size,
                                                    g_state.model.config
                                                        .companion_motion,
                                                    g_state.model.config
                                                        .companion_dock,
                                                    g_state.model.config
                                                        .companion_labels,
                                                    g_state.model.config
                                                        .companion_free_x,
                                                    g_state.model.config
                                                        .companion_free_y);
                                                bootstrap(app);
                                              });
                                            });
                                          });
                                    });
                                  });
                            });
                          });
                    });
                  });
            });
          });
    });
  };
  // Honest capability report (issue #54/#56): the Mubi companion needs
  // reliable placement + click-through, which GTK4 only offers on X11.
  // main() prefers Xwayland on Wayland sessions exactly for this, so this
  // branch is the rare native-Wayland fallback (MOVEBIT_BACKEND=wayland,
  // or a session without Xwayland): delivery plans as a notification
  // there, never a floating pet.
  {
    // Decide from the GDK backend actually in use, NOT from environment
    // variables: the Wayland client library falls back to the default
    // socket "wayland-0" under $XDG_RUNTIME_DIR even with no
    // WAYLAND_DISPLAY set, so an env-based guess mislabels a Wayland
    // session as X11 — the companion then maps without any placement.
    bool const on_wayland = []() {
      auto* display = gdk_display_get_default();
      if (display != nullptr) {
#ifdef GDK_WINDOWING_WAYLAND
        if (GDK_IS_WAYLAND_DISPLAY(display)) return true;
#endif
        return !GDK_IS_X11_DISPLAY(display);
      }
      char const* wayland = g_getenv("WAYLAND_DISPLAY");
      char const* session = g_getenv("XDG_SESSION_TYPE");
      return (wayland && *wayland) ||
             (session && std::string(session) == "wayland");
    }();
    auto* display = gdk_display_get_default();
    g_state.mubi_x11 = !on_wayland && display != nullptr &&
                       gdk_display_supports_input_shapes(display);
    refresh_header_buttons();
    (void)g_state.api->set_host_capability_async(g_state.mubi_x11, false,
                                                 [](rivet_app::Result<void>) {});
  }
  (void)g_state.api->initialize_async(chain);
  return G_SOURCE_REMOVE;
}

void start_backend(GtkApplication* app) {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    g_state.set_status(
        "Missing Rivet runtime layout (runtime/*.boot, res/core.zo) next to "
        "the executable. Build with raco rivet build/dev.");
    return;
  }

  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  // Booting the embedded runtime blocks on file I/O; only startup runs off
  // the main loop. Everything after completion dispatches back through
  // g_idle_add.
  g_state.startup_thread = std::thread([app, config = std::move(config)]() mutable {
    auto backend =
        std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    try {
      backend->start();
      {
        std::lock_guard lock(g_state.startup_mutex);
        g_state.startup_backend = std::move(backend);
      }
    } catch (std::exception const& e) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = e.what();
    }
    g_idle_add(on_backend_finished, app);
  });
}

// ---- window / app lifecycle --------------------------------------------------------

gboolean on_main_close_request(GtkWindow*, gpointer) {
  flush_now_sync();
  return FALSE;  // proceed with close; shutdown handler stops the backend
}

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window != nullptr) {
    gtk_window_present(g_state.window);
    return;
  }

  // Single instance: second launches surface the primary's window.
  static std::unique_ptr<rivet::system::SingleInstanceLease> lease;
  lease = std::make_unique<rivet::system::SingleInstanceLease>("site.jrtx.movebit");
  if (!lease->is_primary()) {
    lease->forward_arguments({});
    std::exit(0);
  }
  // The tray registers before the window is built: whether a
  // StatusNotifierWatcher exists decides the header bar's shape (with the
  // tray, it stays a bare title like the mac/win hosts; without one, the
  // mandatory #54 controls live in the header as the fallback). The icon
  // constructor runs on the main thread — its dbusmenu callbacks ride the
  // default main context, which the GTK main loop drives once it starts.
  tray::install();
  lease->set_activation_handler([](std::vector<std::string>) {
    dispatch_ui([] {
      if (g_state.window != nullptr) gtk_window_present(g_state.window);
    });
  });

  auto* window = gtk_application_window_new(app);
  gtk_widget_add_css_class(GTK_WIDGET(window), "app-bg");
  gtk_window_set_title(GTK_WINDOW(window), "MoveBit");
  gtk_window_set_default_size(GTK_WINDOW(window), 860, 760);

  auto* header = gtk_header_bar_new();
  if (!tray::installed()) {
    // Tray-less fallback only (no StatusNotifierWatcher — GNOME without
    // its AppIndicator extension): #54 makes the controls mandatory, so
    // they live in the header here. With the tray present this host looks
    // like the mac/win ones — a bare title, controls in the tray menu.
    auto* pause = gtk_button_new_with_label(l10n::t("tray.pause").c_str());
    g_signal_connect(pause, "clicked", G_CALLBACK(on_pause_clicked), nullptr);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), pause);
    g_state.pause_button = GTK_BUTTON(pause);
    auto* focus = gtk_button_new_with_label(
        l10n::t(g_state.model.quiet ? "tray.focusOff" : "tray.focusOn")
            .c_str());
    g_signal_connect(focus, "clicked", G_CALLBACK(on_focus_clicked), nullptr);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), focus);
    g_state.focus_button = GTK_BUTTON(focus);
    // On desktops without an SNI watcher, quick actions live here instead.
    auto* move = gtk_button_new_with_label(l10n::t("tray.moveAside").c_str());
    gtk_widget_set_sensitive(move, FALSE); // enabled on X11 capability report
    g_signal_connect(move, "clicked", G_CALLBACK(on_move_clicked), nullptr);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), move);
    g_state.move_button = GTK_BUTTON(move);
    auto* place = gtk_button_new_with_label(l10n::t("tray.placeMubi").c_str());
    gtk_widget_set_sensitive(place, FALSE);
    g_signal_connect(place, "clicked", G_CALLBACK(on_place_clicked), nullptr);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), place);
    g_state.place_button = GTK_BUTTON(place);
    auto* quit = gtk_button_new_with_label(l10n::t("tray.exit").c_str());
    g_signal_connect(quit, "clicked", G_CALLBACK(on_quit_clicked), nullptr);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), quit);
    g_state.quit_button = GTK_BUTTON(quit);
  }
  gtk_window_set_titlebar(GTK_WINDOW(window), header);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  g_state.content_root = GTK_BOX(root);
  gtk_window_set_child(GTK_WINDOW(window), root);
  g_signal_connect(window, "close-request", G_CALLBACK(on_main_close_request), nullptr);

  g_state.window = GTK_WINDOW(window);
  g_state.app = app;
  {
    char const* acc = g_getenv("MOVEBIT_ACCEPTANCE");
    g_state.acceptance = acc && *acc == '1';
  }
  apply_global_css();
  gtk_window_present(GTK_WINDOW(window));
  start_backend(app);
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  toast_dismiss();
  micro_dismiss();
  mubi::stop_anim();
  mubi::close_window();
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  {
    std::lock_guard lock(g_state.startup_mutex);
    startup_backend = std::move(g_state.startup_backend);
  }
  if (startup_backend != nullptr) {
    startup_backend->stop();
  }
  if (g_state.backend != nullptr) {
    g_state.backend->stop();
  }
}

}  // namespace

// Wayland sessions cannot dock an ambient companion: mutter has no
// wlr-layer-shell (probed: gtk_layer_is_supported() == false on GNOME 50)
// and core Wayland gives clients no global coordinates, while Xwayland
// ships with every stock GNOME/KDE session and carries the DISPLAY and
// XAUTHORITY the session already exports. Preferring the X11 backend
// unlocks the full feature set — override-redirect companion docking,
// positioned toasts, precise hit regions. MOVEBIT_BACKEND=wayland opts
// out for Wayland-native debugging; a Wayland session without a working
// Xwayland keeps the notification fallback.
void prefer_xwayland_backend() {
  if (char const* forced = g_getenv("MOVEBIT_BACKEND");
      forced != nullptr && *forced != '\0') {
    g_setenv("GDK_BACKEND", forced, TRUE);
    return;
  }
  char const* wayland = g_getenv("WAYLAND_DISPLAY");
  char const* display = g_getenv("DISPLAY");
  if (wayland == nullptr || *wayland == '\0') return;  // real X11 session
  if (display == nullptr || *display == '\0') return;  // no Xwayland
  Display* x = XOpenDisplay(display);
  if (x == nullptr) return;  // Xwayland present but dead
  XCloseDisplay(x);
  g_setenv("GDK_BACKEND", "x11", TRUE);
}

int main(int argc, char** argv) {
  prefer_xwayland_backend();
  auto* app = gtk_application_new("site.jrtx.movebit",
                                  G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
