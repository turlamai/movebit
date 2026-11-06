#pragma once

// One-screen first run (issue #90): meet Mubi, read one sentence, press Start.
// The v1 reboot (issue #55) removed the strictness pact and the cadence/sound
// wizard: the shipped balanced rhythm and silent-by-default sound need no
// confirmation. Closing the window any other way still counts as seen, so the
// screen cannot nag on every launch.

#include "pch.h"
#include "MoveBitModel.h"
#include "Overlays.h"

#include <functional>
#include <string>

namespace winrt::RivetHost::implementation {

using namespace winrt::Microsoft::UI::Xaml;

struct OnboardingWizard {
  Window window{nullptr};
  std::function<void()> on_finish;
  std::function<void()> on_cancel;
  bool finished_ = false;

  void Show() {
    if (window) {
      window.Activate();
      return;
    }
    window = Window{};
    window.Title(winrt::to_hstring(l10n::t("ob.title")));
    apply_window_icon(window);
    window.AppWindow().Resize({460, 520});
    try {
      auto const area = Microsoft::UI::Windowing::DisplayArea::GetFromWindowId(
          window.AppWindow().Id(),
          Microsoft::UI::Windowing::DisplayAreaFallback::Nearest);
      auto const wa = area.WorkArea();
      window.AppWindow().Move({wa.X + std::max(0, (wa.Width - 460) / 2),
                               wa.Y + std::max(0, (wa.Height - 520) / 3)});
    } catch (...) {
    }

    Controls::StackPanel root;
    root.Orientation(Controls::Orientation::Vertical);
    root.Padding(Thickness{32, 28, 32, 28});
    root.Spacing(12);
    root.HorizontalAlignment(HorizontalAlignment::Center);
    root.VerticalAlignment(VerticalAlignment::Center);

    // Mubi's water-drop motif stands in for the layered character surface,
    // which cannot be embedded in a WinUI view; the real Mubi idles on screen
    // behind this window at first launch.
    auto glyph = make_text(L"💧", 64, false, "#26241F");
    glyph.HorizontalAlignment(HorizontalAlignment::Center);
    root.Children().Append(glyph);

    auto hello = make_text(winrt::to_hstring(l10n::t("ob.hello")), 26, true,
                           "#26241F");
    hello.HorizontalAlignment(HorizontalAlignment::Center);
    root.Children().Append(hello);

    auto line = make_text(winrt::to_hstring(l10n::t("ob.line")), 14.5, false,
                          "#6E6A5E");
    line.TextAlignment(TextAlignment::Center);
    line.TextWrapping(TextWrapping::Wrap);
    line.MaxWidth(380);
    line.HorizontalAlignment(HorizontalAlignment::Center);
    root.Children().Append(line);

    auto privacy = make_text(winrt::to_hstring(l10n::t("ob.privacy")), 11.5,
                             false, "#A39B8D");
    privacy.HorizontalAlignment(HorizontalAlignment::Center);
    root.Children().Append(privacy);

    auto start = make_button(winrt::to_hstring(l10n::t("ob.start")), "#C25E3E",
                             "#FFFFFF", false);
    start.CornerRadius(CornerRadius{8, 8, 8, 8});
    start.Padding(Thickness{18, 9, 18, 9});
    start.HorizontalAlignment(HorizontalAlignment::Stretch);
    start.Click([this](IInspectable const&, RoutedEventArgs const&) {
      Finish();
    });
    root.Children().Append(start);

    auto hint = make_text(winrt::to_hstring(l10n::t("ob.startHint")), 11,
                          false, "#A39B8D");
    hint.HorizontalAlignment(HorizontalAlignment::Center);
    root.Children().Append(hint);

    Controls::ScrollViewer scroll;
    scroll.Content(root);
    window.Content(scroll);
    window.Closed([this](IInspectable const&, WindowEventArgs const&) {
      window = {nullptr};
      if (!finished_ && on_cancel) on_cancel();
    });
    window.Activate();
  }

  bool IsOpen() const { return window != nullptr; }

  void Finish() {
    finished_ = true;
    if (on_finish) on_finish();
    Close();
  }

  void Close() {
    if (window) {
      window.Close();
      window = {nullptr};
    }
  }
};

}  // namespace winrt::RivetHost::implementation
