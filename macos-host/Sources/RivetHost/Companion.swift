import SwiftUI
import AppKit

// Mubi（沐比）— the MoveBit v1 companion, rendered from the canonical
// design system (issue #56; assets/mubi/tokens.json + docs/MUBI-DESIGN-
// SYSTEM.md). Reminders first: the character DELIVERS the backend's health
// cues (charter #51), it is not a pet product.
//
// Safety contract (issue #54): the panel is non-activating and FULLY
// pointer-through (`ignoresMouseEvents` on the whole window) — the
// #56-documented fallback, because native partial hit regions are not
// proven safe. Done / Later / Hide / Focus live in the tray and the
// accessible main window. The panel never crosses the document center;
// one bounded dock per the companion-dock setting; re-clamped on display
// changes.
//
// Geometry: the path strings below are the canonical master data from
// assets/mubi/tokens.json (generator: scripts/gen-mubi-art.mjs). Verify
// against tokens.json when touching art — never redraw or approximate.

/// Minimal SVG path parser for the canonical Mubi strings. The master data
/// uses absolute `M / L / C / Z` commands only (enforced by the generator),
/// with spaces and commas as separators.
enum MubiPath {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var index = d.startIndex
        var current: CGPoint = .zero
        var points: [CGPoint] = []

        func skipSeparators() {
            while index < d.endIndex,
                  d[index] == " " || d[index] == "," {
                index = d.index(after: index)
            }
        }
        func number() -> CGFloat {
            skipSeparators()
            let start = index
            if index < d.endIndex, d[index] == "-" { index = d.index(after: index) }
            while index < d.endIndex,
                  d[index].isNumber || d[index] == "." {
                index = d.index(after: index)
            }
            return CGFloat(Double(d[start..<index]) ?? 0)
        }
        func point() -> CGPoint { CGPoint(x: number(), y: number()) }

        while index < d.endIndex {
            skipSeparators()
            guard index < d.endIndex else { break }
            let command = d[index]
            index = d.index(after: index)
            switch command {
            case "M":
                current = point()
                path.move(to: current)
            case "L":
                current = point()
                path.addLine(to: current)
            case "C":
                points = [point(), point(), point()]
                path.addCurve(to: points[2],
                              control1: points[0],
                              control2: points[1])
                current = points[2]
            case "Z":
                path.closeSubpath()
            default:
                break
            }
        }
        return path
    }
}

/// Canonical Mubi geometry + tokens (assets/mubi/tokens.json).
enum MubiArt {
    static let canvas = CGSize(width: 120, height: 140)
    /// The BODY is the sizing contract (S 60 / M 78 / L 104 logical units).
    static let bodyHeight: CGFloat = 108

    static let body = "M 58 16 C 82 18, 106 46, 109 82 C 111 104, 92 124, 60 124 C 33 124, 12.5 106, 11 84 C 9.5 52, 34 14, 58 16 Z"
    static let finLeft = "M 52 24 C 47 13, 40 7, 32 6 C 30 14, 36 23, 45 27 C 48 28.2, 51 26.5, 52 24 Z"
    static let finRight = "M 74 23 C 71 14, 66.5 8, 60.5 6 C 58.5 13, 62.5 21.5, 70 25 C 72.3 25.9, 73.8 25, 74 23 Z"
    static let finShade = "M 48 22 C 44.5 15.5, 39.5 10.5, 34.5 8.5 C 33.5 13.5, 38 20.5, 45 24.5 Z"
    static let lowerShade = "M 16 96 C 24 118, 42 126, 60 126 C 80 126, 98 116, 105 94 C 100 116, 84 128, 60 128 C 38 128, 20 114, 16 96 Z"
    static let eyeClosedLeft = "M 43 65 C 45 67.6, 48 67.6, 50 65"
    static let eyeClosedRight = "M 70 65 C 72 67.6, 75 67.6, 77 65"
    static let mouthAck = "M 57.5 74 C 59 75.4, 61 75.4, 62.5 74"
    static let gazeCrescent = "M 92 38 C 96.5 40.5, 99 45, 98 50"
    static let stretchArcLeft = "M 42 11 C 47 4, 53 2, 58 4"
    static let stretchArcRight = "M 78 11 C 73 4, 67 2, 62 4"
    static let ackGlint = "M 84 56 L 86 60.5 L 90.5 62 L 86 63.5 L 84 68 L 82 63.5 L 77.5 62 L 82 60.5 Z"
    static let cupBody = "M -7 -9 L 7 -9 L 5.4 9 C 5.2 10.6, 4 11.5, 2.4 11.5 L -2.4 11.5 C -4 11.5, -5.2 10.6, -5.4 9 Z"
    static let cupWater = "M -4.6 -6.5 L 4.4 -6.5 L 3.6 1.5 L -4 1.5 Z"

