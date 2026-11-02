import SwiftUI
import AppKit
import RivetEmbedding
import RivetRuntime
import RivetSystem

// Tray app with no SwiftUI scenes: every window is an AppKit NSWindow owned
// by the delegate. Scene placeholders are not viable here — on current macOS
// both Settings and Window scenes present their (empty) window at launch,
// which users read as a stray "MoveBit Settings" window that never goes away.
@main
enum MoveBitApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate // NSApplication.delegate is not retained
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// The status-bar glyphs, drawn as template images (pure black + alpha) so
/// they follow the menu bar's light/dark appearance. Drawn in code — SwiftPM
/// resource bundles cannot ship inside a signed rivet app bundle.
///
/// Three presentation states (rivet's in-place status-item pattern): the
/// droplet is the resting brand glyph, Mubi's silhouette appears while a
/// reminder is on screen — the cue surface is pointer-through, so the menu
/// bar glyph is the character's visible bell — and the moon covers
/// focus/paused. Glyph art is hand-simplified for 18 pt legibility; the
/// canonical paths live in assets/mubi/tokens.json.
private enum MenuBarIcon {
    static var droplet: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 9, y: 16.5))
            path.curve(to: NSPoint(x: 3.1, y: 6.7),
                       controlPoint1: NSPoint(x: 9, y: 13.2),
                       controlPoint2: NSPoint(x: 4.6, y: 10.9))
            path.appendArc(withCenter: NSPoint(x: 9, y: 6.7), radius: 5.9,
                           startAngle: 180, endAngle: 360, clockwise: false)
            path.curve(to: NSPoint(x: 9, y: 16.5),
                       controlPoint1: NSPoint(x: 13.4, y: 10.9),
                       controlPoint2: NSPoint(x: 9, y: 13.2))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Mubi's silhouette: the egg body with two leaf ears, eyes knocked out
    /// (white shows the menu bar through the template mask).
    static var mubi: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            // Ears: slim tilted ovals peeking over the head.
            let ears: [(CGFloat, CGFloat)] = [(6.55, -22.0), (11.45, 22.0)]
            for spec in ears {
                let ear = NSBezierPath(
                    ovalIn: NSRect(x: spec.0 - 1.1, y: 13.6, width: 2.2, height: 3.6))
                var tilt = AffineTransform(translationByX: spec.0, byY: 15.4)
                tilt.rotate(byDegrees: spec.1)
                tilt.translate(x: -spec.0, y: -15.4)
                ear.transform(using: tilt)
                ear.fill()
            }
            // Body: the egg — wide calm bottom, narrow head.
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 9, y: 15.4))
            body.curve(to: NSPoint(x: 2.3, y: 7.6),
                       controlPoint1: NSPoint(x: 5.1, y: 13.6),
                       controlPoint2: NSPoint(x: 2.3, y: 10.9))
            body.curve(to: NSPoint(x: 15.7, y: 7.6),
                       controlPoint1: NSPoint(x: 2.3, y: 2.2),
                       controlPoint2: NSPoint(x: 15.7, y: 2.2))
            body.curve(to: NSPoint(x: 9, y: 15.4),
                       controlPoint1: NSPoint(x: 15.7, y: 10.9),
                       controlPoint2: NSPoint(x: 12.9, y: 13.6))
            body.close()
            body.fill()
            // Eyes: knocked out so the glyph reads as a face, not a blob.
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.1, y: 8.0, width: 1.5, height: 1.9)).fill()
            NSBezierPath(ovalIn: NSRect(x: 10.4, y: 8.0, width: 1.5, height: 1.9)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Quiet hours: focus mode or paused reminders.
    static var moon: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13)).fill()
            NSColor.white.setFill()
            // Same-radius bite offset 3.3pt to the right: the surviving
            // crescent is a slim ~3pt moon with pointed horns opening
            // right. A smaller bite circle reads as a blob at 18pt
            // (verified by rendering the exact rects offline).
            NSBezierPath(ovalIn: NSRect(x: 5.8, y: 2.5, width: 13, height: 13)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var shared: AppDelegate?

    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var onboardingState: OnboardingState?
    private var menuBar: RivetMenuBarController?
    private var menuBarGlyphState: GlyphState?
    private var companion: CompanionController?
    private var toastController: ToastPanelController?
    private var microController: MicroPanelController?
    // Retained for the process lifetime: dropping it releases the lease.
    private var instanceLease: RivetSingleInstance?
    private(set) var model: MoveBitModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Second launches exit; the running instance keeps the tray.
        if let lease = try? RivetSingleInstance(applicationID: "site.jrtx.movebit") {
            guard lease.isPrimary else {
                NSApp.terminate(nil)
                return
            }
            instanceLease = lease
        }
        Self.shared = self
        installMenus()

        let model = MoveBitModel()
        self.model = model

        model.onReady = { [weak self] in self?.handleReady() }
        model.onConfigChanged = { [weak self] in self?.handleConfigChanged() }
        model.onCue = { [weak self] cue in self?.handleHealthCue(cue) }
        model.onPendingCuesChanged = { [weak self] in self?.syncCuePresentation() }
        model.onSitAcknowledged = { [weak self] count in
            self?.handleSitAcknowledged(count)
        }
        // Restart-install handoff: the backend staged the update and spawned
        // the apply helper; quitting lets it swap the bundle and relaunch.
        model.onQuitRequested = { [weak self] in self?.quit() }

        installReminderPanels()
        rebuildMenuBar()
        installMainWindow(model: model)

        model.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flushNowSync()
    }

    // MARK: launch

    private func handleReady() {
        guard let model else { return }
        companion = CompanionController()
        syncCompanionConfig()
        companion?.showIdle()
        if ProcessInfo.processInfo.environment["MOVEBIT_ACCEPTANCE"] == "1" {
            showMainWindow()
            return
        }
        if !model.config.welcome_shown {
            showOnboarding()
        }
    }

    // MARK: main window (settings & stats)

    private func installMainWindow(model: MoveBitModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MoveBit"
        window.minSize = NSSize(width: 460, height: 320)
        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MoveBitMainWindow")
        window.delegate = self
        mainWindow = window
    }

    func showMainWindow() {
        guard let window = mainWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: menu bar (tray)
    // The status item installs once with the droplet icon; the pause label
    // swaps with the paused state and labels follow the language, so refresh
    // the menu entries in place (no status-item flicker on rebuild).

    private func rebuildMenuBar() {
        guard let model else { return }
        var items: [RivetMenuItem] = [
            .action(label: L10n.t("tray.open"), identifier: "tray-open",
                    handler: { [weak self] in self?.showMainWindow() }),
        ]
        // Mandatory reminder controls (issue #54): the character surface is
        // fully pointer-through, so Done/Later/Hide live here, acting on the
        // newest open cue. Always accessible, even mid-presentation.
        if let cue = model.pendingCues.last {
            items.append(.action(label: cueActionLabel(cue, done: L10n.t("tray.cueDone")),
                                 identifier: "tray-cue-done",
                                 handler: { [weak self] in
                                     self?.model?.acknowledgeCue(cue.id)
                                     self?.companion?.showAck()
                                 }))
            items.append(.action(label: L10n.t("tray.cueLater"),
                                 identifier: "tray-cue-later",
                                 handler: { [weak self] in
                                     self?.model?.snoozeCue(cue.id)
                                     // #56 §4 `later`: a tiny quiet settle.
                                     self?.companion?.show(state: .idle,
                                                           message: L10n.t("mubi.laterNote"))
                                 }))
            items.append(.action(label: L10n.t("tray.cueHide"),
                                 identifier: "tray-cue-hide",
                                 handler: { [weak self] in self?.model?.dismissCue(cue.id) }))
        }
        items.append(contentsOf: [
            .action(label: L10n.t("tray.moveAside"), identifier: "tray-mubi-move-aside",
                    handler: { [weak self] in self?.companion?.moveAside() }),
            .action(label: model.paused.paused ? L10n.t("tray.resume") : L10n.t("tray.pause"),
                    identifier: "tray-pause",
                    handler: { [weak self] in self?.model?.togglePause() }),
            .action(label: model.quiet ? L10n.t("tray.focusOff") : L10n.t("tray.focusOn"),
                    identifier: "tray-focus",
                    handler: { [weak self] in
                        guard let self, let model = self.model else { return }
                        let next = !model.quiet
                        model.setQuiet(next)
                        self.companion?.setQuiet(next)
                    }),
            .action(label: L10n.t("tray.exit"), identifier: "tray-exit",
                    handler: { [weak self] in self?.quit() }),
        ])
        if let menuBar {
            // The glyph is the character's bell: droplet at rest, Mubi
            // while a reminder is on screen, moon when quiet or paused.
            // Swapping reinstalls the status item (rivet's controller owns
            // the lifecycle); items themselves refresh in place.
            let state = glyphState(model)
            if state != menuBarGlyphState {
                menuBarGlyphState = state
                menuBar.install(icon: glyphImage(state), items: items)
            } else {
                menuBar.update(items: items)
            }
        } else {
            let controller = RivetMenuBarController()
            let state = glyphState(model)
            menuBarGlyphState = state
            controller.install(icon: glyphImage(state), items: items)
            menuBar = controller
        }
    }

    private enum GlyphState { case droplet, mubi, moon }

    private func glyphState(_ model: MoveBitModel) -> GlyphState {
        if model.paused.paused || model.quiet { return .moon }
        if !model.pendingCues.isEmpty { return .mubi }
        return .droplet
    }

    private func glyphImage(_ state: GlyphState) -> NSImage {
        switch state {
        case .droplet: return MenuBarIcon.droplet
        case .mubi: return MenuBarIcon.mubi
        case .moon: return MenuBarIcon.moon
        }
    }

    /// "Done — drink water" style label: the control names BOTH the action
    /// and the health advice, so the tray is self-explanatory.
    private func cueActionLabel(_ cue: HealthCue, done: String) -> String {
        let advice: String
        switch cue.action {
        case .drink_water: advice = L10n.t("notif.waterTitle")
        case .rest_eyes: advice = L10n.t("micro.hint")
        default: advice = L10n.t("notif.sitTitle")
        }
        return "\(done) · \(advice)"
    }

    /// The open-cue ledger changed: idle the character when nothing is open
    /// (acknowledged, snoozed, hidden, expired or quiet-settled) and refresh
    /// the tray's mandatory cue controls.
    private func syncCuePresentation() {
        if model?.pendingCues.isEmpty != false {
            companion?.showIdle()
        }
        rebuildMenuBar()
    }

    /// Push the v1 companion presentation settings into the character.
    private func syncCompanionConfig() {
        guard let config = model?.config else { return }
        companion?.applyConfig(size: config.companion_size,
                               motion: config.companion_motion,
                               dock: config.companion_dock,
                               labels: config.companion_labels)
    }

    private func handleConfigChanged() {
        syncCompanionConfig()
        rebuildMenuBar()
    }

    /// A milestone of SELF-REPORTED sit acknowledgments: one quiet cheer.
    /// A cheer claims nothing clinical (charter #51).
    private func handleSitAcknowledged(_ count: Int64) {
        guard let model, CopyPool.celebrateAt.contains(count) else { return }
        showToast(title: L10n.t("notif.cheerTitle"),
                  lines: [L10n.t("notif.cheerBody", "\(count)",
                                  CopyFormat.duration(model.today.active_mins))],
                  accent: .sit)
    }

    func quit() {
        model?.flushNowSync()
        NSApp.terminate(nil)
    }

    // MARK: main menu
    // The app is accessory, so its menus show only while a window is focused.
    // This restores the standard keyboard plumbing (Cmd+Q, text commands for
    // the selectable update-failure text, Cmd+W/M on windows) that the SwiftUI
    // scene layer used to provide for free.

    private func installMenus() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.t("menu.about"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.t("tray.exit"),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: L10n.t("menu.edit"))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: L10n.t("menu.undo"),
                         action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.t("menu.redo"),
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.t("menu.cut"),
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.t("menu.copy"),
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.t("menu.paste"),
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.t("menu.selectAll"),
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: L10n.t("menu.window"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.t("menu.close"),
                           action: #selector(NSWindow.performClose(_:)),
                           keyEquivalent: "w")
        windowMenu.addItem(withTitle: L10n.t("menu.minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")

        NSApp.mainMenu = mainMenu
    }

    // MARK: health cues
    // The backend planned the delivery; the host only renders it. The
    // character path is the v1 default; the non-blocking cards stay as the
    // notification fallback (a future "hide character" setting can report
    // surface-supported = false and the backend plans notifications).

    private func handleHealthCue(_ cue: HealthCue) {
        guard let model else { return }

        if cue.delivery == .character {
            // Sound was only played on the notification fallback path.
            // Character cues (water, move, eye rest, including merged kinds)
            // must honor the same user-selected one-shot sound setting.
            // Quiet/focus cues are normally withheld by the backend.
            if model.config.sound_enabled && !model.quiet {
                NSSound(named: "Ping")?.play()
            }
            companion?.show(state: cue.action.mubiState,
                            message: cueMessage(cue))
            model.cueDisplayed(cue.id)
            return
        }

        // Notification fallback (transitional cards, R1-era presentation).
        let kinds: [ReminderKind] = cue.kinds
        if kinds == [.micro] {
            // Micro-only cue: the eye-rest card; finishing it acknowledges.
            microController?.onDone = { [weak self] id in self?.model?.acknowledgeCue(id) }
            microController?.onHide = { [weak self] id in self?.model?.dismissCue(id) }
            microController?.show(durationSeconds: model.config.micro_break_duration_seconds,
                                  title: CopyPool.pickMicro(),
                                  cueId: cue.id)
            model.cueDisplayed(cue.id)
            return
        }

        let lines = cueLines(kinds: kinds, model: model)
        let title: String
        if kinds.contains(.sit) {
            title = L10n.t("notif.sitTitle")
        } else {
            title = L10n.t("notif.waterTitle")
        }
        let accent: ReminderKind = kinds.contains(.sit) ? .sit
            : kinds.contains(.water) ? .water : .micro

        if model.config.sound_enabled {
            NSSound(named: "Ping")?.play()
        }
        toastController?.onDone = { [weak self] id in self?.model?.acknowledgeCue(id) }
        toastController?.onSnooze = { [weak self] id in self?.model?.snoozeCue(id) }
        toastController?.onHide = { [weak self] id in self?.model?.dismissCue(id) }
        toastController?.show(ToastContent(title: title, lines: lines, accent: accent,
                                           snoozeMinutes: model.config.snooze_minutes,
                                           cueId: cue.id))
        model.cueDisplayed(cue.id)
    }

    /// One small, genuinely actionable invitation. When the Racket backend
    /// merges several due kinds (including after Focus), the bubble must name
    /// EVERY kind — the character pose alone communicates only the priority.
    private func cueMessage(_ cue: HealthCue) -> String {
        if cue.kinds.count > 1 {
            var parts: [String] = []
            if cue.kinds.contains(.sit) { parts.append(L10n.t("notif.sitTitle")) }
            if cue.kinds.contains(.water) { parts.append(L10n.t("notif.waterTitle")) }
            if cue.kinds.contains(.micro) { parts.append(L10n.t("micro.defaultTitle")) }
            return parts.joined(separator: " · ")
        }
        switch cue.action {
        case .drink_water: return CopyPool.pickWater()
        // Unlike micro.hint, this doesn't incorrectly promise clicking the
        // entirely pointer-through character to dismiss the notification.
        case .rest_eyes: return L10n.t("micro.defaultTitle")
        default: return L10n.t("notif.sitTitle")
        }
    }

    /// Per-kind line + a rotating pool line.
    private func cueLines(kinds: [ReminderKind], model: MoveBitModel) -> [String] {
        var lines: [String] = []
        if kinds.contains(.sit) {
            lines.append(L10n.t("notif.sitBody",
                                CopyFormat.duration(model.today.active_mins),
                                "\(model.today.sit_breaks)"))
            lines.append(L10n.pick(CopyPool.sitToasts.0, CopyPool.sitToasts.1))
        }
        if kinds.contains(.water) {
            lines.append(L10n.t("notif.waterCount", "\(model.today.water_reminders)"))
            lines.append(CopyPool.pickWater())
        }
        if kinds.contains(.micro) {
            lines.append(CopyPool.pickMicro())
        }
        return lines
    }

    func showToast(title: String, lines: [String], accent: ReminderKind) {
        toastController?.show(ToastContent(title: title, lines: lines, accent: accent,
                                           snoozeMinutes: 10,
                                           cueId: 0))
    }

    // MARK: reminder panels

    private func installReminderPanels() {
        let toast = ToastPanelController()
        toastController = toast

        microController = MicroPanelController()
    }

    // MARK: onboarding

    func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let model else { return }
        let state = OnboardingState()
        onboardingState = state
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = L10n.t("ob.title")
        window.contentView = NSHostingView(
            rootView: OnboardingView(state: state, model: model))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeOnboarding() {
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
        onboardingState = nil
    }

    /// Called by the wizard's finish/skip: mark seen + settled toast (parity).
    func onboardingFinished() {
        if let state = onboardingState {
            state.finished = true
        }
        showToast(title: L10n.t("ob.settled"),
                  lines: [L10n.t("ob.settledBody")],
                  accent: .water)
    }
}

extension AppDelegate: NSWindowDelegate {
    // Closing the main window hides it (the tray brings it back); Quit lives in
    // the tray menu only. The onboarding window really closes — closing midway
    // counts as seen and persists the current selections.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === mainWindow {
            sender.orderOut(nil)
            return false
        }
        if sender === onboardingWindow {
            // Whatever was selected last is kept; onboarding cannot nag again.
            if let state = onboardingState, !state.finished, let model {
                state.persist(model: model, welcomeShown: true)
            }
            onboardingWindow = nil
            onboardingState = nil
        }
        return true
    }
}
