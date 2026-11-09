#pragma once

// Mubi（沐比）for the WinUI host — the canonical character from the v1
// design system (issue #56; assets/mubi/tokens.json + docs/MUBI-DESIGN-
// SYSTEM.md). Renders the canonical path data with GDI+ into a per-pixel-
// alpha layered window (UpdateLayeredWindow), so the character floats
// free on the desktop exactly like the macOS panel — no card behind it.
// Pixels where alpha is 0 are click-through automatically; the whole
// window never activates.
//
// Safety contract (issue #54): WS_EX_TRANSPARENT | WS_EX_NOACTIVATE |
// WS_EX_TOOLWINDOW; Done / Later / Hide / Focus live in the tray menu on
// every host.
//
// Geometry: the path data below is the canonical master data (generator:
// scripts/gen-mubi-art.mjs). Verify against assets/mubi/tokens.json when
// touching art — never redraw or approximate.

#include "pch.h"
#include "I18n.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <cmath>
#include <string>
#include <utility>
#include <vector>

#include <gdiplus.h>

namespace winrt::RivetHost::implementation {

// Headless packaged acceptance skips the companion so the UIA probe sees
// exactly the main window (mirrors the macOS acceptance posture).
inline bool acceptance_mode() {
  static bool const value = [] {
    char buffer[16] = {};
    size_t size = 0;
    getenv_s(&size, buffer, sizeof(buffer), "MOVEBIT_ACCEPTANCE");
    return size > 0 && buffer[0] == '1';
  }();
  return value;
}

// Stage tracer for packaged-desktop diagnosis: appends one line per step to
// %TEMP%\RivetHost-mubi.log so a broken companion names the exact stage
// (no debugger required on the test machine).
inline void mubi_trace(char const* stage) {
  wchar_t path[MAX_PATH]{};
  DWORD const n = ::GetTempPathW(MAX_PATH, path);
  if (n == 0 || n >= MAX_PATH) return;
  std::wstring const file = std::wstring(path) + L"RivetHost-mubi.log";
  HANDLE h = ::CreateFileW(file.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                           nullptr);
  if (h == INVALID_HANDLE_VALUE) return;
  wchar_t line[160]{};
  int const len = swprintf_s(line, L"%llu %hs\r\n",
                             static_cast<unsigned long long>(::GetTickCount64()),
                             stage);
  if (len > 0) {
    DWORD written = 0;
    ::WriteFile(h, line, static_cast<DWORD>(len * sizeof(wchar_t)), &written,
                nullptr);
  }
  ::CloseHandle(h);
}

namespace mubi_detail {

// ---- GDI+ lifetime ---------------------------------------------------------

inline ULONG_PTR gdiplus_token() {
  static ULONG_PTR token = [] {
    Gdiplus::GdiplusStartupInput input;
    ULONG_PTR t = 0;
    GdiplusStartup(&t, &input, nullptr);
    return t;
  }();
  return token;
}

// ---- canonical path parsing (absolute M/L/C/Z only) ------------------------

inline void skip_separators(char const*& it, char const* end) {
  while (it != end && (*it == ' ' || *it == ',')) ++it;
}

inline double read_number(char const*& it, char const* end) {
  skip_separators(it, end);
  std::string digits;
  if (it != end && (*it == '-' || *it == '+')) {
    digits.push_back(*it);
    ++it;
  }
  while (it != end && (isdigit(static_cast<unsigned char>(*it)) ||
                       *it == '.')) {
    digits.push_back(*it);
    ++it;
  }
  return digits.empty() ? 0.0 : std::atof(digits.c_str());
}

inline Gdiplus::PointF read_point(char const*& it, char const* end) {
  double const x = read_number(it, end);
  double const y = read_number(it, end);
  return Gdiplus::PointF(static_cast<float>(x), static_cast<float>(y));
}

// Builds a closed/ open GDI+ path from a canonical M path string.
inline void parse_path(char const* d, bool closed,
                       Gdiplus::GraphicsPath& path) {
  Gdiplus::PointF current(0, 0);
  char const* it = d;
  char const* end = d + std::strlen(d);
  while (it != end) {
    skip_separators(it, end);
    if (it == end) break;
    char const command = *it;
    ++it;
    if (command == 'M') {
      current = read_point(it, end);
      path.StartFigure();
    } else if (command == 'L') {
      Gdiplus::PointF const p = read_point(it, end);
      path.AddLine(current, p);
      current = p;
    } else if (command == 'C') {
      Gdiplus::PointF const c1 = read_point(it, end);
      Gdiplus::PointF const c2 = read_point(it, end);
      Gdiplus::PointF const p3 = read_point(it, end);
      path.AddBezier(current, c1, c2, p3);
      current = p3;
    } else if (command == 'Z') {
      path.CloseFigure();
    }
  }
  if (closed) path.CloseFigure();
}

inline Gdiplus::Color argb(BYTE a, char const* hex) {
  unsigned r = 0, g = 0, b = 0;
  sscanf_s(hex, "#%02x%02x%02x", &r, &g, &b);
  return Gdiplus::Color(a, static_cast<BYTE>(r), static_cast<BYTE>(g),
                        static_cast<BYTE>(b));
}

// Premultiplies a 32bpp top-down DIB in place (UpdateLayeredWindow needs
// premultiplied alpha; GDI+ paints straight alpha).
inline void premultiply(BYTE* bits, int pixels) {
  for (int i = 0; i < pixels; ++i) {
    BYTE* px = bits + i * 4;
    BYTE const a = px[3];
    if (a == 255) continue;
    px[0] = static_cast<BYTE>(px[0] * a / 255);
    px[1] = static_cast<BYTE>(px[1] * a / 255);
    px[2] = static_cast<BYTE>(px[2] * a / 255);
  }
}

}  // namespace mubi_detail

// ---- the floating character ------------------------------------------------

struct MubiCompanion {
  enum class MubiState { Idle, Water, Stand, Eyes, Ack, Focus };

