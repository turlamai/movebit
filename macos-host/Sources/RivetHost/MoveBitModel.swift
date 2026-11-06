import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

/// Copy-pool identifiers emitted by gen-swift-strings.mjs (indexed keys).
enum CopyPool {
    static let sitToasts = ("copy.sitToastPool", 6)
    static let water = ("copy.waterPool", 8)
    static let micro = ("copy.microPool", 9)
    static let lateNightWater = ("copy.lateNightWaterPool", 3)
    static let lateNightMicro = ("copy.lateNightMicroPool", 3)

    /// After 22:00 the droplet drops the jokes (22:00-06:00 per
    /// copy.lateNightWindow).
    static var isLateNight: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour >= 22 || hour < 6
    }

    static func pickWater() -> String {
        isLateNight ? L10n.pick(lateNightWater.0, lateNightWater.1)
                    : L10n.pick(water.0, water.1)
    }

    static func pickMicro() -> String {
        isLateNight ? L10n.pick(lateNightMicro.0, lateNightMicro.1)
                    : L10n.pick(micro.0, micro.1)
    }

    /// Self-reported sit-acknowledgment counts worth a cheer (parity with
    /// the backend's celebrate-at policy; a cheer claims nothing clinical).
    static let celebrateAt: [Int64] = [3, 5, 8]
}

enum CopyFormat {
    /// "45m" / "2h05m" (parity with MainViewModel.FormatMinutes).
    static func minutes(_ total: Int64) -> String {
        let total = max(0, total)
        return total >= 60 ? "\(total / 60)h\(String(format: "%02d", total % 60))m" : "\(total)m"
    }

    /// Localized duration for the big numbers ("2 hr 05 min" / "45 min").
    static func duration(_ total: Int64) -> String {
        let total = max(0, total)
        return total >= 60 ? L10n.t("app.hourMin", "\(total / 60)", String(format: "%02d", total % 60))
                           : L10n.t("app.minutes", "\(max(total, 0))")
    }

    /// Compact axis label: "·" for zero (parity with FormatMinutesCompact).
    static func compact(_ total: Int64) -> String {
        let total = max(0, total)
        if total == 0 { return "·" }
        return total >= 60 ? "\(total / 60)h" : "\(total)m"
    }
}

/// Main-actor model bridging the embedded Racket backend and the host UI.
/// All policy (tick, scheduling, break lifecycle, merging, persistence) lives
/// in the backend; this only renders state and forwards user actions.
@MainActor
final class MoveBitModel: ObservableObject {
    @MainActor
    private final class EventRelay {
        weak var model: MoveBitModel?

        init(_ model: MoveBitModel) { self.model = model }

        func receive(_ event: RivetEvent) {
            model?.receive(event)
        }

        func ready(config: ReminderConfig, today: DayStats, paused: PauseState,
                   loops: [LoopInfo], pendingCues: [HealthCue]) {
            model?.bootstrap(config: config, today: today, paused: paused,
                             loops: loops, pendingCues: pendingCues)
        }

        func fail(_ message: String) {
            guard let model else { return }
            model.ready = false
            model.status = message
        }
    }

    @Published var ready = false
    @Published var status = ""
    @Published var today = DayStats(date: "", active_mins: 0, sit_breaks: 0,
                                    water_reminders: 0, micro_breaks: 0,
                                    longest_session_mins: 0)
    @Published var config = ReminderConfig(
        sit_reminder_minutes: 50, water_reminder_minutes: 60, away_reset_minutes: 5,
        // Pre-bootstrap placeholder = the shipped balanced default; the
        // backend overwrites it with the real persisted config right after init.
        snooze_minutes: 10, micro_break_enabled: true, micro_break_interval_minutes: 20,
        micro_break_duration_seconds: 20, motion_enabled: true, sound_enabled: false,
        auto_check_updates: true, welcome_shown: false, language: "auto",
        companion_size: "M", companion_motion: "subtle",
        companion_dock: "bottom-right", companion_labels: "cue",
        preset: "balanced", sit_enabled: true, water_enabled: true,
        quiet_hours_enabled: false, quiet_hours_start_minutes: 1320,
        quiet_hours_end_minutes: 420)
    @Published var paused = PauseState(paused: false, until_ms: nil)
    @Published var loops: [LoopInfo] = []
    /// Per-kind delivery/response truth for today (issue #88): shown and
    /// self-reported done are separate from the fired-reminder counters, and
    /// nothing here claims a verified break.
    @Published var outcomes: [CueOutcomeTotals] = []
    /// Cues currently pending or on screen (the backend's reconciliation view).
    /// All writes go through `setPendingCues` so presentation observers fire.
    @Published var pendingCues: [HealthCue] = [] {
        didSet { onPendingCuesChanged?() }
    }
    @Published var quiet = false
    @Published var history: [DayStats] = []
    @Published var historyDays = 7
    @Published var autostart = false
    @Published var configStatus = ""
    @Published var dataDir = ""

