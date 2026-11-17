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
      true, true, false, "auto", false, 1320, 420, -1, -1};
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
  // The sit cycle interval in active minutes, derived from the loops state
  // (accumulated + due-in) so the host never hardcodes the cadence; falls
  // back to the shipped 50 (issue #140: one product rhythm, no config).
  std::int64_t sit_interval_mins() const {
    for (auto const& l : loops) {
      if (l.kind == rivet_app::ReminderKind::sit &&
          l.due_in_active_mins.has_value()) {
        return std::max<std::int64_t>(1, l.accumulated_mins +
                                             *l.due_in_active_mins);
      }
    }
    return 50;
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
  GtkStack* main_stack{nullptr};  // 今日/历史/设置/关于 segments (2026-11-15)
  GtkStackSwitcher* header_switcher{nullptr};
  bool dark_theme = false;

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

  // Micro break window (2026-11-15 微休息): invite → running → ended.
  // 停止计时 / 先收起来 / Esc never record completion; 做好了 settles the
  // running kind's open cue (eyes→micro, stretch→sit).
  GtkWindow* micro_window{nullptr};
  guint micro_timeout_id{0};
  double micro_progress = 1.0;
  std::int64_t micro_total_ms = 1000;
  std::int64_t micro_cue_id = 0;
  GtkProgressBar* micro_bar{nullptr};
  GtkLabel* micro_hint{nullptr};
  GtkButton* micro_start_button{nullptr};
  bool micro_started = false;
  int micro_phase = 0;  // 0 invite, 1 running, 2 ended
  bool micro_eyes = true;
  GtkLabel* micro_body_title{nullptr};
  GtkLabel* micro_countdown{nullptr};
  GtkButton* micro_done_button{nullptr};
  GtkButton* micro_stop_button{nullptr};
  GtkButton* micro_restart_button{nullptr};
  GtkButton* micro_switch_button{nullptr};
  GtkButton* micro_tuck_button{nullptr};

  // Mubi（沐比）companion (issue #56): X11-only presentation. On Wayland
  // the compositor owns placement, so the companion stays OFF there and
  // cues deliver as notifications (the documented #54/#56 fallback).
  GtkWindow* mubi_window{nullptr};
  GtkDrawingArea* mubi_canvas{nullptr};
  GtkLabel* mubi_capsule{nullptr};
  std::int64_t mubi_cue_id{0};
  // 2026-11-15 contract: the invitation is attached to the pet — heading
  // + 做到了/稍后 + 只做了一部分 per-kind checklist + × hide, and a •••
  // menu button under the pet. The pet surface itself never records
  // completion; the invitation buttons and the tray items do.
  // Open invitation items: (kind symbol, cue id), priority-ordered.
  std::vector<std::pair<std::string, std::int64_t>> mubi_pending;
  GtkBox* mubi_bubble{nullptr};
  GtkLabel* mubi_bubble_title{nullptr};
  GtkButton* mubi_bubble_close{nullptr};
  GtkButton* mubi_bubble_done{nullptr};
  GtkButton* mubi_bubble_later{nullptr};
  GtkButton* mubi_bubble_partial{nullptr};
  GtkBox* mubi_partial_box{nullptr};
  GtkButton* mubi_bubble_partial_confirm{nullptr};
  GtkLabel* mubi_bubble_partial_note{nullptr};
  std::vector<GtkCheckButton*> mubi_kind_checks;
  // Kind symbol per checklist row (refresh_invitation fills both in step).
  std::vector<std::string> mubi_check_kinds;
  GtkButton* mubi_menu_button{nullptr};
  GtkWindow* mubi_menu_window{nullptr};
  int mubi_pat_count = 0;
  guint mubi_mood_reset_id = 0;
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
  // Free drag (issue #104): pointer-over-window proximity arms the input
  // region; there is no placement mode.
  bool mubi_hover = false;
  // True from the first drag-update past the gesture threshold until the
  // drag ends: the click released after such a drag is a move, not a pet.
  bool mubi_drag_moved = false;
  guint mubi_proximity_tick_id = 0;
  // Persistent invitation + petting + repertoire (issue #140): while a due
  // cue waits, the canvas+capsule become pettable/clickable and Mubi
  // rotates small begging acts; between reminders it plays by itself.
  bool mubi_attending = false;
  int mubi_act = 0;  // 0 none, 1 roll, 2 squish, 3 teary, 4 hop
  double mubi_act_progress = 1.0;
  double mubi_act_step = 0.0;
  double mubi_act_side = 1.0;
  guint mubi_act_tick_id{0};
  guint mubi_play_tick_id{0};
  // #104 central-third visit for a genuine due cue: approach, hold, return
  // to exactly the persisted home. Movement never acknowledges the cue.
  int mubi_home_x = 0;
  int mubi_home_y = 0;
  int mubi_target_x = 0;
  int mubi_target_y = 0;
  int mubi_visit_phase = 0;  // 1 approach, 2 hold, 3 return
  int mubi_visit_step = 0;
  guint mubi_visit_tick_id = 0;
  int mubi_drag_origin_x = 0;
  int mubi_drag_origin_y = 0;
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
void show_menu_window();  // the pet ••• menu card (shared with the statusbar)
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

  // Settings widgets (kept to apply config without re-signaling). The
  // slim surface (issue #140): sound, quiet hours, auto-update, language.
  GtkSwitch* sound_switch{nullptr};
  GtkSwitch* autostart_switch{nullptr};
  GtkSwitch* updates_switch{nullptr};
  GtkDropDown* language_drop{nullptr};
  GtkLabel* settings_next_cue{nullptr};
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

static char const* const kLanguages[] = {"auto", "zh", "en"};

template <std::size_t N>
bool dropdown_index_valid(GtkDropDown* drop, unsigned& index) {
  index = gtk_drop_down_get_selected(drop);
  return index < N;
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
    gtk_button_set_label(g_state.move_button, l10n::t("tray.resetMubi").c_str());
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.move_button), g_state.mubi_x11);
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
    if (!model.is_paused() && model.sit_interval_mins() > 0) {
      fraction = std::min(
          1.0, std::max(0.0, static_cast<double>(model.current_session_mins()) /
                                 static_cast<double>(model.sit_interval_mins())));
    }
    gtk_progress_bar_set_fraction(mw.sit_bar, fraction);
  }
  if (mw.sit_cycle_text != nullptr) {
    std::string text = "—";
    if (!model.is_paused()) {
      text = l10n::t("tpl.sitCycleMin", {l10n::A(model.current_session_mins()),
                                        l10n::A(model.sit_interval_mins())});
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
    std::int64_t const sit = model.sit_interval_mins();
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
  if (mw.sound_switch != nullptr) {
    gtk_switch_set_active(mw.sound_switch, c.sound_enabled);
    gtk_switch_set_active(mw.autostart_switch, g_state.model.autostart);
    gtk_switch_set_active(mw.updates_switch, c.auto_check_updates);
    gtk_drop_down_set_selected(
        mw.language_drop,
        c.language == "zh" ? 1 : c.language == "en" ? 2 : 0);
    gtk_switch_set_active(mw.quiet_switch, c.quiet_hours_enabled);
    gtk_spin_button_set_value(mw.quiet_start_spin,
                              c.quiet_hours_start_minutes / 60);
    gtk_spin_button_set_value(mw.quiet_end_spin,
                              c.quiet_hours_end_minutes / 60);
    gtk_widget_set_visible(mw.quiet_start_row, c.quiet_hours_enabled);
    gtk_widget_set_visible(mw.quiet_end_row, c.quiet_hours_enabled);
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
void reset_home();
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

// 退出必须确认（2026-11-15 contract）: quitting stops every reminder, so
// the dialog names the consequence; 取消 keeps the app running. The
// acceptance driver quits via the window close, not this dialog.
void on_quit_clicked(GtkButton*, gpointer) {
  if (g_state.app == nullptr) return;
  auto* dialog = gtk_message_dialog_new(
      g_state.window, GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION,
      GTK_BUTTONS_NONE, "%s", l10n::t("tray.exit").c_str());
  gtk_message_dialog_format_secondary_text(
      GTK_MESSAGE_DIALOG(dialog), "%s", l10n::t("quit.confirmBody").c_str());
  gtk_dialog_add_button(GTK_DIALOG(dialog), l10n::t("dialog.cancel").c_str(),
                        GTK_RESPONSE_CANCEL);
  gtk_dialog_add_button(GTK_DIALOG(dialog), l10n::t("tray.exit").c_str(),
                        GTK_RESPONSE_OK);
  // GTK4 removed gtk_dialog_run: the response lands through the signal.
  g_signal_connect(
      dialog, "response",
      G_CALLBACK(+[](GtkDialog* d, gint response, gpointer) {
        gtk_window_destroy(GTK_WINDOW(d));
        if (response != GTK_RESPONSE_OK) return;
        flush_now_sync();
        if (g_state.window != nullptr) gtk_window_destroy(g_state.window);
        g_state.window = nullptr;
      }),
      nullptr);
  gtk_widget_set_visible(GTK_WIDGET(dialog), TRUE);
}

// Focus (presentation silence): the backend queues cues and returns one
// bounded summary; the character settles into its quiet pose. The pose
// update is local so the toggle works even while the backend is down (#54).
void on_move_clicked(GtkButton*, gpointer) {
  if (g_state.mubi_x11) mubi::reset_home();
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

  // Four in-window segments (2026-11-15 辅助窗口): 今日 / 历史 / 设置 /
  // 关于. GtkStack pages stay realized, so each segment keeps its scroll
  // position while hidden (the prototype's per-tab scroll memory).
  auto* stack = gtk_stack_new();
  gtk_stack_set_transition_type(GTK_STACK(stack),
                                GTK_STACK_TRANSITION_TYPE_NONE);
  gtk_widget_set_vexpand(stack, TRUE);
  g_state.main_stack = GTK_STACK(stack);
  auto make_segment = [&](char const* key, char const* title_key) {
    auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
    gtk_widget_set_margin_top(box, 18);
    gtk_widget_set_margin_bottom(box, 18);
    gtk_widget_set_margin_start(box, 20);
    gtk_widget_set_margin_end(box, 20);
    auto* seg_scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(seg_scroll, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(seg_scroll),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(seg_scroll), box);
    gtk_stack_add_named(GTK_STACK(stack), seg_scroll, key);
    return box;
  };
  auto* left = make_segment("today", "seg.today");        // 今日 page
  auto* history_page = make_segment("history", "seg.history");  // 历史 page
  auto* right = make_segment("settings", "seg.settings"); // 设置 page
  // The history page collects the history + insight cards; the about page
  // the about card + footer. Pages stay realized: scroll positions persist.
  auto* about_page = make_segment("about", "seg.about");

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
    box_append(history_page, card);
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
    box_append(history_page, card);
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

    // Slim surface (issue #140): the defaults are the product — four
    // controls, no rhythm to study.
    {
      auto* defaults_hint =
          label_with(l10n::t("set.defaultsHint").c_str(), "caption");
      gtk_label_set_wrap(GTK_LABEL(defaults_hint), TRUE);
      box_append(GTK_BOX(card), defaults_hint);
    }

    auto const& c = g_state.model.config;
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

    mw.quiet_switch =
        add_toggle_row(card, l10n::t("set.quietHours").c_str(),
                       c.quiet_hours_enabled,
                       G_CALLBACK(on_quiet_hours_set));
    auto* quiet_hint =
        label_with(l10n::t("set.quietHoursHint").c_str(), "caption");
    gtk_label_set_wrap(GTK_LABEL(quiet_hint), TRUE);
    box_append(GTK_BOX(card), quiet_hint);

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
    box_append(GTK_BOX(card), quiet_start_row);
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
    box_append(GTK_BOX(card), quiet_end_row);
    mw.quiet_end_row = quiet_end_row;
    mw.quiet_end_spin = GTK_SPIN_BUTTON(quiet_end_spin);

    mw.autostart_switch = add_toggle_row(
        card, l10n::t("set.autostart").c_str(), g_state.model.autostart,
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
    box_append(GTK_BOX(card), lang_row);
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
    box_append(about_page, card);
  }

  // --- footer (config path) ---
  {
    auto* footer = gtk_label_new("");
    gtk_widget_add_css_class(footer, "footer");
    gtk_label_set_xalign(GTK_LABEL(footer), 0.0f);
    box_append(about_page, footer);
    mw.footer = GTK_LABEL(footer);
  }

  if (g_state.header_switcher != nullptr) {
    gtk_stack_switcher_set_stack(g_state.header_switcher, GTK_STACK(stack));
    gtk_widget_set_visible(GTK_WIDGET(g_state.header_switcher), TRUE);
  }
  // Segment titles (the switcher reads them; rebuilt on language change).
  for (auto const& [key, title_key] :
       std::array{std::pair{"today", "seg.today"}, std::pair{"history", "seg.history"},
                  std::pair{"settings", "seg.settings"}, std::pair{"about", "seg.about"}}) {
    if (auto* child = gtk_stack_get_child_by_name(GTK_STACK(stack), key)) {
      gtk_stack_page_set_title(gtk_stack_get_page(GTK_STACK(stack), child),
                               l10n::t(title_key).c_str());
    }
  }
  box_append(g_state.content_root, GTK_WIDGET(stack));
  // The statusbar (2026-11-15): 数据只留在本机 + the compact menu button.
  auto* statusbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_add_css_class(statusbar, "statusbar");
  box_append(GTK_BOX(statusbar),
             label_with(l10n::t("win.dataLocal").c_str(), "statusbar"));
  auto* statusbar_more = gtk_button_new_from_icon_name("view-more-symbolic");
  gtk_widget_add_css_class(statusbar_more, "flat");
  gtk_button_set_has_frame(GTK_BUTTON(statusbar_more), FALSE);
  gtk_widget_set_halign(statusbar_more, GTK_ALIGN_END);
  gtk_widget_set_hexpand(statusbar_more, TRUE);
  gtk_widget_set_tooltip_text(statusbar_more, l10n::t("pet.menuOpen").c_str());
  g_signal_connect(statusbar_more, "clicked",
                   G_CALLBACK(+[](GtkButton*, gpointer) { show_menu_window(); }),
                   nullptr);
  gtk_box_append(GTK_BOX(statusbar), statusbar_more);
  box_append(g_state.content_root, statusbar);
  refresh_all();
}

void apply_global_css() {
  auto* provider = gtk_css_provider_new();
  gtk_css_provider_load_from_string(provider, R"CSS(
    /* 2026-11-15 tokens (design/DESIGN.md): window #F8F7F3, titlebar
       #F0EEE8, ink #26241F/#655F55, accent #A7472C; dark pairs
       (#282622/#302D28/#F1EBDF/#C0B5A4/#EFAA85) under the .dark class.
       GTK CSS supports no // comments. */
    .app-bg { background: #F8F7F3; }
    .titlebar-bg { background: #F0EEE8; }
    .dark .app-bg { background: #282622; }
    .dark .titlebar-bg { background: #302D28; }
    .card {
      background: #FFFFFF;
      border: 1px solid #E5DED2;
      border-radius: 16px;
      padding: 6px 4px;
    }
    .dark .card { background: #2A2622; border-color: #3A352E; }
    .section { font-size: 13px; color: #655F55; }
    .dark .section { color: #C0B5A4; }
    .caption { font-size: 11px; color: #655F55; }
    .dark .caption { color: #C0B5A4; }
    .footer { font-size: 11px; color: #8B857A; }
    .row-label { font-size: 13px; color: #26241F; }
    .dark .row-label { color: #F1EBDF; }
    .row-strong { font-size: 14px; font-weight: 600; color: #26241F; }
    .dark .row-strong { color: #F1EBDF; }
    .big-number { font-size: 44px; font-weight: 700; color: #26241F; }
    .dark .big-number { color: #F1EBDF; }
    .counter-value { font-size: 14px; font-weight: 600; color: #26241F; }
    .dark .counter-value { color: #F1EBDF; }
    .metric-tile { background: #EAE3D7; border-radius: 12px; padding: 12px; }
    .dark .metric-tile { background: #39332C; }
    .metric-value { font-size: 20px; font-weight: 600; color: #26241F; }
    .dark .metric-value { color: #F1EBDF; }
    .status { font-size: 12.5px; }
    .status.ok { color: #267344; }
    .dark .status.ok { color: #8BCE9D; }
    .status.paused { color: #EA580C; }
    .accent-label { font-size: 11.5px; color: #A7472C; }
    .dark .accent-label { color: #EFAA85; }
    .sit-bar { min-height: 9px; }
    .sit-bar progress { background: #A7472C; border-radius: 4px; }
    .dark .sit-bar progress { background: #EFAA85; }
    .sit-bar trough { background: #EAE3D7; border-radius: 4px; }
    .dark .sit-bar trough { background: #39332C; }
    .toast-bg { background: #FFFDFB; border-radius: 14px; border: 1px solid #E2DCCC; }
    .dark .toast-bg { background: #2A2622; border-color: #3A352E; }
    .mubi-bg { background: transparent; }
    .mubi-capsule { background: #F6F1E9; border-radius: 12px; }
    .dark .mubi-capsule { background: #3A3028; }
    .mubi-capsule-text { font-size: 13px; font-weight: 600; color: #6D5948; }
    .dark .mubi-capsule-text { color: #E8D4BB; }
    .mubi-bubble { background: #F8F7F3; border: 1px solid rgba(0,0,0,0.10);
                   border-radius: 14px; padding: 12px; }
    .dark .mubi-bubble { background: #282622; border-color: rgba(255,255,255,0.10); }
    .mubi-bubble-title { font-size: 14px; font-weight: 600; color: #26241F; }
    .dark .mubi-bubble-title { color: #F1EBDF; }
    .mubi-bubble-note { font-size: 11px; color: #655F55; }
    .dark .mubi-bubble-note { color: #C0B5A4; }
    .mubi-primary { font-size: 13px; font-weight: 600; color: #F8F7F3;
                    background: #A7472C; border-radius: 8px; padding: 6px 12px; }
    .dark .mubi-primary { color: #241C16; background: #EFAA85; }
    .mubi-kind-check { font-size: 13px; color: #26241F; }
    .dark .mubi-kind-check { color: #F1EBDF; }
    .mubi-menu-button { font-size: 15px; color: #655F55;
                        background: rgba(248,247,243,0.65);
                        border-radius: 14px; padding: 2px 10px; }
    .dark .mubi-menu-button { color: #C0B5A4;
                              background: rgba(40,38,34,0.65); }
    .mubi-menu-card { background: #F8F7F3; border: 1px solid rgba(0,0,0,0.12);
                      border-radius: 12px; }
    .dark .mubi-menu-card { background: #282622;
                            border-color: rgba(255,255,255,0.12); }
    .mubi-menu-card button { font-size: 13px; color: #26241F; }
    .dark .mubi-menu-card button { color: #F1EBDF; }
    .toast-title { font-size: 17px; font-weight: 600; color: #26241F; }
    .dark .toast-title { color: #F1EBDF; }
    .toast-line { font-size: 13.5px; color: #655F55; }
    .dark .toast-line { color: #C0B5A4; }
    .toast-btn { font-size: 12.5px; color: #26241F; background: #F3EEE3;
                 border-radius: 7px; padding: 5px 10px; }
    .dark .toast-btn { color: #F1EBDF; background: #39332C; }
    .toast-btn-muted { font-size: 12.5px; color: #655F55; background: transparent;
                       border: 1px solid #E2DCCC; border-radius: 7px; padding: 5px 10px; }
    .dark .toast-btn-muted { color: #C0B5A4; border-color: #3A352E; }
    .micro-bg { background: #F8F7F3; border-radius: 18px; border: 1px solid #E5DED2; }
    .dark .micro-bg { background: #282622; border-color: #3A352E; }
    .micro-title { font-size: 18px; font-weight: 600; color: #26241F; }
    .dark .micro-title { color: #F1EBDF; }
    .micro-hint { font-size: 11.5px; color: #8B857A; }
    .micro-bar trough { background: #EAE3D7; border-radius: 2px; min-height: 4px; }
    .dark .micro-bar trough { background: #39332C; }
    .micro-bar progress { background: #A7472C; border-radius: 2px; min-height: 4px; }
    .dark .micro-bar progress { background: #EFAA85; }
    .ob-bg { background: #F8F7F3; }
    .ob-card { background: #FFFFFF; border: 1px solid #E5DED2;
               border-radius: 12px; padding: 14px; }
    .dark .ob-card { background: #2A2622; border-color: #3A352E; }
    .ob-card-selected { background: #FBEFE2; border: 1px solid #A7472C;
                        border-radius: 12px; padding: 14px; }
    .dark .ob-card-selected { background: #413025; border-color: #EFAA85; }
    .ob-title { font-size: 22px; font-weight: 700; color: #26241F; }
    .dark .ob-title { color: #F1EBDF; }
    .ob-hello { font-size: 26px; font-weight: 700; color: #26241F; }
    .dark .ob-hello { color: #F1EBDF; }
    .ob-text { font-size: 14.5px; color: #655F55; }
    .dark .ob-text { color: #C0B5A4; }
    .ob-strong { font-size: 15px; font-weight: 600; color: #26241F; }
    .dark .ob-strong { color: #F1EBDF; }
    .ob-caption { font-size: 11px; color: #8B857A; }
    .ob-badge { font-size: 10.5px; color: #A7472C; background: #FBEFE2;
                border-radius: 5px; padding: 2px 6px; }
    .dark .ob-badge { color: #EFAA85; background: #413025; }
    .ob-primary { font-size: 14px; color: #F8F7F3; background: #A7472C;
                  border-radius: 8px; padding: 9px 18px; }
    .dark .ob-primary { color: #241C16; background: #EFAA85; }
    .rhythm-chip { font-size: 12.5px; color: #26241F; background: #F3EEE3;
                   border-radius: 8px; padding: 8px 12px; }
    .dark .rhythm-chip { color: #F1EBDF; background: #39332C; }
    .rhythm-chip-selected { font-size: 12.5px; color: #A7472C;
                            background: #FBEFE2; border: 1px solid #A7472C;
                            border-radius: 8px; padding: 8px 12px; }
    .dark .rhythm-chip-selected { color: #EFAA85; background: #413025;
                                  border-color: #EFAA85; }
    .dot { font-size: 18px; color: #EAE3D7; }
    .dark .dot { color: #39332C; }
    .dot-active { font-size: 18px; color: #A7472C; }
    .dark .dot-active { color: #EFAA85; }
    .statusbar { font-size: 11px; color: #8B857A; padding: 4px 12px; }
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
void on_canvas_tap(GtkGestureClick*, gint, gdouble, gdouble, gpointer);
// 2026-11-15 invitation handlers (the pet surface never acknowledges).
void refresh_invitation();
void on_invitation_done(GtkButton*, gpointer);
void on_invitation_later(GtkButton*, gpointer);
void on_invitation_hide(GtkButton*, gpointer);
void on_invitation_reveal_partial(GtkButton*, gpointer);
void on_invitation_partial_confirm(GtkButton*, gpointer);
void on_menu_button_clicked(GtkButton*, gpointer);
void mubi_react_pat();
void mubi_close_menu();
void show_menu_window();

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
  // Repertoire acts (issue #140): a roll tilts from the docked bottom, a
  // glass-press squishes, a hop lifts — all single-bump transforms.
  double const q = std::sin(std::min(1.0, g_state.mubi_act_progress) *
                            3.14159265358979);
  if (g_state.mubi_act == 1) {
    cairo_translate(cr, 60, 128);
    cairo_rotate(cr, 14.0 * q * g_state.mubi_act_side *
                     3.14159265358979 / 180.0);
    cairo_translate(cr, -60, -128);
  } else if (g_state.mubi_act == 2) {
    cairo_translate(cr, 60, 128);
    cairo_scale(cr, 1.0 + 0.08 * q, 1.0 - 0.10 * q);
    cairo_translate(cr, -60, -128);
  } else if (g_state.mubi_act == 4) {
    cairo_translate(cr, 0, -4.0 * q);
  }
  draw_state(cr, g_state.mubi_state);
  if (g_state.mubi_act == 3) {
    // Teary begging droplets welling under each eye.
    GdkRGBA tear;
    gdk_rgba_parse(&tear, "#65C8B8");
    cairo_set_source_rgba(cr, tear.red, tear.green, tear.blue,
                          tear.alpha * 0.85);
    cairo_arc(cr, 46.5, 72, 1.4, 0, 2 * 3.14159265358979);
    cairo_fill(cr);
    cairo_arc(cr, 73.5, 72, 1.4, 0, 2 * 3.14159265358979);
    cairo_fill(cr);
  }
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

// Kind symbol (wire string) for the acknowledge-cue-kinds RPC.
char const* kind_symbol(rivet_app::ReminderKind kind) {
  switch (kind) {
    case rivet_app::ReminderKind::water: return "water";
    case rivet_app::ReminderKind::micro: return "micro";
    default: return "sit";
  }
}

char const* kind_word_key(std::string const& kind) {
  if (kind == "water") return "kind.water";
  if (kind == "micro") return "kind.micro";
  return "kind.sit";
}

// Bare kind word for the per-kind checklist (起身 / 喝水 / 护眼).
char const* kind_word(rivet_app::ReminderKind kind) {
  return kind_word_key(kind_symbol(kind));
}

// Recompute the open invitation items from the ledger's reconciliation
// view; the arriving cue merges through the same path.
void sync_pending_items() {
  auto& s = g_state;
  s.mubi_pending.clear();
  for (auto const& cue : s.model.pending_cues) {
    for (auto const& kind : cue.kinds) {
      s.mubi_pending.emplace_back(kind_symbol(kind), cue.id);
    }
  }
}

// Composed invitation heading (invite.title.*): one phrase per present
// kind — 起来走走，喝口水？-style, priority-ordered, no state machine talk.
std::string invitation_title() {
  bool has_move = false;
  bool has_water = false;
  bool has_eyes = false;
  for (auto const& [kind, id] : g_state.mubi_pending) {
    has_move = has_move || kind == "sit";
    has_water = has_water || kind == "water";
    has_eyes = has_eyes || kind == "micro";
  }
  int const words = (has_move ? 1 : 0) + (has_water ? 1 : 0) + (has_eyes ? 1 : 0);
  if (words == 3) return l10n::t("invite.title.all");
  if (has_move && has_water && has_eyes) return l10n::t("invite.title.all");
  if (has_move && has_water) return l10n::t("invite.title.moveWater");
  if (has_move && has_eyes) return l10n::t("invite.title.moveEyes");
  if (has_water && has_eyes) return l10n::t("invite.title.waterEyes");
  if (has_move) return l10n::t("invite.title.move");
  if (has_water) return l10n::t("invite.title.water");
  if (has_eyes) return l10n::t("invite.title.eyes");
  return l10n::t("invite.title.all");
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

void reset_home();
void save_placement();
void set_interactive(bool interactive);
void start_proximity_poll();

void present(int state, std::string const& message, GtkApplication* app,
             std::int64_t cue_id);

void stop_visit() {
  auto& s = g_state;
  if (s.mubi_visit_tick_id != 0) {
    g_source_remove(s.mubi_visit_tick_id);
    s.mubi_visit_tick_id = 0;
  }
  s.mubi_visit_phase = 0;
  s.mubi_visit_step = 0;
}

// ---- self-play + begging repertoire (issue #140) ---------------------------
// Small bounded acts with real sleeps between: while an invitation waits
// Mubi begs (roll, press against the glass, teary sniffles); between
// reminders it plays by itself near its dock (hops, curious tilts). Still
// motion, Focus and placement keep everything static.

void schedule_play(bool attending);
void start_act(int kind, bool attending);

void start_act(int kind, bool attending) {
  auto& s = g_state;
  if (s.mubi_act_tick_id != 0) {
    g_source_remove(s.mubi_act_tick_id);
    s.mubi_act_tick_id = 0;
  }
  s.mubi_act = kind;
  s.mubi_act_side = g_random_int_range(0, 2) == 0 ? 1.0 : -1.0;
  s.mubi_act_progress = 0.0;
  s.mubi_act_step = 33.0 / 600.0;
  s.mubi_act_tick_id = g_timeout_add(
      33,
      +[](gpointer user) -> int {
        bool const attending = user != nullptr;
        auto& st = g_state;
        st.mubi_act_progress =
            std::min(1.0, st.mubi_act_progress + st.mubi_act_step);
        if (st.mubi_canvas != nullptr) {
          gtk_widget_queue_draw(GTK_WIDGET(st.mubi_canvas));
        }
        if (st.mubi_act_progress < 1.0) return G_SOURCE_CONTINUE;
        st.mubi_act_tick_id = 0;
        st.mubi_act = 0;
        st.mubi_act_progress = 1.0;
        schedule_play(attending);
        return G_SOURCE_REMOVE;
      },
      attending ? (gpointer)1 : nullptr);
}

void schedule_play(bool attending) {
  auto& s = g_state;
  if (s.mubi_play_tick_id != 0) {
    g_source_remove(s.mubi_play_tick_id);
    s.mubi_play_tick_id = 0;
  }
  auto const delay = attending ? g_random_int_range(13, 20)
                               : g_random_int_range(12, 22);
  s.mubi_play_tick_id = g_timeout_add(
      delay * 1000,
      +[](gpointer user) -> int {
        bool const attending = user != nullptr;
        auto& st = g_state;
        st.mubi_play_tick_id = 0;
        if (st.mubi_motion == "still" || st.mubi_quiet ||
            attending != st.mubi_attending) {
          return G_SOURCE_REMOVE;
        }
        int const kind = attending
            ? static_cast<int>(g_random_int_range(1, 4))
            : (g_random_int_range(0, 2) == 0 ? 4 : 1);
        start_act(kind, attending);
        return G_SOURCE_REMOVE;
      },
      attending ? (gpointer)1 : nullptr);
}

void stop_play() {
  auto& s = g_state;
  if (s.mubi_play_tick_id != 0) {
    g_source_remove(s.mubi_play_tick_id);
    s.mubi_play_tick_id = 0;
  }
  if (s.mubi_act_tick_id != 0) {
    g_source_remove(s.mubi_act_tick_id);
    s.mubi_act_tick_id = 0;
  }
  s.mubi_act = 0;
  s.mubi_act_progress = 1.0;
}

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
void move_visit_window(int x, int y) {
#ifdef GDK_WINDOWING_X11
  auto& s = g_state;
  if (s.mubi_window == nullptr) return;
  auto* surface = gtk_native_get_surface(GTK_NATIVE(s.mubi_window));
  if (surface == nullptr || !GDK_IS_X11_SURFACE(surface)) return;
  auto* display = gdk_display_get_default();
  if (!GDK_IS_X11_DISPLAY(display)) return;
  Display* xdisplay = gdk_x11_display_get_xdisplay(GDK_X11_DISPLAY(display));
  Window xid = gdk_x11_surface_get_xid(GDK_X11_SURFACE(surface));
  XMoveWindow(xdisplay, xid, x, y);
  XFlush(xdisplay);
#else
  (void)x;
  (void)y;
#endif
}
#pragma GCC diagnostic pop

// The 2026-11-15 contract removed the central-visit travel: the invitation
// waits attached to the pet, so "returning home" is just a re-present.
void begin_visit_return() {
  present(g_state.mubi_quiet ? 5 : 0, "", nullptr, 0);
}

void present(int state, std::string const& message, GtkApplication* app,
             std::int64_t cue_id = 0) {
  if (!g_state.mubi_x11) return;  // Wayland: notification fallback only
  if (g_state.acceptance) return;  // headless probe sees the main window only
  if (app == nullptr) app = g_state.app;
  if (app == nullptr) return;
  auto& s = g_state;
  // A due cue = a live invitation on screen (2026-11-15: attached to the
  // pet; no central visit). The ledger snapshot drives the invitation.
  sync_pending_items();
  bool const due = cue_id != 0 && state >= 1 && state <= 3;
  s.mubi_attending = due;
  s.mubi_state = state;
  s.mubi_message = message;
  s.mubi_cue_id = cue_id;
  start_anim(state);
  if (!due) stop_play();
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
    // Petting = Done (issue #140): a tap on the character acknowledges the
    // open cue. The capsule tap = the Later tag.
    auto* tap = gtk_gesture_click_new();
    g_signal_connect(tap, "released", G_CALLBACK(on_canvas_tap), nullptr);
    gtk_widget_add_controller(GTK_WIDGET(canvas), GTK_EVENT_CONTROLLER(tap));
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

    // The invitation attached to the pet (2026-11-15 contract): heading,
    // 做到了 / 稍后, the 只做了一部分 per-kind checklist with 确认所选,
    // and the × hide (隐藏这次, no completion). Contents are rebuilt by
    // refresh_invitation() from the ledger; the pet surface itself never
    // records completion.
    auto* bubble = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(bubble, "mubi-bubble");
    gtk_widget_set_halign(bubble, GTK_ALIGN_FILL);

    auto* head_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    auto* title = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(title), TRUE);
    gtk_label_set_xalign(GTK_LABEL(title), 0.0);
    gtk_widget_add_css_class(title, "mubi-bubble-title");
    gtk_widget_set_hexpand(title, TRUE);
    gtk_box_append(GTK_BOX(head_row), title);
    auto* close = gtk_button_new_from_icon_name("window-close-symbolic");
    gtk_widget_add_css_class(close, "flat");
    gtk_widget_add_css_class(close, "mubi-bubble-close");
    gtk_widget_set_valign(close, GTK_ALIGN_START);
    gtk_button_set_has_frame(GTK_BUTTON(close), FALSE);
    gtk_widget_set_tooltip_text(close, l10n::t("invite.hideClose").c_str());
    g_signal_connect(close, "clicked", G_CALLBACK(on_invitation_hide),
                     nullptr);
    gtk_box_append(GTK_BOX(head_row), close);
    gtk_box_append(GTK_BOX(bubble), head_row);
    s.mubi_bubble_title = GTK_LABEL(title);
    s.mubi_bubble_close = GTK_BUTTON(close);

    auto* action_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    auto* done = gtk_button_new_with_label(l10n::t("tray.cueDone").c_str());
    gtk_widget_add_css_class(done, "mubi-primary");
    gtk_widget_set_hexpand(done, TRUE);
    g_signal_connect(done, "clicked", G_CALLBACK(on_invitation_done),
                     nullptr);
    gtk_box_append(GTK_BOX(action_row), done);
    auto* later = gtk_button_new_with_label(l10n::t("invite.later").c_str());
    g_signal_connect(later, "clicked", G_CALLBACK(on_invitation_later),
                     nullptr);
    gtk_box_append(GTK_BOX(action_row), later);
    gtk_box_append(GTK_BOX(bubble), action_row);
    s.mubi_bubble_done = GTK_BUTTON(done);
    s.mubi_bubble_later = GTK_BUTTON(later);

    auto* partial = gtk_button_new_with_label(l10n::t("invite.partial").c_str());
    gtk_widget_add_css_class(partial, "flat");
    gtk_button_set_has_frame(GTK_BUTTON(partial), FALSE);
    g_signal_connect(partial, "clicked",
                     G_CALLBACK(on_invitation_reveal_partial), nullptr);
    gtk_box_append(GTK_BOX(bubble), partial);
    s.mubi_bubble_partial = GTK_BUTTON(partial);

    auto* partial_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_set_visible(partial_box, FALSE);
    gtk_box_append(GTK_BOX(bubble), partial_box);
    s.mubi_partial_box = GTK_BOX(partial_box);

    auto* partial_confirm = gtk_button_new_with_label(
        l10n::t("invite.partialConfirm").c_str());
    gtk_widget_add_css_class(partial_confirm, "flat");
    gtk_button_set_has_frame(GTK_BUTTON(partial_confirm), FALSE);
    gtk_widget_set_halign(partial_confirm, GTK_ALIGN_START);
    gtk_widget_set_visible(partial_confirm, FALSE);
    g_signal_connect(partial_confirm, "clicked",
                     G_CALLBACK(on_invitation_partial_confirm), nullptr);
    gtk_box_append(GTK_BOX(bubble), partial_confirm);
    s.mubi_bubble_partial_confirm = GTK_BUTTON(partial_confirm);

    auto* partial_note = gtk_label_new(l10n::t("invite.partialNote").c_str());
    gtk_label_set_wrap(GTK_LABEL(partial_note), TRUE);
    gtk_label_set_xalign(GTK_LABEL(partial_note), 0.0);
    gtk_widget_add_css_class(partial_note, "mubi-bubble-note");
    gtk_widget_set_visible(partial_note, FALSE);
    gtk_box_append(GTK_BOX(bubble), partial_note);
    s.mubi_bubble_partial_note = GTK_LABEL(partial_note);

    gtk_box_append(GTK_BOX(body_box), bubble);
    s.mubi_bubble = GTK_BOX(bubble);
    // The bubble sits ABOVE the character (prototype resident-companion;
    // the macOS panel grows the same way).
    gtk_box_reorder_child(GTK_BOX(body_box), bubble, 0);

    // The ••• menu button under the pet: the same compact menu as the tray.
    auto* menu_button = gtk_button_new_from_icon_name("view-more-symbolic");
    gtk_widget_add_css_class(menu_button, "mubi-menu-button");
    gtk_widget_add_css_class(menu_button, "flat");
    gtk_widget_set_tooltip_text(menu_button, l10n::t("pet.menuOpen").c_str());
    gtk_widget_set_halign(menu_button, GTK_ALIGN_CENTER);
    g_signal_connect(menu_button, "clicked",
                     G_CALLBACK(on_menu_button_clicked), nullptr);
    box_append(GTK_BOX(body_box), menu_button);
    s.mubi_menu_button = GTK_BUTTON(menu_button);

    gtk_window_set_child(GTK_WINDOW(window), body_box);
  } else {
    gtk_widget_set_size_request(GTK_WIDGET(s.mubi_canvas),
                                static_cast<int>(120 * scale),
                                static_cast<int>(140 * scale));
  }

  refresh_label();
  refresh_invitation();
  // Explicit size: the window hugs the character plus whatever surfaces the
  // contract puts beside it — the caption (moods only), the invitation
  // bubble while a cue waits, and the ••• menu button.
  bool const label_visible = s.mubi_labels_always || !s.mubi_message.empty();
  int const win_w = std::max(canvas_w, due ? 252 : 0);
  int const win_h = canvas_h + (label_visible ? 44 : 0)
                    + (due ? 132 : 0) + 34;
  gtk_window_set_default_size(s.mubi_window, win_w, win_h);
  // Do not request window-manager keyboard focus for a floating pet.
  gtk_widget_set_visible(GTK_WIDGET(s.mubi_window), TRUE);
  // Pettable surface while an invitation waits (canvas = pet/Done, capsule
  // = Later); click-through again the moment it settles. The proximity
  // poll additionally arms the region while the cursor rests on the window
  // (free drag). Re-apply shortly after, once the label's allocation has
  // landed this frame.
  set_interactive(due);
  start_proximity_poll();
  g_timeout_add(
      60,
      +[](gpointer user) -> int {
        bool const due = user != nullptr;
        if (g_state.mubi_attending == due) {
          set_interactive(due || g_state.mubi_hover);
        }
        return G_SOURCE_REMOVE;
      },
      due ? (gpointer)1 : nullptr);
  {
    gboolean gtk_animations = TRUE;
    if (auto* settings = gtk_settings_get_default()) {
      g_object_get(G_OBJECT(settings), "gtk-enable-animations",
                   &gtk_animations, nullptr);
    }
    if (due && s.mubi_motion != "still" && !s.mubi_quiet &&
        gtk_animations) {
      schedule_play(true);
    } else if (state == 0 && s.mubi_motion != "still" && !s.mubi_quiet &&
               gtk_animations) {
      schedule_play(false);
    } else {
      stop_play();
    }
  }

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
      // The invitation waits AT the pet (2026-11-15): no central visit,
      // no return travel — placement only changes by direct manipulation.
    }
  }
#pragma GCC diagnostic pop
#endif

  // Caption moods read ~2.2 s (contract: 短句只在最近互动后出现), then the
  // companion returns to quiet waiting. The cue itself stays open in the
  // backend ledger — a caption fade is never Done.
  if ((!message.empty() || state == 4) && !due) {
    s.mubi_expire_id = g_timeout_add(
      2200,
      +[](gpointer) -> int {
        g_state.mubi_expire_id = 0;
        present(g_state.mubi_quiet ? 5 : 0, "", nullptr);
        return G_SOURCE_REMOVE;
      },
      nullptr);
  }
  refresh_invitation();
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
    double const scale = gdk_surface_get_scale(surface);
    cairo_region_t* region = cairo_region_create();
    // Union of the character's canvas, the caption, the invitation bubble
    // (buttons + checklist) and the ••• menu button; everything else on the
    // surface stays pointer-through.
    for (GtkWidget* widget :
         {GTK_WIDGET(g_state.mubi_canvas), GTK_WIDGET(g_state.mubi_capsule),
          GTK_WIDGET(g_state.mubi_bubble),
          GTK_WIDGET(g_state.mubi_menu_button)}) {
      if (widget == nullptr) continue;
      // Hidden surfaces (the invitation while nothing is due, the caption
      // while quiet) keep a stale allocation — they must not contribute
      // rectangles to the input region.
      if (!gtk_widget_get_visible(widget)) continue;
      graphene_rect_t bounds;
      if (!gtk_widget_compute_bounds(widget,
                                     GTK_WIDGET(g_state.mubi_window),
                                     &bounds)) {
        continue;
      }
      // The allocation may not exist yet (before the first frame). Fall
      // back to the body area instead of a useless 0×0 region.
      if (bounds.size.width < 1 || bounds.size.height < 1) {
        bounds.origin.x = 4;
        bounds.origin.y = 4;
        bounds.size.width = std::max(
            1, gtk_widget_get_width(GTK_WIDGET(g_state.mubi_window)) - 8);
        bounds.size.height = std::max(
            1, gtk_widget_get_height(GTK_WIDGET(g_state.mubi_window)) - 8);
      }
      cairo_rectangle_int_t rect;
      rect.x = static_cast<int>(std::floor(bounds.origin.x * scale)) - 2;
      rect.y = static_cast<int>(std::floor(bounds.origin.y * scale)) - 2;
      rect.width = static_cast<int>(std::ceil(bounds.size.width * scale)) + 4;
      rect.height = static_cast<int>(std::ceil(bounds.size.height * scale)) + 4;
      if (rect.width > 0 && rect.height > 0) {
        cairo_region_union_rectangle(region, &rect);
      }
    }
    if (cairo_region_num_rectangles(region) == 0) {
      cairo_region_destroy(region);
      return;
    }
    gdk_surface_set_input_region(surface, region);
    cairo_region_destroy(region);
  } else {
    cairo_region_t* empty_input = cairo_region_create();
    gdk_surface_set_input_region(surface, empty_input);
    cairo_region_destroy(empty_input);
  }
#endif
}

// Free drag (issue #104, owner decision 2026-11-10): the input region
// follows the pointer instead of a placement mode. While the cursor rests
// anywhere on the companion window the canvas + capsule region becomes
// sensitive (taps answer, the drag gesture moves the window); the moment
// it leaves, the empty region restores pointer-through. The due state keeps
// its own persistent region (pet = Done, capsule = Later).
gboolean on_proximity_tick(gpointer) {
  auto& s = g_state;
  s.mubi_proximity_tick_id = 0;
  if (!s.mubi_x11 || s.mubi_window == nullptr ||
      !gtk_widget_get_visible(GTK_WIDGET(s.mubi_window))) {
    return G_SOURCE_REMOVE;
  }
  bool hover = false;
#ifdef GDK_WINDOWING_X11
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
  auto* surface = gtk_native_get_surface(GTK_NATIVE(s.mubi_window));
  auto* seat = gdk_display_get_default_seat(
      gtk_widget_get_display(GTK_WIDGET(s.mubi_window)));
  if (surface != nullptr && seat != nullptr) {
    double px = -1.0;
    double py = -1.0;
    gdk_surface_get_device_position(surface, gdk_seat_get_pointer(seat), &px,
                                    &py, nullptr);
    hover = px >= 0 && py >= 0 && px < gdk_surface_get_width(surface) &&
            py < gdk_surface_get_height(surface);
  }
#pragma GCC diagnostic pop
#endif
  if (hover != s.mubi_hover) {
    s.mubi_hover = hover;
    set_interactive(hover || s.mubi_attending);
  }
  s.mubi_proximity_tick_id = g_timeout_add(100, on_proximity_tick, nullptr);
  return G_SOURCE_REMOVE;
}

void start_proximity_poll() {
  auto& s = g_state;
  if (!s.mubi_x11 || s.mubi_proximity_tick_id != 0) return;
  s.mubi_proximity_tick_id = g_timeout_add(100, on_proximity_tick, nullptr);
}

// One tray action for recovery: clear the drag-placed home and park Mubi at
// the default corner. Dragging is the everyday way to move; this exists so
// a misplaced pet is never stuck. Never edits cue completion/snooze.
void reset_home() {
  if (!g_state.mubi_x11) return;
  g_state.mubi_free_x = -1;
  g_state.mubi_free_y = -1;
  g_state.mubi_dock = "bottom-right";
  // Keep the same due cue and readable text when parking Mubi at the
  // default corner. Re-presenting is visual only: no backend acknowledge.
  present(g_state.mubi_state, g_state.mubi_message, nullptr,
          g_state.mubi_cue_id);
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
  g_state.mubi_drag_moved = false;
  if (g_state.mubi_window == nullptr) return;
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
  // Two-dimensional 8 px threshold (contract 直接操作; prototype Math.hypot
  // > 8). Past it this sequence is a move: suppress the tap that fires on
  // release so a drag never submits a health response.
  if (std::hypot(offset_x, offset_y) > 8.0) {
    g_state.mubi_drag_moved = true;
  }
  if (g_state.mubi_window == nullptr) return;
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
  save_placement();
  g_state.mubi_drag_moved = false;
}

void show_ack() {
  if (!g_state.mubi_quiet) present(4, "", nullptr);
}

void set_quiet(bool enabled) {
  g_state.mubi_quiet = enabled;
  present(enabled ? 5 : 0, "", nullptr);
}

void apply_config(std::int64_t freeX, std::int64_t freeY) {
  // One shipped presentation (issue #140): M size, subtle motion, default
  // corner unless a drag-placed position is stored.
  g_state.mubi_size = "M";
  g_state.mubi_motion = "subtle";
  g_state.mubi_dock = "bottom-right";
  g_state.mubi_labels_always = false;
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

// 2026-11-15 contract: petting is companionship ONLY — a playful caption
// rotation (happy → wink → peek), never an acknowledgement. The invitation
// buttons, the tray items and the micro window's 做好了 are the completion
// paths. A release that follows a real drag is the end of a move, not a pet.
void mubi_react_pat() {
  auto& s = g_state;
  s.mubi_pat_count += 1;
  char const* caption = nullptr;
  switch ((s.mubi_pat_count - 1) % 3) {
    case 0: caption = "pet.caption.happy"; break;
    case 1: caption = "pet.caption.wink"; break;
    default: caption = "pet.caption.peek"; break;
  }
  if (s.mubi_capsule != nullptr) {
    gtk_label_set_text(s.mubi_capsule, l10n::t(caption).c_str());
    gtk_widget_set_visible(GTK_WIDGET(s.mubi_capsule), TRUE);
  }
  if (s.mubi_mood_reset_id != 0) g_source_remove(s.mubi_mood_reset_id);
  s.mubi_mood_reset_id = g_timeout_add(
      2200,
      +[](gpointer) -> int {
        g_state.mubi_mood_reset_id = 0;
        if (g_state.mubi_capsule != nullptr &&
            !g_state.mubi_attending && g_state.mubi_message.empty()) {
          gtk_widget_set_visible(GTK_WIDGET(g_state.mubi_capsule), FALSE);
        }
        return G_SOURCE_REMOVE;
      },
      nullptr);
}

void on_canvas_tap(GtkGestureClick*, gint, gdouble, gdouble, gpointer) {
  if (g_state.mubi_drag_moved) return;
  mubi_react_pat();
}

void on_mubi_done(GtkButton*, gpointer) {
  auto cue_id = g_state.mubi_cue_id;
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->acknowledge_cue_async(cue_id,
                                             [](rivet_app::Result<void>) {});
  }
  if (g_state.mubi_quiet) {
    mubi::present(5, "", nullptr);
  } else {
    mubi::present(4, "", nullptr);  // happy glint, then travel home
  }
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
  // #56 §4 `later`: a quiet settle — the reassurance note rides the toast,
  // Mubi walks home (the persistent invitation is settled now).
  if (g_state.app != nullptr) {
    ::show_toast_plain(l10n::t("mubi.laterNote"), {},
                       rivet_app::ReminderKind::water, g_state.app);
  }
  mubi::begin_visit_return();
}

void on_mubi_hide(GtkButton*, gpointer) {
  auto cue_id = g_state.mubi_cue_id;
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->abandon_cue_async(cue_id, [](rivet_app::Result<void>) {});
  }
  mubi::present(g_state.mubi_quiet ? 5 : 0, "", nullptr);
}

// ---- invitation attached to the pet (2026-11-15 contract) ------------------
void micro_show(std::int64_t duration_seconds, std::string const& title,
                std::string const& hint_text, std::int64_t cue_id,
                GtkApplication* app);
void on_pause_clicked(GtkButton*, gpointer);
void on_quit_clicked(GtkButton*, gpointer);
void on_focus_clicked(GtkButton*, gpointer);

bool pending_has_kind(std::string const& kind) {
  for (auto const& [k, id] : g_state.mubi_pending) {
    if (k == kind) return true;
  }
  return false;
}

rivet_app::HealthCue const* newest_cue_with_kind(rivet_app::ReminderKind kind) {
  for (auto it = g_state.model.pending_cues.rbegin();
       it != g_state.model.pending_cues.rend(); ++it) {
    if (std::find(it->kinds.begin(), it->kinds.end(), kind) != it->kinds.end())
      return &*it;
  }
  return nullptr;
}

// Rebuild the bubble from the open ledger snapshot: heading, checklist and
// visibility. 零选择不提交 — the confirm button disables itself on empty.
void refresh_invitation() {
  auto& s = g_state;
  if (s.mubi_bubble == nullptr) return;
  bool const due = s.mubi_attending && !s.mubi_pending.empty() && !s.mubi_quiet;
  gtk_widget_set_visible(GTK_WIDGET(s.mubi_bubble), due);
  if (!due) return;
  gtk_label_set_text(s.mubi_bubble_title, mubi::invitation_title().c_str());
  // Rebuild the per-kind checklist (one item per open kind).
  for (auto* check : s.mubi_kind_checks) {
    if (gtk_widget_get_parent(GTK_WIDGET(check)) != nullptr) {
      gtk_box_remove(s.mubi_partial_box, GTK_WIDGET(check));
    }
  }
  s.mubi_kind_checks.clear();
  std::vector<std::string> seen;
  for (auto const& [kind, id] : s.mubi_pending) {
    if (std::find(seen.begin(), seen.end(), kind) != seen.end()) continue;
    seen.push_back(kind);
    auto* check = GTK_CHECK_BUTTON(
        gtk_check_button_new_with_label(
        l10n::t(mubi::kind_word_key(kind)).c_str()));
    gtk_check_button_set_active(check, TRUE);
    gtk_widget_add_css_class(GTK_WIDGET(check), "mubi-kind-check");
    gtk_box_append(s.mubi_partial_box, GTK_WIDGET(check));
    s.mubi_kind_checks.push_back(check);
    s.mubi_check_kinds.push_back(kind);
  }
}

// Done (做到了): settles EVERY kind of the current invitation — the same
// gesture the tray offers, applied to all open cue ids.
void on_invitation_done(GtkButton*, gpointer) {
  auto const& pending = g_state.mubi_pending;
  if (g_state.api == nullptr || pending.empty()) return;
  std::vector<std::int64_t> ids;
  for (auto const& [kind, id] : pending) {
    if (std::find(ids.begin(), ids.end(), id) == ids.end()) {
      ids.push_back(id);
      (void)g_state.api->acknowledge_cue_async(id,
                                               [](rivet_app::Result<void>) {});
    }
  }
  mubi::show_ack();
}

// Later (稍后): defers every merged kind by the snooze minutes.
void on_invitation_later(GtkButton*, gpointer) {
  if (g_state.api == nullptr || g_state.mubi_pending.empty()) return;
  std::vector<std::int64_t> ids;
  for (auto const& [kind, id] : g_state.mubi_pending) {
    if (std::find(ids.begin(), ids.end(), id) == ids.end()) {
      ids.push_back(id);
      (void)g_state.api->snooze_cue_async(id, [](rivet_app::Result<void>) {});
    }
  }
  mubi::present(0, l10n::t("mubi.laterNote"), nullptr);
}

// Hide this invitation (× / 隐藏这次): no completion, no deferral.
void on_invitation_hide(GtkButton*, gpointer) {
  if (g_state.api == nullptr || g_state.mubi_pending.empty()) return;
  std::vector<std::int64_t> ids;
  for (auto const& [kind, id] : g_state.mubi_pending) {
    if (std::find(ids.begin(), ids.end(), id) == ids.end()) {
      ids.push_back(id);
      (void)g_state.api->dismiss_cue_async(id, [](rivet_app::Result<void>) {});
    }
  }
  mubi::present(g_state.mubi_quiet ? 5 : 0, "", nullptr);
}

// 只做了一部分: expand the per-kind checklist.
void on_invitation_reveal_partial(GtkButton*, gpointer) {
  auto& s = g_state;
  if (s.mubi_bubble == nullptr || s.mubi_pending.empty()) return;
  gtk_widget_set_visible(GTK_WIDGET(s.mubi_partial_box), TRUE);
  gtk_widget_set_visible(GTK_WIDGET(s.mubi_bubble_partial_confirm), TRUE);
  gtk_widget_set_visible(GTK_WIDGET(s.mubi_bubble_partial_note), TRUE);
  gtk_widget_set_visible(GTK_WIDGET(s.mubi_bubble_partial), FALSE);
}

// 确认所选: settles only the checked kinds per cue; zero selection never
// submits (零选择不提交). The residual kinds keep waiting in place.
void on_invitation_partial_confirm(GtkButton*, gpointer) {
  auto& s = g_state;
  if (s.api == nullptr || s.mubi_pending.empty()) return;
  // Checkbox rows carry their kind symbol in mubi_check_kinds (same order);
  // the checklist is rebuilt whenever the ledger snapshot changes.
  std::vector<std::string> symbols;
  for (std::size_t i = 0; i < s.mubi_kind_checks.size(); ++i) {
    if (gtk_check_button_get_active(s.mubi_kind_checks[i]) &&
        i < s.mubi_check_kinds.size()) {
      symbols.push_back(s.mubi_check_kinds[i]);
    }
  }
  if (symbols.empty()) return;  // 零选择不提交
  std::vector<std::int64_t> ids;
  for (auto const& [kind, id] : s.mubi_pending) {
    if (std::find(ids.begin(), ids.end(), id) != ids.end()) continue;
    std::vector<std::string> settled;
    for (auto const& [k2, i2] : s.mubi_pending) {
      if (i2 != id) continue;
      if (std::find(symbols.begin(), symbols.end(), k2) != symbols.end() &&
          std::find(settled.begin(), settled.end(), k2) == settled.end()) {
        settled.push_back(k2);
      }
    }
    if (settled.empty()) continue;
    (void)s.api->acknowledge_cue_kinds_async(
        id, settled, [](rivet_app::Result<void>) {});
    ids.push_back(id);
  }
  mubi::show_ack();
}

// The ••• menu button: the same compact menu as the tray, anchored at the
// pet (a small floating card per the prototype's resident-menu).
void on_menu_button_clicked(GtkButton*, gpointer) { show_menu_window(); }

void mubi_close_menu() {
  if (g_state.mubi_menu_window != nullptr) {
    gtk_window_destroy(g_state.mubi_menu_window);
    g_state.mubi_menu_window = nullptr;
  }
}

void show_menu_window() {
  auto& s = g_state;
  if (s.app == nullptr) return;
  mubi_close_menu();
  auto* window = GTK_WINDOW(gtk_application_window_new(s.app));
  gtk_window_set_title(window, "MoveBit");
  gtk_window_set_decorated(window, FALSE);
  gtk_widget_add_css_class(GTK_WIDGET(window), "mubi-menu-card");
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
  gtk_widget_set_margin_top(box, 8);
  gtk_widget_set_margin_bottom(box, 8);
  gtk_widget_set_margin_start(box, 8);
  gtk_widget_set_margin_end(box, 8);

  auto add_item = [&](char const* label_key, std::function<void()> action) {
    auto* button = gtk_button_new_with_label(l10n::t(label_key).c_str());
    gtk_widget_add_css_class(button, "flat");
    gtk_button_set_has_frame(GTK_BUTTON(button), FALSE);
    gtk_widget_set_halign(GTK_WIDGET(button), GTK_ALIGN_FILL);
    auto* fn = new std::function<void()>(std::move(action));
    g_signal_connect_data(
        button, "clicked",
        G_CALLBACK(+[](GtkButton*, gpointer user) {
          (*static_cast<std::function<void()>*>(user))();
        }),
        fn,
        +[](gpointer data, GClosure*) {
          delete static_cast<std::function<void()>*>(data);
        },
        static_cast<GConnectFlags>(0));
    gtk_box_append(GTK_BOX(box), GTK_WIDGET(button));
  };
  auto add_separator = [&] {
    auto* line = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL);
    gtk_box_append(GTK_BOX(box), line);
  };

  add_item("tray.open", [] {
    mubi_close_menu();
    if (g_state.window != nullptr) gtk_window_present(g_state.window);
  });
  if (!s.mubi_pending.empty()) {
    add_separator();
    add_item("tray.cueDone", [] { mubi_close_menu(); on_invitation_done(nullptr, nullptr); });
    add_item("tray.confirmIndividually", [] {
      mubi_close_menu();
      on_invitation_reveal_partial(nullptr, nullptr);
    });
    add_item("tray.cueLater", [] { mubi_close_menu(); on_invitation_later(nullptr, nullptr); });
    add_item("tray.cueHide", [] { mubi_close_menu(); on_invitation_hide(nullptr, nullptr); });
  }
  add_separator();
  add_item(s.model.quiet ? "tray.focusOff" : "tray.focusOn", [] {
    mubi_close_menu();
    on_focus_clicked(nullptr, nullptr);
  });
  add_item(s.model.is_paused() ? "tray.resume" : "tray.pause", [] {
    mubi_close_menu();
    on_pause_clicked(nullptr, nullptr);
  });
  add_separator();
  add_item("tray.eyeRest", [] {
    mubi_close_menu();
    if (auto const* cue = newest_cue_with_kind(rivet_app::ReminderKind::micro)) {
      micro_show(20, l10n::t("tray.eyeRest"), l10n::t("micro.hint"), cue->id,
                 g_state.app);
    }
  });
  add_item("tray.stretch", [] {
    mubi_close_menu();
    if (auto const* cue = newest_cue_with_kind(rivet_app::ReminderKind::sit)) {
      micro_show(120, l10n::t("tray.stretch"), l10n::t("stretch.hint"), cue->id,
                 g_state.app);
    }
  });
  add_item("tray.resetMubi", [] { mubi_close_menu(); mubi::reset_home(); });
  add_separator();
  add_item("tray.exit", [] {
    mubi_close_menu();
    on_quit_clicked(nullptr, nullptr);
  });
  add_item("tray.backToDesktop", [] { mubi_close_menu(); });

  gtk_window_set_child(window, box);
  s.mubi_menu_window = window;
  gtk_widget_set_visible(GTK_WIDGET(window), TRUE);
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

// The 2026-11-15 tray response items act on the WHOLE merged invitation
// (the same surface the pet's bubble offers); plain prototype wording.
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
    items.push_back(menu_item(l10n::t("tray.cueDone"), [] {
      on_invitation_done(nullptr, nullptr);
    }));
    items.push_back(menu_item(l10n::t("tray.confirmIndividually"), [] {
      on_invitation_reveal_partial(nullptr, nullptr);
    }));
    items.push_back(menu_item(l10n::t("tray.cueLater"), [] {
      on_invitation_later(nullptr, nullptr);
    }));
    items.push_back(menu_item(l10n::t("tray.cueHide"), [] {
      on_invitation_hide(nullptr, nullptr);
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
        show_guided(20, l10n::t("tray.eyeRest"), l10n::t("micro.hint"));
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
    items.push_back(menu_item(l10n::t("tray.resetMubi"),
                              [] { mubi::reset_home(); }));
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
    g_state.micro_countdown = nullptr;
    g_state.micro_body_title = nullptr;
    g_state.micro_done_button = nullptr;
    g_state.micro_stop_button = nullptr;
    g_state.micro_restart_button = nullptr;
    g_state.micro_switch_button = nullptr;
    g_state.micro_tuck_button = nullptr;
    g_state.micro_started = false;
    g_state.micro_phase = 0;
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

void micro_reset() {
  auto& s = g_state;
  s.micro_phase = 0;
  s.micro_started = false;
  s.micro_timeout_id = 0;
}

// Click / Esc / a newer cue: end early as a Hide — no completion claimed.
void micro_dismiss() {
  auto cue_id = g_state.micro_cue_id;
  micro_close();
  if (g_state.api != nullptr && cue_id != 0) {
    (void)g_state.api->abandon_cue_async(cue_id, [](rivet_app::Result<void>) {});
  }
}

// Phase surface (2026-11-15 微休息): invite → running → ended, with the
// contract copy on each state. Stopping never records completion.
void micro_set_phase(int phase) {
  auto& s = g_state;
  s.micro_phase = phase;
  auto show = [phase](GtkWidget* w, bool visible) {
    if (w != nullptr) gtk_widget_set_visible(w, visible);
  };
  show(GTK_WIDGET(s.micro_start_button), phase == 0);
  show(GTK_WIDGET(s.micro_done_button), phase != 0);
  show(GTK_WIDGET(s.micro_stop_button), phase == 1);
  show(GTK_WIDGET(s.micro_restart_button), phase == 2);
  show(GTK_WIDGET(s.micro_switch_button), phase == 0);
  show(GTK_WIDGET(s.micro_bar), phase == 1);
  show(GTK_WIDGET(s.micro_countdown), phase == 1);
  if (s.micro_body_title != nullptr) {
    gtk_label_set_text(
        s.micro_body_title,
        l10n::t(phase == 2
                    ? "micro.endedTitle"
                    : (s.micro_eyes ? "micro.eyesTitle" : "micro.stretchTitle"))
            .c_str());
  }
  if (s.micro_hint != nullptr) {
    char const* key = phase == 2
        ? "micro.endedHint"
        : (phase == 1 ? (s.micro_eyes ? "micro.eyesBody" : "micro.stretchBody")
                      : "micro.inviteHint");
    gtk_label_set_text(s.micro_hint, l10n::t(key).c_str());
  }
}

char const* micro_switch_label() {
  return g_state.micro_eyes ? "micro.switchStretch" : "micro.switchEyes";
}

// 开始 / 重新开始: the countdown runs by deadline (contract 倒计时按截止
// 时间计算), and the timer NEVER auto-confirms — the ended state keeps the
// in-place 做好了.
void micro_start() {
  auto& s = g_state;
  if (s.micro_window == nullptr || s.micro_phase == 1) return;
  s.micro_started = true;
  micro_set_phase(1);
  s.micro_progress = 1.0;
  if (s.micro_bar != nullptr) {
    gtk_progress_bar_set_fraction(s.micro_bar, 1.0);
  }
  if (s.micro_timeout_id != 0) g_source_remove(s.micro_timeout_id);
  s.micro_timeout_id = g_timeout_add(
      250,
      +[](gpointer) -> int {
        auto& st = g_state;
        st.micro_progress =
            std::max(0.0, st.micro_progress - 250.0 / st.micro_total_ms);
        if (st.micro_bar != nullptr) {
          gtk_progress_bar_set_fraction(st.micro_bar, st.micro_progress);
        }
        if (st.micro_countdown != nullptr) {
          gtk_label_set_text(
              st.micro_countdown,
              std::to_string(
                  static_cast<int>(st.micro_progress * st.micro_total_ms / 1000 + 0.999))
                  .c_str());
        }
        if (st.micro_progress <= 0.0) {
          st.micro_timeout_id = 0;
          // In-place confirm: the window stays; 做好了 is explicit and a
          // restart keeps the session going. Nothing auto-closes here.
          micro_set_phase(2);
          return G_SOURCE_REMOVE;
        }
        return G_SOURCE_CONTINUE;
      },
      nullptr);
}

// 停止计时: back to the invite, nothing recorded.
void micro_stop() {
  auto& s = g_state;
  if (s.micro_timeout_id != 0) {
    g_source_remove(s.micro_timeout_id);
    s.micro_timeout_id = 0;
  }
  s.micro_progress = 1.0;
  micro_set_phase(0);
}

// 改为 20 秒护眼 / 改为 2 分钟拉伸: invite-state kind switch.
void micro_switch() {
  auto& s = g_state;
  if (s.micro_phase != 0) return;
  s.micro_eyes = !s.micro_eyes;
  s.micro_total_ms = (s.micro_eyes ? 20 : 120) * 1000;
  s.micro_progress = 1.0;
  if (s.micro_switch_button != nullptr) {
    gtk_button_set_label(s.micro_switch_button,
                         l10n::t(micro_switch_label()).c_str());
  }
  micro_set_phase(0);
}

void micro_show(std::int64_t duration_seconds, std::string const& title,
                std::string const& hint_text, std::int64_t cue_id,
                GtkApplication* app) {
  // The contract copy derives from the running kind; the caller-supplied
  // title/hint stay for the older notification-fallback paths.
  (void)title;
  (void)hint_text;
  // Replacing a session must not record the previous cue as abandoned.
  micro_close();
  g_state.micro_cue_id = cue_id;
  g_state.micro_eyes = duration_seconds < 120;
  g_state.micro_total_ms = std::max<std::int64_t>(1, duration_seconds) * 1000;
  auto* window = gtk_application_window_new(app);
  gtk_widget_add_css_class(GTK_WIDGET(window), "micro-bg");
  gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
  gtk_window_set_default_size(GTK_WINDOW(window), 420, -1);
  g_state.micro_window = GTK_WINDOW(window);

  auto* body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(body, 16);
  gtk_widget_set_margin_bottom(body, 16);
  gtk_widget_set_margin_start(body, 22);
  gtk_widget_set_margin_end(body, 22);
  auto* body_title = gtk_label_new("");
  gtk_widget_add_css_class(body_title, "micro-title");
  gtk_label_set_xalign(GTK_LABEL(body_title), 0.0f);
  box_append(GTK_BOX(body), body_title);
  g_state.micro_body_title = GTK_LABEL(body_title);
  auto* hint = gtk_label_new("");
  gtk_widget_add_css_class(hint, "micro-hint");
  gtk_label_set_wrap(GTK_LABEL(hint), TRUE);
  gtk_label_set_xalign(GTK_LABEL(hint), 0.0f);
  box_append(GTK_BOX(body), hint);
  g_state.micro_hint = GTK_LABEL(hint);
  auto* countdown = gtk_label_new("");
  gtk_widget_add_css_class(countdown, "counter-value");
  gtk_label_set_xalign(GTK_LABEL(countdown), 0.0f);
  box_append(GTK_BOX(body), countdown);
  g_state.micro_countdown = GTK_LABEL(countdown);
  auto* bar = gtk_progress_bar_new();
  gtk_progress_bar_set_fraction(GTK_PROGRESS_BAR(bar), 0.0);
  gtk_widget_add_css_class(bar, "micro-bar");
  box_append(GTK_BOX(body), bar);
  g_state.micro_bar = GTK_PROGRESS_BAR(bar);

  auto* actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  auto* start = gtk_button_new_with_label(l10n::t("micro.start").c_str());
  gtk_widget_add_css_class(start, "ob-primary");
  g_signal_connect(
      start, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_start(); }), nullptr);
  gtk_box_append(GTK_BOX(actions), start);
  g_state.micro_start_button = GTK_BUTTON(start);
  auto* done = gtk_button_new_with_label(l10n::t("micro.done").c_str());
  gtk_widget_add_css_class(done, "ob-primary");
  g_signal_connect(
      done, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_finish(); }), nullptr);
  gtk_box_append(GTK_BOX(actions), done);
  g_state.micro_done_button = GTK_BUTTON(done);
  auto* stop = gtk_button_new_with_label(l10n::t("micro.stop").c_str());
  gtk_widget_add_css_class(stop, "flat");
  gtk_button_set_has_frame(GTK_BUTTON(stop), FALSE);
  g_signal_connect(
      stop, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_stop(); }), nullptr);
  gtk_box_append(GTK_BOX(actions), stop);
  g_state.micro_stop_button = GTK_BUTTON(stop);
  auto* restart = gtk_button_new_with_label(l10n::t("micro.restart").c_str());
  gtk_widget_add_css_class(restart, "flat");
  gtk_button_set_has_frame(GTK_BUTTON(restart), FALSE);
  g_signal_connect(
      restart, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_start(); }), nullptr);
  gtk_box_append(GTK_BOX(actions), restart);
  g_state.micro_restart_button = GTK_BUTTON(restart);
  auto* tuck = gtk_button_new_with_label(l10n::t("micro.tuckAway").c_str());
  gtk_widget_add_css_class(tuck, "flat");
  gtk_button_set_has_frame(GTK_BUTTON(tuck), FALSE);
  g_signal_connect(
      tuck, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_dismiss(); }), nullptr);
  gtk_box_append(GTK_BOX(actions), tuck);
  g_state.micro_tuck_button = GTK_BUTTON(tuck);
  gtk_box_append(GTK_BOX(body), actions);
  auto* switch_btn = gtk_button_new_with_label("");
  gtk_widget_add_css_class(switch_btn, "flat");
  gtk_button_set_has_frame(GTK_BUTTON(switch_btn), FALSE);
  gtk_widget_set_halign(switch_btn, GTK_ALIGN_START);
  g_signal_connect(
      switch_btn, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer) { micro_switch(); }), nullptr);
  box_append(GTK_BOX(body), switch_btn);
  g_state.micro_switch_button = GTK_BUTTON(switch_btn);
  gtk_window_set_child(GTK_WINDOW(window), body);
  micro_set_phase(0);
  if (g_state.micro_switch_button != nullptr) {
    gtk_button_set_label(g_state.micro_switch_button,
                         l10n::t(micro_switch_label()).c_str());
  }
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
    // 2026-11-15: the invitation bubble attached to the pet carries the
    // composed heading; the arriving cue joins the ledger snapshot so the
    // bubble lists every open kind (persistent invitations supersede-merge).
    g_state.model.pending_cues.push_back(cue);
    mubi::present(static_cast<int>(state), "", app, cue.id);
    cue_displayed(cue.id);
    return;
  }
  if (kinds.size() == 1 && kinds[0] == rivet_app::ReminderKind::micro) {
    micro_show(20, pick_micro(), l10n::t("micro.hint"), cue.id, app);
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
  toast_show(title, lines, accent, cue.id, 10, app);
  cue_displayed(cue.id);
}

void show_toast_plain(std::string const& title, std::vector<std::string> const& lines,
                      rivet_app::ReminderKind accent, GtkApplication* app) {
  toast_show(title, lines, accent, 0, 10, app);
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
                    mubi::sync_pending_items();
                    refresh_invitation();
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
  mubi::apply_config(changed.companion_free_x, changed.companion_free_y);
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
  // Deterministic acceptance hook for the central cue visit (#104): deliver
  // one real due cue after startup so the X11 e2e can measure approach and
  // return without waiting for a schedule.
  char const* visit_test = g_getenv("MOVEBIT_VISIT_TEST");
  if (visit_test != nullptr && std::string(visit_test) == "1") {
    g_timeout_add(
        2500,
        +[](gpointer) -> int {
          mubi::present(1, "Water", g_state.app, 4242);
          return G_SOURCE_REMOVE;
        },
        nullptr);
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
    auto* move = gtk_button_new_with_label(l10n::t("tray.resetMubi").c_str());
    gtk_widget_set_sensitive(move, FALSE); // enabled on X11 capability report
    g_signal_connect(move, "clicked", G_CALLBACK(on_move_clicked), nullptr);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), move);
    g_state.move_button = GTK_BUTTON(move);
    auto* quit = gtk_button_new_with_label(l10n::t("tray.exit").c_str());
    g_signal_connect(quit, "clicked", G_CALLBACK(on_quit_clicked), nullptr);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(header), quit);
    g_state.quit_button = GTK_BUTTON(quit);
  }
  gtk_window_set_titlebar(GTK_WINDOW(window), header);
  // Compact titlebar center: the four segment tabs (今日/历史/设置/关于).
  auto* switcher = gtk_stack_switcher_new();
  g_state.header_switcher = GTK_STACK_SWITCHER(switcher);
  // The stack arrives with build_main_content(); it binds + titles lazily.
  gtk_header_bar_set_title_widget(GTK_HEADER_BAR(header), switcher);
  gtk_widget_set_visible(switcher, FALSE);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_add_css_class(GTK_WIDGET(root), "titlebar-bg");
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
  // Follow the system color scheme: the .dark class swaps the token pairs
  // (the character itself never inverts — 暗色不反相 is the art contract).
  gboolean prefer_dark = FALSE;
  if (auto* settings = gtk_settings_get_default()) {
    g_object_get(G_OBJECT(settings), "gtk-application-prefer-dark-theme",
                 &prefer_dark, nullptr);
  }
  if (prefer_dark) {
    gtk_widget_add_css_class(GTK_WIDGET(window), "dark");
    g_state.dark_theme = true;
  }
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
