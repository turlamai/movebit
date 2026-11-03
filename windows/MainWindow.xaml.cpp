#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <chrono>
#include <dbghelp.h>
#include <fstream>
#include <stdexcept>

#pragma comment(lib, "dbghelp.lib")
#pragma comment(lib, "shell32.lib")

namespace {

// The launch smoke reported exit-status 0xC0000005 with empty output and the
// runner's WER LocalDumps produced nothing, so the host writes its own
// minidump: an unhandled exception lands as %TEMP%\\movebit-crash.dmp and
// the release job analyzes it on failure.
LONG WINAPI WriteCrashDumpAndContinue(EXCEPTION_POINTERS* info) noexcept {
  wchar_t path[MAX_PATH];
  DWORD const length = ::GetTempPathW(MAX_PATH, path);
  if (length > 0 && length < MAX_PATH - 20) {
    wcscpy_s(path + length, MAX_PATH - length, L"movebit-crash.dmp");
    HANDLE file = ::CreateFileW(path, GENERIC_WRITE, 0, nullptr,
                                CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
      MINIDUMP_EXCEPTION_INFORMATION mei{GetCurrentThreadId(), info, FALSE};
      ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(), file,
                          MiniDumpNormal, &mei, nullptr, nullptr);
      ::CloseHandle(file);
    }
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

namespace winrt::RivetHost::implementation {
namespace {

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  if (wide.empty()) {
    return {};
  }
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            wide.data(), static_cast<int>(wide.size()),
                            result.data(), size, nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

// A GUI process launched from Explorer has NULL standard handles, and the
// embedded Racket runtime (rktio) responds to that by allocating a console
// window on the first stderr write — every start started with a stray black
// terminal showing rivet's diagnostic JSONL. Point the handles at NUL before
// the backend boots so rktio never needs to create a console.
void QuietStdHandles() noexcept {
  for (DWORD const which : {STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
                            STD_ERROR_HANDLE}) {
    HANDLE const current = ::GetStdHandle(which);
    if (current != nullptr && current != INVALID_HANDLE_VALUE) {
      continue;
    }
    HANDLE nul = ::CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
                               FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                               OPEN_EXISTING, 0, nullptr);
    if (nul != INVALID_HANDLE_VALUE) {
      ::SetStdHandle(which, nul);
    }
  }
}

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";

  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  // Replace the stderr JSONL sink with the debugger channel so lifecycle
  // diagnostics stay observable without any console window.
  config.diagnostic_sink = [](rivet::DiagnosticRecord const& record) {
    ::OutputDebugStringW(winrt::to_hstring(
                             "movebit " + diagnostic_json_line(record) + "\n")
                             .c_str());
  };
  return config;
}

}  // namespace

using namespace winrt::Microsoft::UI::Xaml;

MainWindow::MainWindow() {
  QuietStdHandles();
  ::SetUnhandledExceptionFilter(&WriteCrashDumpAndContinue);
  InitializeComponent();
  dispatcher_ = DispatcherQueue();
  Title(L"MoveBit");
  SetWindowIconFromResources();
  // Tray-app behavior: closing the window parks MoveBit in the tray; real
  // quit goes through the tray menu (really_quitting_).
  AppWindow().Closing(
      [this](Microsoft::UI::Windowing::AppWindow const&,
             Microsoft::UI::Windowing::AppWindowClosingEventArgs const& args) {
        wchar_t acceptance[2]{};
        if (::GetEnvironmentVariableW(L"MOVEBIT_ACCEPTANCE", acceptance, 2) == 1 &&
            acceptance[0] == L'1') {
          really_quitting_ = true;
          return;
        }
        if (really_quitting_) return;
        args.Cancel(true);
        HideToTray();
      });
  Closed([this](IInspectable const&, WindowEventArgs const&) {
    // Best-effort flush with a 1 s budget (port of FlushToday-on-exit).
    tray_.Detach();
    if (api_ != nullptr) {
      auto future = api_->flush_now();
      (void)future.wait_for(std::chrono::seconds(1));
    }
    // A real close IS the quit, and it must be UNCONDITIONAL: the packaged
    // acceptance repeatedly caught the backend cleanly shut down (its own
    // shutdown frame recorded) with the UI gone, yet the process lingering
    // past the e2e's 30 s exit budget — some stray message source kept the
    // loop alive. Everything worth a graceful teardown has already happened
    // above (tray detached, day flushed, backend stopped); hiding to the
    // tray cancels the close upstream and never reaches this handler.
    ::ExitProcess(0);
  });
  InitTray();
  ApplyTexts();
  InitializeBackendAsync();
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());

  try {
    // Booting the embedded runtime can block on file I/O, so only startup is
    // moved off the UI thread. RPC/State traffic below is completion-driven.
    co_await winrt::resume_background();
    backend->start();

    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        try {
          window->api_ = new rivet_app::API(*window->backend_);
          window->SubscribeEvents();
          window->api_->initialize_async(
              [weak](rivet_app::Result<void> init) {
                (void)init;
                if (auto self = weak.get()) {
                  // Re-dispatch: the completion runs on the reader thread.
                  self->dispatcher_.TryEnqueue([weak] {
                    if (auto w = weak.get()) {
                      if (w->api_ == nullptr) return;
                      (void)w->api_->get_active_config_async(
                          [weak](rivet_app::Result<rivet_app::ReminderConfig> c) {
                            if (auto self2 = weak.get()) {
                              self2->dispatcher_.TryEnqueue([weak, c] {
                                if (auto w = weak.get()) {
                                  try {
                                    w->model_.config = c.get();
                                    // The updater needs the install root to
                                    // stage a payload it can swap.
                                    (void)w->api_->set_install_dir_async(
                                        winrt::to_string(
                                            executable_path().parent_path()
                                                .wstring()),
                                        [](rivet_app::Result<void>) {});
                                    w->Bootstrap();
                                    // A previously failed update left its
                                    // marker; surface it once, now that the
                                    // UI is up.
                                    w->HandleUpdateFailureMarker();
                                  } catch (std::exception const& e) {
                                    w->SetStatus(e.what());
                                  }
                                }
                              });
                            }
                          });
                    }
                  });
                }
              });
        } catch (std::exception const& e) {
          window->SetStatus(e.what());
        }
      } else {
        // Never destroy the last Backend reference on its own reader thread.
        std::thread([backend = std::move(backend)]() mutable {
          backend->stop();
        }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetStatus(message);
      }
    });
  }
}

void MainWindow::SubscribeEvents() {
  auto const weak = get_weak();
  backend_->set_event_handler(
      [weak](std::string const& name, rivet::Value const& value) {
        if (auto window = weak.get()) {
          window->dispatcher_.TryEnqueue([weak, name, value] {
            if (auto self = weak.get()) self->HandleEvent(name, value);
          });
        }
      });
}

