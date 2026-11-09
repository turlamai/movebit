import SwiftUI
import AppKit

// MARK: - palette (warm paper, light/dark follows system; parity with App.axaml)

enum Palette {
    static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(hex: hex)
        }))
    }

    static let appBg = dynamic(light: "#F5F2EB", dark: "#201D1A")
    static let cardBg = dynamic(light: "#FFFFFF", dark: "#2A2622")
    static let cardBorder = dynamic(light: "#EAE2D6", dark: "#3A352E")
    static let inkPrimary = dynamic(light: "#26241F", dark: "#EDE7DA")
    static let inkSecondary = dynamic(light: "#6E6A5E", dark: "#B0A696")
    static let inkMuted = dynamic(light: "#A39B8D", dark: "#7A7264")
    static let accent = dynamic(light: "#C25E3E", dark: "#D97B54")
    static let accentSoft = dynamic(light: "#FBEFE2", dark: "#3A2A20")
    static let trackBg = dynamic(light: "#EAE6DC", dark: "#38332D")
    static let chartBar = dynamic(light: "#D2C8B2", dark: "#4E4638")
    static let waterBlue = dynamic(light: "#3E7EC2", dark: "#7AB0E8")
    static let okGreen = dynamic(light: "#4E9A6A", dark: "#6FBF8A")
    static let pausedOrange = Color(red: 0xEA / 255, green: 0x58 / 255, blue: 0x0C / 255)
    static let runningGreen = Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255)

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

/// Main window: two-column card layout, single column when narrow.
struct MainView: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                columns(narrow: geo.size.width < 700)
            }
            .background(Palette.appBg)
        }
    }

    @ViewBuilder
    private func columns(narrow: Bool) -> some View {
        let left = leftColumn
        let right = rightColumn
        if narrow {
            VStack(spacing: 16) { left; right }
                .padding(20)
        } else {
            HStack(alignment: .top, spacing: 14) {
                left.frame(maxWidth: .infinity)
                right.frame(maxWidth: .infinity)
            }
            .padding(24)
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 16) {
            TodayCard()
            HistoryCard()
            InsightCard()
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 16) {
            SettingsCard()
            AboutCard()
            configPathFooter
        }
    }

    @ViewBuilder
    private var configPathFooter: some View {
        if !model.dataDir.isEmpty {
            Text(L10n.t("main.configPath", model.dataDir))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - card chrome

private struct CardBackground: ViewModifier {
    var palette: Color = Palette.cardBg

    func body(content: Content) -> some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(palette))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

// MARK: - today card

private struct TodayCard: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.t("today.title"))
                    .font(.system(size: 13))
                    .foregroundColor(Palette.inkSecondary)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.system(size: 12.5))
                        .foregroundColor(statusColor)
                }
            }

            Text(CopyFormat.duration(model.today.active_mins))
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundColor(Palette.inkPrimary)

            sitCycleBar

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sitCycleText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Palette.inkPrimary)
                    Text(L10n.t("today.sitCycle"))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.inkSecondary)
                }
                Spacer()
                nextCueBadge
            }

            outcomeRows

            Text(L10n.t("today.outcomeLegend"))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(CardBackground())
    }

    /// The nearest countdown the user can actually expect, or an honest
    /// "paused"/"off" instead of a promise.
    @ViewBuilder
    private var nextCueBadge: some View {
        if model.isPaused {
            Text(L10n.t("tpl.running"))
                .font(.system(size: 11.5))
                .foregroundColor(Palette.inkMuted)
        } else if let next = model.nextCue {
            Text(L10n.t("today.nextCue", "\(next.minutes)"))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Palette.kindAccent(next.kind))
                .multilineTextAlignment(.trailing)
        } else {
            Text(L10n.t("set.nextCueOff"))
                .font(.system(size: 11.5))
                .foregroundColor(Palette.inkMuted)
        }
    }

    /// Shown vs self-reported done, per kind. Delivery ("presented") and the
    /// user's own "Done" are deliberately separate numbers (issue #88); a kind
    /// with no recorded event is omitted rather than displayed as zero.
    @ViewBuilder
    private var outcomeRows: some View {
        let kinds: [ReminderKind] = [.sit, .water, .micro]
        let visible = kinds.compactMap { kind -> (ReminderKind, CueOutcomeTotals)? in
            guard let totals = model.outcome(kind) else { return nil }
            return (kind, totals)
        }
        VStack(spacing: 6) {
            if visible.isEmpty {
                Text(L10n.t("today.outcomeEmpty"))
                    .font(.system(size: 12))
                    .foregroundColor(Palette.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(visible, id: \.0) { kind, totals in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Palette.kindAccent(kind))
                            .frame(width: 6, height: 6)
                        Text(model.kindLabel(kind))
                            .font(.system(size: 12))
                            .foregroundColor(Palette.inkSecondary)
                        Spacer()
                        Text(L10n.t("today.outcome",
                                    "\(totals.presented)",
                                    "\(totals.self_reported_done)"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Palette.inkPrimary)
                    }
                }
            }
        }
    }

    private var statusColor: Color { model.isPaused ? Palette.pausedOrange : Palette.runningGreen }

    private var statusText: String {
        if model.isPaused, let until = model.paused.until_ms {
            return L10n.t("tpl.pausedUntil", Date(timeIntervalSince1970: Double(until) / 1000))
        }
        return L10n.t("tpl.running")
    }

    private var sitCycleText: String {
        if model.isPaused { return "—" }
        let accumulated = model.loop(.sit)?.accumulated_mins ?? 0
        return L10n.t("tpl.sitCycleMin", "\(accumulated)", "\(model.sitIntervalMins)")
    }

    private var sitCycleBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Palette.trackBg)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Palette.accent)
                    .frame(width: barWidth(in: geo.size.width))
            }
        }
        .frame(height: 9)
    }

    private func barWidth(in width: CGFloat) -> CGFloat {
        guard !model.isPaused else { return 0 }
        let interval = Double(model.sitIntervalMins)
        guard interval > 0 else { return 0 }
        let accumulated = Double(model.loop(.sit)?.accumulated_mins ?? 0)
        let fraction = min(1, max(0, accumulated / interval))
        return width * CGFloat(fraction)
    }
}

