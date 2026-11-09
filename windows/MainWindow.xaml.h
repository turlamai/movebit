#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "MoveBitModel.h"
#include "Overlays.h"
#include "Mubi.h"
#include "Onboarding.h"
#include "TrayIcon.h"

#include <map>
#include <optional>

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  // XAML event handlers.
  void Status_Click(winrt::Windows::Foundation::IInspectable const& sender,
                    Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void HistRange_SelectionChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const& args);
  void Language_SelectionChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const& args);
  void Sound_Toggled(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void QuietHours_Toggled(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void QuietStart_ValueChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const& args);
  void QuietEnd_ValueChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::Controls::NumberBoxValueChangedEventArgs const& args);
  void Autostart_Toggled(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Updates_Toggled(winrt::Windows::Foundation::IInspectable const& sender,
                       Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void UpdateCheck_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void UpdateCancel_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void UpdateCopyError_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void HandleUpdateCheck(
      rivet_app::Result<rivet_app::UpdateCheck> const& result);
  void StartUpdateDownload();
  void PollUpdateProgress();
  void ApplyStagedUpdate();
  // One-shot receipt: a failed update leaves update-failed.txt in the
  // updates dir; surface it once on the next launch and delete it.
  void HandleUpdateFailureMarker();
  void ChangeDataDir_Click(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);

 private:
  winrt::fire_and_forget InitializeBackendAsync();
  void SubscribeEvents();
  void Bootstrap();
  void HandleEvent(std::string const& name, rivet::Value const& value);
  void HandleHealthCue(rivet_app::HealthCue const& cue);
  void CueDisplayed(std::int64_t id);
  void HandleCueAcknowledged(rivet_app::CueAcknowledged const& acked);
  void RefreshTrayState();
  void ApplyConfig(rivet_app::ReminderConfig const& changed, bool announce);
  void RefreshStatesAfterTick();
  void ReloadOutcomes();
  void ReloadHistory();
  void ReloadAutostart();
  void ReloadDataDir();

  void ApplyTexts();
  void RefreshTodayCard();
  void RefreshHistoryCard();
  void RefreshInsightCard();
  void RefreshSettingsWidgets();
  void RefreshStatusMarker();
  void RefreshFooter();
  void ShowHistoryBars();
  void ShowOnboarding();
  void SetStatus(std::string const& message);
  // Update failure text must leave the screen with the user (family
  // UPDATE.md rule): the hint carries the failure and the copy button
  // (UpdCopyError) puts exactly that string on the clipboard.
  void ShowUpdateErrorHint(winrt::hstring const& text);
  void ClearUpdateErrorHint();
  void SetWindowIconFromResources();
  winrt::fire_and_forget PickDataFolderAsync();

  template <typename F>
  void MutateConfig(F mutate);
  void SaveConfig(rivet_app::ReminderConfig draft);

  Microsoft::UI::Dispatching::DispatcherQueue dispatcher_{nullptr};
  std::shared_ptr<rivet::windows::Backend> backend_;
  rivet_app::API* api_ = nullptr;
  movebit::Model model_;
  std::string language_ = "zh";
  bool updating_settings_ = false;
  bool suppressing_numberbox_ = false;

  ToastCard toast_;
  MicroCard micro_;
  MubiCompanion companion_;
  OnboardingWizard onboarding_;
  TrayUi tray_;
  bool really_quitting_ = false;
  bool tray_hint_shown_ = false;
  // Update button state machine: idle | checking | available | downloading |
  // cancelled | ready | applying | error | up-to-date.
  std::string update_phase_ = "idle";
  winrt::hstring last_update_error_;
  Microsoft::UI::Dispatching::DispatcherQueueTimer update_progress_timer_{nullptr};
  // GetTickCount64 at download start — the host-side 30-minute backstop for
  // a wedged backend (the backend's own watchdog normally fires first).
  unsigned long long update_download_start_tick_ = 0;

  void InitTray();
  void HideToTray();
  void BringToForeground();
  void TogglePause();
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}  // namespace winrt::RivetHost::factory_implementation
