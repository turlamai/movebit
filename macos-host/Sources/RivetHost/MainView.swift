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
    func with(
        sit_reminder_minutes: Int64? = nil,
        water_reminder_minutes: Int64? = nil,
        away_reset_minutes: Int64? = nil,
        snooze_minutes: Int64? = nil,
        micro_break_enabled: Bool? = nil,
        micro_break_interval_minutes: Int64? = nil,
        micro_break_duration_seconds: Int64? = nil,
        motion_enabled: Bool? = nil,
        sound_enabled: Bool? = nil,
        auto_check_updates: Bool? = nil,
        welcome_shown: Bool? = nil,
        language: String? = nil,
        companion_size: String? = nil,
        companion_motion: String? = nil,
        companion_dock: String? = nil,
        companion_labels: String? = nil
    ) -> ReminderConfig {
        ReminderConfig(
            sit_reminder_minutes: sit_reminder_minutes ?? self.sit_reminder_minutes,
            water_reminder_minutes: water_reminder_minutes ?? self.water_reminder_minutes,
            away_reset_minutes: away_reset_minutes ?? self.away_reset_minutes,
            snooze_minutes: snooze_minutes ?? self.snooze_minutes,
            micro_break_enabled: micro_break_enabled ?? self.micro_break_enabled,
            micro_break_interval_minutes: micro_break_interval_minutes ?? self.micro_break_interval_minutes,
            micro_break_duration_seconds: micro_break_duration_seconds ?? self.micro_break_duration_seconds,
            motion_enabled: motion_enabled ?? self.motion_enabled,
            sound_enabled: sound_enabled ?? self.sound_enabled,
            auto_check_updates: auto_check_updates ?? self.auto_check_updates,
            welcome_shown: welcome_shown ?? self.welcome_shown,
            language: language ?? self.language,
            companion_size: companion_size ?? self.companion_size,
            companion_motion: companion_motion ?? self.companion_motion,
            companion_dock: companion_dock ?? self.companion_dock,
            companion_labels: companion_labels ?? self.companion_labels)
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

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sitCycleText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Palette.inkPrimary)
                    Text(L10n.t("today.sitCycle"))
                        .font(.system(size: 11))
                        .foregroundColor(Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                counter(emoji: "🚶", value: model.today.sit_breaks, label: L10n.t("today.sit"))
                counter(emoji: "💧", value: model.today.water_reminders, label: L10n.t("today.water"))
                counter(emoji: "👀", value: model.today.micro_breaks, label: L10n.t("today.micro"))
            }
            Text(L10n.t("today.countsNote"))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(CardBackground())
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
        return L10n.t("tpl.sitCycleMin", "\(accumulated)", "\(model.config.sit_reminder_minutes)")
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
        guard !model.isPaused, model.config.sit_reminder_minutes > 0 else { return 0 }
        let accumulated = Double(model.loop(.sit)?.accumulated_mins ?? 0)
        let fraction = min(1, max(0, accumulated / Double(model.config.sit_reminder_minutes)))
        return width * CGFloat(fraction)
    }

    private func counter(emoji: String, value: Int64, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(emoji).font(.system(size: 14))
                Text("\(value)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Palette.inkPrimary)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Palette.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let sit = model.config.sit_reminder_minutes
        if longest <= 0 { return L10n.t("insight.noData") }
        if longest >= sit * 2 { return L10n.t("insight.long2", CopyFormat.minutes(longest)) }
        if longest >= sit { return L10n.t("insight.long1", CopyFormat.minutes(longest)) }
        return L10n.t("insight.long0", CopyFormat.minutes(longest))
    }
}

