#pragma once

// Code-built transient windows for the WinUI MoveBit host: the reminder
// toast and the micro eye-rest card. Built in code (no XAML/idl) so each is
// one header; all methods must be called on the UI thread, and all of them
// are owned by MainWindow (which outlives them), so handlers capture `this`
// directly. Mirrors the SwiftUI Overlays.swift behavior. The v1 reboot
// (issue #55) removed the forced-break fullscreen overlay from this file.

#include "pch.h"
#include "MoveBitModel.h"

#include <functional>
#include <string>
#include <vector>

namespace winrt::RivetHost::implementation {

using namespace winrt::Microsoft::UI::Xaml;

namespace {

inline Windows::UI::Color color_from(char const* hex) {
  int r = 0, g = 0, b = 0;
  sscanf_s(hex, "#%02x%02x%02x", &r, &g, &b);
  Windows::UI::Color color;
  color.R = static_cast<BYTE>(r);
  color.G = static_cast<BYTE>(g);
  color.B = static_cast<BYTE>(b);
  color.A = 255;
  return color;
}

inline Media::SolidColorBrush brush_from(char const* hex) {
  Media::SolidColorBrush brush;
  brush.Color(color_from(hex));
  return brush;
}

inline Controls::TextBlock make_text(winrt::hstring const& text, double size,
                                     bool bold, char const* hex_color) {
  Controls::TextBlock block;
  block.Text(text);
  block.FontSize(size);
  if (bold) block.FontWeight(Microsoft::UI::Text::FontWeights::SemiBold());
  block.Foreground(brush_from(hex_color));
  block.TextWrapping(TextWrapping::Wrap);
  block.HorizontalAlignment(HorizontalAlignment::Center);
  return block;
}

inline winrt::hstring wide(std::string const& utf8) {
  return winrt::to_hstring(utf8);
}

inline Controls::Button make_button(winrt::hstring const& content,
                                    char const* background_hex,
                                    char const* foreground_hex,
                                    bool bordered) {
  Controls::Button button;
  button.Content(winrt::box_value(winrt::hstring(content)));
  button.Background(brush_from(background_hex));
  button.Foreground(brush_from(foreground_hex));
  if (!bordered) {
    button.BorderThickness(Thickness{0, 0, 0, 0});
  }
  button.CornerRadius(CornerRadius{7, 7, 7, 7});
  button.Padding(Thickness{10, 5, 10, 5});
  return button;
}

inline Controls::ProgressBar make_progress(char const* fill_hex) {
  Controls::ProgressBar bar;
  bar.Maximum(1.0);
  bar.Value(0.0);
  bar.Foreground(brush_from(fill_hex));
  bar.Background(brush_from("#EAE6DC"));
  bar.CornerRadius(CornerRadius{2, 2, 2, 2});
  return bar;
}

inline Microsoft::UI::Dispatching::DispatcherQueue ui_queue() {
  return Microsoft::UI::Dispatching::DispatcherQueue::GetForCurrentThread();
}

inline Microsoft::UI::Dispatching::DispatcherQueueTimer make_timer(
    std::chrono::milliseconds interval, bool repeating,
    std::function<void()> tick) {
  auto timer = ui_queue().CreateTimer();
  timer.Interval(interval);
  timer.IsRepeating(repeating);
  timer.Tick([tick = std::move(tick)](IInspectable const&, IInspectable const&) {
    tick();
  });
  return timer;
}

/// Move a frameless card to the bottom-right (toast) or top-center (micro)
/// of the display that hosts the window.
inline void position_card(Window const& window, int width, bool bottom_right) {
  try {
    auto app_window = window.AppWindow();
    auto const area = Microsoft::UI::Windowing::DisplayArea::GetFromWindowId(
        app_window.Id(),
        Microsoft::UI::Windowing::DisplayAreaFallback::Nearest);
    auto const wa = area.WorkArea();
    if (bottom_right) {
      app_window.Move({wa.X + wa.Width - width - 16,
                       wa.Y + std::max(0, wa.Height - 220)});
    } else {
      // Micro: top-center, in the sight line (28% from the top).
      app_window.Move({wa.X + std::max(0, (wa.Width - width) / 2),
                       wa.Y + static_cast<int>(wa.Height * 0.28)});
    }
  } catch (...) {
  }
}

inline void strip_chrome(Window const& window) {
  try {
    if (auto presenter = window.AppWindow().Presenter()
                             .try_as<Microsoft::UI::Windowing::OverlappedPresenter>()) {
      presenter.SetBorderAndTitleBar(false, false);
      presenter.IsAlwaysOnTop(true);
    }
  } catch (...) {
  }
}

// WinUI desktop windows render a placeholder glyph in the title bar/taskbar
// until SetIcon is called; the icon resource compiled into the exe (rivet's
// windows-icon) does not flow through automatically. The resource carries the
// string name the generated .rc assigns; try ordinal 1 as a fallback.
inline void apply_window_icon(Window const& window) {
  try {
    auto const size = ::GetSystemMetrics(SM_CXICON);
    HANDLE icon = ::LoadImageW(::GetModuleHandleW(nullptr),
                               L"IDI_RIVET_APP_ICON", IMAGE_ICON, size, size,
                               LR_DEFAULTCOLOR);
    if (!icon) {
      icon = ::LoadImageW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1),
                          IMAGE_ICON, size, size, LR_DEFAULTCOLOR);
    }
    if (icon) {
      window.AppWindow().SetIcon(winrt::Microsoft::UI::IconId{
          static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(icon))});
    }
  } catch (...) {
  }
}

}  // namespace
// ---- reminder toast -----------------------------------------------------------
// One card stands in for every kind due this tick. The buttons map to the v1
// cue lifecycle: Done acknowledges (self-reported), Later snoozes every
// merged kind, Hide removes the card without claiming completion; the 9 s
// auto-close is a Hide. Transitional presentation (issue #55 R1): the R2
// character replaces this card on macOS first.