// MARK: - history card

private struct HistoryCard: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        let isMonth = model.historyDays >= 30
        let slices = model.historySlice(days: model.historyDays)
        let total = model.historyTotal(slices: slices)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isMonth ? L10n.t("hist.range30") : L10n.t("hist.range7"))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.inkSecondary)
                    Text(totalText(total))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Palette.inkPrimary)
                }
                Spacer()
                Picker("", selection: $model.historyDays) {
                    Text(L10n.t("hist.toggle7")).tag(7)
                    Text(L10n.t("hist.toggle30")).tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            HistoryChart(slices: slices, isMonth: isMonth)
        }
        .modifier(CardBackground())
    }

    private func totalText(_ total: Int64) -> String {
        total >= 60 ? L10n.t("hist.totalLong", "\(total / 60)", "\(total % 60)")
                    : L10n.t("hist.totalShort", "\(total)")
    }
}

/// Bar chart of active minutes: zero-filled gaps, today highlighted, dashed
/// daily-average line (parity with the old HistoryChart grid).
private struct HistoryChart: View {
    let slices: [DaySlice]
    let isMonth: Bool

    private let barMin: CGFloat = 5
    private let barMax: CGFloat = 86

    var body: some View {
        let maxMinutes = max(60, slices.map(\.stats.active_mins).max() ?? 0)
        let active = slices.filter { $0.stats.active_mins > 0 }.map(\.stats.active_mins)
        let average = averageLabel(active: active)
        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(slices.indices, id: \.self) { index in
                        column(slices[index], maxMinutes: maxMinutes)
                    }
                }
                if let average {
                    averageLine(average, maxMinutes: maxMinutes)
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

    private func averageLabel(active: [Int64]) -> Int64? {
        guard !active.isEmpty else { return nil }
        return (active.reduce(0, +) + Int64(active.count) / 2) / Int64(active.count)
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

    private func averageLine(_ average: Int64, maxMinutes: Int64) -> some View {
        let offset = barMin + (barMax - barMin) * CGFloat(average) / CGFloat(maxMinutes)
        return VStack(spacing: 3) {
            Text(L10n.t("hist.avg", CopyFormat.compact(average)))
                .font(.system(size: 10))
                .foregroundColor(Palette.inkMuted)
            Rectangle()
                .fill(Palette.inkMuted.opacity(0.55))
                .frame(height: 1)
        }
        .offset(y: -offset)
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

// MARK: - insight card

private struct InsightCard: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        let summary = model.insightSummary(days: 30)
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("insight.title"))
                .font(.system(size: 13))
                .foregroundColor(Palette.inkSecondary)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    metric(title: L10n.t("insight.current"),
                           value: CopyFormat.minutes(model.currentSessionMins))
                    metric(title: L10n.t("insight.todayLongest"),
                           value: CopyFormat.minutes(model.today.longest_session_mins))
                }
                HStack(spacing: 10) {
                    metric(title: L10n.t("insight.recentLongest"),
                           value: CopyFormat.minutes(summary.longest))
                    metric(title: L10n.t("insight.recentAvg"),
                           value: CopyFormat.minutes(summary.average))
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text(L10n.t("insight.busiest"))
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.inkMuted)
                Text(busiestText(summary.busiest))
                    .font(.system(size: 11.5))
                    .foregroundColor(Palette.inkPrimary)
            }
            Text(sedentaryText(summary))
                .font(.system(size: 11.5))
                .foregroundColor(Palette.inkSecondary)
        }
        .modifier(CardBackground())
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(Palette.inkPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.trackBg))
    }

    private func busiestText(_ busiest: DayStats?) -> String {
        guard let busiest,
              let date = MoveBitModel.keyFormatter.date(from: busiest.date) else {
            return L10n.t("insight.none")
        }
        let label = MoveBitModel.monthDayFormatter.string(from: date)
        return "\(label) · \(CopyFormat.minutes(busiest.active_mins))"
    }

    /// Parity with RebuildInsights: threshold against the sit interval.
    private func sedentaryText(_ summary: InsightSummary) -> String {
        let longest = summary.longest
        let sit = model.sitIntervalMins
        if longest <= 0 { return L10n.t("insight.noData") }
        if longest >= sit * 2 { return L10n.t("insight.long2", CopyFormat.minutes(longest)) }
        if longest >= sit { return L10n.t("insight.long1", CopyFormat.minutes(longest)) }
        return L10n.t("insight.long0", CopyFormat.minutes(longest))
    }
}

