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

  HWND hwnd = nullptr;
  Microsoft::UI::Dispatching::DispatcherQueueTimer anim_timer{nullptr};
  Microsoft::UI::Dispatching::DispatcherQueueTimer label_timer{nullptr};
  double anim_progress = 0.0;
  std::int64_t anim_total_ticks = 0;
  MubiState anim_state = MubiState::Idle;

  static double body_height_for(std::string const& size) {
    if (size == "S") return 60;
    if (size == "L") return 104;
    return 78;
  }

  void ApplyConfig(std::string const& size, std::string const& m,
                   std::string const& d, std::string const& labels) {
    body_height = body_height_for(size);
    motion = m;
    dock = d;
    labels_always = labels == "always";
    if (hwnd != nullptr) {
      Render(quiet ? MubiState::Focus : MubiState::Idle, L"");
    }
  }

  void SetQuiet(bool enabled) {
    quiet = enabled;
    if (acceptance_mode()) return;
    Show(quiet ? MubiState::Focus : MubiState::Idle, L"");
  }

  void Show(MubiState state, std::wstring const& message) {
    if (acceptance_mode()) return;
    mubi_trace("show:enter");
    try {
      EnsureWindow();
      mubi_trace("show:ensure-ok");
      anim_state = state;
      current_message = message;
      Render(state, message);
      mubi_trace("show:render-ok");
      StartGesture(state);
      StartLabelTimer(message);
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
  }

  void Dismiss() {
    mubi_trace("dismiss:enter");
    if (hwnd != nullptr) {
      ::DestroyWindow(hwnd);
      hwnd = nullptr;
    }
    if (anim_timer) anim_timer.Stop();
    if (label_timer) label_timer.Stop();
  }

 private:
  std::wstring current_message;

  // 120x140 design grid + capsule row; scaled by the Mubi size and DPI.
  SIZE pixel_size() const {
    UINT dpi = 96;
    if (hwnd != nullptr) dpi = ::GetDpiForWindow(hwnd);
    double const dp = static_cast<double>(dpi) / 96.0;
    double const s = body_height / 108.0;
    int const w = static_cast<int>((120.0 * s + 8.0) * dp);
    int const h = static_cast<int>((140.0 * s + 8.0) * dp);
    return SIZE{w, h};
  }

  void EnsureWindow() {
    mubi_detail::gdiplus_token();
    if (hwnd != nullptr) return;
    WNDCLASSW wc{};
    wc.lpfnWndProc = ::DefWindowProcW;
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
    // Float above normal windows without stealing focus; never in the
    // taskbar (the TOOLWINDOW ex-style already keeps it out).
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
    if (dock == "bottom-left") {
      x = wa.left + clearance;
      y = wa.bottom - size.cy - clearance;
    } else if (dock == "top-right") {
      x = wa.right - size.cx - clearance;
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
    SIZE const size = pixel_size();

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
      float const oy = static_cast<float>((size.cy - grid_h) / 2.0);
      graphics.TranslateTransform(ox, oy);
      graphics.ScaleTransform(static_cast<float>(s * dp),
                              static_cast<float>(s * dp));
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
        Gdiplus::SolidBrush shade_brush(argb(90, "#D8C8B5"));
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
        brush.SetInterpolationColors(stops, 3);
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
        graphics.FillEllipse(&Gdiplus::SolidBrush(argb(255, ink_hex)),
                             static_cast<float>(cx - 3), static_cast<float>(cy - 3.6),
                             6.0f, 7.2f);
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
        graphics.FillPath(&Gdiplus::SolidBrush(argb(255, "#62B6FF")), &cup);
        Gdiplus::GraphicsPath water;
        parse_path(
            "M -4.6 -6.5 L 4.4 -6.5 L 3.6 1.5 L -4 1.5 Z", true, water);
        graphics.FillPath(&Gdiplus::SolidBrush(argb(217, "#8FCBFF")),
                          &water);
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
        graphics.FillPath(&Gdiplus::SolidBrush(argb(a, "#F2C96B")),
                          &glint);
      } else if (state == MubiState::Focus) {
        graphics.FillEllipse(&Gdiplus::SolidBrush(argb(190, "#8DA1B5")),
                             88.0f, 30.0f, 16.0f, 16.0f);
      }

      graphics.ResetTransform();

      // Label capsule: contextual pill during cues (or always, per the
      // Label setting). Painted into the same alpha surface — no second
      // window anywhere.
      bool const show_label = labels_always || !message.empty();
      if (show_label) {
        std::wstring const text = message.empty() ? L"MoveBit" : message;
        float const pill_w = 120.0f * s * dp;
        float const pill_h = 30.0f * dp;
        float const px = (static_cast<float>(size.cx) - pill_w) / 2.0f;
        float const py = static_cast<float>(size.cy) - pill_h - 4.0f * dp;
        Gdiplus::SolidBrush pill(dark ? argb(230, "#33302B")
                                      : argb(235, "#FFFDFB"));
        graphics.FillRoundedRectangle(
            &pill, px, py, pill_w, pill_h, 10.0f * dp);
        Gdiplus::FontFamily family(IsCjkText(text) ? L"Microsoft YaHei UI"
                                                   : L"Segoe UI");
        Gdiplus::Font font(&family, static_cast<float>(12 * dp),
                           Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush text_brush(dark ? argb(255, "#F1EEE7")
                                            : argb(255, "#2D2A28"));
        Gdiplus::StringFormat format;
        format.SetAlignment(Gdiplus::StringAlignmentCenter);
        format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        Gdiplus::RectF box(px, py, pill_w, pill_h);
        graphics.DrawString(text.c_str(), -1, &font, box, &format,
                            &text_brush);
      }
    }

    mubi_detail::premultiply(static_cast<BYTE*>(bits), size.cx * size.cy);

    // Content + dock positioning in one atomic UpdateLayeredWindow.
    POINT const dst = dock_position(size);
    POINT const src{0, 0};
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

  // The label reads ~5 s, then the card returns to its calm pose (#56 §4).
  void StartLabelTimer(std::wstring const& message) {
    if (label_timer) label_timer.Stop();
    if (message.empty() && !labels_always) return;
    if (!label_timer) {
      label_timer = make_timer(std::chrono::milliseconds(5000), false,
                               [this] {
                                 ShowIdle();
                               });
    }
    label_timer.Start();
  }
};

}  // namespace winrt::RivetHost::implementation