    static let eyeLeft = CGPoint(x: 46.5, y: 65)
    static let eyeRight = CGPoint(x: 73.5, y: 65)

    // Color tokens (assets/mubi/tokens.json).
    static let bodyLight = Color(hex: "#FBF5E9")
    static let bodyBase = Color(hex: "#F6EEDF")
    static let bodyDeep = Color(hex: "#E8D7BE")
    static let shadow = Color(hex: "#D8C8B5")
    static let ink = Color(hex: "#2D2A28")
    static let fin = Color(hex: "#F1E4CC")
    static let water = Color(hex: "#62B6FF")
    static let waterSoft = Color(hex: "#8FCBFF")
    static let move = Color(hex: "#FF8C6B")
    static let eyes = Color(hex: "#65C8B8")
    static let done = Color(hex: "#F2C96B")
    static let focusTint = Color(hex: "#8DA1B5")
    static let labelSurfaceLight = Color(hex: "#FFFDFB")
    static let labelTextLight = Color(hex: "#2D2A28")
    static let labelSurfaceDark = Color(hex: "#33302B")
    static let labelTextDark = Color(hex: "#F1EEE7")
}

/// The seven presentation states (#56 §4). `focus` replaces the idle pose
/// while Focus/presentation silence is on.
enum MubiState {
    case idle
    case water
    case stand
    case eyes
    case ack
    case focus
}

extension CueAction {
    /// Semantic suggested action -> Mubi presentation state.
    var mubiState: MubiState {
        switch self {
        case .stand_and_stretch: return .stand
        case .drink_water: return .water
        case .rest_eyes: return .eyes
        @unknown default: return .idle
        }
    }
}

// MARK: - character view

private struct MubiShape: Shape {
    let d: String
    func path(in rect: CGRect) -> Path {
        MubiPath.parse(d)
            .applying(CGAffineTransform(scaleX: rect.width / MubiArt.canvas.width,
                                        y: rect.height / MubiArt.canvas.height))
    }
}

/// The character + its speech capsule. One accessibility element carries the
/// reminder text; the mascot itself is decorative alongside it.
struct MubiView: View {
    let state: MubiState
    let message: String
    let bodySize: CGFloat          // logical body height (60/78/104)
    let motion: String             // "still" | "subtle" | "lively"
    let labelsAlways: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hop = false
    @State private var standStretch = false
    @State private var cupRaise = false
    @State private var nod = false
    @State private var blinking = false
    @State private var idleGazeOffset: CGFloat = 0

    private var dark: Bool { scheme == .dark }
    private var motionAllowed: Bool { motion != "still" && !systemReduceMotion }
    private var idleMotionActive: Bool { state == .idle && motionAllowed }
    // Restart the animation task on motion level or Reduce Motion changes.
    private var idleAnimationToken: String { idleMotionActive ? motion : "off" }
    private var scale: CGFloat { bodySize / MubiArt.bodyHeight }
    private var artSize: CGSize {
        CGSize(width: MubiArt.canvas.width * scale,
               height: MubiArt.canvas.height * scale)
    }

    var body: some View {
        VStack(spacing: 6) {
            character
            capsule
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.isEmpty ? "MoveBit" : message)
        .onAppear { cueAnimation() }
        .onChange(of: state) { _ in cueAnimation() }
        // SwiftUI cancels this task when the view disappears or the token
        // changes; no perpetual timer or renderer wakeups while hidden/focused.
        .task(id: idleAnimationToken) { await runIdleAnimation() }
    }