// MARK: - settings card

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
                Text(L10n.t("set.intro"))
                    .font(.system(size: 11))
                    .foregroundColor(Palette.inkMuted)
            }
            reminderRows
            languageRow
        }
        .modifier(CardBackground())
    }

    private func save(_ draft: ReminderConfig) {
        model.saveConfig(draft)
    }

    private var reminderRows: some View {
        VStack(spacing: 10) {
            StepperRow(label: L10n.t("set.sitInterval"), value: model.config.sit_reminder_minutes,
                       range: 10...240, step: 5) {
                save(model.config.with(sit_reminder_minutes: $0))
            }
            StepperRow(label: L10n.t("set.waterInterval"), value: model.config.water_reminder_minutes,
                       range: 5...180, step: 5) {
                save(model.config.with(water_reminder_minutes: $0))
            }
            StepperRow(label: L10n.t("set.awayReset"), value: model.config.away_reset_minutes,
                       range: 1...60, step: 1) {
                save(model.config.with(away_reset_minutes: $0))
            }
            StepperRow(label: L10n.t("set.snooze"), value: model.config.snooze_minutes,
                       range: 5...60, step: 5) {
                save(model.config.with(snooze_minutes: $0))
            }
            ToggleRow(label: L10n.t("set.microToggle"), isOn: model.config.micro_break_enabled) {
                save(model.config.with(micro_break_enabled: $0))
            }
            HStack {
                Text(L10n.t("set.microParams"))
                    .font(.system(size: 12.5))
                    .foregroundColor(Palette.inkSecondary)
                Spacer()
                StepperRow(label: "", value: model.config.micro_break_interval_minutes,
                           range: 10...60, step: 5, compact: true) {
                    save(model.config.with(micro_break_interval_minutes: $0))
                }
                StepperRow(label: "", value: model.config.micro_break_duration_seconds,
                           range: 10...60, step: 5, compact: true) {
                    save(model.config.with(micro_break_duration_seconds: $0))
                }
            }
            pickerRow(label: L10n.t("set.mubiSize"),
                      selection: model.config.companion_size,
                      options: [("S", "S"), ("M", "M"), ("L", "L")]) {
                save(model.config.with(companion_size: $0))
            }
            pickerRow(label: L10n.t("set.mubiMotion"),
                      selection: model.config.companion_motion,
                      options: [("still", L10n.t("mubi.motionStill")),
                                ("subtle", L10n.t("mubi.motionSubtle")),
                                ("lively", L10n.t("mubi.motionLively"))]) {
                save(model.config.with(companion_motion: $0))
            }
            pickerRow(label: L10n.t("set.mubiDock"),
                      selection: model.config.companion_dock,
                      options: [("bottom-right", L10n.t("mubi.dockBottomRight")),
                                ("bottom-left", L10n.t("mubi.dockBottomLeft")),
                                ("top-right", L10n.t("mubi.dockTopRight"))]) {
                save(model.config.with(companion_dock: $0))
            }
            pickerRow(label: L10n.t("set.mubiLabels"),
                      selection: model.config.companion_labels,
                      options: [("cue", L10n.t("mubi.labelsCue")),
                                ("always", L10n.t("mubi.labelsAlways"))]) {
                save(model.config.with(companion_labels: $0))
            }
            ToggleRow(label: L10n.t("set.motion"), isOn: model.config.motion_enabled) {
                save(model.config.with(motion_enabled: $0))
            }
            ToggleRow(label: L10n.t("set.sound"), isOn: model.config.sound_enabled) {
                save(model.config.with(sound_enabled: $0))
            }
            ToggleRow(label: L10n.t("set.autostart"), isOn: model.autostart) {
                model.setAutostart($0)
            }
        }
    }

    private func pickerRow(label: String, selection: String,
                           options: [(String, String)],
                           save: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label)
                .foregroundColor(Palette.inkPrimary)
            Spacer()
            Picker("", selection: Binding(get: { selection },
                                          set: { save($0) })) {
                ForEach(options, id: \.0) { value, title in
                    Text(title).tag(value)
                }
            }
            .labelsHidden()
            .frame(width: 132)
        }
        .font(.system(size: 13))
    }

    private var languageRow: some View {
        HStack {
            Text(L10n.t("set.language"))
                .foregroundColor(Palette.inkPrimary)
            Spacer()
            Picker("", selection: languageBinding) {
                Text(L10n.t("lang.auto")).tag("auto")
                Text("中文").tag("zh")
                Text("English").tag("en")
            }
            .labelsHidden()
            .frame(width: 132)
        }
        .font(.system(size: 13))
    }

    private var languageBinding: Binding<String> {
        Binding(get: { model.config.language },
                set: { save(model.config.with(language: $0)) })
    }
}

/// Label + numeric stepper row; edits save immediately (the backend clamps).
private struct StepperRow: View {
    let label: String
    let value: Int64
    let range: ClosedRange<Int>
    let step: Int
    var compact = false
    let onChange: (Int64) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(Palette.inkPrimary)
                Spacer()
            }
            if !compact {
                Text("\(value)")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(Palette.inkPrimary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            Stepper("", onIncrement: { change(by: Int64(step)) },
                    onDecrement: { change(by: -Int64(step)) })
                .labelsHidden()
        }
    }

    private func change(by delta: Int64) -> Void {
        let clamped = min(Int64(range.upperBound), max(Int64(range.lowerBound), value + delta))
        onChange(clamped)
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
                        "https://github.com/turinglambdaai/movebit/issues")!)
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