void MainWindow::Bootstrap() {
  model_.today = rivet_app::DayStats{"", 0, 0, 0, 0, 0};
  auto const weak = get_weak();
  auto const api = api_;

  // Sequential state reads land in model_; the last one renders everything.
  (void)api->get_today_async([weak](rivet_app::Result<rivet_app::DayStats> t) {
    if (auto self = weak.get()) {
      self->dispatcher_.TryEnqueue([weak, t] {
        if (auto w = weak.get()) {
          try {
            w->model_.today = t.get();
          } catch (std::exception const& e) {
            w->SetStatus(e.what());
            return;
          }
          (void)w->api_->get_paused_async(
              [weak](rivet_app::Result<rivet_app::PauseState> p) {
                if (auto self2 = weak.get()) {
                  self2->dispatcher_.TryEnqueue([weak, p] {
                    if (auto w = weak.get()) {
                      try {
                        w->model_.paused = p.get();
                      } catch (std::exception const& e) {
                        w->SetStatus(e.what());
                        return;
                      }
                      (void)w->api_->get_loops_async(
                          [weak](rivet_app::Result<std::vector<rivet_app::LoopInfo>> l) {
                            if (auto self3 = weak.get()) {
                              self3->dispatcher_.TryEnqueue([weak, l] {
                                if (auto w = weak.get()) {
                                  try {
                                    w->model_.loops = l.get();
                                  } catch (std::exception const& e) {
                                    w->SetStatus(e.what());
                                    return;
                                  }
                                  (void)w->api_->get_pending_cues_async(
                                      [weak](rivet_app::Result<
                                          std::vector<rivet_app::HealthCue>>
                                          q) {
                                        if (auto self4 = weak.get()) {
                                          self4->dispatcher_.TryEnqueue([weak, q] {
                                            if (auto w = weak.get()) {
                                              try {
                                                w->model_.pending_cues = q.get();
                                              } catch (std::exception const& e) {
                                                w->SetStatus(e.what());
                                                return;
                                              }
                                              // Everything is loaded: render.
                                              w->language_ =
                                                  movebit::resolve_language(
                                                      w->model_.config.language);
                                              l10n::g_language = w->language_;
                                              w->ApplyTexts();
                                              w->RefreshTodayCard();
                                              w->RefreshHistoryCard();
                                              w->RefreshInsightCard();
                                              w->RefreshSettingsWidgets();
                                              w->companion_.ApplyConfig(
                                                  w->model_.config
                                                      .companion_size,
                                                  w->model_.config
                                                      .companion_motion,
                                                  w->model_.config
                                                      .companion_dock,
                                                  w->model_.config
                                                      .companion_labels);
                                              w->companion_.ShowIdle();
                                              w->ReloadHistory();
                                              w->ReloadAutostart();
                                              w->ReloadDataDir();
                                              if (!w->model_.config
                                                        .welcome_shown) {
                                                w->ShowOnboarding();
                                              }
                                              w->SetStatus("");
                                            }
                                          });
                                        }
                                      });
                                }
                              });
                            }
                          });
                    }
                  });
            }
          });
        }
      });
    }
  });
}

// ---- events -------------------------------------------------------------------

void MainWindow::HandleEvent(std::string const& name, rivet::Value const& value) {
  try {
    auto event = rivet_app::decode_event(name, value);
    std::visit(
        [&](auto const& e) {
          using T = std::decay_t<decltype(e)>;
          if constexpr (std::is_same_v<T, rivet_app::Tick_statsEvent>) {
            // Synced-in shards from other devices move the aggregate without
            // any local activity; when the totals move, pick the history
            // chart up on the same tick instead of waiting for a restart.
            bool const history_dirty =
                model_.today.active_mins != e.value.active_mins ||
                model_.today.sit_breaks != e.value.sit_breaks ||
                model_.today.water_reminders != e.value.water_reminders ||
                model_.today.micro_breaks != e.value.micro_breaks;
            model_.today = e.value;
            RefreshTodayCard();
            RefreshInsightCard();
            RefreshStatesAfterTick();
            if (history_dirty) ReloadHistory();
          } else if constexpr (std::is_same_v<T, rivet_app::Health_cueEvent>) {
            HandleHealthCue(e.value);
          } else if constexpr (std::is_same_v<T,
                                  rivet_app::Cue_acknowledgedEvent>) {
            HandleCueAcknowledged(e.value);
          } else if constexpr (std::is_same_v<T, rivet_app::Day_completedEvent>) {
            model_.today = e.value;
            RefreshTodayCard();
            RefreshInsightCard();
            ReloadHistory();
          } else if constexpr (std::is_same_v<T, rivet_app::Config_changedEvent>) {
            ApplyConfig(e.value, false);
          }
        },
        event);
  } catch (std::exception const&) {
    // Unknown events are ignored (forward compatibility).
  }
}

void MainWindow::HandleHealthCue(rivet_app::HealthCue const& cue) {
  // The backend planned the delivery; the host only renders it. The Mubi
  // companion is the v1 default; the R1 cards stay as the notification
  // fallback path.
  auto const weak = get_weak();
  if (cue.delivery == rivet_app::CueDelivery::character) {
    if (model_.config.sound_enabled) {
      ::MessageBeep(MB_ICONASTERISK);
    }
    using State = MubiCompanion::MubiState;
    State state = State::Idle;
    switch (cue.action) {
      case rivet_app::CueAction::stand_and_stretch: state = State::Stand; break;
      case rivet_app::CueAction::drink_water: state = State::Water; break;
      case rivet_app::CueAction::rest_eyes: state = State::Eyes; break;
      default: state = State::Idle; break;
    }
    std::wstring message;
    if (cue.kinds.size() > 1) {
      // Racket merges simultaneous due events (also Focus resume) into
      // ONE cue. The gesture shows its first kind; the text must name all.
      std::vector<std::string> parts;
      auto has = [&cue](rivet_app::ReminderKind kind) {
        return std::find(cue.kinds.begin(), cue.kinds.end(), kind) !=
               cue.kinds.end();
      };
      if (has(rivet_app::ReminderKind::sit))
        parts.push_back(l10n::t("notif.sitTitle"));
      if (has(rivet_app::ReminderKind::water))
        parts.push_back(l10n::t("notif.waterTitle"));
      if (has(rivet_app::ReminderKind::micro))
        parts.push_back(l10n::t("micro.defaultTitle"));
      std::string joined;
      for (auto const& part : parts) {
        if (!joined.empty()) joined += " / ";
        joined += part;
      }
      message = wide(joined);
    } else {
      switch (cue.action) {
        case rivet_app::CueAction::drink_water:
          message = wide(movebit::pick_water()); break;
        case rivet_app::CueAction::rest_eyes:
          message = wide(l10n::t("micro.defaultTitle")); break;
        case rivet_app::CueAction::stand_and_stretch:
          message = wide(l10n::t("notif.sitTitle")); break;
        default: break;
      }
    }
    companion_.Show(state, message);
    CueDisplayed(cue.id);
    RefreshTrayState();
    return;
  }
  if (model_.config.sound_enabled) {
    ::MessageBeep(MB_ICONASTERISK);
  }
  auto const& kinds = cue.kinds;
  if (kinds.size() == 1 && kinds[0] == rivet_app::ReminderKind::micro) {
    micro_.on_done = [weak](std::int64_t id) {
      if (auto self = weak.get()) {
        (void)self->api_->acknowledge_cue_async(id,
                                                [](rivet_app::Result<void>) {});
      }
    };
    micro_.on_hide = [weak](std::int64_t id) {
      if (auto self = weak.get()) {
        (void)self->api_->dismiss_cue_async(id, [](rivet_app::Result<void>) {});
      }
    };
    micro_.Show(model_.config.micro_break_duration_seconds,
                movebit::pick_micro(), cue.id);
    CueDisplayed(cue.id);
    return;
  }

  std::vector<std::string> lines;
  if (std::find(kinds.begin(), kinds.end(),
                rivet_app::ReminderKind::sit) != kinds.end()) {
    lines.push_back(l10n::t("notif.sitBody",
                            {l10n::A(movebit::format_duration(
                                 model_.today.active_mins)),
                             l10n::A(model_.today.sit_breaks)}));
    lines.push_back(l10n::pick("copy.sitToastPool", 6));
  }
  if (std::find(kinds.begin(), kinds.end(),
                rivet_app::ReminderKind::water) != kinds.end()) {
    lines.push_back(
        l10n::t("notif.waterCount", {l10n::A(model_.today.water_reminders)}));
    lines.push_back(movebit::pick_water());
  }
  if (std::find(kinds.begin(), kinds.end(),
                rivet_app::ReminderKind::micro) != kinds.end()) {
    lines.push_back(movebit::pick_micro());
  }

  std::string title = l10n::t("notif.sitTitle");
  auto accent = rivet_app::ReminderKind::sit;
  if (std::find(kinds.begin(), kinds.end(),
                rivet_app::ReminderKind::water) != kinds.end()) {
    title = l10n::t("notif.waterTitle");
    accent = rivet_app::ReminderKind::water;
  }

  toast_.on_done = [weak](std::int64_t id) {
    if (auto self = weak.get()) {
      (void)self->api_->acknowledge_cue_async(id,
                                              [](rivet_app::Result<void>) {});
    }
  };
  toast_.on_snooze = [weak](std::int64_t id) {
    if (auto self = weak.get()) {
      (void)self->api_->snooze_cue_async(id, [](rivet_app::Result<void>) {});
    }
  };
  toast_.on_hide = [weak](std::int64_t id) {
    if (auto self = weak.get()) {
      (void)self->api_->dismiss_cue_async(id, [](rivet_app::Result<void>) {});
    }
  };
  toast_.Show(title, lines, accent, cue.id, model_.config.snooze_minutes);
  CueDisplayed(cue.id);
  RefreshTrayState();
}

