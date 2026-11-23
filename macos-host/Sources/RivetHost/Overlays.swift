import SwiftUI
import AppKit

// MARK: - micro break window (2026-11-15 contract 微休息)
// A small top-center non-activating window with three real states —
// invite (开始), running (timer by deadline), ended (in-place 做好了).
// Stopping, closing, Esc and 先收起来 never record completion; 做好了
// acknowledges the cue of the running kind when one is open. Never
// fullscreen, never locks, silent by design.

@MainActor
final class MicroPanelController: ObservableObject {
    enum Phase: Equatable {
        case invite
        case running
        case ended
    }

    @Published var phase: Phase = .invite
    @Published var seconds: Int64 = 20
    @Published var remaining: Int64 = 20
    @Published var progress: Double = 1

    /// Acknowledges the cue matching the running kind (eyes→micro,
    /// stretch→sit); no open cue of that kind = nothing is recorded.
    var onDone: ((Int64) -> Void)?
    /// 先收起来 / Esc / window close: a deliberate stop, not a completion.
    var onHide: ((Int64) -> Void)?

    private var panel: NSPanel?
    private var generation = 0
    private var keyMonitor: Any?
    /// Open cue ids by kind symbol ("sit"/"water"/"micro") at show time.
    private var cueIds: [String: Int64] = [:]
    private var deadline: Date = .distantFuture
    private var ticker: Task<Void, Never>?

    /// Duration per kind (contract: 20-second eyes / 2-minute stretch; the
    /// rhythm is a product default, the KIND is user-chosen here).
    private static let eyesSeconds: Int64 = 20
    private static let stretchSeconds: Int64 = 120

    func show(cueIds: [String: Int64], eyes: Bool) {
        closePanel()
        generation += 1
        self.cueIds = cueIds
        phase = .invite
        setKind(eyes: eyes)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingView(rootView: MicroBreakView(controller: self))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        position(panel)
        panel.orderFrontRegardless()
        installKeyMonitor()
    }

    /// Tray/menu entry points keep their shape; the cue map decides what
    /// 做好了 can settle.
    func show(durationSeconds: Int64, title: String, hint: String,
              cueId: Int64) {
        let kind = durationSeconds >= 120 ? "sit" : "micro"
        show(cueIds: [kind: cueId], eyes: durationSeconds < 120)
    }

    private func setKind(eyes: Bool) {
        seconds = eyes ? Self.eyesSeconds : Self.stretchSeconds
        remaining = seconds
        progress = 1
    }

    var isEyes: Bool { seconds == Self.eyesSeconds }

    /// 开始: the timer runs by deadline (contract 倒计时按截止时间计算).
    func start() {
        guard phase == .invite || phase == .ended else { return }
        phase = .running
        remaining = seconds
        progress = 1
        deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let current = generation
        ticker?.cancel()
        ticker = Task { [weak self] in
            while let self, current == self.generation, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard current == self.generation else { return }
                let left = Int64(max(0, self.deadline.timeIntervalSinceNow.rounded()))
                if left != self.remaining {
                    self.remaining = left
                    self.progress =
                        Double(max(0, left)) / Double(max(1, self.seconds))
                }
                if left <= 0 {
                    // In-place confirm (contract: 结束后保留原地确认，不自动
                    // 算完成、不要求去托盘). No auto-close.
                    self.phase = .ended
                    return
                }
            }
        }
    }

    /// 停止计时: back to the invite, nothing recorded.
    func stopTimer() {
        ticker?.cancel()
        phase = .invite
        remaining = seconds
        progress = 1
    }

    var currentCueId: Int64? {
        isEyes ? cueIds["micro"] : cueIds["sit"]
    }

    /// 做好了: settle the running kind's open cue; without one nothing is
    /// recorded (完成由你确认，同类待回应项才消除).
    func finish() {
        ticker?.cancel()
        let id = currentCueId
        closePanel()
        if let id { onDone?(id) }
    }

    /// 先收起来 / Esc / close: deliberate stop, never a completion.
    func tuckAway() {
        ticker?.cancel()
        let id = currentCueId
        closePanel()
        if let id { onHide?(id) }
    }

    /// 改为 20 秒护眼 / 改为 2 分钟拉伸: invite-state kind switch.
    func switchKind() {
        guard phase == .invite else { return }
        setKind(eyes: !isEyes)
    }

    private func closePanel() {
        generation += 1
        ticker?.cancel()
        cueIds = [:]
        panel?.orderOut(nil)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape — never records completion
                if let self {
                    MainActor.assumeIsolated { self.tuckAway() }
                }
                return nil
            }
            return event
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
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

/// The break window body: compact titlebar (leaf + title + ×) and the
/// state-driven content per the prototype's micro() view.
private struct MicroBreakView: View {
    @ObservedObject var controller: MicroPanelController
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var title: String {
        controller.isEyes ? L10n.t("micro.eyesTitle") : L10n.t("micro.stretchTitle")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                LeafIcon()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Palette.inkSecondary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.inkPrimary)
                Spacer()
                Button {
                    controller.tuckAway()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Palette.inkMuted)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.t("micro.tuckAway"))
                .help(L10n.t("micro.tuckAway"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Palette.titlebarBg)

            VStack(alignment: .leading, spacing: 12) {
                Text(bodyHeading)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Palette.inkPrimary)
                Text(bodyText)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if controller.phase == .running {
                    Text("\(controller.remaining) \(L10n.t("micro.seconds"))")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundColor(Palette.inkPrimary)
                        .monospacedDigit()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Palette.trackBg)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Palette.accent)
                                .frame(width: geo.size.width
                                       * CGFloat(controller.progress))
                        }
                    }
                    .frame(height: 8)
                }

                HStack(spacing: 10) {
                    switch controller.phase {
                    case .running:
                        primaryButton(L10n.t("micro.done")) { controller.finish() }
                        quietButton(L10n.t("micro.stop")) { controller.stopTimer() }
                    case .ended:
                        Text(L10n.t("micro.endedHint"))
                            .font(.system(size: 11.5))
                            .foregroundColor(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        primaryButton(L10n.t("micro.done")) { controller.finish() }
                        quietButton(L10n.t("micro.restart")) { controller.start() }
                    case .invite:
                        primaryButton(L10n.t("micro.start")) { controller.start() }
                    }
                    quietButton(L10n.t("micro.tuckAway")) { controller.tuckAway() }
                    Spacer()
                }
                if controller.phase == .invite {
                    quietButton(controller.isEyes ? L10n.t("micro.switchStretch")
                                                  : L10n.t("micro.switchEyes")) {
                        controller.switchKind()
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.appBg))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Palette.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var bodyHeading: String {
        switch controller.phase {
        case .ended: return L10n.t("micro.endedTitle")
        default: return controller.isEyes ? L10n.t("micro.eyesTitle")
                                          : L10n.t("micro.stretchTitle")
        }
    }

    private var bodyText: String {
        if controller.phase == .ended {
            return L10n.t("micro.endedHint")
        }
        return controller.isEyes ? L10n.t("micro.eyesBody")
                                 : L10n.t("micro.stretchBody")
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(dark ? Color(hex: "#241C16") : Palette.appBg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent))
        .buttonStyle(.plain)
    }

    private func quietButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(Palette.inkSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .buttonStyle(.plain)
    }
}
