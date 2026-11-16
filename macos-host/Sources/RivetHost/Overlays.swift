import SwiftUI
import AppKit

// MARK: - micro eye-rest card
// Small top-center card with a thin shrinking progress bar: rest your eyes
// while it runs. Letting it finish acknowledges the cue; click / Esc ends it
// early as a Hide. Never locks, never steals focus, silent by design.

@MainActor
final class MicroPanelController: ObservableObject {
    @Published var progress = 1.0
    /// The guided rest only starts on an explicit user action (#94).
    @Published var started = false
    /// The countdown reached zero. Completion is NOT a self-report: the user
    /// marks Done explicitly, or clicks the card away as a Hide.
    @Published var finished = false

    var onDone: ((Int64) -> Void)?
    var onHide: ((Int64) -> Void)?

    private var panel: NSPanel?
    private var generation = 0
    private var keyMonitor: Any?
    private var currentCueId: Int64 = 0
    private var durationSeconds: Int64 = 20
    /// Invitation copy for this session (eye rest vs guided movement).
    private(set) var hintText = L10n.t("micro.hint")

    func show(durationSeconds: Int64, title: String, hint: String,
              cueId: Int64) {
        // Replacing a session (a newer cue, or the menu reopened) must not
        // record the previous cue as abandoned; only an explicit Hide does.
        closePanel()
        generation += 1
        let generation = generation
        progress = 1
        started = false
        finished = false
        hintText = hint
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

        self.durationSeconds = max(1, durationSeconds)
    }

    /// Explicit opt-in: only now does the countdown run.
    func start() {
        guard !started, !finished else { return }
        started = true
        progress = 1
        let generation = generation
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
            Text(controller.finished ? L10n.t("micro.finishedHint")
                                     : controller.hintText)
                .font(.system(size: 11.5))
                .foregroundColor(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if controller.started {
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
            }
            HStack(spacing: 8) {
                if !controller.started {
                    Button(L10n.t("micro.start")) { controller.start() }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .controlSize(.small)
                }
                Button(L10n.t("micro.done")) { controller.finish() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(L10n.t("notif.hide")) { controller.dismissInteractive() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.top, 6)
        }
        .padding(EdgeInsets(top: 18, leading: 26, bottom: 18, trailing: 26))
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 18).fill(Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Palette.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