    // Window-level requests handled by the AppDelegate (it owns the NSWindows).
    var onReady: (() -> Void)?
    var onConfigChanged: (() -> Void)?
    var onCue: ((HealthCue) -> Void)?
    /// The open-cue ledger changed: the tray cue actions and the companion's
    /// idle/cue pose re-derive from `pendingCues`.
    var onPendingCuesChanged: (() -> Void)?
    /// A self-reported sit acknowledgment landed (milestone cheer source).
    var onSitAcknowledged: ((Int64) -> Void)?
    /// The restart-install handoff: after the backend staged the payload and
    /// spawned the apply helper, the host must quit so the helper can swap
    /// the bundle and relaunch.
    var onQuitRequested: (() -> Void)?

    private var backend: EmbeddedRacketBackend?
    private var language = "auto"

    var resolvedLanguage: String {
        if language == "auto" {
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? "zh" : "en"
        }
        return language
    }

    func api() -> RivetAPI? {
        guard let backend else { return nil }
        return RivetAPI(client: backend.client)
    }

    func loop(_ kind: ReminderKind) -> LoopInfo? {
        loops.first { $0.kind == kind }
    }

    func outcome(_ kind: ReminderKind) -> CueOutcomeTotals? {
        outcomes.first { $0.kind == kind }
    }

    /// Nearest enabled kind still counting down, in active minutes. Nil when
    /// every kind is off (or paused) — the UI then says so instead of showing
    /// a promise that will not fire.
    var nextCue: (kind: ReminderKind, minutes: Int64)? {
        guard !isPaused else { return nil }
        let candidates: [(ReminderKind, Int64)] = loops.compactMap { loop in
            guard let due = loop.due_in_active_mins else { return nil }
            return (loop.kind, max(0, due))
        }
        return candidates.min { $0.1 < $1.1 }
            .map { (kind: $0.0, minutes: $0.1) }
    }

    func kindLabel(_ kind: ReminderKind) -> String {
        switch kind {
        case .sit: return L10n.t("today.sit")
        case .water: return L10n.t("today.water")
        case .micro: return L10n.t("today.micro")
        }
    }

    var isPaused: Bool { paused.paused }

    /// Sit-loop minutes accumulated in the current cycle — the closest host-side
    /// reading of "current continuous session" (it resets on break/away/snooze).
    var currentSessionMins: Int64 {
        loop(.sit)?.accumulated_mins ?? 0
    }

    // MARK: lifecycle

