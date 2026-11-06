#pragma once

// App-side tray bindings. Everything mechanical — HWND subclassing, the
// activation callback, TaskbarCreated recovery, the popup menu, WM_COMMAND
// routing — is rivet's first-party rivet::system::TrayController. What stays
// here is the application layer: menu labels from the i18n single source and
// the action callbacks (open / pause toggle / check updates / exit).
//
// Left click  -> on_open (show/focus the main window)
// Right click -> the menu below

#include "pch.h"
#include "I18n.h"
#include "system_services.hpp"
// NativeWindowHandle lives outside system_services.hpp in rivet 0.11: the
// platform library stays WinUI-free, WinUI hosts include this header directly.
#include "winui_window.hpp"

#include <functional>
#include <memory>

namespace winrt::RivetHost::implementation {

inline std::wstring tray_wide(std::string const& utf8) {
  auto const wide = winrt::to_hstring(utf8);
  return std::wstring{wide.c_str()};
}

struct TrayUi {
  std::function<void()> on_open;
  std::function<void()> on_pause_toggle;
  std::function<void()> on_check_updates;
  std::function<void()> on_exit;
  // Mandatory reminder controls (#54): the companion is pointer-through, so
  // Done / Later / Hide / Focus live here. Actions act on the newest open
  // cue; they are only meaningful while a cue exists but stay enabled for
  // simplicity — an action on no cue is a backend no-op.
  std::function<void()> on_cue_done;
  std::function<void()> on_cue_later;
  std::function<void()> on_cue_hide;
  std::function<void()> on_focus_toggle;
  std::function<void()> on_mubi_move_aside;
  std::function<void()> on_mubi_place;
  std::function<void()> on_eye_rest;
  std::function<void()> on_stretch;
  bool cue_open = false;
  bool quiet = false;
  bool cue_has_sit = false;
  bool cue_has_micro = false;

  void Attach(winrt::Microsoft::UI::Xaml::Window const& window) {
    paused_ = false;
    controller_ = std::make_unique<rivet::system::TrayController>(
        rivet::system::NativeWindowHandle(window), kIconId, kCallbackMessage,
        L"MoveBit", LoadAppIcon(), BuildMenu(),
        [this] {
          if (on_open) on_open();
        });
  }

  void Detach() { controller_.reset(); }

  void SetPaused(bool paused) {
    if (paused_ == paused) return;
    paused_ = paused;
    if (controller_) controller_->SetMenu(BuildMenu());
  }

  void SetPlacing(bool placing) {
    if (placing_ == placing) return;
    placing_ = placing;
    if (controller_) controller_->SetMenu(BuildMenu());
  }

  void RefreshCueState(bool cue_open, bool quiet, bool has_sit = false,
                       bool has_micro = false) {
    if (cue_open_ == cue_open && quiet_ == quiet && cue_has_sit_ == has_sit &&
        cue_has_micro_ == has_micro) {
      return;
    }
    cue_open_ = cue_open;
    quiet_ = quiet;
    cue_has_sit_ = has_sit;
    cue_has_micro_ = has_micro;
    if (controller_) controller_->SetMenu(BuildMenu());
  }

  void SetTooltip(std::wstring const& tooltip) {
    if (controller_) controller_->SetTooltip(tooltip);
  }

  void ShowInfo(std::string const& title, std::string const& body) {
    if (controller_) controller_->Notify(tray_wide(title), tray_wide(body));
  }

 private:
  static constexpr UINT kIconId = 1;
  static constexpr UINT kCallbackMessage = WM_APP + 7;
  enum MenuId {
    kMenuOpen = 1,
    kMenuPauseToggle = 2,
    kMenuCheckUpdates = 3,
    kMenuExit = 4,
    kMenuCueDone = 5,
    kMenuCueLater = 6,
    kMenuCueHide = 7,
    kMenuFocusToggle = 8,
    kMenuMubiMoveAside = 9,
    kMenuMubiPlace = 10,
    kMenuEyeRest = 11,
    kMenuStretch = 12
  };

  bool paused_ = false;
  bool cue_open_ = false;
  bool quiet_ = false;
  bool placing_ = false;
  bool cue_has_sit_ = false;
  bool cue_has_micro_ = false;
  std::unique_ptr<rivet::system::TrayController> controller_;

  static HICON LoadAppIcon() {
    HICON icon = static_cast<HICON>(::LoadImageW(
        ::GetModuleHandleW(nullptr), L"IDI_RIVET_APP_ICON", IMAGE_ICON,
        ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
        LR_DEFAULTCOLOR));
    if (!icon) {
      icon = static_cast<HICON>(::LoadImageW(
          ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1), IMAGE_ICON,
          ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
          LR_DEFAULTCOLOR));
    }
    return icon;
  }

  std::vector<rivet::system::TrayMenuItem> BuildMenu() const {
    using rivet::system::TrayMenuItem;
    auto bind = [this](std::function<void()> const& action) {
      return [this, action] {
        if (action) action();
      };
    };
    std::vector<TrayMenuItem> items = {
        TrayMenuItem(kMenuOpen, tray_wide(l10n::t("tray.open")),
                     bind(on_open)),
    };
    if (cue_open_) {
      items.push_back(TrayMenuItem(
          kMenuCueDone, tray_wide(l10n::t("tray.cueDone")), bind(on_cue_done)));
      items.push_back(TrayMenuItem(
          kMenuCueLater, tray_wide(l10n::t("tray.cueLater")),
          bind(on_cue_later)));
      items.push_back(TrayMenuItem(
          kMenuCueHide, tray_wide(l10n::t("tray.cueHide")), bind(on_cue_hide)));
    }
    items.push_back(TrayMenuItem(
        kMenuMubiMoveAside, tray_wide(l10n::t("tray.moveAside")),
        bind(on_mubi_move_aside)));
    items.push_back(TrayMenuItem(
        kMenuMubiPlace,
        tray_wide(l10n::t(placing_ ? "tray.placeMubiDone" : "tray.placeMubi")),
        bind(on_mubi_place)));
    items.push_back(TrayMenuItem(
        kMenuPauseToggle,
        tray_wide(l10n::t(paused_ ? "tray.resume" : "tray.pause")),
        bind(on_pause_toggle)));
    items.push_back(TrayMenuItem(
        kMenuFocusToggle,
        tray_wide(l10n::t(quiet_ ? "tray.focusOff" : "tray.focusOn")),
        bind(on_focus_toggle)));
    items.push_back(TrayMenuItem(TrayMenuItem::Type::separator));
    items.push_back(TrayMenuItem(
        kMenuCheckUpdates, tray_wide(l10n::t("tray.checkUpdate")),
        bind(on_check_updates)));
    items.push_back(TrayMenuItem(kMenuExit, tray_wide(l10n::t("tray.exit")),
                                 bind(on_exit)));
    return items;
  }
};

}  // namespace winrt::RivetHost::implementation