void MainWindow::HandleCueAcknowledged(
    rivet_app::CueAcknowledged const& acked) {
  // Milestone cheer for SELF-REPORTED sit acknowledgments — a cheer claims
  // nothing clinical (charter #51).
  if (acked.kind != rivet_app::ReminderKind::sit) return;
  bool const milestone =
      acked.count_today == 3 || acked.count_today == 5 || acked.count_today == 8;
  if (!milestone) return;
  toast_.Show(
      l10n::t("notif.cheerTitle"),
      {l10n::t("notif.cheerBody",
               {l10n::A(acked.count_today),
                l10n::A(movebit::format_duration(model_.today.active_mins))})},
      rivet_app::ReminderKind::sit, 0, model_.config.snooze_minutes);
}

void MainWindow::CueDisplayed(std::int64_t id) {
  (void)api_->cue_displayed_async(id, [](rivet_app::Result<void>) {});
}

void MainWindow::RefreshStatesAfterTick() {
  if (api_ == nullptr) return;
  auto const weak = get_weak();
  (void)api_->get_pending_cues_async(
      [weak](rivet_app::Result<std::vector<rivet_app::HealthCue>> r) {
        if (auto self = weak.get()) {
          self->dispatcher_.TryEnqueue([weak, r] {
            if (auto w = weak.get()) {
              try {
                if (r.succeeded()) w->model_.pending_cues = r.get();
              } catch (std::exception const&) {
              }
              w->RefreshTrayState();
            }
          });
        }
      });
  (void)api_->get_loops_async([weak](rivet_app::Result<
                                     std::vector<rivet_app::LoopInfo>> r) {
    if (auto self = weak.get()) {
      self->dispatcher_.TryEnqueue([weak, r] {
        if (auto w = weak.get()) {
          try {
            w->model_.loops = r.get();
            w->RefreshTodayCard();
          } catch (std::exception const&) {
          }
        }
      });
    }
  });
  (void)api_->get_paused_async([weak](rivet_app::Result<rivet_app::PauseState> r) {
    if (auto self = weak.get()) {
      self->dispatcher_.TryEnqueue([weak, r] {
        if (auto w = weak.get()) {
          try {
            w->model_.paused = r.get();
            w->RefreshTodayCard();
          } catch (std::exception const&) {
          }
        }
      });
    }
  });
}


void MainWindow::ApplyConfig(rivet_app::ReminderConfig const& changed,
                             bool announce) {
  // Compare against the host's LIVE language, not the cached config: the
  // settings UI writes optimistic drafts into model_.config, so the cached
  // language can already match the incoming one before the host has ever
  // rebuilt in it.
  bool const language_changed =
      movebit::resolve_language(changed.language) != language_;
  model_.config = changed;
  companion_.ApplyConfig(changed.companion_size, changed.companion_motion,
                         changed.companion_dock, changed.companion_labels);
  language_ = movebit::resolve_language(changed.language);
  l10n::g_language = language_;
  if (language_changed || announce) {
    ApplyTexts();
  }
  RefreshTodayCard();
  RefreshHistoryCard();
  RefreshInsightCard();
  RefreshSettingsWidgets();
  RefreshFooter();
}

// ---- config mutations -------------------------------------------------------------

template <typename F>
void MainWindow::MutateConfig(F mutate) {
  // WinUI fires NumberBox::ValueChanged and ToggleSwitch::Toggled while the
  // XAML tree loads — long before the embedded backend (and api_) exists.
  if (api_ == nullptr) return;
  auto const previous = model_.config;
  auto draft = previous;
  mutate(draft);
  model_.config = draft;
  // The live language is NOT switched here: ApplyConfig (the backend's
  // config-changed broadcast) owns it. An optimistic switch would make
  // ApplyConfig's language_changed check miss the toggle — the host kept
  // rendering stale-language static labels after switching (same bug shape
  // as the GTK host's, fixed there in the same slice).
  auto const weak = get_weak();
  // Optimistic save; the backend clamps and re-announces via config-changed.
  // Completions run on the backend reader thread — re-dispatch.
  (void)api_->set_config_async(draft, [weak, previous](
                                          rivet_app::Result<void> result) {
    if (auto self = weak.get()) {
      self->dispatcher_.TryEnqueue([weak, previous, result] {
        if (auto w = weak.get()) {
          if (result.succeeded()) {
            w->model_.config_status =
                l10n::t("set.statusSaved", {l10n::T(movebit::now_ms())});
          } else {
            w->model_.config = previous;  // roll back the optimistic draft
            w->model_.config_status = l10n::t("set.statusSaveFailed");
          }
          w->RefreshStatusMarker();
        }
      });
    }
  });
  model_.config_status = l10n::t("set.statusSaved", {l10n::T(movebit::now_ms())});
  RefreshStatusMarker();
}

void MainWindow::SaveConfig(rivet_app::ReminderConfig draft) {
  MutateConfig([&draft](rivet_app::ReminderConfig& d) { d = draft; });
}

void MainWindow::RefreshStatusMarker() {
  if (ConfigStatus() != nullptr) {
    ConfigStatus().Text(winrt::to_hstring(
        model_.config_status.empty() ? l10n::t("set.statusDefault")
                                     : model_.config_status));
  }
}

// ---- refresh ---------------------------------------------------------------------

void MainWindow::SetStatus(std::string const& message) {
  // The bar is startup/error feedback only: informational while booting, red
  // on failure, closed once everything is fine (an open Success-severity bar
  // read as a permanent green strip the user could not explain away).
  StatusBar().Message(winrt::to_hstring(message));
  StatusBar().Severity(
      message.empty()
          ? Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational
          : Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().IsOpen(!message.empty());
}

void MainWindow::SetWindowIconFromResources() {
  apply_window_icon(*this);
}

// Update failure text must leave the screen with the user (family UPDATE.md
// rule): whatever lands in the hint is remembered and the 复制错误信息 /
// Copy error button (UpdCopyError) puts exactly that string on the
// clipboard — a bug report starts from this string.
void MainWindow::ShowUpdateErrorHint(winrt::hstring const& text) {
  last_update_error_ = text;
  AboutCheckHint().Text(text);
  UpdateCopyErrorButton().Visibility(Visibility::Visible);
}

void MainWindow::ClearUpdateErrorHint() {
  last_update_error_.clear();
  UpdateCopyErrorButton().Visibility(Visibility::Collapsed);
}

void MainWindow::UpdateCopyError_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  try {
    winrt::Windows::ApplicationModel::DataTransfer::DataPackage package;
    package.SetText(last_update_error_);
    winrt::Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(
        package);
  } catch (...) {
    // The clipboard can be briefly held by another process; the failure is
    // still on screen to copy by selection.
  }
}