  double body_height = 78;   // logical px (S 60 / M 78 / L 104)
  std::string motion = "subtle";
  std::string dock = "bottom-right";
  bool labels_always = false;
  bool quiet = false;
  // Issue #104: normalized directly placed home (-1 = named dock) and the
  // temporary drag surface. The mode never persists: a 30 s timer, Done,
  // Focus, Hide or a due cue restores full pointer-through.
  std::int64_t free_x = -1;
  std::int64_t free_y = -1;
  bool placing = false;
  std::function<void(std::int64_t, std::int64_t)> on_placement_changed;
  std::function<void()> on_placement_ended;

  bool IsPlacing() const { return placing; }

  // Persistent invitation + petting + repertoire (issue #140): while a due
  // cue waits, the character is pettable (tap = Done) and a Later tag rides
  // the capsule; between reminders Mubi plays by itself near its dock.
  bool attending = false;
  std::function<void()> on_pet;
  std::function<void()> on_later;
  // Localized "Later" label for the bubble tag; the host keeps it current.
  std::wstring later_tag_text = L"Later";
  int act = 0;  // 0 none, 1 roll, 2 squish, 3 teary, 4 hop
  double act_progress = 0.0;
  double act_total_ticks = 1.0;
  double act_side = 1.0;
  Microsoft::UI::Dispatching::DispatcherQueueTimer act_timer{nullptr};
  Microsoft::UI::Dispatching::DispatcherQueueTimer play_timer{nullptr};
  Microsoft::UI::Dispatching::DispatcherQueueTimer proximity_timer{nullptr};

  HWND hwnd = nullptr;
  Microsoft::UI::Dispatching::DispatcherQueueTimer anim_timer{nullptr};
  Microsoft::UI::Dispatching::DispatcherQueueTimer label_timer{nullptr};
  Microsoft::UI::Dispatching::DispatcherQueueTimer visit_timer{nullptr};
  // One finite health reminder visit; no background screen roaming.
  enum class VisitPhase { None, Approaching, Holding, Returning };
  VisitPhase visit_phase = VisitPhase::None;
  POINT visit_home{};
  POINT visit_target{};
  POINT visit_position{};
  int visit_step = 0;
  double anim_progress = 0.0;
  std::int64_t anim_total_ticks = 0;
  MubiState anim_state = MubiState::Idle;

  static double body_height_for(std::string const& size) {
    if (size == "S") return 60;
    if (size == "L") return 104;
    return 78;
  }

  void ApplyConfig(std::int64_t freeX, std::int64_t freeY) {
    StopVisit();
    // One shipped presentation (issue #140): M size, subtle motion, default
    // corner unless a drag-placed position is stored.
    body_height = body_height_for("M");
    motion = "subtle";
    dock = "bottom-right";
    labels_always = false;
    free_x = freeX;
    free_y = freeY;
    if (hwnd != nullptr) {
      // Reset a stale due state and its label width before redocking.
      Show(quiet ? MubiState::Focus : MubiState::Idle, L"");
    }
  }

  // The user can move the floating pet away with one tray action, even
  // though the transparent surface itself must remain mouse-through.
  // This changes only the local visual dock, not the Racket user settings
  // or any still-pending reminder's completion state.
  void MoveAside() {
    EndPlacement();
    // Cancel an in-flight cue visit; Render below re-homes at the new dock.
    StopVisit();
    free_x = -1;
    free_y = -1;
    if (dock == "bottom-right") dock = "bottom-left";
    else if (dock == "bottom-left") dock = "top-left";
    else if (dock == "top-left") dock = "top-right";
    else dock = "bottom-right";
    // Keep the current cue/pose and its existing timeout. Relocation is not
    // a Hide, Later or Done action and must not silently erase the notice.
    if (hwnd != nullptr) Render(anim_state, current_message);
  }

  void SetQuiet(bool enabled) {
    EndPlacement();
    quiet = enabled;
    if (acceptance_mode()) return;
    Show(quiet ? MubiState::Focus : MubiState::Idle, L"");
  }

  void Show(MubiState state, std::wstring const& message) {
    if (placing) EndPlacement();
    if (acceptance_mode()) return;
    mubi_trace("show:enter");
    try {
      StopVisit();
      EnsureWindow();
      mubi_trace("show:ensure-ok");
      attending = IsDueState(state);
      anim_state = state;
      current_message = message;
      Render(state, message);
      mubi_trace("show:render-ok");
      StartGesture(state);
      StartVisit(state);
      StartLabelTimer(message, state);
      if (attending) {
        StartProximity();
        SchedulePlay(true);
      } else {
        StopProximity();
        if (state == MubiState::Idle) {
          SchedulePlay(false);
        } else {
          StopPlay();
        }
      }
      mubi_trace("show:timers-ok");
    } catch (...) {
      mubi_trace("show:caught");
      // The reminder surface must never take the tray app down; the cue
      // itself stays safe in the backend ledger.
      Dismiss();
    }
  }

  // Launch-visible: the first idle call creates the floating character.
  void ShowIdle() {
    if (acceptance_mode()) return;
    Show(quiet ? MubiState::Focus : MubiState::Idle, L"");
  }

  void ShowAck() {
    if (quiet) return;
    Show(MubiState::Ack, L"");
    // The glint plays, then Mubi walks home (the invitation is settled).
    if (label_timer) label_timer.Stop();
    if (!label_timer) {
      label_timer = make_timer(std::chrono::milliseconds(700), false,
                               [this] { ShowIdle(); });
    }
    label_timer.Interval(std::chrono::milliseconds(700));
    label_timer.Start();
  }

