import SwiftUI
import AppKit

// The utility window per the 2026-11-15 contract (design/DESIGN.md 辅助
// 窗口): compact titlebar, four in-window segments (今日 / 历史 / 设置 /
// 关于) with per-segment scroll preservation, and a statusbar. No web
// navigation, marketing headline or footer. All four segments stay mounted
// so each keeps its scroll position while hidden (prototype tabScroll).

// MARK: - palette (2026-11-15 tokens, light/dark paired)

enum Palette {
    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(hex: hex)
        }))
    }

    // Window surfaces + type (design/DESIGN.md 视觉规范 table).
    static let appBg = dynamic(light: "#F8F7F3", dark: "#282622")
    static let titlebarBg = dynamic(light: "#F0EEE8", dark: "#302D28")
    static let cardBg = dynamic(light: "#FFFFFF", dark: "#2A2622")
    static let cardBorder = dynamic(light: "#E5DED2", dark: "#3A352E")
    static let inkPrimary = dynamic(light: "#26241F", dark: "#F1EBDF")
    static let inkSecondary = dynamic(light: "#655F55", dark: "#C0B5A4")
    static let inkMuted = dynamic(light: "#8B857A", dark: "#8F8676")
    static let accent = dynamic(light: "#A7472C", dark: "#EFAA85")
    static let accentSoft = dynamic(light: "#FBEFE2", dark: "#413025")
    static let trackBg = dynamic(light: "#EAE3D7", dark: "#39332C")
    static let chartBar = dynamic(light: "#AEA08A", dark: "#9C8C75")
    static let waterBlue = dynamic(light: "#488BBE", dark: "#95C6F7")
    static let okGreen = dynamic(light: "#267344", dark: "#8BCE9D")
    static let pausedOrange = Color(red: 0xEA / 255, green: 0x58 / 255, blue: 0x0C / 255)
    static let runningGreen = dynamic(light: "#267344", dark: "#8BCE9D")

    static func kindAccent(_ kind: ReminderKind) -> Color {
        switch kind {
        case .water: return waterBlue
        case .sit: return pausedOrange
        case .micro: return Color(red: 0x8A / 255, green: 0x84 / 255, blue: 0x9E / 255)
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: .alphanumerics.inverted))
            .scanHexInt64(&value)
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

// MARK: - ReminderConfig copy helper (generated records expose `let` fields)

extension ReminderConfig {
    /// The slim settings surface (issue #140): language, quiet hours,
    /// sound, auto-update — plus internal state (welcome-shown) and the
    /// drag-placed home position. Cadence and presentation are product
    /// defaults and have no setters at all.
    func with(
        sound_enabled: Bool? = nil,
        auto_check_updates: Bool? = nil,
        welcome_shown: Bool? = nil,
        language: String? = nil,
        quiet_hours_enabled: Bool? = nil,
        quiet_hours_start_minutes: Int64? = nil,
        quiet_hours_end_minutes: Int64? = nil,
        companion_free_x: Int64? = nil,
        companion_free_y: Int64? = nil
    ) -> ReminderConfig {
        ReminderConfig(
            sound_enabled: sound_enabled ?? self.sound_enabled,
            auto_check_updates: auto_check_updates ?? self.auto_check_updates,
            welcome_shown: welcome_shown ?? self.welcome_shown,
            language: language ?? self.language,
            quiet_hours_enabled: quiet_hours_enabled ?? self.quiet_hours_enabled,
            quiet_hours_start_minutes:
                quiet_hours_start_minutes ?? self.quiet_hours_start_minutes,
            quiet_hours_end_minutes:
                quiet_hours_end_minutes ?? self.quiet_hours_end_minutes,
            companion_free_x: companion_free_x ?? self.companion_free_x,
            companion_free_y: companion_free_y ?? self.companion_free_y)
    }
}

// MARK: - history/insight computations (client-side, from fetched history)

struct DaySlice {
    let stats: DayStats
    let isToday: Bool
}

struct InsightSummary {
    let longest: Int64
    let average: Int64
    let busiest: DayStats?
}