    /// Rare, bounded idle gestures rather than one blink on initial appear.
    /// Sleeps between gestures (no display-link or continuous rendering), and
    /// cancellation follows focus/quiet, Still, system Reduce Motion and
    /// NSHostingView removal. Never schedule a health cue from decoration.
    @MainActor
    private func runIdleAnimation() async {
        guard idleMotionActive else {
            blinking = false
            idleGazeOffset = 0
            return
        }
        while !Task.isCancelled {
            let delay: ClosedRange<UInt64> = motion == "lively"
                ? 7_000_000_000...12_000_000_000
                : 12_000_000_000...21_000_000_000
            do { try await Task.sleep(nanoseconds: UInt64.random(in: delay)) }
            catch { break }
            guard !Task.isCancelled, idleMotionActive else { break }

            if Bool.random() {
                // Short 150ms blink; don't flash or bounce in idle.
                withAnimation(.easeInOut(duration: 0.07)) { blinking = true }
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { break }
                withAnimation(.easeInOut(duration: 0.07)) { blinking = false }
            } else {
                // A single tiny sideways glance, then return to neutral.
                let glance: CGFloat = (Bool.random() ? 1.6 : -1.6) * scale
                withAnimation(.easeInOut(duration: 0.2)) { idleGazeOffset = glance }
                do { try await Task.sleep(nanoseconds: 850_000_000) }
                catch { break }
                withAnimation(.easeInOut(duration: 0.2)) { idleGazeOffset = 0 }
            }
        }
        blinking = false
        idleGazeOffset = 0
    }

    private func cueAnimation() {
        hop = false
        standStretch = false
        cupRaise = false
        nod = false
        guard motionAllowed, state != .idle, state != .focus else { return }
        let lively = motion == "lively"
        switch state {
        case .stand:
            withAnimation(.easeInOut(duration: lively ? 0.8 : 1.0)) {
                standStretch = true
            }
        case .water:
            withAnimation(.easeOut(duration: lively ? 0.6 : 0.75)) {
                cupRaise = true
            }
        case .ack:
            withAnimation(.easeInOut(duration: 0.4)) { nod = true }
        default:
            // One short arrival hop for the eyes state (two on lively).
            // Water/stand run their own named gestures; no attention loop.
            if state == .eyes {
                withAnimation(.easeInOut(duration: lively ? 0.24 : 0.28)
                    .repeatCount(lively ? 4 : 2, autoreverses: true)) {
                    hop = true
                }
            }
        }
    }