// A failed update leaves update-failed.txt next to the apply helper (the
// data dir's updates/); the helper already restored the old install before
// this ever runs, so this one-time hint is the receipt, not an alarm (the
// taskly marker shape). Deleting the marker is what makes it once.
void MainWindow::HandleUpdateFailureMarker() {
  if (api_ == nullptr) return;
  auto const weak = get_weak();
  (void)api_->get_data_dir_async([weak](rivet_app::Result<std::string> r) {
    if (auto outer = weak.get()) {
      outer->dispatcher_.TryEnqueue([weak, r] {
        if (auto w = weak.get()) {
          if (w->api_ == nullptr) return;
          try {
            std::filesystem::path const data_dir(
                winrt::to_hstring(r.get()).c_str());
            std::filesystem::path const marker =
                data_dir / L"updates" / L"update-failed.txt";
            std::error_code ec;
            if (!std::filesystem::exists(marker, ec)) return;
            std::ifstream in(marker);
            std::string reason((std::istreambuf_iterator<char>(in)),
                               std::istreambuf_iterator<char>());
            std::filesystem::remove(marker, ec);
            w->ShowUpdateErrorHint(winrt::to_hstring(
                l10n::t("upd.failed") + " (" + reason + ")"));
          } catch (std::exception const& e) {
            w->SetStatus(e.what());
          } catch (...) {
          }
        }
      });
    }
  });
}

void MainWindow::UpdateCheck_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (api_ == nullptr) return;
  // The button is the state machine: check -> download -> restart-install.
  if (update_phase_ == "available" || update_phase_ == "cancelled") {
    StartUpdateDownload();
    return;
  }
  if (update_phase_ == "ready") {
    ApplyStagedUpdate();
    return;
  }
  update_phase_ = "checking";
  UpdateCheckButton().IsEnabled(false);
  UpdateCheckButton().Content(
      winrt::box_value(winrt::to_hstring(l10n::t("upd.checkingShort"))));
  AboutCheckHint().Text(winrt::to_hstring(l10n::t("upd.checking")));
  auto const weak = get_weak();
  (void)api_->check_updates_async(
      [weak](rivet_app::Result<rivet_app::UpdateCheck> r) {
        if (auto w = weak.get()) {
          w->dispatcher_.TryEnqueue([weak, r] {
            if (auto self = weak.get()) self->HandleUpdateCheck(r);
          });
        }
      });
}

void MainWindow::HandleUpdateCheck(
    rivet_app::Result<rivet_app::UpdateCheck> const& r) {
  UpdateCheckButton().IsEnabled(true);
  try {
    auto const check = r.get();
    if (check.status == "available") {
      update_phase_ = "available";
      ClearUpdateErrorHint();
      UpdateCheckButton().Content(winrt::box_value(
          winrt::to_hstring(l10n::t("upd.actionUpdate"))));
      AboutCheckHint().Text(winrt::to_hstring(l10n::t(
          "upd.found", {l10n::A(check.available_version.value_or(""))})));
      return;
    }
    if (check.status == "up-to-date") {
      update_phase_ = "up-to-date";
      ClearUpdateErrorHint();
      UpdateCheckButton().Content(winrt::box_value(
          winrt::to_hstring(l10n::t("about.checkUpdates"))));
      AboutCheckHint().Text(winrt::to_hstring(l10n::t(
          "upd.currentUpToDate", {l10n::A(check.current_version)})));
      return;
    }
    update_phase_ = "error";
    UpdateCheckButton().Content(winrt::box_value(
        winrt::to_hstring(l10n::t("upd.actionRetry"))));
    // Show the real reason: check failures are network/signing conditions,
    // not user mistakes, and "try again later" alone hides which one.
    ShowUpdateErrorHint(winrt::to_hstring(
        check.error.value_or(l10n::t("upd.checkFailed"))));
  } catch (std::exception const& e) {
    update_phase_ = "error";
    UpdateCheckButton().Content(winrt::box_value(
        winrt::to_hstring(l10n::t("about.checkUpdates"))));
    ShowUpdateErrorHint(winrt::to_hstring(l10n::t("upd.checkFailed")));
    SetStatus(e.what());
  }
}

void MainWindow::StartUpdateDownload() {
  update_phase_ = "downloading";
  update_download_start_tick_ = GetTickCount64();
  UpdateCheckButton().IsEnabled(false);
  UpdateCheckButton().Content(winrt::box_value(
      winrt::to_hstring(l10n::t("upd.actionUpdating"))));
  UpdateCancelButton().Visibility(Visibility::Visible);
  UpdateCancelButton().Content(winrt::box_value(
      winrt::to_hstring(l10n::t("upd.actionCancel"))));
  AboutCheckHint().Text(
      winrt::to_hstring(l10n::t("upd.downloading", {l10n::A("")})));
  auto const weak = get_weak();
  (void)api_->start_update_download_async([weak](rivet_app::Result<void> r) {
    if (auto outer = weak.get()) {
      outer->dispatcher_.TryEnqueue([weak, r] {
        if (auto w = weak.get()) {
          if (r.succeeded()) {
            // Progress arrives through the state snapshot; poll it.
            w->update_progress_timer_ = make_timer(
                std::chrono::milliseconds(700), true, [weak] {
              if (auto window = weak.get()) window->PollUpdateProgress();
            });
            w->update_progress_timer_.Start();
          } else {
            try {
              std::rethrow_exception(r.error);
            } catch (std::exception const& e) {
              w->ShowUpdateErrorHint(
                  winrt::to_hstring(std::string("start failed: ") + e.what()));
              w->SetStatus(e.what());
            }
            w->update_phase_ = "error";
            w->update_download_start_tick_ = 0;
            w->UpdateCancelButton().Visibility(Visibility::Collapsed);
            w->UpdateCheckButton().IsEnabled(true);
            w->UpdateCheckButton().Content(winrt::box_value(
                winrt::to_hstring(l10n::t("upd.actionRetry"))));
          }
        }
      });
    }
  });
}

// The start RPC doubles as the cancel gesture (the backend's toggle
// contract): this call cancels the in-flight download, and the poll loop
// observes the idle phase — the card flips to the cancelled state, which
// offers the update again. A cancel is not a failure, so no error hint.
void MainWindow::UpdateCancel_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (api_ == nullptr || update_phase_ != "downloading") return;
  (void)api_->start_update_download_async([](rivet_app::Result<void>) {});
}