extension MoveBitModel {
    static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    /// Zero-filled day list ending today; today's entry is the live state.
    func historySlice(days: Int) -> [DaySlice] {
        let calendar = Calendar.current
        let formatter = Self.keyFormatter
        let todayKey = today.date.isEmpty ? formatter.string(from: Date()) : today.date
        guard let start = formatter.date(from: todayKey) else { return [] }
        let byDate = Dictionary(history.map { ($0.date, $0) },
                                uniquingKeysWith: { first, _ in first })
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else {
                return nil
            }
            let key = formatter.string(from: day)
            let isToday = key == todayKey
            let stats = isToday ? today
                : byDate[key] ?? DayStats(date: key, active_mins: 0, sit_breaks: 0,
                                          water_reminders: 0, micro_breaks: 0,
                                          longest_session_mins: 0)
            return DaySlice(stats: stats, isToday: isToday)
        }
    }

    /// 30-day aggregates over active days (parity with RebuildInsights).
    func insightSummary(days: Int = 30) -> InsightSummary {
        let slices = historySlice(days: days)
        let longest = slices.map(\.stats.longest_session_mins).max() ?? 0
        let active = slices.filter { $0.stats.active_mins > 0 }
        let average = active.isEmpty ? 0
            : (active.map(\.stats.active_mins).reduce(0, +) + Int64(active.count) / 2)
                / Int64(active.count)
        let busiest = active.max { $0.stats.active_mins < $1.stats.active_mins }?.stats
        return InsightSummary(longest: longest, average: average, busiest: busiest)
    }

    func historyTotal(slices: [DaySlice]) -> Int64 {
        slices.map(\.stats.active_mins).reduce(0, +)
    }
}

// MARK: - root layout

/// The utility window content: compact titlebar + four segments + statusbar.
/// All segments stay mounted so each keeps its scroll position while hidden
/// (the prototype's per-tab scroll memory).
struct MainView: View {
    @EnvironmentObject var model: MoveBitModel
    // Dev/acceptance-only entry segment (MOVEBIT_DEBUG_SEGMENT); e2e asserts
    // each segment without synthetic clicks. Always "today" in production.
    @State private var segment = ProcessInfo.processInfo.environment[
        "MOVEBIT_DEBUG_SEGMENT"] ?? "today"

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            Divider().overlay(Palette.cardBorder)
            segmentTabs
            ZStack {
                segmentScroll("today") { TodaySegment() }
                segmentScroll("history") { HistorySegment() }
                segmentScroll("settings") { SettingsSegment() }
                segmentScroll("about") { AboutSegment() }
            }
            Divider().overlay(Palette.cardBorder)
            statusbar
        }
        .background(Palette.appBg)
        .frame(minWidth: 460, minHeight: 420)
    }

    /// Compact titlebar: the leaf mark + MoveBit on the platform titlebar
    /// row (traffic lights stay at the leading edge — 按平台标准窗口实现).
    private var titlebar: some View {
        HStack(spacing: 7) {
            leafMark
                .padding(.leading, 72) // traffic-light clearance
            Text("MoveBit")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.inkPrimary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.titlebarBg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.t("win.utilityA11y"))
    }

    /// The linear SVG leaf vocabulary (prototype glyph('leaf')).
    private var leafMark: some View {
        LeafIcon()
            .frame(width: 14, height: 14)
            .foregroundColor(Palette.inkSecondary)
    }

    private var segmentTabs: some View {
        HStack(spacing: 2) {
            segmentButton("today", L10n.t("seg.today"))
            segmentButton("history", L10n.t("seg.history"))
            segmentButton("settings", L10n.t("seg.settings"))
            segmentButton("about", L10n.t("seg.about"))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.titlebarBg)
        .accessibilityElement(children: .contain)
    }

    private func segmentButton(_ key: String, _ label: String) -> some View {
        Button {
            segment = key
        } label: {
            Text(label)
                .font(.system(size: 12.5, weight: segment == key ? .semibold : .regular))
                .foregroundColor(segment == key ? Palette.inkPrimary : Palette.inkSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(segment == key ? Color.primary.opacity(0.07)
                                             : Color.clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(segment == key ? .isSelected : [])
    }

    @ViewBuilder
    private func segmentScroll<Content: View>(_ key: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
        }
        .opacity(segment == key ? 1 : 0)
        .allowsHitTesting(segment == key)
        .accessibilityHidden(segment != key)
    }

    private var statusbar: some View {
        HStack(spacing: 8) {
            Text(L10n.t("win.dataLocal"))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
            Spacer()
            CompanionMenuButton { windowRect in
                AppDelegate.shared?.popupFromUtilityStatusbar(windowRect)
            }
            .frame(width: 28, height: 24)
            .accessibilityLabel(L10n.t("pet.menuOpen"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Palette.titlebarBg)
    }
}

/// The linear leaf glyph (canonical prototype icon vocabulary; not emoji).
struct LeafIcon: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 12, y: 21))
            path.addCurve(to: CGPoint(x: 12, y: 5),
                          control1: CGPoint(x: 3, y: 21),
                          control2: CGPoint(x: 3, y: 11))
            path.addCurve(to: CGPoint(x: 12, y: 5),
                          control1: CGPoint(x: 21, y: 11),
                          control2: CGPoint(x: 21, y: 21))
            path.closeSubpath()
            path.move(to: CGPoint(x: 12, y: 5))
            path.addCurve(to: CGPoint(x: 6, y: 2),
                          control1: CGPoint(x: 9, y: 1),
                          control2: CGPoint(x: 6, y: 2))
            path.addCurve(to: CGPoint(x: 12, y: 5),
                          control1: CGPoint(x: 6, y: 6),
                          control2: CGPoint(x: 10, y: 7))
        }
        .aspectRatio(contentMode: .fit)
    }
}