struct ToastCard {
  Window window{nullptr};
  Controls::TextBlock title_text{nullptr};
  Controls::StackPanel lines_panel{nullptr};
  std::int64_t cue_id = 0;
  std::function<void(std::int64_t)> on_done;
  std::function<void(std::int64_t)> on_snooze;
  std::function<void(std::int64_t)> on_hide;
  Microsoft::UI::Dispatching::DispatcherQueueTimer timer{nullptr};

  void Show(std::string const& title, std::vector<std::string> const& lines,
            rivet_app::ReminderKind accent, std::int64_t id,
            std::int64_t snooze_minutes) {
    Dismiss();
    cue_id = id;

    window = Window{};
    strip_chrome(window);

    Controls::Grid root;
    root.Background(brush_from("#FFFDFB"));
    root.BorderBrush(brush_from("#E2DCCC"));
    root.BorderThickness(Thickness{1, 1, 1, 1});
    root.CornerRadius(CornerRadius{14, 14, 14, 14});
    root.Width(380);

    Controls::StackPanel body;
    body.Orientation(Controls::Orientation::Vertical);
    body.Padding(Thickness{24, 16, 20, 14});
    body.Spacing(10);

    title_text = make_text(wide(title), 17, true, "#26241F");
    title_text.HorizontalAlignment(HorizontalAlignment::Left);
    body.Children().Append(title_text);

    lines_panel = Controls::StackPanel{};
    lines_panel.Spacing(3);
    for (auto const& line : lines) {
      auto block = make_text(wide(line), 13.5, false, "#6E6A5E");
      block.HorizontalAlignment(HorizontalAlignment::Left);
      lines_panel.Children().Append(block);
    }
    body.Children().Append(lines_panel);

    Controls::StackPanel buttons;
    buttons.Orientation(Controls::Orientation::Horizontal);
    buttons.HorizontalAlignment(HorizontalAlignment::Right);
    buttons.Spacing(10);
    if (cue_id != 0) {
      auto hide_button =
          make_button(winrt::to_hstring(l10n::t("notif.hide")), "#FFFDFB",
                      "#A39E8C", false);
      hide_button.Click([this](IInspectable const&, RoutedEventArgs const&) {
        HideTapped();
      });
      buttons.Children().Append(hide_button);
      auto snooze_button = make_button(
          wide(l10n::t("notif.snooze", {l10n::A(snooze_minutes)})), "#FFFDFB",
          "#6E6A5E", true);
      snooze_button.BorderBrush(brush_from("#E2DCCC"));
      snooze_button.Click([this](IInspectable const&, RoutedEventArgs const&) {
        SnoozeTapped();
      });
      buttons.Children().Append(snooze_button);
      auto done_button =
          make_button(winrt::to_hstring(l10n::t("notif.done")), "#F3EEE3",
                      "#26241F", false);
      done_button.Click([this](IInspectable const&, RoutedEventArgs const&) {
        DoneTapped();
      });
      buttons.Children().Append(done_button);
    } else {
      auto got_it =
          make_button(winrt::to_hstring(l10n::t("notif.gotIt")), "#F3EEE3",
                      "#26241F", false);
      got_it.Click([this](IInspectable const&, RoutedEventArgs const&) {
        Dismiss();
      });
      buttons.Children().Append(got_it);
    }
    body.Children().Append(buttons);

    // Accent bar on the left edge.
    auto accent_bar = Controls::Grid{};
    accent_bar.Width(5);
    accent_bar.HorizontalAlignment(HorizontalAlignment::Left);
    accent_bar.VerticalAlignment(VerticalAlignment::Stretch);
    accent_bar.Background(brush_from(
        accent == rivet_app::ReminderKind::water
            ? "#3E7EC2"
            : accent == rivet_app::ReminderKind::micro ? "#8A849E" : "#EA580C"));

    Controls::Grid content;
    content.Children().Append(accent_bar);
    content.Children().Append(body);
    window.Content(content);

    position_card(window, 380, true);
    window.Activate();

    if (!timer) {
      timer = make_timer(std::chrono::milliseconds(9000), false,
                         [this] { HideTapped(); });
    }
    timer.Stop();
    timer.Start();
  }