  /// Temporary explicit placement mode (issue #104). Only while active does
  /// the layered window drop WS_EX_TRANSPARENT; opaque Mubi pixels then act
  /// as the drag handle (HTCAPTION) and everything else stays click-through.
  void BeginPlacement() {
    if (quiet) return;
    ShowIdle();
    if (hwnd == nullptr || placing) return;
    placing = true;
    StopVisit();
    ::SetTimer(hwnd, kPlacementTimerId, 30000, nullptr);
    ApplyPlacementStyle(true);
  }

  void EndPlacement() {
    if (!placing) return;
    placing = false;
    if (hwnd != nullptr) {
      ::KillTimer(hwnd, kPlacementTimerId);
      SavePlacement();
      ApplyPlacementStyle(false);
      Render(anim_state, current_message);
    }
    if (on_placement_ended) on_placement_ended();
  }

  void Dismiss() {
    EndPlacement();
    mubi_trace("dismiss:enter");
    StopVisit();
    if (hwnd != nullptr) {
      ::DestroyWindow(hwnd);
      hwnd = nullptr;
    }
    if (anim_timer) anim_timer.Stop();
    if (label_timer) label_timer.Stop();
    if (act_timer) act_timer.Stop();
    if (play_timer) play_timer.Stop();
    if (proximity_timer) proximity_timer.Stop();
  }

 private:
  static constexpr UINT_PTR kPlacementTimerId = 2;
  std::wstring current_message;

  static LRESULT CALLBACK PlacementWindowProc(HWND h, UINT msg, WPARAM w,
                                              LPARAM l) {
    auto* self = reinterpret_cast<MubiCompanion*>(
        ::GetWindowLongPtrW(h, GWLP_USERDATA));
    if (self != nullptr && self->placing) {
      if (msg == WM_NCHITTEST) return HTCAPTION;
      if (msg == WM_EXITSIZEMOVE) {
        self->SavePlacement();
        return 0;
      }
      if (msg == WM_TIMER && w == kPlacementTimerId) {
        self->EndPlacement();
        return 0;
      }
    }
    if (self != nullptr && self->attending && !self->placing &&
        msg == WM_LBUTTONDOWN) {
      // Client == window (WS_POPUP): the click lands where the layered
      // content paints. Character = pet/Done, Later tag = snooze.
      LONG const x = static_cast<LONG>(static_cast<short>(l & 0xFFFF));
      LONG const y = static_cast<LONG>(static_cast<short>(
          (l >> 16) & 0xFFFF));
      self->HandleCueClick(x, y);
      return 0;
    }
    return ::DefWindowProcW(h, msg, w, l);
  }

  void ApplyPlacementStyle(bool draggable) {
    if (hwnd == nullptr) return;
    LONG_PTR ex = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if (draggable) {
      ex &= ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
    } else {
      ex |= static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
    }
    ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
    ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE |
                       SWP_FRAMECHANGED);
  }