// MARK: - today segment

private struct TodaySegment: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                statusPill
                Spacer()
                Button {
                    model.togglePause()
                } label: {
                    Text(model.isPaused ? L10n.t("tray.resume") : L10n.t("tray.pause"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("today.title"))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.inkSecondary)
                Text(CopyFormat.duration(model.today.active_mins))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundColor(Palette.inkPrimary)
                Text(L10n.t("today.activityNote"))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.inkSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.t("today.sitCycle"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Palette.inkPrimary)
                    Spacer()
                    Text(sitCycleText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Palette.inkPrimary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Palette.trackBg)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Palette.accent)
                            .frame(width: barWidth(in: geo.size.width))
                    }
                }
                .frame(height: 8)
            }
            .padding(.top, 4)

            kindMetrics

            Text(L10n.t("today.outcomeLegend"))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .overlay(Palette.cardBorder)

            nextReminderRow
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundColor(statusColor)
        }
    }

    private var statusColor: Color {
        if model.isPaused { return Palette.pausedOrange }
        if model.quiet { return Palette.inkSecondary }
        return Palette.runningGreen
    }

    private var statusText: String {
        if model.isPaused, let until = model.paused.until_ms {
            return L10n.t("tpl.pausedUntil", Date(timeIntervalSince1970: Double(until) / 1000))
        }
        if model.quiet { return L10n.t("tpl.focus") }
        return L10n.t("tpl.running")
    }

    private var sitCycleText: String {
        if model.isPaused { return "—" }
        let accumulated = model.loop(.sit)?.accumulated_mins ?? 0
        return L10n.t("tpl.sitCycleMin", "\(accumulated)", "\(model.sitIntervalMins)")
    }

    private func barWidth(in width: CGFloat) -> CGFloat {
        guard !model.isPaused else { return 0 }
        let interval = Double(model.sitIntervalMins)
        guard interval > 0 else { return 0 }
        let accumulated = Double(model.loop(.sit)?.accumulated_mins ?? 0)
        let fraction = min(1, max(0, accumulated / interval))
        return width * CGFloat(fraction)
    }

    /// Per-kind response counters (prototype todayPanel metrics): shown as
    /// icon + kind + N 次回应 + 提醒 M 次. Reminder counts are FIRED counts;
    /// responses are the user's own reports — nothing implies verified breaks.
    private var kindMetrics: some View {
        let kinds: [ReminderKind] = [.sit, .water, .micro]
        return HStack(alignment: .top, spacing: 0) {
            ForEach(Array(kinds.enumerated()), id: \.1) { index, kind in
                if index > 0 {
                    Divider()
                        .overlay(Palette.cardBorder)
                        .frame(height: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        KindGlyph(kind: kind)
                            .frame(width: 13, height: 13)
                            .foregroundColor(Palette.inkSecondary)
                        Text(kindWordLabel(kind))
                            .font(.system(size: 12))
                            .foregroundColor(Palette.inkSecondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(model.outcome(kind)?.self_reported_done ?? 0)")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundColor(Palette.inkPrimary)
                        Text(L10n.t("today.responses"))
                            .font(.system(size: 11))
                            .foregroundColor(Palette.inkSecondary)
                    }
                    Text(L10n.t("today.reminderCount",
                                "\(reminderCount(kind))"))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, index == 0 ? 0 : 12)
            }
        }
    }

    private func kindWordLabel(_ kind: ReminderKind) -> String {
        switch kind {
        case .sit: return L10n.t("kind.sit")
        case .water: return L10n.t("kind.water")
        case .micro: return L10n.t("kind.micro")
        }
    }

    private func reminderCount(_ kind: ReminderKind) -> Int {
        switch kind {
        case .sit: return Int(model.today.sit_breaks)
        case .water: return Int(model.today.water_reminders)
        case .micro: return Int(model.today.micro_breaks)
        }
    }

    @ViewBuilder
    private var nextReminderRow: some View {
        if model.isPaused || model.quiet {
            Text(L10n.t("today.suspendedNote"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Palette.inkSecondary)
        } else if !model.pendingCues.isEmpty {
            HStack {
                Text(L10n.t("today.pendingNote"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Palette.inkPrimary)
                Spacer()
                Button {
                    // The invitation lives on the pet; closing the window
                    // returns the user to the same desktop.
                    NSApp.windows.first { $0 is NSPanel }?.orderOut(nil)
                    AppDelegate.shared?.hideUtilityWindow()
                } label: {
                    Text(L10n.t("today.backToMubi"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.accent)
                }
                .buttonStyle(.plain)
            }
        } else if let next = model.nextCue {
            Text(L10n.t("today.nextMove", "\(next.minutes)"))
                .font(.system(size: 12.5))
                .foregroundColor(Palette.kindAccent(next.kind))
        } else {
            Text(L10n.t("set.nextCueOff"))
                .font(.system(size: 12.5))
                .foregroundColor(Palette.inkMuted)
        }
    }
}

/// Linear kind glyphs (prototype healthIcon vocabulary; never emoji).
struct KindGlyph: View {
    let kind: ReminderKind

    var body: some View {
        Path { path in
            switch kind {
            case .sit:
                // Walking figure (simplified linear stroke).
                path.addEllipse(in: CGRect(x: 9, y: 1, width: 5, height: 5))
                path.move(to: CGPoint(x: 10.5, y: 8))
                path.addLine(to: CGPoint(x: 13.5, y: 11))
                path.addLine(to: CGPoint(x: 15, y: 16))
                path.move(to: CGPoint(x: 12, y: 9.5))
                path.addLine(to: CGPoint(x: 9.5, y: 15))
                path.move(to: CGPoint(x: 11, y: 13))
                path.addLine(to: CGPoint(x: 6, y: 17))
            case .water:
                // Droplet outline.
                path.move(to: CGPoint(x: 9, y: 2))
                path.addCurve(to: CGPoint(x: 9, y: 20),
                              control1: CGPoint(x: 3.5, y: 9),
                              control2: CGPoint(x: 3.5, y: 14))
                path.addCurve(to: CGPoint(x: 9, y: 2),
                              control1: CGPoint(x: 14.5, y: 14),
                              control2: CGPoint(x: 14.5, y: 9))
                path.move(to: CGPoint(x: 6, y: 13.5))
                path.addArc(center: CGPoint(x: 9, y: 14.5), radius: 3,
                            startAngle: .degrees(200), endAngle: .degrees(320),
                            clockwise: false)
            case .micro:
                // Eye outline.
                path.move(to: CGPoint(x: 1, y: 11))
                path.addCurve(to: CGPoint(x: 17, y: 11),
                              control1: CGPoint(x: 6, y: 3),
                              control2: CGPoint(x: 12, y: 3))
                path.addCurve(to: CGPoint(x: 1, y: 11),
                              control1: CGPoint(x: 12, y: 19),
                              control2: CGPoint(x: 6, y: 19))
                path.addEllipse(in: CGRect(x: 7, y: 8, width: 4, height: 4))
            }
        }
        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                   lineJoin: .round))
        .aspectRatio(contentMode: .fit)
    }
}

// MARK: - history segment

private struct HistorySegment: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(L10n.t("today.countsNote"))
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Picker("", selection: $model.historyDays) {
                    Text(L10n.t("hist.toggle7")).tag(7)
                    Text(L10n.t("hist.toggle30")).tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }

            let slices = model.historySlice(days: model.historyDays)
            let active = slices.filter { $0.stats.active_mins > 0 }
            if active.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("hist.empty"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.inkPrimary)
                    Text(L10n.t("hist.emptyHint"))
                        .font(.system(size: 12))
                        .foregroundColor(Palette.inkSecondary)
                }
                .padding(.vertical, 24)
            } else {
                HistoryChart(slices: slices, isMonth: model.historyDays >= 30)
                chartCaption(slices)
            }

            Text(L10n.t("insight.title"))
                .font(.system(size: 12))
                .foregroundColor(Palette.inkSecondary)
                .padding(.top, 6)

            let summary = model.insightSummary(days: 30)
            insightGrid(summary)

            Text(busiestLine(summary))
                .font(.system(size: 11.5))
                .foregroundColor(Palette.inkSecondary)
        }
    }

    /// The caption under the chart: the selected bar's detail or the range
    /// total (prototype chartCaption; honest totals, no invented data).
    @ViewBuilder
    private func chartCaption(_ slices: [DaySlice]) -> some View {
        let total = model.historyTotal(slices: slices)
        let text = total >= 60
            ? L10n.t("hist.totalLong", "\(total / 60)", "\(total % 60)")
            : L10n.t("hist.totalShort", "\(total)")
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(Palette.inkMuted)
    }

    private func busiestLine(_ summary: InsightSummary) -> String {
        guard let busiest = summary.busiest,
              let date = MoveBitModel.keyFormatter.date(from: busiest.date) else {
            return L10n.t("insight.noData")
        }
        let label = MoveBitModel.monthDayFormatter.string(from: date)
        return "\(L10n.t("insight.busiest")): \(label) · \(CopyFormat.minutes(busiest.active_mins))."
    }

    private func insightGrid(_ summary: InsightSummary) -> some View {
        VStack(spacing: 0) {
            insightRow(L10n.t("insight.current"),
                       CopyFormat.minutes(model.currentSessionMins))
            Divider().overlay(Palette.cardBorder)
            insightRow(L10n.t("insight.todayLongest"),
                       CopyFormat.minutes(model.today.longest_session_mins))
            Divider().overlay(Palette.cardBorder)
            insightRow(L10n.t("insight.recentLongest"),
                       CopyFormat.minutes(summary.longest))
            Divider().overlay(Palette.cardBorder)
            insightRow(L10n.t("insight.recentAvg"),
                       CopyFormat.minutes(summary.average))
        }
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Palette.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func insightRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Palette.inkSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Palette.inkPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// Bar chart of active minutes: zero-filled gaps, today highlighted.
private struct HistoryChart: View {
    let slices: [DaySlice]
    let isMonth: Bool

    private let barMin: CGFloat = 5
    private let barMax: CGFloat = 86

    var body: some View {
        let maxMinutes = max(60, slices.map(\.stats.active_mins).max() ?? 0)
        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(slices.indices, id: \.self) { index in
                        column(slices[index], maxMinutes: maxMinutes)
                    }
                }
            }
            .frame(height: 110)
            Rectangle()
                .fill(Palette.cardBorder)
                .frame(height: 1)
                .padding(.bottom, 5)
            HStack(spacing: 0) {
                ForEach(slices.indices, id: \.self) { index in
                    label(slices[index])
                }
            }
        }
    }

    private func column(_ slice: DaySlice, maxMinutes: Int64) -> some View {
        let height = barMin + (barMax - barMin)
            * CGFloat(slice.stats.active_mins) / CGFloat(maxMinutes)
        return VStack(spacing: 3) {
            if !isMonth {
                Text(CopyFormat.compact(slice.stats.active_mins))
                    .font(.system(size: 10, weight: slice.isToday ? .semibold : .regular))
                    .foregroundColor(slice.isToday ? Palette.accent : Palette.inkMuted)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(slice.isToday ? Palette.accent : Palette.chartBar)
                .frame(width: isMonth ? 8 : 26, height: max(barMin, height))
        }
        .frame(maxWidth: .infinity)
        .help(tooltip(slice))
    }

    private func label(_ slice: DaySlice) -> some View {
        Text(dayLabel(slice))
            .font(.system(size: 10.5, weight: slice.isToday ? .semibold : .regular))
            .foregroundColor(slice.isToday ? Palette.accent : Palette.inkSecondary)
            .frame(maxWidth: .infinity)
            .help(tooltip(slice))
    }

    private func dayLabel(_ slice: DaySlice) -> String {
        if slice.isToday { return L10n.t("hist.today") }
        guard let date = MoveBitModel.keyFormatter.date(from: slice.stats.date) else {
            return ""
        }
        if isMonth {
            let day = Calendar.current.component(.day, from: date)
            return day % 5 == 0 ? "\(day)" : ""
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.language == "en" ? "en_US" : "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func tooltip(_ slice: DaySlice) -> String {
        L10n.t("hist.tooltip", slice.stats.date,
               "\(slice.stats.active_mins)", "\(slice.stats.sit_breaks)",
               "\(slice.stats.longest_session_mins)")
    }
}

// MARK: - settings segment

/// Exactly four items per the contract: sound, quiet hours (with times),
/// launch-at-login, language. No cadence setters — the rhythm is a product
/// default (issue #140), stated once at the top.
private struct SettingsSegment: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("set.intro"))
                .font(.system(size: 12))
                .foregroundColor(Palette.inkMuted)

            settingRow(label: L10n.t("set.sound"),
                       hint: L10n.t("set.soundHint")) {
                Toggle("", isOn: Binding(
                    get: { model.config.sound_enabled },
                    set: { model.saveConfig(model.config.with(sound_enabled: $0)) }))
                    .labelsHidden()
            }

            settingRow(label: L10n.t("set.quietHours"),
                       hint: L10n.t("set.quietHoursHint")) {
                Toggle("", isOn: Binding(
                    get: { model.config.quiet_hours_enabled },
                    set: { model.saveConfig(model.config.with(quiet_hours_enabled: $0)) }))
                    .labelsHidden()
            }
            if model.config.quiet_hours_enabled {
                timeRow(label: L10n.t("set.quietStart"),
                        minutes: model.config.quiet_hours_start_minutes) {
                    model.saveConfig(model.config.with(quiet_hours_start_minutes: $0))
                }
                timeRow(label: L10n.t("set.quietEnd"),
                        minutes: model.config.quiet_hours_end_minutes) {
                    model.saveConfig(model.config.with(quiet_hours_end_minutes: $0))
                }
                Text(L10n.t("set.quietOvernight"))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.inkMuted)
                    .padding(.leading, 12)
            }

            settingRow(label: L10n.t("set.autostart"),
                       hint: L10n.t("set.autostartHint")) {
                Toggle("", isOn: Binding(
                    get: { model.autostart },
                    set: { model.setAutostart($0) }))
                    .labelsHidden()
            }

            settingRow(label: L10n.t("set.language"),
                       hint: L10n.t("set.languageHint")) {
                Picker("", selection: languageBinding) {
                    Text(L10n.t("lang.auto")).tag("auto")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                .labelsHidden()
                .frame(width: 132)
            }

            Text(model.configStatus.isEmpty
                 ? L10n.t("set.autosaveNote") : model.configStatus)
                .font(.system(size: 11))
                .foregroundColor(model.configStatus.isEmpty
                                 ? Palette.inkMuted : Palette.accent)
        }
    }

    private var languageBinding: Binding<String> {
        Binding(get: { model.config.language },
                set: { model.saveConfig(model.config.with(language: $0)) })
    }

    private func settingRow<Control: View>(label: String, hint: String,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Palette.inkPrimary)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
        .padding(.vertical, 6)
    }

    private func timeRow(label: String, minutes: Int64,
                         onChange: @escaping (Int64) -> Void) -> some View {
        // The picker works in 30-minute steps; a value written by another
        // build is snapped for display only, never silently rewritten.
        let snapped = (minutes / 30) * 30
        return HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Palette.inkSecondary)
                .padding(.leading, 12)
            Spacer()
            Picker("", selection: Binding(get: { snapped },
                                          set: { onChange($0) })) {
                ForEach(Array(stride(from: Int64(0), to: 1440, by: 30)), id: \.self) { m in
                    Text(Self.timeText(m)).tag(m)
                }
            }
            .labelsHidden()
            .frame(width: 96)
        }
    }

    static func timeText(_ minutes: Int64) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