void MainWindow::PollUpdateProgress() {
  if (api_ == nullptr || update_phase_ != "downloading") return;
  // Host-side backstop: the backend's own watchdog (stall 120 s / total
  // 30 min) normally lands the terminal state first; if the backend itself
  // is wedged, break out of an endless progress bar — fire the cancel
  // toggle so a half-alive backend resets too, then render the failure.
  if (update_download_start_tick_ != 0 &&
      GetTickCount64() - update_download_start_tick_ >
          30ULL * 60 * 1000) {
    auto const weak = get_weak();
    (void)api_->start_update_download_async([](rivet_app::Result<void>) {});
    dispatcher_.TryEnqueue([weak] {
      if (auto w = weak.get()) {
        if (w->update_phase_ != "downloading") return;
        if (w->update_progress_timer_) w->update_progress_timer_.Stop();
        w->update_download_start_tick_ = 0;
        w->UpdateCancelButton().Visibility(Visibility::Collapsed);
        w->update_phase_ = "error";
        w->UpdateCheckButton().IsEnabled(true);
        w->UpdateCheckButton().Content(winrt::box_value(
            winrt::to_hstring(l10n::t("upd.actionRetry"))));
        w->ShowUpdateErrorHint(
            winrt::to_hstring(l10n::t("upd.checkFailed")));
      }
    });
    return;
  }
  auto const weak = get_weak();
  (void)api_->get_update_state_async(
      [weak](rivet_app::Result<rivet_app::UpdateState> r) {
        if (auto outer = weak.get()) {
          outer->dispatcher_.TryEnqueue([weak, r] {
            if (auto w = weak.get()) {
              // A throwing completion here would take the whole XAML thread
              // down (0xc000027b); every failure becomes a Retry state.
              try {
                if (w->update_phase_ != "downloading") return;
                auto const state = r.get();
                auto const percent = state.percent;
                w->AboutCheckHint().Text(winrt::to_hstring(
                    l10n::t("upd.downloadingPct",
                            {l10n::A(state.available_version.value_or("")),
                             l10n::A(percent)})));
                if (state.phase == "idle") {
                  // The cancel gesture landed: back to the offer, with the
                  // update still one click away.
                  if (w->update_progress_timer_)
                    w->update_progress_timer_.Stop();
                  w->update_download_start_tick_ = 0;
                  w->UpdateCancelButton().Visibility(Visibility::Collapsed);
                  w->update_phase_ = "cancelled";
                  w->ClearUpdateErrorHint();
                  w->UpdateCheckButton().IsEnabled(true);
                  w->UpdateCheckButton().Content(winrt::box_value(
                      winrt::to_hstring(l10n::t("upd.actionUpdate"))));
                  w->AboutCheckHint().Text(winrt::to_hstring(
                      l10n::t("upd.cancelled")));
                  return;
                }
                if (state.phase == "downloaded" || state.phase == "error") {
                  if (w->update_progress_timer_)
                    w->update_progress_timer_.Stop();
                  w->update_download_start_tick_ = 0;
                  w->UpdateCancelButton().Visibility(Visibility::Collapsed);
                  if (state.phase == "error") {
                    w->ShowUpdateErrorHint(winrt::to_hstring(
                        state.message.value_or(
                            l10n::t("upd.checkFailed"))));
                  }
                  if (state.phase == "downloaded") {
                    w->update_phase_ = "ready";
                    w->ClearUpdateErrorHint();
                    w->UpdateCheckButton().IsEnabled(true);
                    w->UpdateCheckButton().Content(winrt::box_value(
                        winrt::to_hstring(
                            l10n::t("upd.actionRestartInstall"))));
                    w->AboutCheckHint().Text(winrt::to_hstring(
                        l10n::t("upd.restartPrep",
                                {l10n::A(
                                    state.available_version.value_or(""))})));
                  } else {
                    w->update_phase_ = "error";
                    w->UpdateCheckButton().IsEnabled(true);
                    w->UpdateCheckButton().Content(winrt::box_value(
                        winrt::to_hstring(l10n::t("upd.actionRetry"))));
                  }
                }
              } catch (std::exception const& e) {
                if (w->update_progress_timer_)
                  w->update_progress_timer_.Stop();
                w->update_phase_ = "error";
                w->UpdateCheckButton().IsEnabled(true);
                w->UpdateCheckButton().Content(winrt::box_value(
                    winrt::to_hstring(l10n::t("upd.actionRetry"))));
                w->ShowUpdateErrorHint(
                    winrt::to_hstring(std::string("poll: ") + e.what()));
                w->SetStatus(e.what());
              } catch (...) {
                if (w->update_progress_timer_)
                  w->update_progress_timer_.Stop();
                w->update_phase_ = "error";
                w->UpdateCheckButton().IsEnabled(true);
                w->UpdateCheckButton().Content(winrt::box_value(
                    winrt::to_hstring(l10n::t("upd.actionRetry"))));
                w->ShowUpdateErrorHint(
                    winrt::to_hstring(L"poll: non-standard exception"));
              }
            }
          });
        }
      });
}
void MainWindow::ApplyStagedUpdate() {
  update_phase_ = "applying";
  UpdateCheckButton().IsEnabled(false);
  AboutCheckHint().Text(
      winrt::to_hstring(l10n::t("upd.restarting")));
  auto const weak = get_weak();
  (void)api_->prepare_update_install_async(
      [weak](rivet_app::Result<std::string> r) {
        if (auto outer = weak.get()) {
          outer->dispatcher_.TryEnqueue([weak, r] {
            if (auto w = weak.get()) {
            try {
              // The backend extracted the staged payload AND spawned the
              // detached helper (it waits for this process to exit, swaps,
              // relaunches). Our only job: quit cleanly so the flush runs.
              (void)r.get();
              w->really_quitting_ = true;
              w->Close();
            } catch (std::exception const& e) {
              // Most common cause: the install directory is not writable
              // (MSI into Program Files) — point at the releases page.
              w->update_phase_ = "error";
              w->UpdateCheckButton().IsEnabled(true);
              w->UpdateCheckButton().Content(winrt::box_value(
                  winrt::to_hstring(l10n::t("upd.actionRetry"))));
              w->SetStatus(e.what());
              ::ShellExecuteW(
                  nullptr, L"open",
                  L"https://github.com/turlamai/movebit/releases/latest",
                  nullptr, nullptr, SW_SHOWNORMAL);
            }
            }
          });
        }
      });
}

void MainWindow::ChangeDataDir_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  PickDataFolderAsync();
}

// Folder picker -> backend set-data-dir (validated + persisted into the
// bootstrap file outside the synced data) -> applied on next launch.
winrt::fire_and_forget MainWindow::PickDataFolderAsync() {
  if (api_ == nullptr) co_return;

  Windows::Storage::Pickers::FolderPicker picker;
  picker.FileTypeFilter().Append(L"*");
  // Unpackaged WinUI needs the picker bound to a real HWND.
  auto window_native = try_as<::IWindowNative>();
  if (window_native) {
    HWND hwnd = nullptr;
    if (SUCCEEDED(window_native->get_WindowHandle(&hwnd)) && hwnd) {
      if (auto init = picker.try_as<::IInitializeWithWindow>()) {
        init->Initialize(hwnd);
      }
    }
  }

  auto folder = co_await picker.PickSingleFolderAsync();
  if (!folder || api_ == nullptr) co_return;

  auto const path = winrt::to_string(folder.Path());
  auto const weak = get_weak();
  auto const dispatcher = dispatcher_;
  (void)api_->set_data_dir_async(
      path, [weak, dispatcher, path](rivet_app::Result<void> result) {
        dispatcher.TryEnqueue([weak, result, path] {
          if (auto window = weak.get()) {
            if (result.succeeded()) {
              window->model_.config_status =
                  l10n::t("about.dataFolderApplied");
              window->RefreshStatusMarker();
              window->DataFolderValue().Text(winrt::to_hstring(path));
            } else {
              try {
                std::rethrow_exception(result.error);
              } catch (std::exception const& e) {
                window->SetStatus(e.what());
              }
            }
          }
        });
      });
}

