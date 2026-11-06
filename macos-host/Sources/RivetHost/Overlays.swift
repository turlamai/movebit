import SwiftUI
import AppKit

// MARK: - reminder toast
// Non-activating bottom-right panel, 9 s auto-close paused on hover; one card
// lists all due kinds. The buttons map to the v1 cue lifecycle: Done
// acknowledges (self-reported), Later snoozes every merged kind, Hide removes
// the card without claiming completion; the auto-close is a Hide.
// This panel is the transitional presentation (issue #55 R1): R2 replaces it
// with the edge-docked character.

struct ToastContent {
    let title: String
    let lines: [String]
    let accent: ReminderKind
    let snoozeMinutes: Int64
    /// The cue payload id; 0 for informational toasts (cheers, onboarding)
    /// which carry no lifecycle actions.
    let cueId: Int64
}

@MainActor
final class ToastPanelController: ObservableObject {
    var onDone: ((Int64) -> Void)?
    var onSnooze: ((Int64) -> Void)?
    var onHide: ((Int64) -> Void)?

    private var panel: NSPanel?
    private var dismissGeneration = 0
    private var currentCueId: Int64 = 0

    func show(_ content: ToastContent) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        currentCueId = content.cueId
        let hosting = NSHostingView(rootView: ToastView(content: content, controller: self))
        hosting.sizingOptions = .preferredContentSize
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
        restartAutoClose()
    }

    func restartAutoClose() {
        // Called on pointer enter and exit: hovering holds the card open.
        dismissGeneration += 1
        let generation = dismissGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard let self, generation == self.dismissGeneration else { return }
            self.hideTapped()
        }
    }

    func doneTapped() {
        let id = currentCueId
        dismiss()
        if id != 0 { onDone?(id) }
    }

    func snoozeTapped() {
        let id = currentCueId
        dismiss()
        if id != 0 { onSnooze?(id) }
    }

    func hideTapped() {
        let id = currentCueId
        dismiss()
        if id != 0 { onHide?(id) }
    }

    /// Non-cue toasts (cheers) just close.
    func dismiss() {
        dismissGeneration += 1
        currentCueId = 0
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - 16,
                             y: visible.minY + 16)
        panel.setFrameOrigin(origin)
    }
}

private struct ToastView: View {
    let content: ToastContent
    @ObservedObject var controller: ToastPanelController

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Palette.kindAccent(content.accent))
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 10) {
                Text(content.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(hex: "#26241F"))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(content.lines.indices, id: \.self) { index in
                        Text(content.lines[index])
                            .font(.system(size: 13.5))
                            .opacity(0.75)
                            .foregroundColor(Color(hex: "#6E6A5E"))
                    }
                }
                HStack(spacing: 10) {
                    Spacer()
                    if content.cueId != 0 {
                        Button(L10n.t("notif.hide")) { controller.hideTapped() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(hex: "#A39E8C"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        Button(L10n.t("notif.snooze", "\(content.snoozeMinutes)")) {
                            controller.snoozeTapped()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: "#6E6A5E"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color(hex: "#E2DCCC"), lineWidth: 1))
                        Button(L10n.t("notif.done")) { controller.doneTapped() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(hex: "#26241F"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(Color(hex: "#F3EEE3")))
                    } else {
                        Button(L10n.t("notif.gotIt")) { controller.dismiss() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(hex: "#26241F"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(Color(hex: "#F3EEE3")))
                    }
                }
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20))
        }
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: "#FFFDFB")))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { _ in controller.restartAutoClose() }
    }
}

// MARK: - micro eye-rest card
// Small top-center card with a thin shrinking progress bar: rest your eyes
// while it runs. Letting it finish acknowledges the cue; click / Esc ends it
// early as a Hide. Never locks, never steals focus, silent by design.

@MainActor
final class MicroPanelController: ObservableObject {
    @Published var progress = 1.0
    /// The countdown reached zero. Completion is NOT a self-report: the user
    /// marks Done in the tray, or clicks the card away as a Hide.
    @Published var finished = false

    var onDone: ((Int64) -> Void)?
    var onHide: ((Int64) -> Void)?

    private var panel: NSPanel?
    private var generation = 0
    private var keyMonitor: Any?
    private var currentCueId: Int64 = 0

    func show(durationSeconds: Int64, title: String, cueId: Int64) {
        dismissInteractive()
        generation += 1
        let generation = generation
        progress = 1
        finished = false
        currentCueId = cueId

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: MicroBreakView(title: title, controller: self))
        hosting.sizingOptions = .preferredContentSize
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        panel.orderFrontRegardless()
        installKeyMonitor()

        let totalNanos = UInt64(max(1, durationSeconds) * 1_000_000_000)
        let tick = min(totalNanos, 250_000_000)
        Task { [weak self] in
            while let self, generation == self.generation {
                try? await Task.sleep(nanoseconds: tick)
                guard generation == self.generation else { return }
                self.progress = max(0, self.progress - Double(tick) / Double(totalNanos))
                if self.progress <= 0 {
                    self.finished = true
                    // Leave the card briefly so the finish is visible, then
                    // hide it without claiming completion. The cue stays
                    // open in the tray for an explicit Done.
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    guard generation == self.generation, self.finished else { return }
                    self.dismissInteractive()
                    return
                }
            }
        }
    }

    /// The eye rest ran its course: acknowledge the cue (self-reported).
    func finish() {
        let id = currentCueId
        closePanel()
        if id != 0 { onDone?(id) }
    }

    /// Click / Esc / a newer cue: end early as a Hide — no completion claimed.
    func dismissInteractive() {
        let id = currentCueId
        closePanel()
        if id != 0 { onHide?(id) }
    }

    private func closePanel() {
        generation += 1
        currentCueId = 0
        panel?.orderOut(nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                if let self {
                    MainActor.assumeIsolated { self.dismissInteractive() }
                }
                return nil
            }
            return event
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 110),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// Upper third of the primary screen, in the sight line.
    private func position(_ panel: NSPanel) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - visible.height * 0.28 - size.height)
        panel.setFrameOrigin(origin)
    }
}

private struct MicroBreakView: View {
    let title: String
    @ObservedObject var controller: MicroPanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("👀").font(.system(size: 22))
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Palette.inkPrimary)
            }
            Text(L10n.t(controller.finished ? "micro.finishedHint" : "micro.hint"))
                .font(.system(size: 11.5))
                .foregroundColor(Palette.inkMuted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Palette.trackBg)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent)
                        .frame(width: geo.size.width * CGFloat(controller.progress))
                }
            }
            .frame(height: 4)
            .padding(.top, 6)
            if controller.finished {
                Button(L10n.t("micro.done")) { controller.finish() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 26, bottom: 18, trailing: 26))
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Palette.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(Rectangle())
        .onTapGesture { controller.dismissInteractive() }
    }
}
