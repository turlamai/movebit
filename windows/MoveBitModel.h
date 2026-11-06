#pragma once

// Shared host-side model for the WinUI MoveBit host: copy pools, duration
// formatting, and the client-side history/insight slicing. Mirrors the Swift
// MoveBitModel/CopyPool and the GTK host helpers — all policy still lives in
// the backend; this only formats what the backend publishes.

#include "GeneratedBackend.hpp"
#include "I18n.h"

#include <algorithm>
#include <cstdint>
#include <ctime>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace movebit {

inline std::int64_t now_ms() {
  return static_cast<std::int64_t>(std::time(nullptr)) * 1000;
}

inline bool late_night() {
  std::time_t t = std::time(nullptr);
  std::tm local{};
  localtime_s(&local, &t);
  return local.tm_hour >= 22 || local.tm_hour < 6;
}

/// "45m" / "2h05m" (parity with MainViewModel.FormatMinutes).
inline std::string format_minutes(std::int64_t total) {
  total = std::max<std::int64_t>(0, total);
  if (total < 60) return std::to_string(total) + "m";
  auto m = std::to_string(total % 60);
  if (m.size() < 2) m = "0" + m;
  return std::to_string(total / 60) + "h" + m + "m";
}

inline std::string pad2(std::int64_t n) {
  auto s = std::to_string(n);
  if (s.size() < 2) s = "0" + s;
  return s;
}

/// Localized big-number duration ("2 hr 05 min" / "45 min").
inline std::string format_duration(std::int64_t total) {
  total = std::max<std::int64_t>(0, total);
  return total >= 60
             ? l10n::t("app.hourMin", {l10n::A(total / 60), l10n::A(pad2(total % 60))})
             : l10n::t("app.minutes", {l10n::A(total)});
}

/// Compact axis label: "·" for zero (parity with FormatMinutesCompact).
inline std::string format_compact(std::int64_t total) {
  if (total == 0) return "·";
  return total >= 60 ? std::to_string(total / 60) + "h"
                     : std::to_string(total) + "m";
}

inline std::string pick_water() {
  return late_night() ? l10n::pick("copy.lateNightWaterPool", 3)
                      : l10n::pick("copy.waterPool", 8);
}

inline std::string pick_micro() {
  return late_night() ? l10n::pick("copy.lateNightMicroPool", 3)
                      : l10n::pick("copy.microPool", 9);
}

inline std::string day_key(std::int64_t epoch_ms) {
  return l10n::format_epoch(epoch_ms, "%Y-%m-%d");
}

inline std::string resolve_language(std::string const& configured) {
  if (configured != "auto") return configured;
  char lang[128] = {};
  size_t size = 0;
  getenv_s(&size, lang, sizeof(lang), "LANG");
  if (size == 0) {
    // LANG is the Unix convention and a Windows GUI process rarely has it;
    // ask for the user's UI language instead (parity with the old Avalonia
    // host's CultureInfo.CurrentUICulture). zh stays the default.
    wchar_t name[16] = {};
    if (::GetLocaleInfoW(::GetUserDefaultUILanguage(), LOCALE_SISO639LANGNAME,
                         name, 16) > 0) {
      char narrow[16] = {};
      if (::WideCharToMultiByte(CP_UTF8, 0, name, -1, narrow, sizeof(narrow),
                                nullptr, nullptr) > 0) {
        return std::string(narrow).rfind("zh", 0) == 0 ? "zh" : "en";
      }
    }
    return "zh";
  }
  return std::string(lang).rfind("zh", 0) == 0 ? "zh" : "en";
}

struct DaySlice {
  rivet_app::DayStats stats;
  std::int64_t day_start_ms;
  bool is_today;
};

/// Zero-filled day list ending today; today's entry is the live state.
template <typename TodayFn, typename HistoryFn>
inline std::vector<DaySlice> history_slice(int days, TodayFn today_fn,
                                           HistoryFn history_fn) {
  std::vector<DaySlice> slices;
  auto const today = today_fn();
  std::string const today_key =
      today.date.empty() ? day_key(now_ms()) : today.date;
  std::map<std::string, rivet_app::DayStats> by_date;
  for (auto const& d : history_fn()) by_date.emplace(d.date, d);

  std::time_t secs = static_cast<std::time_t>(now_ms() / 1000);
  std::tm local{};
  localtime_s(&local, &secs);
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
        is_today ? today
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
  rivet_app::DayStats busiest;
  bool has_busiest;
};

template <typename Slices>
inline InsightSummary insight_summary(Slices const& slices) {
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

struct Model {
  // Pre-bootstrap placeholder = the shipped default; the backend overwrites
  // it with the real persisted config right after init.
  rivet_app::ReminderConfig config{
      50, 60, 5, 10, true, 20, 20, true, false, true, false, "auto",
      "M", "subtle", "bottom-right", "cue",
      "balanced", true, true, false, 1320, 420};
  rivet_app::DayStats today{"", 0, 0, 0, 0, 0};
  rivet_app::PauseState paused{false, std::nullopt};
  std::vector<rivet_app::LoopInfo> loops;
  // Per-kind delivery/response truth for today (issue #88): shown and
  // self-reported done are separate from the fired-reminder counters.
  std::vector<rivet_app::CueOutcomeTotals> outcomes;
  // Cues currently pending or on screen (backend reconciliation view).
  std::vector<rivet_app::HealthCue> pending_cues;
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
  bool is_paused() const { return paused.paused; }
  std::int64_t current_session_mins() const {
    auto sit = loop(rivet_app::ReminderKind::sit);
    return sit.has_value() ? sit->accumulated_mins : 0;
  }
  std::optional<rivet_app::CueOutcomeTotals> outcome(
      rivet_app::ReminderKind kind) const {
    for (auto const& o : outcomes) {
      if (o.kind == kind) return o;
    }
    return std::nullopt;
  }
  // Nearest enabled kind still counting down, in active minutes. Empty when
  // paused or every kind is off.
  std::optional<std::pair<rivet_app::ReminderKind, std::int64_t>> next_cue()
      const {
    if (is_paused()) return std::nullopt;
    std::optional<std::pair<rivet_app::ReminderKind, std::int64_t>> best;
    for (auto const& l : loops) {
      if (!l.due_in_active_mins.has_value()) continue;
      auto const due = std::max<std::int64_t>(0, *l.due_in_active_mins);
      if (!best.has_value() || due < best->second) best = {l.kind, due};
    }
    return best;
  }
  std::string kind_label(rivet_app::ReminderKind kind) const {
    switch (kind) {
      case rivet_app::ReminderKind::sit: return l10n::t("today.sit");
      case rivet_app::ReminderKind::water: return l10n::t("today.water");
      case rivet_app::ReminderKind::micro: return l10n::t("today.micro");
    }
    return "";
  }
};

}  // namespace movebit