// MARK: - settings card

/// Companion-first settings (issues #87/#90): one rhythm choice and sound are
/// the everyday surface; cadence steppers, quiet hours and character details
/// live behind one explicit "Customize" disclosure.
private struct SettingsCard: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(L10n.t("set.title"))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.inkSecondary)
                    Spacer()
                    Text(model.configStatus.isEmpty
                         ? L10n.t("set.statusDefault") : model.configStatus)
                        .font(.system(size: 11.5))
                        .foregroundColor(Palette.accent)
                        .multilineTextAlignment(.trailing)
                }
                Text(L10n.t("set.defaultsHint"))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            nextCueLine

            Divider()

            ToggleRow(label: L10n.t("set.sound"),
                      isOn: model.config.sound_enabled) {
                save(model.config.with(sound_enabled: $0))
            }
            Text(L10n.t("set.soundHint"))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ToggleRow(label: L10n.t("set.quietHours"),
                      isOn: model.config.quiet_hours_enabled) {
                save(model.config.with(quiet_hours_enabled: $0))
            }
            Text(L10n.t("set.quietHoursHint"))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
            if model.config.quiet_hours_enabled {
                timeRow(label: L10n.t("set.quietStart"),
                        minutes: model.config.quiet_hours_start_minutes) {
                    save(model.config.with(quiet_hours_start_minutes: $0))
                }
                timeRow(label: L10n.t("set.quietEnd"),
                        minutes: model.config.quiet_hours_end_minutes) {
                    save(model.config.with(quiet_hours_end_minutes: $0))
                }
            }

            Divider()

            ToggleRow(label: L10n.t("set.autostart"), isOn: model.autostart) {
                model.setAutostart($0)
            }
            languageRow
        }
        .modifier(CardBackground())
    }

    private func save(_ draft: ReminderConfig) {
        model.saveConfig(draft)
    }

    @ViewBuilder
    private var nextCueLine: some View {
        HStack(spacing: 6) {
            if let next = model.nextCue {
                Text(L10n.t("set.nextCue", "\(next.minutes)"))
                    .foregroundColor(Palette.kindAccent(next.kind))
            } else if model.isPaused {
                Text(L10n.t("tpl.running"))
                    .foregroundColor(Palette.inkMuted)
            } else {
                Text(L10n.t("set.nextCueOff"))
                    .foregroundColor(Palette.inkMuted)
            }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func timeRow(label: String, minutes: Int64,
                         onChange: @escaping (Int64) -> Void) -> some View {
        // The picker works in 30-minute steps; a value written by another
        // build is snapped for display only, never silently rewritten.
        let snapped = (minutes / 30) * 30
        return HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(Palette.inkSecondary)
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

    private var languageRow: some View {
        HStack {
            Text(L10n.t("set.language"))
                .font(.system(size: 12.5))
                .foregroundColor(Palette.inkSecondary)
            Spacer()
            Picker("", selection: languageBinding) {
                Text(L10n.t("lang.auto")).tag("auto")
                Text("中文").tag("zh")
                Text("English").tag("en")
            }
            .labelsHidden()
            .frame(width: 132)
        }
    }

    private var languageBinding: Binding<String> {
        Binding(get: { model.config.language },
                set: { save(model.config.with(language: $0)) })
    }
}

private struct ToggleRow: View {
    let label: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Palette.inkPrimary)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .labelsHidden()
        }
    }
}

