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
        // Issue #104: persist the drag-placed position through the same
        // config RPC.
        companion?.onPlacementChanged = { [weak self] x, y in
            guard let self, let model = self.model else { return }
            model.saveConfig(model.config.with(companion_free_x: x,
                                               companion_free_y: y))
        }
        // 2026-11-15 contract: petting is companionship ONLY — completion
        // submits through the invitation's buttons, the tray items or the
        // micro window's 做好了. The pet surface never acknowledges.
        companion?.onPat = { _ = self }
        companion?.onDoneAll = { [weak self] in
            guard let self, let model = self.model else { return }
            model.acknowledgeAllPending()
            self.companion?.showAck()
        }
        companion?.onLater = { [weak self] in
            guard let self, let model = self.model else { return }
            model.snoozeAllPending()
            self.companion?.react(.later)
        }
        companion?.onHideThis = { [weak self] in
            self?.model?.dismissAllPending()
        }
        companion?.onConfirmPartial = { [weak self] words in
            guard let self, let model = self.model else { return }
            for cue in model.pendingCues {
                let selected = cue.kinds
                    .map { $0.invitationWord }
                    .filter { words.contains($0) }
                if !selected.isEmpty {
                    model.acknowledgeCueKinds(cue.id, kinds: selected)
                }
            }
            self.companion?.showAck()
        }
        companion?.onMenuButton = { [weak self] rect in
            self?.popupCompanionMenu(at: rect)
        }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        // Compact titlebar (2026-11-15 辅助窗口): the platform titlebar row
        // carries the traffic lights; the title text is hidden and the leaf
        // mark + wordmark render inside the content's titlebar row.
        window.title = "MoveBit"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 460, height: 420)
        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MoveBitMainWindow")
        window.delegate = self
        mainWindow = window
    }

    /// 今日 ▸ 回到沐比身边: the utility window steps aside; the invitation
    /// waits with the pet on the same desktop (reminders are never cleared).
    func hideUtilityWindow() {
        mainWindow?.orderOut(nil)
    }

    /// 关于 ▸ 数据位置: reveal the real local data directory in Finder.
    func revealDataLocation() {
        guard let model else { return }
        let dir = model.dataDir
        guard !dir.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    /// The utility statusbar's ••• opens the same compact menu as the tray.
    func popupFromUtilityStatusbar(_ windowRect: NSRect) {
        guard let window = mainWindow else { return }
        popupCompanionMenu(at: window.convertToScreen(windowRect))
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

    /// The shared menu content (tray status item AND the pet's ••• button
    /// popup): the 2026-11-15 contract's compact menu. Response items act on
    /// the whole merged invitation; the character surface never does.
    private func makeTrayItems() -> [RivetMenuItem] {
        guard let model else { return [] }
        var items: [RivetMenuItem] = [
            .action(label: L10n.t("tray.open"), identifier: "tray-open",
                    handler: { [weak self] in self?.showMainWindow() }),
        ]
        if !model.pendingCues.isEmpty {
            items.append(.separator)
            items.append(.action(label: L10n.t("tray.cueDone"),
                                 identifier: "tray-cue-done",
                                 handler: { [weak self] in
                                     self?.model?.acknowledgeAllPending()
                                     self?.companion?.showAck()
                                 }))
            items.append(.action(label: L10n.t("tray.confirmIndividually"),
                                 identifier: "tray-cue-partial",
                                 handler: { [weak self] in
                                     self?.companion?.revealPartial()
                                 }))
            items.append(.action(label: L10n.t("tray.cueLater"),
                                 identifier: "tray-cue-later",
                                 handler: { [weak self] in
                                     self?.model?.snoozeAllPending()
                                     self?.companion?.react(.later)
                                 }))
            items.append(.action(label: L10n.t("tray.cueHide"),
                                 identifier: "tray-cue-hide",
                                 handler: { [weak self] in
                                     self?.model?.dismissAllPending()
                                 }))
        }
        // Opt-in guided sessions (#94): only offered while a real cue is
        // open, never as ambient entertainment.
        if let cue = model.pendingCues.first(where: { $0.kinds.contains(.micro) }) {
            items.append(.separator)
            items.append(.action(
                label: L10n.t("tray.eyeRest"), identifier: "tray-eye-rest",
                handler: { [weak self] in
                    self?.microController?.show(
                        durationSeconds: 20,
                        title: L10n.t("tray.eyeRest"),
                        hint: L10n.t("micro.hint"),
                        cueId: cue.id)
                }))
        }
        if let cue = model.pendingCues.first(where: { $0.kinds.contains(.sit) }) {
            items.append(.action(
                label: L10n.t("tray.stretch"), identifier: "tray-stretch",
                handler: { [weak self] in
                    self?.microController?.show(
                        durationSeconds: 120,
                        title: L10n.t("stretch.title"),
                        hint: L10n.t("stretch.hint"),
                        cueId: cue.id)
                }))
        }
        items.append(.separator)
        items.append(.action(label: model.paused.paused ? L10n.t("tray.resume") : L10n.t("tray.pause"),
                             identifier: "tray-pause",
                             handler: { [weak self] in self?.model?.togglePause() }))
        items.append(.action(label: model.quiet ? L10n.t("tray.focusOff") : L10n.t("tray.focusOn"),
                             identifier: "tray-focus",
                             handler: { [weak self] in
                                 guard let self, let model = self.model else { return }
                                 let next = !model.quiet
                                 model.setQuiet(next)
                                 self.companion?.setSuspended(next || model.isPaused)
                             }))
        items.append(.action(label: L10n.t("tray.resetMubi"), identifier: "tray-mubi-reset",
                             handler: { [weak self] in self?.companion?.resetHome() }))
        items.append(.separator)
        items.append(.action(label: L10n.t("tray.checkUpdate"), identifier: "tray-update",
                             handler: { [weak self] in
                                 self?.showMainWindow()
                             }))
        items.append(.separator)
        items.append(.action(label: L10n.t("tray.exit"), identifier: "tray-exit",
                             handler: { [weak self] in self?.quit() }))
        return items
    }

    /// The pet's ••• button pops the same menu as the tray at its anchor.
    private var companionMenuHandlers: [String: () -> Void] = [:]

    func popupCompanionMenu(at screenRect: NSRect) {
        let menu = NSMenu()
        companionMenuHandlers.removeAll()
        for item in makeTrayItems() {
            switch item {
            case .action(let label, let identifier, let handler):
                let menuItem = NSMenuItem(
                    title: label,
                    action: #selector(invokeCompanionMenuItem(_:)),
                    keyEquivalent: "")
                menuItem.identifier =
                    NSUserInterfaceItemIdentifier(identifier)
                menuItem.target = self
                menu.addItem(menuItem)
                companionMenuHandlers[identifier] = handler
            case .separator:
                menu.addItem(.separator())
            }
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil,
                   at: NSPoint(x: screenRect.minX,
                               y: screenRect.maxY + 6),
                   in: nil)
    }

    @objc private func invokeCompanionMenuItem(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue,
              let handler = companionMenuHandlers[identifier] else { return }
        handler()
    }

    private func rebuildMenuBar() {
        guard let model else { return }
        let items = makeTrayItems()
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

    /// The open-cue ledger changed: re-derive the invitation attached to
    /// the pet and refresh the tray's response items. Suspended states
    /// (pause / focus / quiet hours) tuck the invitation away.
    private func syncCuePresentation() {
        guard let model else { return }
        let suspended = model.isPaused || model.quiet
        let words = model.pendingCues
            .flatMap { $0.kinds.map { $0.invitationWord } }
        let kinds = ["move", "water", "eyes"].filter { words.contains($0) }
        companion?.update(
            invitation: kinds.isEmpty ? nil : CompanionInvitation(kinds: kinds),
            suspended: suspended)
        rebuildMenuBar()
    }

    /// Push the v1 companion presentation settings into the character.
    private func syncCompanionConfig() {
        guard let config = model?.config else { return }
        companion?.applyConfig(freeX: config.companion_free_x,
                               freeY: config.companion_free_y)
    }

    private func handleConfigChanged() {
        syncCompanionConfig()
        syncCuePresentation()
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

    /// One soft chime per arrival, plus at most one per minute for begging
    /// acts — attention, never noise. Honors the sound setting and Focus.
    private var lastChimeAt = Date.distantPast
    private func playCueChime() {
        guard let model, model.config.sound_enabled, !model.quiet else { return }
        guard Date().timeIntervalSince(lastChimeAt) >= 60 else { return }
        lastChimeAt = Date()
        NSSound(named: "Ping")?.play()
    }

    private func handleHealthCue(_ cue: HealthCue) {
        guard let model else { return }

        if cue.delivery == .character {
            // Character cues (water, move, eye rest, including merged kinds)
            // honor the user-selected one-shot sound setting. The invitation
            // attaches to the pet and waits there (2026-11-15: no visit, no
            // toast). Quiet/focus cues are normally withheld by the backend.
            playCueChime()
            model.cueDisplayed(cue.id)
            return
        }

        // Notification fallback (no character surface): the system
        // notification center carries the cue; the tray/main window keep the
        // response paths reachable (2026-11-15 contract, 常驻系统入口 row).
        model.cueDisplayed(cue.id)
    }


    // MARK: reminder panels

    private func installReminderPanels() {
        microController = MicroPanelController()
        microController?.onDone = { [weak self] id in self?.model?.acknowledgeCue(id) }
        microController?.onHide = { [weak self] id in self?.model?.abandonCue(id) }
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
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

    /// Called by the onboarding Start: mark seen. The pet's hello caption
    /// is the settle feedback (2026-11-15: no toast surfaces).
    func onboardingFinished() {
        if let state = onboardingState {
            state.finished = true
        }
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