// MARK: - about segment

private struct AboutSegment: View {
    @EnvironmentObject var model: MoveBitModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.t("upd.currentVersion", RivetGeneratedConfig.version))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Palette.inkPrimary)
            Text(L10n.t("ob.privacy"))
                .font(.system(size: 12))
                .foregroundColor(Palette.inkSecondary)

            HStack(spacing: 10) {
                Button(action: model.handleUpdateButton) {
                    Text(updateButtonLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(colorScheme == .dark
                                         ? Color(hex: "#241C16")
                                         : Palette.appBg)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent))
                .buttonStyle(.plain)
                .disabled(!updateButtonEnabled)
                .opacity(updateButtonEnabled ? 1 : 0.5)

                quietLink(L10n.t("about.website"),
                          URL(string: "https://movebit.jrtx.site")!)
                quietLink(L10n.t("about.reportIssue"),
                          URL(string: "https://github.com/turlamai/movebit/issues")!)
                Button {
                    AppDelegate.shared?.revealDataLocation()
                } label: {
                    Text(L10n.t("about.dataFolder"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Palette.inkSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if model.updatePhase == .downloading {
                HStack(spacing: 10) {
                    ProgressView(value: Double(model.updatePercent), total: 100)
                        .frame(maxWidth: 160)
                    Text("\(model.updatePercent)%")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.inkSecondary)
                    Button(L10n.t("upd.actionCancel")) {
                        model.cancelUpdateDownload()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.inkSecondary)
                }
            }

            if !updateHint.isEmpty {
                Text(updateHint)
                    .font(.system(size: 11))
                    .foregroundColor(model.updatePhase == .failed
                                     ? Palette.pausedOrange : Palette.inkMuted)
                    .multilineTextAlignment(.leading)
                    // Failure text must leave the screen with the user —
                    // selectable, so it can be copied into a bug report.
                    .textSelection(.enabled)
            }

            Text("\(L10n.t("about.autoUpdate")) · \(L10n.t("about.autoUpdateHint")) \(L10n.t("about.license"))")
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func quietLink(_ label: String, _ url: URL) -> some View {
        Link(label, destination: url)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(Palette.inkSecondary)
    }

    private var updateButtonLabel: String {
        switch model.updatePhase {
        case .checking: return L10n.t("upd.checkingShort")
        case .available, .cancelled: return L10n.t("upd.actionUpdate")
        case .downloading: return L10n.t("upd.actionUpdating")
        case .ready: return L10n.t("upd.actionRestartInstall")
        case .applying: return L10n.t("upd.actionUpdating")
        case .failed: return L10n.t("upd.actionRetry")
        case .idle, .upToDate: return L10n.t("about.checkUpdates")
        }
    }

    private var updateButtonEnabled: Bool {
        switch model.updatePhase {
        case .checking, .downloading, .applying: return false
        default: return true
        }
    }

    private var updateHint: String {
        switch model.updatePhase {
        case .checking:
            return L10n.t("upd.checking")
        case .available:
            return L10n.t("upd.found", model.updateAvailableVersion ?? "")
        case .downloading:
            return L10n.t("upd.downloadingPct",
                          model.updateAvailableVersion ?? "",
                          "\(model.updatePercent)")
        case .cancelled:
            return L10n.t("upd.cancelled")
        case .ready:
            return L10n.t("upd.restartPrep", model.updateAvailableVersion ?? "")
        case .applying:
            return L10n.t("upd.restarting")
        case .failed:
            return model.updateErrorText ?? L10n.t("upd.checkFailed")
        case .upToDate:
            return L10n.t("upd.currentUpToDate", RivetGeneratedConfig.version)
        case .idle:
            return ""
        }
    }
}