void MainWindow::ApplyTexts() {
  TodayTitle().Text(winrt::to_hstring(l10n::t("today.title")));
  SitCycleCaption().Text(winrt::to_hstring(l10n::t("today.sitCycle")));
  TodaySitCaption().Text(winrt::to_hstring(l10n::t("today.sit")));
  TodayWaterCaption().Text(winrt::to_hstring(l10n::t("today.water")));
  TodayMicroCaption().Text(winrt::to_hstring(l10n::t("today.micro")));
  TodayCountsNote().Text(winrt::to_hstring(l10n::t("today.countsNote")));
  InsightTitleLabel().Text(winrt::to_hstring(l10n::t("insight.title")));
  InsightCurrentTitle().Text(winrt::to_hstring(l10n::t("insight.current")));
  InsightTodayLongestTitle().Text(
      winrt::to_hstring(l10n::t("insight.todayLongest")));
  InsightRecentLongestTitle().Text(
      winrt::to_hstring(l10n::t("insight.recentLongest")));
  InsightRecentAvgTitle().Text(
      winrt::to_hstring(l10n::t("insight.recentAvg")));
  InsightBusiestLabel().Text(winrt::to_hstring(l10n::t("insight.busiest")));
  SettingsTitle().Text(winrt::to_hstring(l10n::t("set.title")));
  SettingsIntro().Text(winrt::to_hstring(l10n::t("set.intro")));
  SetSitLabel().Text(winrt::to_hstring(l10n::t("set.sitInterval")));
  SetWaterLabel().Text(winrt::to_hstring(l10n::t("set.waterInterval")));
  SetAwayLabel().Text(winrt::to_hstring(l10n::t("set.awayReset")));
  SetMubiSizeLabel().Text(winrt::to_hstring(l10n::t("set.mubiSize")));
  SetMubiMotionLabel().Text(winrt::to_hstring(l10n::t("set.mubiMotion")));
  SetMubiDockLabel().Text(winrt::to_hstring(l10n::t("set.mubiDock")));
  SetMubiLabelsLabel().Text(winrt::to_hstring(l10n::t("set.mubiLabels")));
  SetMotionLabel().Text(winrt::to_hstring(l10n::t("set.motion")));
  SetSnoozeLabel().Text(winrt::to_hstring(l10n::t("set.snooze")));
  SetMicroLabel().Text(winrt::to_hstring(l10n::t("set.microToggle")));
  SetMicroParamsLabel().Text(winrt::to_hstring(l10n::t("set.microParams")));
  SetSoundLabel().Text(winrt::to_hstring(l10n::t("set.sound")));
  SetAutostartLabel().Text(winrt::to_hstring(l10n::t("set.autostart")));
  SetLanguageLabel().Text(winrt::to_hstring(l10n::t("set.language")));
  AboutUpdateLabel().Text(winrt::to_hstring(l10n::t("about.autoUpdate")));
  AboutUpdateHint().Text(winrt::to_hstring(l10n::t("about.autoUpdateHint")));
  AboutCheckLabel().Text(winrt::to_hstring(l10n::t("about.checkUpdates")));
  AboutCheckHint().Text(winrt::to_hstring(l10n::t("about.checkUpdatesHint")));
  UpdateCheckButton().Content(
      winrt::box_value(winrt::to_hstring(l10n::t("about.checkUpdates"))));
  UpdateCopyErrorButton().Content(
      winrt::box_value(winrt::to_hstring(l10n::t("upd.copyError"))));
  WebsiteLink().Content(
      winrt::box_value(winrt::to_hstring(l10n::t("about.website"))));
  IssueLink().Content(
      winrt::box_value(winrt::to_hstring(l10n::t("about.reportIssue"))));
  AboutLicenseText().Text(winrt::to_hstring(l10n::t("about.license")));
  DataFolderLabel().Text(winrt::to_hstring(l10n::t("about.dataFolder")));
  DataFolderHint().Text(winrt::to_hstring(l10n::t("about.dataFolderHint")));
  DataFolderButton().Content(
      winrt::box_value(winrt::to_hstring(l10n::t("about.changeDataFolder"))));
  LanguageDrop().Items().GetAt(0).as<Controls::ComboBoxItem>().Content(
      winrt::box_value(winrt::to_hstring(l10n::t("lang.auto"))));
  RefreshStatusMarker();
  RefreshFooter();
}

void MainWindow::RefreshTodayCard() {
  auto const& m = model_;
  TodayDuration().Text(
      winrt::to_hstring(movebit::format_duration(m.today.active_mins)));
  std::wstring status;
  Windows::UI::Color status_color =
      color_from("#16A34A");
  if (m.is_paused()) {
    status_color = color_from("#EA580C");
    auto const until = m.paused.until_ms.value_or(movebit::now_ms());
    status = winrt::to_hstring(
        l10n::t("tpl.pausedUntil", {l10n::T(until)}));
  } else {
    status = winrt::to_hstring(l10n::t("tpl.running"));
  }
  auto const status_hex = status_color.R == 0xEA ? "#EA580C" : "#16A34A";
  TodayStatus().Text(status);
  TodayStatus().Foreground(brush_from(status_hex));
  StatusDot().Background(brush_from(status_hex));
  // The indicator is the control; the tooltip spells out the action.
  Controls::ToolTipService::SetToolTip(
      StatusButton(),
      winrt::box_value(winrt::to_hstring(l10n::t(
          m.is_paused() ? "today.resumeHint" : "today.pauseHint"))));
  tray_.SetPaused(m.is_paused());
  tray_.SetTooltip(winrt::to_hstring(
      m.is_paused()
          ? l10n::t("tray.paused",
                    {l10n::A(""), l10n::T(m.paused.until_ms.value_or(
                         movebit::now_ms()))})
          : l10n::t("tray.running",
                    {l10n::A(""),
                     l10n::A(movebit::format_duration(m.today.active_mins)),
                     l10n::A(m.current_session_mins()),
                     l10n::A(m.config.sit_reminder_minutes)}))
      .c_str());

  double fraction = 0;
  if (!m.is_paused() && m.config.sit_reminder_minutes > 0) {
    fraction = std::min(1.0, std::max(0.0,
        static_cast<double>(m.current_session_mins()) /
        static_cast<double>(m.config.sit_reminder_minutes)));
  }
  SitBar().Value(fraction);

  if (m.is_paused()) {
    SitCycleText().Text(L"—");
  } else {
    SitCycleText().Text(winrt::to_hstring(
        l10n::t("tpl.sitCycleMin", {l10n::A(m.current_session_mins()),
                                   l10n::A(m.config.sit_reminder_minutes)})));
  }
  TodaySit().Text(winrt::to_hstring(m.today.sit_breaks));
  TodayWater().Text(winrt::to_hstring(m.today.water_reminders));
  TodayMicro().Text(winrt::to_hstring(m.today.micro_breaks));
}

void MainWindow::RefreshHistoryCard() {
  auto const is_month = model_.history_days >= 30;
  HistTitle().Text(winrt::to_hstring(
      l10n::t(is_month ? "hist.range30" : "hist.range7")));
  auto slices = movebit::history_slice(
      model_.history_days, [this] { return model_.today; },
      [this] { return model_.history; });
  std::int64_t total = 0;
  for (auto const& s : slices) total += s.stats.active_mins;
  HistTotal().Text(winrt::to_hstring(
      total >= 60
          ? l10n::t("hist.totalLong", {l10n::A(total / 60), l10n::A(total % 60)})
          : l10n::t("hist.totalShort", {l10n::A(total)})));
  ShowHistoryBars();
}

void MainWindow::ShowHistoryBars() {
  auto const slices = movebit::history_slice(
      model_.history_days, [this] { return model_.today; },
      [this] { return model_.history; });
  auto const is_month = model_.history_days >= 30;
  std::int64_t max_minutes = 60;
  for (auto const& s : slices) {
    max_minutes = std::max(max_minutes, s.stats.active_mins);
  }

  HistChartBars().Children().Clear();
  Controls::Grid columns;
  columns.Height(150);
  for (std::size_t i = 0; i <= slices.size(); ++i) {
    Controls::ColumnDefinition col;
    col.Width(GridLength{1, GridUnitType::Star});
    columns.ColumnDefinitions().Append(col);
  }
  for (std::size_t i = 0; i < slices.size(); ++i) {
    auto const& slice = slices[i];
    auto const bar_max = 110.0;
    auto const bar_min = 5.0;
    double const height =
        bar_min + (bar_max - bar_min) *
                      static_cast<double>(slice.stats.active_mins) /
                      static_cast<double>(max_minutes);
    auto bar = Controls::Border{};
    bar.CornerRadius(CornerRadius{4, 4, 4, 4});
    bar.Background(brush_from(slice.is_today ? "#C25E3E"
                                                             : "#D2C8B2"));
    bar.Height(height);
    bar.Width(is_month ? 8.0 : 26.0);
    bar.VerticalAlignment(VerticalAlignment::Bottom);

    auto cell = Controls::StackPanel{};
    cell.Orientation(Controls::Orientation::Vertical);
    cell.VerticalAlignment(VerticalAlignment::Bottom);
    if (!is_month) {
      auto value = make_text(
          winrt::to_hstring(movebit::format_compact(slice.stats.active_mins)),
          10, slice.is_today,
          slice.is_today ? "#C25E3E" : "#A39B8D");
      cell.Children().Append(value);
    }
    cell.Children().Append(bar);

    std::wstring label;
    if (slice.is_today) {
      label = winrt::to_hstring(l10n::t("hist.today"));
    } else if (!is_month) {
      std::time_t const t =
          static_cast<std::time_t>(slice.day_start_ms / 1000);
      std::tm lt{};
      localtime_s(&lt, &t);
      static wchar_t const* zh_days[] = {L"日", L"一", L"二", L"三", L"四",
                                         L"五", L"六"};
      static wchar_t const* en_days[] = {L"Sun", L"Mon", L"Tue", L"Wed",
                                         L"Thu", L"Fri", L"Sat"};
      label = language_ == "en" ? en_days[lt.tm_wday] : zh_days[lt.tm_wday];
    }
    auto label_block = make_text(
        winrt::to_hstring(label.c_str()), 10.5, slice.is_today,
        slice.is_today ? "#C25E3E" : "#6E6A5E");
    Controls::StackPanel full_cell{};
    full_cell.Orientation(Controls::Orientation::Vertical);
    full_cell.VerticalAlignment(VerticalAlignment::Bottom);
    full_cell.Children().Append(cell);
    full_cell.Children().Append(label_block);
    Controls::Grid wrapper;
    wrapper.Children().Append(full_cell);
    columns.Children().Append(wrapper);
    Controls::Grid::SetColumn(wrapper, static_cast<int>(i));
  }
  HistChartBars().Children().Append(columns);
}