    func start() {
        guard backend == nil else { return }
        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName)
            let backend = EmbeddedRacketBackend(configuration: config)
            let relay = EventRelay(self)
            self.backend = backend
            status = "Starting embedded Racket CS…"
            Task.detached { [backend, relay] in
                do {
                    try backend.start { name, value in
                        guard let event = try? RivetEvent.decode(name: name, value: value) else { return }
                        Task { @MainActor in relay.receive(event) }
                    }
                    let api = RivetAPI(client: backend.client)
                    // initialize seeds states and starts the 30 s backend tick.
                    try await api.initialize()
                    // The updater stages its payload into the install root
                    // (the folder holding movebit.app) — hand it over before
                    // anything can start a download.
                    try? await api.set_install_dir(
                        path: Bundle.main.bundleURL.deletingLastPathComponent()
                            .path)
                    // This host ships the safe character surface; the OS
                    // Reduce Motion report is polled on changes (static cue
                    // fallback), and the backend plans every delivery.
                    let reduceMotion =
                        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    try? await api.set_host_capability(
                        character_surface_supported: true, reduce_motion: reduceMotion)
                    async let config = api.get_active_config()
                    async let today = api.get_today()
                    async let paused = api.get_paused()
                    async let loops = api.get_loops()
                    async let pendingCues = api.get_pending_cues()
                    let (c, t, p, l, q) = try await (config, today, paused, loops, pendingCues)
                    await relay.ready(config: c, today: t, paused: p,
                                      loops: l, pendingCues: q)
                } catch {
                    await relay.fail(String(describing: error))
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    private func bootstrap(config: ReminderConfig, today: DayStats, paused: PauseState,
                           loops: [LoopInfo], pendingCues: [HealthCue]) {
        self.config = config
        self.today = today
        self.paused = paused
        self.loops = loops
        self.pendingCues = pendingCues
        language = config.language
        L10n.language = resolvedLanguage
        ready = true
        status = ""

        Task { await reloadHistory() }
        Task { await reloadOutcomes() }
        Task { await reloadAutostart() }
        Task { await reloadDataDir() }
        Task { reflectPendingUpdate() }
        onReady?()
    }

    // MARK: events

    private func receive(_ event: RivetEvent) {
        switch event {
        case .tick_stats(let stats):
            today = stats
            // The tick thread also republishes loops/paused/pending-cues states.
            Task {
                if let api = api() {
                    if let l = try? await api.get_loops() { loops = l }
                    if let p = try? await api.get_paused() { paused = p }
                    if let q = try? await api.get_pending_cues() { pendingCues = q }
                    if let o = try? await api.get_cue_outcomes() { outcomes = o }
                }
            }
        case .health_cue(let cue):
            // The backend planned the delivery (character / notification /
            // quiet); quiet cues never arrive here, they queue backend-side.
            pendingCues.append(cue)
            onCue?(cue)
        case .cue_acknowledged(let acked):
            // Milestone cheer source (3/5/8 self-reported sit claims).
            if acked.kind == .sit { onSitAcknowledged?(acked.count_today) }
        case .day_completed(let stats):
            today = stats
            Task { await reloadHistory() }
        case .config_changed(let changed):
            applyConfig(changed, announce: false)
        }
    }

    // MARK: state reloads

    func reloadOutcomes() async {
        guard let api = api() else { return }
        outcomes = (try? await api.get_cue_outcomes()) ?? outcomes
    }

    func reloadHistory() async {
        guard let api = api() else { return }
        // Always fetch 30 days; the 7/30 toggle is pure client-side slicing.
        history = (try? await api.get_history(days: 30)) ?? history
    }

    private func reloadAutostart() async {
        guard let api = api() else { return }
        autostart = (try? await api.get_autostart()) ?? false
    }

    /// The config-file path footer comes from the diagnostics text block.
    private func reloadDataDir() async {
        guard let api = api(), let text = try? await api.get_diagnostics() else { return }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("data-dir: ") {
                dataDir = String(line.dropFirst("data-dir: ".count))
            }
        }
    }

    // MARK: config

    private func applyConfig(_ changed: ReminderConfig, announce: Bool) {
        let languageChanged = changed.language != config.language
        config = changed
        language = changed.language
        L10n.language = resolvedLanguage
        if languageChanged || announce {
            onConfigChanged?()
        }
    }

    /// Optimistic save; the backend clamps and re-announces via config-changed.
    func saveConfig(_ draft: ReminderConfig) {
        guard let api = api() else { return }
        let previous = config
        config = draft
        language = draft.language
        L10n.language = resolvedLanguage
        Task {
            do {
                try await api.set_config(value: draft)
                configStatus = L10n.t("set.statusSaved", Date())
            } catch {
                config = previous
                language = previous.language
                L10n.language = resolvedLanguage
                configStatus = L10n.t("set.statusSaveFailed")
            }
        }
    }

    /// Select a named rhythm preset. The exact cadence values live in the
    /// Racket config module; the host only sends the name.
    func applyRhythmPreset(_ name: String) {
        guard let api = api() else { return }
        Task {
            do {
                try await api.set_rhythm_preset(name: name)
                if let c = try? await api.get_active_config() {
                    applyConfig(c, announce: true)
                }
                if let l = try? await api.get_loops() { loops = l }
                configStatus = L10n.t("set.statusSaved", Date())
            } catch {
                configStatus = L10n.t("set.statusSaveFailed")
            }
        }
    }

    func setAutostart(_ enabled: Bool) {
        guard let api = api() else { return }
        let previous = autostart
        autostart = enabled
        Task {
            do {
                try await api.set_autostart(enabled: enabled)
                configStatus = L10n.t("set.statusApplied", Date())
            } catch {
                autostart = previous
                configStatus = L10n.t("set.statusSaveFailed")
            }
        }
    }

    // MARK: cue actions (the v1 lifecycle: Done / Later / Hide)

    /// Done — self-reported acknowledgement. The backend never counts it as
    /// proof that water was drunk or a break taken.
    func acknowledgeCue(_ id: Int64) {
        guard let api = api() else { return }
        Task {
            try? await api.acknowledge_cue(id: id)
            if let q = try? await api.get_pending_cues() { pendingCues = q }
        }
    }

    /// Later — defers every kind merged into the cue by the snooze minutes.
    func snoozeCue(_ id: Int64) {
        guard let api = api() else { return }
        Task {
            try? await api.snooze_cue(id: id)
            if let l = try? await api.get_loops() { loops = l }
            if let q = try? await api.get_pending_cues() { pendingCues = q }
        }
    }

    /// Hide — removes the cue without claiming completion and without
    /// deferring; the next reminder arrives on its normal schedule.
    func dismissCue(_ id: Int64) {
        guard let api = api() else { return }
        Task {
            try? await api.dismiss_cue(id: id)
            if let q = try? await api.get_pending_cues() { pendingCues = q }
        }
    }

    /// Host report: the cue is actually visible (pending → displayed).
    func cueDisplayed(_ id: Int64) {
        guard let api = api() else { return }
        Task { try? await api.cue_displayed(id: id) }
    }

    /// Focus/presentation silence. While quiet the backend queues cues and
    /// emits nothing; leaving quiet delivers one bounded summary cue.
    func setQuiet(_ enabled: Bool) {
        guard let api = api() else { return }
        quiet = enabled
        Task {
            try? await api.set_quiet(enabled: enabled)
            if let q = try? await api.get_pending_cues() { pendingCues = q }
            onConfigChanged?()
        }
    }

    func togglePause() {
        guard let api = api() else { return }
        Task {
            if paused.paused {
                try? await api.resume()
            } else {
                try? await api.pause_1h()
            }
            if let p = try? await api.get_paused() { paused = p }
            onConfigChanged?()
        }
    }

    /// Best-effort flush on exit (port of FlushToday-on-exit).
    func flushNowSync() {
        guard let api = api() else { return }
        let semaphore = DispatchSemaphore(value: 0)
        let apiCopy = api
        Task.detached {
            try? await apiCopy.flush_now()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1)
    }

    // MARK: updates (backend-driven state machine)

    /// Update state machine, mirroring the Windows host's controller and the
    /// backend's snapshot phases: idle → checking → (available | upToDate |
    /// failed) → downloading → (cancelled | ready) → applying. The backend
    /// owns verify + download (signed feed) and the staged swap; this is
    /// presentation only.
    enum UpdatePhase: Equatable {
        case idle
        case checking
        case available
        case downloading
        case cancelled
        case ready
        case applying
        case upToDate
        case failed
    }

    @Published var updatePhase: UpdatePhase = .idle
    @Published var updateAvailableVersion: String?
    @Published var updatePercent: Int64 = 0
    /// Raw backend failure text — the About card shows it selectable so a
    /// bug report starts from the real message (family UPDATE.md rule).
    @Published var updateErrorText: String?

    private var updatePollTask: Task<Void, Never>?
    /// Wall-clock start of the current download — the host-side 30-minute
    /// watchdog reads it (nil whenever no download is in flight).
    private var updateDownloadStartedAt: Date?

    /// Manual entry (About card ▸ Check for Updates). Every outcome is
    /// visible — up to date and failures included.
    func checkForUpdates() {
        guard updatePhase != .checking, updatePhase != .downloading,
              updatePhase != .applying else { return }
        guard let api = api() else { return }
        updatePollTask?.cancel()
        updatePhase = .checking
        updateErrorText = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let check = try await api.check_updates()
                self.handleUpdateCheck(check)
            } catch {
                self.updatePhase = .failed
                self.updateErrorText = Self.cleanError(String(describing: error))
            }
        }
    }

    private func handleUpdateCheck(_ check: RivetTypes.UpdateCheck) {
        switch check.status {
        case "available":
            updatePhase = .available
            updateAvailableVersion = check.available_version
            updateErrorText = nil
        case "up-to-date":
            updatePhase = .upToDate
            updateAvailableVersion = nil
            updateErrorText = nil
        default:
            updatePhase = .failed
            updateErrorText = check.error ?? L10n.t("upd.checkFailed")
        }
    }

    /// One-shot snapshot read at startup: the backend's silent auto-check
    /// (startup + every 6 h) leaves its outcome in the state box; surface a
    /// pending update without nagging about anything else.
    func reflectPendingUpdate() {
        guard updatePhase == .idle, let api = api() else { return }
        Task { [weak self] in
            guard let self, let state = try? await api.get_update_state() else { return }
            guard self.updatePhase == .idle else { return }
            if state.phase == "idle", let version = state.available_version {
                self.updatePhase = .available
                self.updateAvailableVersion = version
            }
        }
    }

    /// Consent given: the backend downloads against the signed manifest while
    /// the UI polls the state snapshot.
    func startUpdateDownload() {
        guard updatePhase == .available || updatePhase == .cancelled,
              let api = api() else { return }
        updatePhase = .downloading
        updatePercent = 0
        updateErrorText = nil
        updateDownloadStartedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await api.start_update_download()
                self.pollUpdateState()
            } catch {
                self.updatePhase = .failed
                self.updateErrorText = Self.cleanError(String(describing: error))
            }
        }
    }

    /// The start RPC doubles as the cancel gesture (the backend's toggle
    /// contract): calling it while a download runs cancels that download and
    /// the poll loop observes the idle phase. The card then offers the
    /// update again instead of reporting a failure — a cancel is not one.
    func cancelUpdateDownload() {
        guard updatePhase == .downloading, api() != nil else { return }
        Task { [weak self] in
            guard let self, let api = self.api() else { return }
            _ = try? await api.start_update_download()
        }
    }

    /// 700 ms poll while downloading; terminal phases leave the loop. The
    /// 30-minute ceiling is the host-side backstop: the backend's own
    /// watchdog (stall 120 s / total 30 min) normally lands the terminal
    /// state first, but if the backend itself is wedged this forces the UI
    /// out of an endless progress bar.
    private func pollUpdateState() {
        updatePollTask?.cancel()
        updatePollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(30 * 60)
            while !Task.isCancelled {
                guard let self, let api = self.api() else { return }
                if let state = try? await api.get_update_state() {
                    self.applyUpdateState(state)
                }
                if Date() > deadline, self.updatePhase == .downloading {
                    self.cancelUpdateDownload()
                    self.updatePollTask?.cancel()
                    self.updateDownloadStartedAt = nil
                    self.updatePhase = .failed
                    self.updateErrorText = L10n.t("upd.checkFailed")
                    return
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    private func applyUpdateState(_ state: RivetTypes.UpdateState) {
        guard updatePhase == .downloading else { return }
        updatePercent = state.percent
        if let version = state.available_version {
            updateAvailableVersion = version
        }
        switch state.phase {
        case "downloaded":
            updatePollTask?.cancel()
            updateDownloadStartedAt = nil
            updatePhase = .ready
            updateErrorText = nil
        case "idle":
            // The cancel gesture landed: back to the offer, not a failure.
            updatePollTask?.cancel()
            updateDownloadStartedAt = nil
            updatePhase = .cancelled
            updateErrorText = nil
        case "error":
            updatePollTask?.cancel()
            updateDownloadStartedAt = nil
            updatePhase = .failed
            updateErrorText = state.message ?? L10n.t("upd.checkFailed")
        default:
            break
        }
    }

    /// 重启并安装: the backend stages the payload and spawns the detached
    /// helper; this host's only remaining job is to quit so the helper can
    /// swap the bundle and relaunch.
    func applyStagedUpdate() {
        guard updatePhase == .ready, let api = api() else { return }
        updatePhase = .applying
        updatePollTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await api.prepare_update_install()
                self.onQuitRequested?()
            } catch {
                self.updatePhase = .failed
                self.updateErrorText = Self.cleanError(String(describing: error))
            }
        }
    }

    /// The About card's button IS the state machine (parity with Windows):
    /// check → download → restart-install, retry on failure.
    func handleUpdateButton() {
        switch updatePhase {
        case .available, .cancelled:
            startUpdateDownload()
        case .ready:
            applyStagedUpdate()
        default:
            checkForUpdates()
        }
    }

    static func cleanError(_ text: String) -> String {
        // RVT1 failures arrive as "...error: <message>"; keep the message.
        if let range = text.range(of: "error: ") {
            return String(text[range.upperBound...])
        }
        return text
    }
}