    private var character: some View {
        ZStack {
            // Fins (behind the body): left leans out, right leans inward.
            MubiShape(d: MubiArt.finLeft)
                .fill(MubiArt.fin)
            MubiShape(d: MubiArt.finRight)
                .fill(MubiArt.fin)
            MubiShape(d: MubiArt.finShade)
                .fill(MubiArt.shadow.opacity(0.35))
            // Body with volume gradient.
            MubiShape(d: MubiArt.body)
                .fill(LinearGradient(
                    stops: [
                        .init(color: MubiArt.bodyLight, location: 0),
                        .init(color: MubiArt.bodyBase, location: 0.45),
                        .init(color: MubiArt.bodyDeep.opacity(dark ? 0.9 : 1), location: 1),
                    ],
                    startPoint: UnitPoint(x: 0.18, y: 0.10),
                    endPoint: UnitPoint(x: 0.78, y: 1.0)))
            // Lower form shade.
            MubiShape(d: MubiArt.lowerShade)
                .fill(LinearGradient(
                    stops: [
                        .init(color: MubiArt.shadow.opacity(0), location: 0),
                        .init(color: MubiArt.shadow.opacity(dark ? 0.4 : 0.55), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom))
            // Upper-left rim light; dark mode reduces it (#56 §2).
            Ellipse()
                .fill(RadialGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(dark ? 0.22 : 0.45),
                        Color.white.opacity(0),
                    ]),
                    center: .center, startRadius: 0, endRadius: 30))
                .frame(width: 34 * scale, height: 48 * scale)
                .rotationEffect(.degrees(-18))
                .offset(x: -22 * scale, y: -24 * scale)

            face
            props
        }
        .frame(width: artSize.width, height: artSize.height)
        .offset(y: hop ? -4 : 0)
        .scaleEffect(x: 1, y: standStretch ? 1.06 : 1, anchor: .bottom)
        .offset(y: nod ? 1.5 : 0)
    }

    @ViewBuilder private var face: some View {
        switch state {
        case .eyes, .focus:
            MubiShape(d: MubiArt.eyeClosedLeft)
                .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            MubiShape(d: MubiArt.eyeClosedRight)
                .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        case .idle where blinking:
            MubiShape(d: MubiArt.eyeClosedLeft)
                .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            MubiShape(d: MubiArt.eyeClosedRight)
                .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        default:
            Ellipse().fill(MubiArt.ink)
                .frame(width: 6 * scale, height: 7.2 * scale)
                .offset(x: (MubiArt.eyeLeft.x - 60) * scale + idleGazeOffset,
                        y: (MubiArt.eyeLeft.y - 70) * scale)
            Ellipse().fill(MubiArt.ink)
                .frame(width: 6 * scale, height: 7.2 * scale)
                .offset(x: (MubiArt.eyeRight.x - 60) * scale + idleGazeOffset,
                        y: (MubiArt.eyeRight.y - 70) * scale)
            // Glints (upward glance in the water state).
            let gy = state == .water ? -6.8 : -6.2
            Circle().fill(Color.white.opacity(0.85))
                .frame(width: 2 * scale, height: 2 * scale)
                .offset(x: (MubiArt.eyeLeft.x - 60 + 1.1) * scale + idleGazeOffset, y: gy * scale)
            Circle().fill(Color.white.opacity(0.85))
                .frame(width: 2 * scale, height: 2 * scale)
                .offset(x: (MubiArt.eyeRight.x - 60 + 1.1) * scale + idleGazeOffset, y: gy * scale)
            if state == .ack {
                MubiShape(d: MubiArt.mouthAck)
                    .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            }
        }
    }

    @ViewBuilder private var props: some View {
        switch state {
        case .water:
            // cue.water cup raised at the right flank.
            Group {
                MubiShape(d: MubiArt.cupBody)
                    .fill(MubiArt.water)
                MubiShape(d: MubiArt.cupWater)
                    .fill(MubiArt.waterSoft.opacity(0.85))
            }
            .frame(width: artSize.width, height: artSize.height)
            .scaleEffect(0.9)
            // The cup path is authored around its own origin; the master
            // places it at canvas (97, 57) via translate — mirror that here.
            .offset(x: 97 * scale,
                    y: (57 + (cupRaise ? -12 : 0)) * scale)
        case .stand:
            MubiShape(d: MubiArt.stretchArcLeft)
                .stroke(MubiArt.move,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .opacity(standStretch ? 1 : 0.3)
            MubiShape(d: MubiArt.stretchArcRight)
                .stroke(MubiArt.move.opacity(0.65),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .opacity(standStretch ? 1 : 0.3)
        case .eyes:
            MubiShape(d: MubiArt.gazeCrescent)
                .stroke(MubiArt.eyes,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
        case .ack:
            MubiShape(d: MubiArt.ackGlint)
                .fill(MubiArt.done)
                .scaleEffect(nod ? 1.15 : 0.9)
                .opacity(nod ? 1 : 0.4)
        case .focus:
            // Quiet moon mark: a small tinted circle overlapped by a
            // body-colored disc (the even-odd crescent, drawn natively).
            Circle()
                .fill(MubiArt.focusTint.opacity(dark ? 0.55 : 0.75))
                .frame(width: 16 * scale, height: 16 * scale)
                .offset(x: 30 * scale, y: -26 * scale)
                .overlay(
                    Circle()
                        .fill(dark ? MubiArt.bodyDeep.opacity(0.9) : MubiArt.bodyBase)
                        .frame(width: 12 * scale, height: 12 * scale)
                        .offset(x: 5 * scale, y: -4 * scale))
        case .idle:
            EmptyView()
        }
    }

    /// The actionable text capsule: opaque-enough surface, subtle stroke,
    /// native typography — text scales with accessibility, not the character.
    private var capsuleIcon: String {
        switch state {
        case .water: return "drop.fill"
        case .stand: return "figure.stand"
        case .eyes: return "eye"
        case .ack: return "checkmark"
        case .focus: return "moon.zzz"
        case .idle: return ""
        }
    }

    @ViewBuilder private var capsule: some View {
        if labelsAlways || !message.isEmpty {
            HStack(spacing: 7) {
                if !capsuleIcon.isEmpty {
                    Image(systemName: capsuleIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(dark ? MubiArt.labelTextDark : MubiArt.labelTextLight)
                }
                Text(message.isEmpty ? "MoveBit" : message)
                    .font(.system(size: message.isEmpty ? 12 : 14, weight: .semibold))
                    .lineLimit(message.isEmpty ? 1 : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 240, alignment: .leading)
                    .foregroundColor(dark ? MubiArt.labelTextDark : MubiArt.labelTextLight)
            }
            .padding(.horizontal, message.isEmpty ? 12 : 16)
            .padding(.vertical, message.isEmpty ? 6 : 10)
            .frame(minWidth: message.isEmpty ? nil : 200,
                   maxWidth: message.isEmpty ? nil : 280)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(dark ? MubiArt.labelSurfaceDark
                               : MubiArt.labelSurfaceLight))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder((dark ? Color.white : Color.black).opacity(0.08),
                                  lineWidth: 1))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - controller

@MainActor
final class CompanionController: NSObject {
    private var panel: NSPanel?
    private var generation = 0
    private var idleTask: Task<Void, Never>?
    // One short approach per real due cue. Never a continuous roaming timer.
    // Cancelling this task on Focus/Hide/Done/Snooze must stop every pending
    // movement step and return the character to its original dock.
    private var visitTask: Task<Void, Never>?

    // Presentation inputs from the v1 config; applied on bootstrap/change.
    private var bodySize: CGFloat = 78
    private var motion = "subtle"
    private var dock = "bottom-right"
    private var labelsAlways = false
    private var quiet = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func applyConfig(size: String, motion: String, dock: String, labels: String) {
        cancelVisit()
        bodySize = Self.bodyHeight(for: size)
        self.motion = motion
        self.dock = dock
        labelsAlways = labels == "always"
        if let panel, panel.isVisible {
            present(quiet ? .focus : .idle, message: "")
        }
    }

    static func bodyHeight(for size: String) -> CGFloat {
        switch size {
        case "S": return 60
        case "L": return 104
        default: return 78
        }
    }

    /// A genuine due cue makes one friendly, non-activating visit toward the
    /// visible work area's center. The label is readable for ~9 seconds once
    /// there; it never silently records completion. Focus/Hide/ack/snooze
    /// cancel the visit synchronously and return Mubi to its home dock.
    func show(state: MubiState, message: String) {
        cancelVisit()
        guard !quiet else { return }
        present(state, message: message)
        let current = generation
        // "Later" also uses show(state: .idle, message: ...); it must NOT
        // trigger a second attention-grabbing center-screen visit.
        let dueInvitation = state == .water || state == .stand || state == .eyes
        visitTask = Task { [weak self] in
            guard let self else { return }
            await self.runVisit(generation: current, dueInvitation: dueInvitation)
        }
    }

    func showIdle() {
        cancelVisit()
        present(quiet ? .focus : .idle, message: "")
    }

    /// Brief acknowledgment flourish after a tray Done (self-reported).
    func showAck() {
        guard !quiet else { return }
        cancelVisit()
        present(.ack, message: "")
        let current = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, self.generation == current else { return }
            self.present(.idle, message: "")
        }
    }

    func setQuiet(_ enabled: Bool) {
        cancelVisit()
        quiet = enabled
        present(quiet ? .focus : .idle, message: "")
    }

    func hide() {
        cancelVisit()
        generation += 1
        panel?.orderOut(nil)
    }

    private func cancelVisit() {
        visitTask?.cancel()
        visitTask = nil
    }

    /// Frame-bounded animation instead of a persistent 30/60 FPS timer.
    /// The panel remains fully pointer-through and non-activating throughout.
    /// Window movement is a health-cue-only behavior, not autonomous roaming.
    private func runVisit(generation current: Int,
                          dueInvitation: Bool) async {
        guard let panel else { return }
        let home = panel.frame.origin
        let size = panel.frame.size
        let canTravel = dueInvitation && motion != "still"
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        // Respect the current monitor's usable area (Dock/menu bar included).
        // Fallback: show a static readable cue at the original dock.
        if canTravel, let screen {
            let safe = screen.visibleFrame
            let clearance: CGFloat = 16
            let maxX = max(safe.minX + clearance,
                           safe.maxX - size.width - clearance)
            let maxY = max(safe.minY + clearance,
                           safe.maxY - size.height - clearance)
            let target = NSPoint(
                x: min(max(safe.midX - size.width / 2, safe.minX + clearance), maxX),
                y: min(max(safe.midY - size.height / 2, safe.minY + clearance), maxY))
            guard await travel(panel: panel, from: home, to: target,
                               steps: 18, current: current) else { return }
        }

        // Visible for a bounded interval, regardless of animation setting.
        // The Racket cue ledger survives this visual timer untouched.
        do {
            try await Task.sleep(nanoseconds: dueInvitation
                                 ? 9_000_000_000 : 4_000_000_000)
        } catch { return }
        guard !Task.isCancelled, generation == current, !quiet else { return }

        if canTravel {
            guard await travel(panel: panel, from: panel.frame.origin,
                               to: home, steps: 12, current: current) else { return }
        }
        guard !Task.isCancelled, generation == current, !quiet else { return }
        present(.idle, message: "")
    }

    /// ~720ms approach and ~480ms return. Cancellation is checked for each
    /// frame and every sleep; Focus/Hide never waits for a long animation.
    private func travel(panel: NSPanel, from: NSPoint, to: NSPoint,
                        steps: Int, current: Int) async -> Bool {
        for step in 1...steps {
            guard !Task.isCancelled, generation == current, !quiet else {
                return false
            }
            let t = CGFloat(step) / CGFloat(steps)
            let eased = t * t * (3 - 2 * t)
            panel.setFrameOrigin(NSPoint(
                x: from.x + (to.x - from.x) * eased,
                y: from.y + (to.y - from.y) * eased))
            do { try await Task.sleep(nanoseconds: 40_000_000) }
            catch { return false }
        }
        return !Task.isCancelled && generation == current && !quiet
    }

    private func present(_ state: MubiState, message: String) {
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: MubiView(state: state, message: message,
                               bodySize: bodySize, motion: motion,
                               labelsAlways: labelsAlways))
        relayout()
        // NSPanel never becomes key or main; the whole window ignores mouse
        // events (#54 pointer-through fallback).
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Deliberately transient: presentation safety outranks being
        // omnipresent — Mubi does not follow into full-screen Spaces.
        panel.collectionBehavior = [.transient]
        panel.isMovableByWindowBackground = false
        return panel
    }

    private func relayout() {
        guard let panel, let contentView = panel.contentView,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setContentSize(contentView.fittingSize)
        let size = panel.frame.size
        let safe = screen.visibleFrame
        let clearance: CGFloat = 16
        let x: CGFloat
        let y: CGFloat
        switch dock {
        case "bottom-left":
            x = safe.minX + clearance
            y = safe.minY + clearance
        case "top-right":
            x = safe.maxX - size.width - clearance
            y = safe.maxY - size.height - clearance
        default: // bottom-right
            x = safe.maxX - size.width - clearance
            y = safe.minY + clearance
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        guard let panel, panel.isVisible else { return }
        // A hotplug/work-area change invalidates the visit's old coordinates.
        // Re-dock immediately; the next due cue recalculates the new bounds.
        cancelVisit()
        present(quiet ? .focus : .idle, message: "")
    }
}