void MainWindow::RefreshInsightCard() {
  auto const slices = movebit::history_slice(
      30, [this] { return model_.today; }, [this] { return model_.history; });
  auto const summary = movebit::insight_summary(slices);
  InsightCurrent().Text(
      winrt::to_hstring(movebit::format_minutes(model_.current_session_mins())));
  InsightTodayLongest().Text(winrt::to_hstring(
      movebit::format_minutes(model_.today.longest_session_mins)));
  InsightRecentLongest().Text(
      winrt::to_hstring(movebit::format_minutes(summary.longest)));
  InsightRecentAvg().Text(
      winrt::to_hstring(movebit::format_minutes(summary.average)));
  std::string busiest_text = l10n::t("insight.none");
  if (summary.has_busiest && summary.busiest.date.size() >= 10) {
    busiest_text = summary.busiest.date.substr(5, 5) + " · " +
                   movebit::format_minutes(summary.busiest.active_mins);
  }
  InsightBusiest().Text(winrt::to_hstring(busiest_text));

  std::int64_t const sit = model_.config.sit_reminder_minutes;
  std::string sedentary;
  if (summary.longest <= 0) {
    sedentary = l10n::t("insight.noData");
  } else if (summary.longest >= sit * 2) {
    sedentary = l10n::t("insight.long2",
                        {l10n::A(movebit::format_minutes(summary.longest))});
  } else if (summary.longest >= sit) {
    sedentary = l10n::t("insight.long1",
                        {l10n::A(movebit::format_minutes(summary.longest))});
  } else {
    sedentary = l10n::t("insight.long0",
                        {l10n::A(movebit::format_minutes(summary.longest))});
  }
  InsightSedentary().Text(winrt::to_hstring(sedentary));
}

void MainWindow::RefreshSettingsWidgets() {
  auto const& c = model_.config;
  updating_settings_ = true;
  SitBox().Value(static_cast<double>(c.sit_reminder_minutes));
  WaterBox().Value(static_cast<double>(c.water_reminder_minutes));
  AwayBox().Value(static_cast<double>(c.away_reset_minutes));
  SnoozeBox().Value(static_cast<double>(c.snooze_minutes));
  MicroIntervalBox().Value(
      static_cast<double>(c.micro_break_interval_minutes));
  MicroDurationBox().Value(
      static_cast<double>(c.micro_break_duration_seconds));
  MotionSwitch().IsOn(c.motion_enabled);
  MubiSizeCombo().SelectedIndex(
      c.companion_size == "S" ? 0 : c.companion_size == "L" ? 2 : 1);
  MubiMotionCombo().SelectedIndex(
      c.companion_motion == "still" ? 0
      : c.companion_motion == "lively" ? 2 : 1);
  MubiDockCombo().SelectedIndex(
      c.companion_dock == "bottom-left" ? 1
      : c.companion_dock == "top-right" ? 2
      : c.companion_dock == "top-left" ? 3 : 0);
  MubiLabelsCombo().SelectedIndex(c.companion_labels == "always" ? 1 : 0);
  MicroSwitch().IsOn(c.micro_break_enabled);
  SoundSwitch().IsOn(c.sound_enabled);
  UpdatesSwitch().IsOn(c.auto_check_updates);
  AutostartSwitch().IsOn(model_.autostart);
  LanguageDrop().SelectedIndex(c.language == "zh" ? 1
                               : c.language == "en" ? 2 : 0);
  HistRange().SelectedIndex(model_.history_days >= 30 ? 1 : 0);
  updating_settings_ = false;
  RefreshStatusMarker();
}

void MainWindow::RefreshFooter() {
  FooterText().Text(winrt::to_hstring(
      model_.data_dir.empty()
          ? L""
          : winrt::to_hstring(
                l10n::t("main.configPath", {l10n::A(model_.data_dir)}))));
  AboutVersion().Text(winrt::to_hstring(
      l10n::t("upd.currentVersion", {l10n::A(rivet_app::kVersion)})));
}

// ---- reloads ------------------------------------------------------------------------

void MainWindow::ReloadHistory() {
  if (api_ == nullptr) return;
  // Always fetch 30 days; the 7/30 toggle is pure client-side slicing.
  auto const weak = get_weak();
  (void)api_->get_history_async(
      30, [weak](rivet_app::Result<std::vector<rivet_app::DayStats>> r) {
        if (auto self = weak.get()) {
          self->dispatcher_.TryEnqueue([weak, r] {
            if (auto w = weak.get()) {
              try {
                w->model_.history = r.get();
                w->RefreshHistoryCard();
                w->RefreshInsightCard();
              } catch (std::exception const& e) {
                w->SetStatus(e.what());
              }
            }
          });
        }
      });
}

void MainWindow::ReloadAutostart() {
  if (api_ == nullptr) return;
  auto const weak = get_weak();
  (void)api_->get_autostart_async([weak](rivet_app::Result<bool> r) {
    if (auto self = weak.get()) {
      self->dispatcher_.TryEnqueue([weak, r] {
        if (auto w = weak.get()) {
          try {
            w->model_.autostart = r.get();
            w->updating_settings_ = true;
            w->AutostartSwitch().IsOn(w->model_.autostart);
            w->updating_settings_ = false;
          } catch (std::exception const&) {
          }
        }
      });
    }
  });
}

void MainWindow::ReloadDataDir() {
  if (api_ == nullptr) return;
  auto const weak = get_weak();
  (void)api_->get_data_dir_async([weak](rivet_app::Result<std::string> r) {
    if (auto self = weak.get()) {
      self->dispatcher_.TryEnqueue([weak, r] {
        if (auto w = weak.get()) {
          try {
            w->model_.data_dir = r.get();
            w->RefreshFooter();
            w->DataFolderValue().Text(winrt::to_hstring(w->model_.data_dir));
          } catch (std::exception const&) {
          }
        }
      });
    }
  });
}

// ---- onboarding ---------------------------------------------------------------------