  void SavePlacement() {
    if (hwnd == nullptr) return;
    RECT rect{};
    if (!::GetWindowRect(hwnd, &rect)) return;
    HMONITOR monitor =
        ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof(MONITORINFO)};
    if (!::GetMonitorInfoW(monitor, &info)) return;
    RECT const wa = info.rcWork;
    LONG const clearance = 16;
    LONG const width = rect.right - rect.left;
    LONG const height = rect.bottom - rect.top;
    LONG const travel_w =
        std::max<LONG>(1, (wa.right - wa.left) - width - 2 * clearance);
    LONG const travel_h =
        std::max<LONG>(1, (wa.bottom - wa.top) - height - 2 * clearance);
    double const fx = static_cast<double>(rect.left - wa.left - clearance) /
                      static_cast<double>(travel_w);
    double const fy = static_cast<double>(rect.top - wa.top - clearance) /
                      static_cast<double>(travel_h);
    auto clamp_permille = [](double f) {
      f = std::clamp(f, 0.0, 1.0);
      return static_cast<std::int64_t>(std::lround(f * 1000.0));
    };
    std::int64_t const nx = clamp_permille(fx);
    std::int64_t const ny = clamp_permille(fy);
    if (nx == free_x && ny == free_y) return;
    free_x = nx;
    free_y = ny;
    if (on_placement_changed) on_placement_changed(nx, ny);
  }


  // Only genuine health cues get the wider readable card.
  bool IsReadableHealthCue() const {
    return !current_message.empty() &&
           (anim_state == MubiState::Water || anim_state == MubiState::Stand ||
            anim_state == MubiState::Eyes);
  }

  // 120x140 design grid + capsule row; scaled by the Mubi size and DPI.
  SIZE pixel_size() const {
    UINT dpi = 96;
    if (hwnd != nullptr) dpi = ::GetDpiForWindow(hwnd);
    double const dp = static_cast<double>(dpi) / 96.0;
    double const s = body_height / 108.0;
    bool const due = IsReadableHealthCue();
    int const w = static_cast<int>(((due ? 252.0 : 120.0 * s) + 8.0) * dp);
    int const h = static_cast<int>((140.0 * s + 8.0 + (due ? 44.0 : 0.0)) * dp);
    return SIZE{w, h};
  }

  void EnsureWindow() {
    mubi_detail::gdiplus_token();
    if (hwnd != nullptr) return;
    WNDCLASSW wc{};
    wc.lpfnWndProc = &MubiCompanion::PlacementWindowProc;
    wc.hInstance = ::GetModuleHandleW(nullptr);
    wc.lpszClassName = L"MoveBitMubi";
    ::RegisterClassW(&wc);
    hwnd = ::CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE |
            WS_EX_TOOLWINDOW,
        L"MoveBitMubi", L"Mubi", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr,
        wc.hInstance, nullptr);
    if (hwnd == nullptr) {
      throw std::runtime_error("mubi window creation failed");
    }
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(this));
    // Float above normal windows without stealing focus; never in the
    // taskbar (the TOOLWINDOW ex-style already keeps it out).
    // UpdateLayeredWindow does not set the visible bit on its own —
    // a layered window stays hidden until explicitly shown.
    ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  // Screen coordinates for the docked window, physical pixels.
  POINT dock_position(SIZE size) const {
    HMONITOR monitor = ::MonitorFromWindow(
        hwnd != nullptr ? hwnd : ::GetDesktopWindow(),
        MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof(MONITORINFO)};
    if (!::GetMonitorInfoW(monitor, &info)) return POINT{0, 0};
    auto const wa = info.rcWork;
    int const clearance = 16;
    int x = 0;
    int y = 0;
    if (free_x >= 0 && free_y >= 0) {
      // Clamp to the usable travel range so a stale/synced position can
      // never put the character partly or wholly off-screen.
      LONG const travel_w =
          std::max<LONG>(0, (wa.right - wa.left) - size.cx - 2 * clearance);
      LONG const travel_h =
          std::max<LONG>(0, (wa.bottom - wa.top) - size.cy - 2 * clearance);
      x = wa.left + clearance +
          static_cast<int>(travel_w * free_x / 1000);
      y = wa.top + clearance +
          static_cast<int>(travel_h * free_y / 1000);
      return POINT{x, y};
    }
    if (dock == "bottom-left") {
      x = wa.left + clearance;
      y = wa.bottom - size.cy - clearance;
    } else if (dock == "top-right") {
      x = wa.right - size.cx - clearance;
      y = wa.top + clearance;
    } else if (dock == "top-left") {
      x = wa.left + clearance;
      y = wa.top + clearance;
    } else {  // bottom-right
      x = wa.right - size.cx - clearance;
      y = wa.bottom - size.cy - clearance;
    }
    return POINT{x, y};
  }

  // Paints the current pose into a 32bpp ARGB DIB and presents it through
  // UpdateLayeredWindow (which also moves the window into place).
  void Render(MubiState state, std::wstring const& message) {
    if (hwnd == nullptr) return;
    using namespace mubi_detail;

    double const s = body_height / 108.0;
    UINT dpi = ::GetDpiForWindow(hwnd);
    double const dp = static_cast<double>(dpi) / 96.0;
    SIZE size = pixel_size();

    HDC screen = ::GetDC(nullptr);
    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = size.cx;
    bi.bmiHeader.biHeight = -size.cy;  // top-down
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP dib = ::CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits,
                                     nullptr, 0);
    HDC mem = ::CreateCompatibleDC(screen);
    HGDIOBJ old = ::SelectObject(mem, dib);

    {
      Gdiplus::Graphics graphics(mem);
      graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
      graphics.SetTextRenderingHint(
          Gdiplus::TextRenderingHintAntiAliasGridFit);
      graphics.Clear(Gdiplus::Color(0, 0, 0, 0));

      // Design grid 120x140 centered in the surface, scaled.
      double const grid_w = 120.0 * s * dp;
      double const grid_h = 140.0 * s * dp;
      float const ox = static_cast<float>((size.cx - grid_w) / 2.0);
      float const oy = static_cast<float>((size.cy - grid_h) / 2.0 -
                                           (IsReadableHealthCue() ? 22.0 * dp : 0));
      graphics.TranslateTransform(ox, oy);
      graphics.ScaleTransform(static_cast<float>(s * dp),
                              static_cast<float>(s * dp));
      // Repertoire acts (issue #140): a roll tilts from the docked bottom,
      // a glass-press squishes, a hop lifts — single-bump transforms.
      double const act_q =
          std::sin(std::min(1.0, act_progress) * 3.14159265358979);
      if (act == 1) {
        graphics.TranslateTransform(60.0f, 128.0f);
        graphics.RotateTransform(
            static_cast<float>(14.0 * act_q * act_side));
        graphics.TranslateTransform(-60.0f, -128.0f);
      } else if (act == 2) {
        graphics.TranslateTransform(60.0f, 128.0f);
        graphics.ScaleTransform(static_cast<float>(1.0 + 0.08 * act_q),
                                static_cast<float>(1.0 - 0.10 * act_q));
        graphics.TranslateTransform(-60.0f, -128.0f);
      } else if (act == 4) {
        graphics.TranslateTransform(0.0f, static_cast<float>(-4.0 * act_q));
      }
      // Everything below paints in the 120x140 canonical grid.

      // Stand stretches the body upward from the docked bottom edge.
      if (state == MubiState::Stand) {
        graphics.TranslateTransform(0, 124);
        graphics.ScaleTransform(1.0f, static_cast<float>(1.0 + 0.06 *
                                                          anim_progress));
        graphics.TranslateTransform(0, -124);
      }

      bool const dark = IsDark();
      char const* fin_hex = "#F1E4CC";
      char const* body_light = "#FBF5E9";
      char const* body_mid = "#F6EEDF";
      char const* body_deep = "#E8D7BE";
      char const* shadow_hex = "#D8C8B5";
      char const* ink_hex = "#2D2A28";
      if (dark) {
        fin_hex = "#E4D6BC";
        body_light = "#EDE2CC";
        body_mid = "#E4D6BC";
        body_deep = "#CDBB9F";
        shadow_hex = "#5A5245";
        ink_hex = "#F1EEE7";
      }

      // Fins.
      {
        Gdiplus::GraphicsPath fin;
        parse_path(
            "M 52 24 C 47 13, 40 7, 32 6 C 30 14, 36 23, 45 27 "
            "C 48 28.2, 51 26.5, 52 24 Z", true, fin);
        Gdiplus::SolidBrush brush(argb(255, fin_hex));
        graphics.FillPath(&brush, &fin);
        Gdiplus::GraphicsPath fin2;
        parse_path(
            "M 74 23 C 71 14, 66.5 8, 60.5 6 C 58.5 13, 62.5 21.5, 70 25 "
            "C 72.3 25.9, 73.8 25, 74 23 Z", true, fin2);
        graphics.FillPath(&brush, &fin2);
        Gdiplus::GraphicsPath shade;
        parse_path(
            "M 48 22 C 44.5 15.5, 39.5 10.5, 34.5 8.5 "
            "C 33.5 13.5, 38 20.5, 45 24.5 Z", true, shade);
        Gdiplus::SolidBrush shade_brush(argb(90, shadow_hex));
        graphics.FillPath(&shade_brush, &shade);
      }

      // Body with the volume gradient (tokens: body.light -> body -> deep).
      {
        Gdiplus::GraphicsPath body;
        parse_path(
            "M 58 16 C 82 18, 106 46, 109 82 C 111 104, 92 124, 60 124 "
            "C 33 124, 12.5 106, 11 84 C 9.5 52, 34 14, 58 16 Z", true,
            body);
        Gdiplus::LinearGradientBrush brush(
            Gdiplus::PointF(20, 14), Gdiplus::PointF(95, 124),
            argb(255, body_light), argb(255, body_deep));
        Gdiplus::Color stops[] = {
            argb(255, body_light), argb(255, body_mid),
            argb(255, body_deep)};
        float const positions[] = {0.0f, 0.45f, 1.0f};
        brush.SetInterpolationColors(stops, positions, 3);
        graphics.FillPath(&brush, &body);
      }

      // Lower form shade.
      {
        Gdiplus::GraphicsPath lower;
        parse_path(
            "M 16 96 C 24 118, 42 126, 60 126 C 80 126, 98 116, 105 94 "
            "C 100 116, 84 128, 60 128 C 38 128, 20 114, 16 96 Z", true,
            lower);
        Gdiplus::LinearGradientBrush brush(
            Gdiplus::PointF(0, 94), Gdiplus::PointF(0, 128),
            argb(0, shadow_hex), argb(140, shadow_hex));
        graphics.FillPath(&brush, &lower);
      }

      // Face at the frozen placement; state decides open/closed/props.
      auto eye = [&](double cx, double cy) {
        Gdiplus::SolidBrush eye_brush(argb(255, ink_hex));
        graphics.FillEllipse(
            &eye_brush, static_cast<float>(cx - 3),
            static_cast<float>(cy - 3.6), 6.0f, 7.2f);
      };
      auto closed_arc = [&](char const* d) {
        Gdiplus::GraphicsPath arc;
        parse_path(d, false, arc);
        Gdiplus::Pen pen(argb(255, ink_hex), 2.2f);
        pen.SetStartCap(Gdiplus::LineCapRound);
        pen.SetEndCap(Gdiplus::LineCapRound);
        graphics.DrawPath(&pen, &arc);
      };
      if (state == MubiState::Eyes || state == MubiState::Focus) {
        closed_arc("M 43 65 C 45 67.6, 48 67.6, 50 65");
        closed_arc("M 70 65 C 72 67.6, 75 67.6, 77 65");
      } else {
        eye(46.5, 65);
        eye(73.5, 65);
        if (act == 3) {
          // Teary begging droplets welling under each eye.
          Gdiplus::SolidBrush tear_brush(argb(217, "#65C8B8"));
          graphics.FillEllipse(&tear_brush, 45.1f, 69.5f, 2.8f, 4.2f);
          graphics.FillEllipse(&tear_brush, 72.1f, 69.5f, 2.8f, 4.2f);
        }
        if (state == MubiState::Ack) {
          closed_arc("M 57.5 74 C 59 75.4, 61 75.4, 62.5 74");
        }
      }

      // Per-state props (one expressive gesture per cue, #56 §4).
      if (state == MubiState::Water) {
        graphics.TranslateTransform(97, static_cast<float>(51 -
                                                         12 * anim_progress));
        graphics.RotateTransform(-10);
        graphics.ScaleTransform(0.9f, 0.9f);
        Gdiplus::GraphicsPath cup;
        parse_path(
            "M -7 -9 L 7 -9 L 5.4 9 C 5.2 10.6, 4 11.5, 2.4 11.5 "
            "L -2.4 11.5 C -4 11.5, -5.2 10.6, -5.4 9 Z", true, cup);
        Gdiplus::SolidBrush cup_brush(argb(255, "#62B6FF"));
        graphics.FillPath(&cup_brush, &cup);
        Gdiplus::GraphicsPath water;
        parse_path(
            "M -4.6 -6.5 L 4.4 -6.5 L 3.6 1.5 L -4 1.5 Z", true, water);
        Gdiplus::SolidBrush water_brush(argb(217, "#8FCBFF"));
        graphics.FillPath(&water_brush, &water);
      } else if (state == MubiState::Stand) {
        BYTE const a = static_cast<BYTE>((0.3 + 0.7 * anim_progress) * 255);
        Gdiplus::Pen pen(argb(a, "#FF8C6B"), 3.0f);
        pen.SetStartCap(Gdiplus::LineCapRound);
        pen.SetEndCap(Gdiplus::LineCapRound);
        Gdiplus::GraphicsPath left;
        parse_path("M 42 11 C 47 4, 53 2, 58 4", false, left);
        graphics.DrawPath(&pen, &left);
        Gdiplus::Pen pen2(argb(static_cast<BYTE>(a * 0.65), "#FF8C6B"),
                          3.0f);
        pen2.SetStartCap(Gdiplus::LineCapRound);
        pen2.SetEndCap(Gdiplus::LineCapRound);
        Gdiplus::GraphicsPath right;
        parse_path("M 78 11 C 73 4, 67 2, 62 4", false, right);
        graphics.DrawPath(&pen2, &right);
      } else if (state == MubiState::Eyes) {
        Gdiplus::Pen pen(argb(255, "#65C8B8"), 3.0f);
        pen.SetStartCap(Gdiplus::LineCapRound);
        pen.SetEndCap(Gdiplus::LineCapRound);
        Gdiplus::GraphicsPath arc;
        parse_path("M 92 38 C 96.5 40.5, 99 45, 98 50", false, arc);
        graphics.DrawPath(&pen, &arc);
      } else if (state == MubiState::Ack) {
        Gdiplus::GraphicsPath glint;
        parse_path(
            "M 84 56 L 86 60.5 L 90.5 62 L 86 63.5 L 84 68 L 82 63.5 "
            "L 77.5 62 L 82 60.5 Z", true, glint);
        BYTE a = static_cast<BYTE>((0.4 + 0.6 * anim_progress) * 255);
        Gdiplus::SolidBrush glint_brush(argb(a, "#F2C96B"));
        graphics.FillPath(&glint_brush, &glint);
      } else if (state == MubiState::Focus) {
        Gdiplus::SolidBrush moon_brush(argb(190, "#8DA1B5"));
        graphics.FillEllipse(&moon_brush, 88.0f, 30.0f, 16.0f, 16.0f);
      }

      graphics.ResetTransform();

      // Label capsule: contextual pill during cues (or always, per the
      // Label setting). Painted into the same alpha surface — no second
      // window anywhere.
      bool const show_label = labels_always || !message.empty();
      if (show_label) {
        std::wstring const text = message.empty() ? L"MoveBit" : message;
        float const pill_w = (IsReadableHealthCue() ? 244.0f : 120.0f * s)
                             * static_cast<float>(dp);
        float const pill_h = (IsReadableHealthCue() ? 54.0f : 30.0f)
                             * static_cast<float>(dp);
        float const px = (static_cast<float>(size.cx) - pill_w) / 2.0f;
        float const py = static_cast<float>(size.cy) - pill_h - 4.0f * dp;
        Gdiplus::SolidBrush pill(dark ? argb(230, "#33302B")
                                      : argb(235, "#FFFDFB"));
        // GDI+ has no rounded-rect fill: a pill is two half-cap arcs
        // closed by the top and bottom edges.
        Gdiplus::GraphicsPath pill_path;
        float const cap_d = pill_h;
        pill_path.AddArc(px, py, cap_d, cap_d, 180, 180);
        pill_path.AddArc(px + pill_w - cap_d, py, cap_d, cap_d, 270,
                         180);
        pill_path.CloseFigure();
        graphics.FillPath(&pill, &pill_path);
        Gdiplus::FontFamily family(IsCjkText(text) ? L"Microsoft YaHei UI"
                                                   : L"Segoe UI");
        Gdiplus::Font font(&family,
                           static_cast<float>((IsReadableHealthCue() ? 14 : 12) * dp),
                           Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush text_brush(dark ? argb(255, "#F1EEE7")
                                            : argb(255, "#2D2A28"));
        Gdiplus::StringFormat format;
        format.SetAlignment(Gdiplus::StringAlignmentCenter);
        format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        Gdiplus::RectF box(px, py, pill_w, pill_h);
        graphics.DrawString(text.c_str(), -1, &font, box, &format,
                            &text_brush);
        if (IsReadableHealthCue()) {
          // The Later tag: one click defers every merged kind (issue #140).
          float const tag_w = 64.0f * dp;
          float const tag_h = pill_h - 12.0f * dp;
          float const tag_x = px + pill_w - tag_w - 6.0f * dp;
          float const tag_y = py + 6.0f * dp;
          Gdiplus::GraphicsPath tag_path;
          float const tag_cap = tag_h;
          tag_path.AddArc(tag_x, tag_y, tag_cap, tag_cap, 180, 180);
          tag_path.AddArc(tag_x + tag_w - tag_cap, tag_y, tag_cap, tag_cap,
                          270, 180);
          tag_path.CloseFigure();
          Gdiplus::SolidBrush tag_brush(dark ? argb(255, "#4A453D")
                                             : argb(255, "#EFE3D2"));
          graphics.FillPath(&tag_brush, &tag_path);
          Gdiplus::FontFamily tag_family(
              IsCjkText(later_tag_text) ? L"Microsoft YaHei UI" : L"Segoe UI");
          Gdiplus::Font tag_font(
              &tag_family, static_cast<float>(11 * dp), Gdiplus::FontStyleBold,
              Gdiplus::UnitPixel);
          Gdiplus::SolidBrush tag_text_brush(
              dark ? argb(255, "#F1EEE7") : argb(255, "#2D2A28"));
          Gdiplus::StringFormat tag_format;
          tag_format.SetAlignment(Gdiplus::StringAlignmentCenter);
          tag_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
          Gdiplus::RectF tag_box(tag_x, tag_y, tag_w, tag_h);
          graphics.DrawString(later_tag_text.c_str(), -1, &tag_font, tag_box,
                              &tag_format, &tag_text_brush);
        }
      }
    }

    mubi_detail::premultiply(static_cast<BYTE*>(bits), size.cx * size.cy);

    // Content + dock positioning in one atomic UpdateLayeredWindow.
    POINT dst = visit_phase == VisitPhase::None
                    ? dock_position(size) : visit_position;
    POINT src{0, 0};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    if (!::UpdateLayeredWindow(hwnd, screen, &dst, &size, mem, &src, 0,
                               &blend, ULW_ALPHA)) {
      mubi_trace("render:ulw-failed");
    }
    ::SelectObject(mem, old);
    ::DeleteObject(dib);
    ::DeleteDC(mem);
    ::ReleaseDC(nullptr, screen);
  }

  static bool IsCjkText(std::wstring const& text) {
    for (wchar_t ch : text) {
      if (ch >= 0x2E80) return true;
    }
    return false;
  }

  // Art direction per card build: the same setting XAML's ActualTheme
  // resolves, read from the registry (never touches any window tree).
  static bool IsDark() {
    HIGHCONTRAST hc{sizeof(HIGHCONTRAST)};
    if (::SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(hc), &hc, 0) &&
        (hc.dwFlags & HCF_HIGHCONTRASTON)) {
      return true;
    }
    DWORD light = 1;
    DWORD size = sizeof(light);
    if (::RegGetValueW(HKEY_CURRENT_USER,
                       L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes"
                       L"\\Personalize",
                       L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr,
                       &light, &size) == ERROR_SUCCESS) {
      return light == 0;
    }
    return false;
  }

  static bool IsDueState(MubiState state) {
    return state == MubiState::Water || state == MubiState::Stand ||
           state == MubiState::Eyes;
  }

  void StopVisit() {
    if (visit_timer) visit_timer.Stop();
    visit_phase = VisitPhase::None;
    visit_step = 0;
  }

  void StartVisit(MubiState state) {
    // Focus, Still and short "Later" replies do not travel.
    if (!IsDueState(state) || motion == "still" || quiet) return;
    // Respect the native Windows accessibility preference for less animation.
    BOOL client_animation_enabled = TRUE;
    if (::SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0,
                                &client_animation_enabled, 0) &&
        !client_animation_enabled) return;
    SIZE const size = pixel_size();
    visit_home = dock_position(size);
    HMONITOR const monitor = ::MonitorFromPoint(visit_home, MONITOR_DEFAULTTONEAREST);
    MONITORINFO info{sizeof(MONITORINFO)};
    if (!::GetMonitorInfoW(monitor, &info)) return;
    RECT const wa = info.rcWork;
    // RECT and SIZE use LONG; keep std::clamp operands the same type on
    // MSVC (mixing LONG with int fails template argument deduction).
    LONG const margin = 16;
    LONG const max_x = std::max(wa.left + margin,
                                wa.right - size.cx - margin);
    LONG const max_y = std::max(wa.top + margin,
                                wa.bottom - size.cy - margin);
    visit_target.x = std::clamp(wa.left + (wa.right - wa.left - size.cx) / 2,
                                wa.left + margin, max_x);
    visit_target.y = std::clamp(wa.top + (wa.bottom - wa.top - size.cy) / 2,
                                wa.top + margin, max_y);
    visit_position = visit_home;
    visit_step = 0;
    visit_phase = VisitPhase::Approaching;
    if (!visit_timer) {
      visit_timer = make_timer(std::chrono::milliseconds(40), true, [this] {
        if (hwnd == nullptr || quiet) { StopVisit(); return; }
        if (visit_phase != VisitPhase::Approaching &&
            visit_phase != VisitPhase::Returning) {
          if (visit_timer) visit_timer.Stop();
          return;
        }
        bool const returning = visit_phase == VisitPhase::Returning;
        int const steps = returning ? 12 : 18;
        double const t = std::min(1.0,
                                  static_cast<double>(++visit_step) / steps);
        double const eased = t * t * (3.0 - 2.0 * t);
        POINT const from = returning ? visit_target : visit_home;
        POINT const to = returning ? visit_home : visit_target;
        visit_position = POINT{
            static_cast<LONG>(std::lround(from.x + (to.x - from.x) * eased)),
            static_cast<LONG>(std::lround(from.y + (to.y - from.y) * eased))};
        Render(anim_state, current_message);
        if (t >= 1.0) {
          visit_timer.Stop();
          if (returning) {
            visit_phase = VisitPhase::None;
            ShowIdle();
          } else {
            visit_phase = VisitPhase::Holding;
          }
        }
      });
    }
    visit_timer.Start();
  }

  void BeginReturn() {
    if (visit_phase == VisitPhase::None) { ShowIdle(); return; }
    if (visit_phase == VisitPhase::Returning) return;
    visit_phase = VisitPhase::Returning;
    visit_step = 0;
    if (visit_timer) visit_timer.Start();
  }

  // One expressive gesture per due moment (#56 §4); "still" stays static.
  void StartGesture(MubiState state) {
    if (anim_timer) anim_timer.Stop();
    anim_progress = 1.0;
    std::int64_t ms = 0;
    switch (state) {
      case MubiState::Water: ms = motion == "lively" ? 950 : 750; break;
      case MubiState::Stand: ms = motion == "lively" ? 1150 : 900; break;
      case MubiState::Ack: ms = 450; break;
      default: ms = 0; break;  // eyes/idle/focus are the quietest poses
    }
    if (ms == 0 || motion == "still") return;
    anim_progress = 0.0;
    anim_total_ticks = ms / 33 + 1;
    if (!anim_timer) {
      anim_timer = make_timer(std::chrono::milliseconds(33), true, [this] {
        anim_progress =
            std::min(1.0, anim_progress + 1.0 /
                                        static_cast<double>(anim_total_ticks));
        Render(anim_state, current_message);
        if (anim_progress >= 1.0 && anim_timer) anim_timer.Stop();
      });
    }
    anim_timer.Start();
  }

  // Persistent invitations (issue #140): due cues never auto-return — the
  // surface waits until answered. Only a transient reply (the Later note)
  // settles back after ~5 s; timeouts never ack the cue ledger.
  void StartLabelTimer(std::wstring const& message, MubiState state) {
    if (label_timer) label_timer.Stop();
    if (IsDueState(state)) return;
    // "Always show label" means persistent idle text, NOT a recurring
    // five-second idle timer that repeatedly wakes and recreates Mubi.
    if (message.empty()) return;
    if (!label_timer) {
      label_timer = make_timer(std::chrono::milliseconds(5000), false,
                               [this] {
                                 if (visit_phase != VisitPhase::None)
                                   BeginReturn();
                                 else
                                   ShowIdle();
                               });
    }
    label_timer.Interval(std::chrono::milliseconds(5000));
    label_timer.Start();
  }

  // ---- petting + repertoire (issue #140) --------------------------------

  void HandleCueClick(LONG x, LONG y) {
    UINT dpi = ::GetDpiForWindow(hwnd);
    double const dp = static_cast<double>(dpi) / 96.0;
    double const s = body_height / 108.0;
    SIZE const size = pixel_size();
    double const grid_w = 120.0 * s * dp;
    double const grid_h = 140.0 * s * dp;
    double const grid_ox = (static_cast<double>(size.cx) - grid_w) / 2.0;
    double const grid_oy = (static_cast<double>(size.cy) - grid_h) / 2.0 -
                           22.0 * dp;
    // Character: pet = Done.
    RECT const pet{static_cast<LONG>(grid_ox),
                   static_cast<LONG>(grid_oy),
                   static_cast<LONG>(grid_ox + grid_w),
                   static_cast<LONG>(grid_oy + grid_h)};
    // Later tag: right end of the capsule pill band.
    double const pill_w = 244.0 * dp;
    double const pill_h = 54.0 * dp;
    double const pill_x = (static_cast<double>(size.cx) - pill_w) / 2.0;
    double const pill_y =
        static_cast<double>(size.cy) - pill_h - 4.0 * dp;
    RECT const later{static_cast<LONG>(pill_x + pill_w / 2),
                     static_cast<LONG>(pill_y),
                     static_cast<LONG>(pill_x + pill_w),
                     static_cast<LONG>(pill_y + pill_h)};
    POINT const point{x, y};
    if (::PtInRect(&later, point)) {
      if (on_later) on_later();
    } else if (::PtInRect(&pet, point)) {
      if (on_pet) on_pet();
    }
    // Clicks on empty surface areas do nothing: only an explicit answer
    // (pet, tag, tray) ends the invitation.
  }

  void StartProximity() {
    if (proximity_timer) {
      proximity_timer.Start();
      return;
    }
    proximity_timer = make_timer(std::chrono::milliseconds(250), true,
                                 [this] {
      if (hwnd == nullptr || placing || !attending) return;
      POINT cursor{};
      if (!::GetCursorPos(&cursor)) return;
      RECT rect{};
      if (!::GetWindowRect(hwnd, &rect)) return;
      bool const inside = ::PtInRect(&rect, cursor) != FALSE;
      LONG_PTR ex = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
      bool const transparent_now =
          (ex & static_cast<LONG_PTR>(WS_EX_TRANSPARENT)) != 0;
      if (inside == transparent_now) {
        // Cursor over Mubi: the surface becomes pettable; elsewhere it
        // returns to full pointer-through.
        ApplyPlacementStyle(!inside);
      }
    });
    proximity_timer.Start();
  }

  void StopProximity() {
    if (proximity_timer) proximity_timer.Stop();
    if (!placing && hwnd != nullptr) ApplyPlacementStyle(false);
  }

  void StartAct(int kind, bool attending) {
    if (act_timer) act_timer.Stop();
    act = kind;
    act_side = (::GetTickCount64() % 2) == 0 ? 1.0 : -1.0;
    act_progress = 0.0;
    act_total_ticks = 600.0 / 33.0 + 1.0;
    if (!act_timer) {
      act_timer = make_timer(std::chrono::milliseconds(33), true,
                             [this, attending] {
        act_progress = std::min(
            1.0, act_progress + 1.0 / act_total_ticks);
        Render(anim_state, current_message);
        if (act_progress >= 1.0) {
          if (act_timer) act_timer.Stop();
          act = 0;
          act_progress = 1.0;
          SchedulePlay(attending);
        }
      });
    }
    act_timer.Start();
  }

  void SchedulePlay(bool attending) {
    if (play_timer) play_timer.Stop();
    if (motion == "still" || quiet || placing) return;
    BOOL client_animation_enabled = TRUE;
    if (::SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0,
                                &client_animation_enabled, 0) &&
        !client_animation_enabled) {
      return;
    }
    if (attending != this->attending) return;
    auto const ms = static_cast<int>(
        attending ? 13000 + (::GetTickCount64() % 7000)
                  : 12000 + (::GetTickCount64() % 10000));
    if (!play_timer) {
      play_timer = make_timer(std::chrono::milliseconds(ms), false,
                              [this, attending] {
        if (play_timer) play_timer.Stop();
        if (motion == "still" || quiet || placing ||
            attending != this->attending) {
          return;
        }
        int const kind = attending
            ? static_cast<int>(::GetTickCount64() % 3) + 1
            : (::GetTickCount64() % 2 == 0 ? 4 : 1);
        StartAct(kind, attending);
      });
    }
    play_timer.Interval(std::chrono::milliseconds(ms));
    play_timer.Start();
  }

  void StopPlay() {
    if (play_timer) play_timer.Stop();
    if (act_timer) act_timer.Stop();
    act = 0;
    act_progress = 1.0;
  }
};

}  // namespace winrt::RivetHost::implementation
