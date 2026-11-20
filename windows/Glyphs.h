#pragma once

// Shared vector glyphs, ported 1:1 from the prototype's linear icon
// vocabulary (design/prototype/shared.js `healthIcon`, 24x24 stroke
// paths; circles are expressed as arc paths because the XAML path
// mini-language has no circle shorthand). Emoji placeholders are
// retired (#167): the design contract requires one linear glyph
// vocabulary for all functional icons, and the welcome window shows a
// static vector Mubi built from the prototype's own pet geometry.

#include "pch.h"

#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Shapes.h>

#include <string>

namespace winrt::RivetHost::implementation {

using namespace winrt::Microsoft::UI::Xaml;

enum class HealthGlyph { sit, water, eyes };

inline wchar_t const* health_glyph_data(HealthGlyph kind) {
  switch (kind) {
    case HealthGlyph::sit:
      // circle(13,4,r2) + walking figure
      return L"M11 4a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"
             L"m-1 5 3-2 3 4 3 1M13 7l-2 7 4 3 1 5M11 14l-4 6M10 9l-4 3";
    case HealthGlyph::water:
      // droplet + inner arc
      return L"M12 3C9 7 5 11 5 15a7 7 0 0 0 14 0c0-4-4-8-7-12Z"
             L"M9 16a3 3 0 0 0 3 3";
    case HealthGlyph::eyes:
      // eye + pupil circle(12,12,r3)
      return L"M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z"
             L"M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0";
  }
  return L"";
}

// Stroke-only glyph rendered at `size` px, mirroring the prototype's
// fill=none / round caps-and-joins rendering.
inline FrameworkElement make_health_glyph(HealthGlyph kind, double size,
                                          wchar_t const* stroke_hex,
                                          double stroke_width) {
  auto xaml =
      std::wstring(
          L"<Viewbox xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' "
          L"Width='") +
      std::to_wstring(size) + L"' Height='" + std::to_wstring(size) +
      L"'>"
      L"<Path Data='" +
      health_glyph_data(kind) +
      L"' Fill='None' Stroke='" + stroke_hex +
      L"' StrokeThickness='" + std::to_wstring(stroke_width) +
      L"' StrokeStartLineCap='Round' StrokeEndLineCap='Round' "
      L"StrokeLineJoin='Round' Width='24' Height='24'/>"
      L"</Viewbox>";
  return Markup::XamlReader::Load(xaml).as<FrameworkElement>();
}

// Static welcome Mubi: the hello pose (smiling eyes, raised right hand)
// drawn with the prototype's own pet geometry and palette tokens
// (design/prototype/shared.css --mubi-*), so first launch meets the same
// character as the desktop instead of an emoji stand-in.
inline FrameworkElement make_mubi_welcome() {
  auto xaml = std::wstring(
      L"<Viewbox xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' "
      L"Width='104' Height='121'>"
      L"<Canvas Width='120' Height='140'>"
      // ground shadow
      L"<Ellipse Canvas.Left='30' Canvas.Top='128' Width='60' Height='8' "
      L"Fill='#D8C8B5' Opacity='0.32'/>"
      // leaf fins
      L"<Path Data='M52 24C47 13 40 7 32 6 30 14 36 23 45 27 48 28 51 26 52 24Z' "
      L"Fill='#F1E4CC'/>"
      L"<Path Data='M74 23C71 14 66.5 8 60.5 6 58.5 13 62.5 21.5 70 25 72 26 74 25 74 23Z' "
      L"Fill='#F1E4CC'/>"
      // body
      L"<Path Data='M58 16C82 18 106 46 109 82 111 104 92 124 60 124 33 124 12.5 106 11 84 9.5 52 34 14 58 16Z'>"
      L"<Path.Fill>"
      L"<LinearGradientBrush StartPoint='0,0' EndPoint='1,1'>"
      L"<GradientStop Color='#FBF5E9' Offset='0'/>"
      L"<GradientStop Color='#F6EEDF' Offset='0.55'/>"
      L"<GradientStop Color='#E8D7BE' Offset='1'/>"
      L"</LinearGradientBrush>"
      L"</Path.Fill>"
      L"</Path>"
      // hands (right one waves: prototype hello pose)
      L"<Path Data='M22 91q-10 3-7 11 5 6 11-2' Fill='#F1E4CC'/>"
      L"<Path Data='M96 90q11 4 8 12-5 5-11-3' Fill='#F1E4CC'>"
      L"<Path.RenderTransform>"
      L"<RotateTransform Angle='-32' CenterX='100' CenterY='98'/>"
      L"</Path.RenderTransform>"
      L"</Path>"
      // smiling eyes + blush + mouth
      L"<Path Data='M42 66q5 -8 10 0' Stroke='#2D2A28' StrokeThickness='2.5' "
      L"StrokeStartLineCap='Round' StrokeEndLineCap='Round'/>"
      L"<Path Data='M69 66q5 -8 10 0' Stroke='#2D2A28' StrokeThickness='2.5' "
      L"StrokeStartLineCap='Round' StrokeEndLineCap='Round'/>"
      L"<Ellipse Canvas.Left='29' Canvas.Top='73.5' Width='14' Height='7' "
      L"Fill='#E79E88' Opacity='0.6'/>"
      L"<Ellipse Canvas.Left='78' Canvas.Top='73.5' Width='14' Height='7' "
      L"Fill='#E79E88' Opacity='0.6'/>"
      L"<Path Data='M55 77q6 10 12 0' Fill='#B98070' Stroke='#2D2A28' "
      L"StrokeThickness='1.5' StrokeStartLineCap='Round' "
      L"StrokeEndLineCap='Round'/>"
      L"</Canvas>"
      L"</Viewbox>");
  return Markup::XamlReader::Load(xaml).as<FrameworkElement>();
}

}  // namespace winrt::RivetHost::implementation