void MainWindow::ShowOnboarding() {
  auto const weak = get_weak();
  onboarding_.on_finish = [weak](std::int64_t sit, std::int64_t water,
                                 bool sound) {
    if (auto self = weak.get()) {
      self->MutateConfig([&](rivet_app::ReminderConfig& d) {
        d.sit_reminder_minutes = sit;
        d.water_reminder_minutes = water;
        d.sound_enabled = sound;
        d.welcome_shown = true;
      });
      self->toast_.Show(l10n::t("ob.settled"), {l10n::t("ob.settledBody")},
                        rivet_app::ReminderKind::water, {},
                        self->model_.config.snooze_minutes);
    }
  };
  // Title-bar close without finishing still counts as seen (old-app parity:
  // the wizard must not nag on every launch); whatever was selected is kept.
  onboarding_.on_cancel = [weak] {
    if (auto self = weak.get()) {
      self->MutateConfig(
          [&](rivet_app::ReminderConfig& d) { d.welcome_shown = true; });
    }
  };
  onboarding_.Show();
}

// ---- click handlers -------------------------------------------------------------------

void MainWindow::Status_Click(winrt::Windows::Foundation::IInspectable const&,
                              Microsoft::UI::Xaml::RoutedEventArgs const&) {
  TogglePause();
}

void MainWindow::TogglePause() {
  if (api_ == nullptr) return;
  // The backend publishes the paused state, but hosts only re-read states on
  // the 30 s tick; re-pull immediately so the status control flips now.
  auto const weak = get_weak();
  auto const pull = [weak](rivet_app::Result<void>) {
    if (auto self = weak.get()) self->RefreshStatesAfterTick();
  };
  if (model_.is_paused()) {
    (void)api_->resume_async(pull);
  } else {
    (void)api_->pause_1h_async(pull);
  }
}

void MainWindow::InitTray() {
  tray_.on_open = [this]() { BringToForeground(); };
  tray_.on_pause_toggle = [this]() { TogglePause(); };
  tray_.on_mubi_move_aside = [this]() { companion_.MoveAside(); };
  tray_.on_check_updates = [this]() {
    ::ShellExecuteW(nullptr, L"open",
                    L"https://github.com/turlamai/movebit/releases/latest",
                    nullptr, nullptr, SW_SHOWNORMAL);
  };
  // Mandatory reminder controls (#54): act on the newest open cue.
  tray_.on_cue_done = [this]() {
    if (model_.pending_cues.empty()) return;
    auto const id = model_.pending_cues.back().id;
    (void)api_->acknowledge_cue_async(id, [](rivet_app::Result<void>) {});
    companion_.ShowAck();
    RefreshTrayState();
  };
  tray_.on_cue_later = [this]() {
    if (model_.pending_cues.empty()) return;
    auto const id = model_.pending_cues.back().id;
    (void)api_->snooze_cue_async(id, [](rivet_app::Result<void>) {});
    RefreshTrayState();
  };
  tray_.on_cue_hide = [this]() {
    if (model_.pending_cues.empty()) return;
    auto const id = model_.pending_cues.back().id;
    (void)api_->dismiss_cue_async(id, [](rivet_app::Result<void>) {});
    RefreshTrayState();
  };
  tray_.on_focus_toggle = [this]() {
    auto const next = !model_.quiet;
    (void)api_->set_quiet_async(next, [](rivet_app::Result<void>) {});
    model_.quiet = next;
    companion_.SetQuiet(next);
    RefreshTrayState();
  };
  tray_.on_exit = [this]() {
    really_quitting_ = true;
    Close();
  };
  tray_.Attach(*this);
}

void MainWindow::RefreshTrayState() {
  tray_.RefreshCueState(!model_.pending_cues.empty(), model_.quiet);
}

void MainWindow::HideToTray() {
  AppWindow().Hide();
  if (!tray_hint_shown_) {
    tray_hint_shown_ = true;
    tray_.ShowInfo(l10n::t("tray.hideHintTitle"), l10n::t("tray.hideHintBody"));
  }
}

void MainWindow::BringToForeground() {
  AppWindow().Show();
  if (auto window_native = try_as<::IWindowNative>()) {
    HWND hwnd = nullptr;
    if (SUCCEEDED(window_native->get_WindowHandle(&hwnd)) && hwnd) {
      // Show() restores the window; foreground raises it over the current app.
      ::SetForegroundWindow(hwnd);
    }
  }
}

void MainWindow::HistRange_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (updating_settings_) return;
  model_.history_days = HistRange().SelectedIndex() == 1 ? 30 : 7;
  RefreshHistoryCard();
}

void MainWindow::Language_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (updating_settings_) return;
  static char const* values[] = {"auto", "zh", "en"};
  auto const index = LanguageDrop().SelectedIndex();
  if (index < 0 || index > 2) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.language = values[index];
  });
}

void MainWindow::Sit_ValueChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const&) {
  if (updating_settings_) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.sit_reminder_minutes = static_cast<std::int64_t>(SitBox().Value());
  });
}

void MainWindow::Water_ValueChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const&) {
  if (updating_settings_) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.water_reminder_minutes =
        static_cast<std::int64_t>(WaterBox().Value());
  });
}

void MainWindow::Away_ValueChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const&) {
  if (updating_settings_) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.away_reset_minutes = static_cast<std::int64_t>(AwayBox().Value());
  });
}

void MainWindow::Snooze_ValueChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const&) {
  if (updating_settings_) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.snooze_minutes = static_cast<std::int64_t>(SnoozeBox().Value());
  });
}

void MainWindow::MicroInterval_ValueChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const&) {
  if (updating_settings_) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.micro_break_interval_minutes =
        static_cast<std::int64_t>(MicroIntervalBox().Value());
  });
}

void MainWindow::MicroDuration_ValueChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const&) {
  if (updating_settings_) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.micro_break_duration_seconds =
        static_cast<std::int64_t>(MicroDurationBox().Value());
  });
}

void MainWindow::MubiSize_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (updating_settings_) return;
  static char const* values[] = {"S", "M", "L"};
  auto const index = MubiSizeCombo().SelectedIndex();
  if (index < 0 || index > 2) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.companion_size = values[index];
  });
}

void MainWindow::MubiMotion_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (updating_settings_) return;
  static char const* values[] = {"still", "subtle", "lively"};
  auto const index = MubiMotionCombo().SelectedIndex();
  if (index < 0 || index > 2) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.companion_motion = values[index];
  });
}

void MainWindow::MubiDock_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (updating_settings_) return;
  static char const* values[] = {"bottom-right", "bottom-left",
                                 "top-right", "top-left"};
  auto const index = MubiDockCombo().SelectedIndex();
  if (index < 0 || index > 3) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.companion_dock = values[index];
  });
}

void MainWindow::MubiLabels_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (updating_settings_) return;
  static char const* values[] = {"cue", "always"};
  auto const index = MubiLabelsCombo().SelectedIndex();
  if (index < 0 || index > 1) return;
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.companion_labels = values[index];
  });
}

void MainWindow::Motion_Toggled(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (updating_settings_) return;
  auto const on = MotionSwitch().IsOn();
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.motion_enabled = on;
  });
}

void MainWindow::Micro_Toggled(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (updating_settings_) return;
  auto const on = MicroSwitch().IsOn();
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.micro_break_enabled = on;
  });
}

void MainWindow::Sound_Toggled(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (updating_settings_) return;
  auto const on = SoundSwitch().IsOn();
  MutateConfig([&](rivet_app::ReminderConfig& d) { d.sound_enabled = on; });
}

void MainWindow::Autostart_Toggled(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (updating_settings_ || api_ == nullptr) return;
  auto const on = AutostartSwitch().IsOn();
  model_.autostart = on;
  model_.config_status =
      l10n::t("set.statusApplied", {l10n::T(movebit::now_ms())});
  RefreshStatusMarker();
  (void)api_->set_autostart_async(on, [](rivet_app::Result<void>) {});
}

void MainWindow::Updates_Toggled(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (updating_settings_) return;
  auto const on = UpdatesSwitch().IsOn();
  MutateConfig([&](rivet_app::ReminderConfig& d) {
    d.auto_check_updates = on;
  });
}

}  // namespace winrt::RivetHost::implementation