  void DoneTapped() {
    auto id = cue_id;
    Dismiss();
    if (id != 0 && on_done) on_done(id);
  }

  void SnoozeTapped() {
    auto id = cue_id;
    Dismiss();
    if (id != 0 && on_snooze) on_snooze(id);
  }

  void HideTapped() {
    auto id = cue_id;
    Dismiss();
    if (id != 0 && on_hide) on_hide(id);
  }

  void Dismiss() {
    cue_id = 0;
    if (timer) timer.Stop();
    if (hide_timer) hide_timer.Stop();
    if (window) {
      window.Close();
      window = {nullptr};
      title_text = {nullptr};
      lines_panel = {nullptr};
    }
  }
};

// ---- micro eye-rest card -------------------------------------------------------
// Small top-center card with a shrinking progress bar: rest your eyes while
// it runs. Finishing the timer is NOT an acknowledgment (the user may have
// ignored it): Done is a tray action. Clicking ends it early as a Hide.
// Never locks, never steals focus, silent by design.

struct MicroCard {
  Window window{nullptr};
  Controls::ProgressBar bar{nullptr};
  Controls::TextBlock hint{nullptr};
  double progress = 1.0;
  std::int64_t total_ms = 1000;
  std::int64_t cue_id = 0;
  std::function<void(std::int64_t)> on_done;
  std::function<void(std::int64_t)> on_hide;
  Microsoft::UI::Dispatching::DispatcherQueueTimer timer{nullptr};
  Microsoft::UI::Dispatching::DispatcherQueueTimer hide_timer{nullptr};

  void Show(std::int64_t duration_seconds, std::string const& title,
            std::int64_t id) {
    Dismiss();
    cue_id = id;
    window = Window{};
    strip_chrome(window);

    Controls::Grid root;
    root.Background(brush_from("#FFFFFF"));
    root.BorderBrush(brush_from("#EAE2D6"));
    root.BorderThickness(Thickness{1, 1, 1, 1});
    root.CornerRadius(CornerRadius{18, 18, 18, 18});
    root.Width(400);

    Controls::StackPanel body;
    body.Orientation(Controls::Orientation::Vertical);
    body.Padding(Thickness{26, 18, 26, 18});
    body.Spacing(5);

    Controls::StackPanel head;
    head.Orientation(Controls::Orientation::Horizontal);
    head.Spacing(10);
    head.Children().Append(make_text(L"👀", 22, false, "#26241F"));
    auto title_block = make_text(wide(title), 18, true, "#26241F");
    title_block.HorizontalAlignment(HorizontalAlignment::Left);
    head.Children().Append(title_block);
    body.Children().Append(head);

    hint = make_text(winrt::to_hstring(l10n::t("micro.hint")), 11.5,
                     false, "#A39B8D");
    hint.HorizontalAlignment(HorizontalAlignment::Left);
    body.Children().Append(hint);

    bar = make_progress("#C25E3E");
    bar.Value(1.0);
    body.Children().Append(bar);

    auto done = make_button(winrt::to_hstring(l10n::t("micro.done")),
                            "#F3EEE3", "#26241F", false);
    done.HorizontalAlignment(HorizontalAlignment::Left);
    done.Margin(Thickness{0, 6, 0, 0});
    done.Click([this](IInspectable const&, RoutedEventArgs const&) {
      DoneTapped();
    });
    body.Children().Append(done);
    root.Children().Append(body);
    window.Content(root);

    // Click anywhere ends the rest early as a Hide.
    root.PointerPressed([this](IInspectable const&,
                               Input::PointerRoutedEventArgs const&) {
      HideTapped();
    });

    total_ms = std::max<std::int64_t>(1, duration_seconds) * 1000;
    progress = 1.0;
    position_card(window, 400, false);
    window.Activate();

    timer = make_timer(std::chrono::milliseconds(250), true, [this] {
      progress = std::max(0.0, progress - 250.0 / total_ms);
      if (bar) bar.Value(progress);
      if (progress <= 0.0) {
        timer.Stop();
        if (hint) hint.Text(winrt::to_hstring(l10n::t("micro.finishedHint")));
        // Hide the finished card later without claiming completion; the cue
        // stays open for the tray's explicit Done.
        hide_timer = make_timer(std::chrono::seconds(60), false, [this] {
          HideTapped();
        });
        hide_timer.Start();
      }
    });
    timer.Start();
  }

  void DoneTapped() {
    auto id = cue_id;
    Dismiss();
    if (id != 0 && on_done) on_done(id);
  }

  void HideTapped() {
    auto id = cue_id;
    Dismiss();
    if (id != 0 && on_hide) on_hide(id);
  }

  void Dismiss() {
    cue_id = 0;
    if (timer) timer.Stop();
    if (hide_timer) hide_timer.Stop();
    if (window) {
      window.Close();
      window = {nullptr};
      bar = {nullptr};
      hint = {nullptr};
    }
  }
};

}  // namespace winrt::RivetHost::implementation