// MARK: - about card

private struct AboutCard: View {
    @EnvironmentObject var model: MoveBitModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("upd.currentVersion", RivetGeneratedConfig.version))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Palette.inkPrimary)
            // The button IS the update state machine (parity with the
            // Windows host): check → download with progress → restart-install.
            HStack(spacing: 12) {
                Button(action: model.handleUpdateButton) {
                    Text(updateButtonLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(!updateButtonEnabled)
                if model.updatePhase == .downloading {
                    ProgressView(value: Double(model.updatePercent), total: 100)
                        .frame(maxWidth: 140)
                    Text("\(model.updatePercent)%")
                        .font(.system(size: 11))
                        .foregroundColor(Palette.inkSecondary)
                    Button(action: model.cancelUpdateDownload) {
                        Text(L10n.t("upd.actionCancel"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            }
            if !updateHint.isEmpty {
                Text(updateHint)
                    .font(.system(size: 11))
                    .foregroundColor(model.updatePhase == .failed
                                        ? Palette.pausedOrange
                                        : Palette.inkMuted)
                    .multilineTextAlignment(.leading)
                    // Failure text must leave the screen with the user —
                    // selectable, so it can be copied into a bug report.
                    .textSelection(.enabled)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("about.autoUpdate"))
                        .font(.system(size: 13))
                        .foregroundColor(Palette.inkPrimary)
                    Text(L10n.t("about.autoUpdateHint"))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.inkMuted)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.config.auto_check_updates },
                    set: { model.saveConfig(model.config.with(auto_check_updates: $0)) }))
                    .labelsHidden()
            }
            // Website / issue tracker / license — the family About rows.
            HStack(spacing: 16) {
                Link(L10n.t("about.website"),
                     destination: URL(string: "https://movebit.jrtx.site")!)
                Link(L10n.t("about.reportIssue"),
                     destination: URL(string:
                        "https://github.com/turlamai/movebit/issues")!)
            }
            .font(.system(size: 12))
            .tint(Palette.accent)
            Text(L10n.t("about.license"))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
        }
        .modifier(CardBackground())
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
