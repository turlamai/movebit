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
    let bodySize: CGFloat          // logical body height (the shipped 78)
    let motion: String             // "still" | "subtle" | "lively"
    /// Petting = Done: tapping the character acknowledges the open cue.
    var onPet: (() -> Void)? = nil
    /// The bubble's Later tag = snooze.
    var onLater: (() -> Void)? = nil
    /// A teary begging act played — the host may add a rate-limited chime.
    var onTearyAct: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hop = false
    @State private var standStretch = false
    @State private var cupRaise = false
    @State private var nod = false
    @State private var blinking = false
    @State private var idleGazeOffset: CGFloat = 0
    // Begging-repertoire states (issue #140): roll, glass-press, teary eyes.
    @State private var tilt: CGFloat = 0
    @State private var squishing = false
    @State private var teary = false

    private var dark: Bool { scheme == .dark }
    private var motionAllowed: Bool { motion != "still" && !systemReduceMotion }
    private var idleMotionActive: Bool { state == .idle && motionAllowed }
    /// A live invitation waits on screen: the begging repertoire runs and the
    /// Later tag shows. Petting (tap on the character) = Done.
    private var attending: Bool {
        state == .water || state == .stand || state == .eyes
    }
    // Restart the animation tasks on motion level / state / Reduce Motion changes.
    private var idleAnimationToken: String { idleMotionActive ? motion : "off" }
    private var performanceToken: String {
        (attending && motionAllowed) ? "cue-\(state)" : "off"
    }
    private var scale: CGFloat { bodySize / MubiArt.bodyHeight }
    private var artSize: CGSize {
        CGSize(width: MubiArt.canvas.width * scale,
               height: MubiArt.canvas.height * scale)
    }

    var body: some View {
        VStack(spacing: 6) {
            character
                .contentShape(Rectangle())
                .onTapGesture { onPet?() }
            capsule
            if attending {
                laterPill
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.isEmpty ? "MoveBit" : message)
        .accessibilityHint(attending ? L10n.t("tray.cueDone") : "")
        .onAppear { cueAnimation() }
        .onChange(of: state) { _ in cueAnimation() }
        // SwiftUI cancels these tasks when the view disappears or the token
        // changes; no perpetual timer or renderer wakeups while hidden/focused.
        .task(id: idleAnimationToken) { await runIdleAnimation() }
        .task(id: performanceToken) { await runCuePerformance() }
    }

    /// The bubble's Later tag: one click defers every merged kind. The only
    /// non-pet answer path on the surface itself — everything else stays in
    /// the tray menu.
    private var laterPill: some View {
        Button(action: { onLater?() }) {
            Text(L10n.t("tray.cueLater"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(dark ? MubiArt.labelTextDark : MubiArt.labelTextLight)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(
                    (dark ? MubiArt.labelSurfaceDark : MubiArt.labelSurfaceLight)
                        .opacity(0.92)))
                .overlay(Capsule().strokeBorder(
                    (dark ? Color.white : Color.black).opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(L10n.t("tray.cueLater"))
    }

    /// Idle self-play (issue #140): while nothing is due, Mubi plays by
    /// itself near its dock — blinks, glances, tilts, little rolls and hops
    /// — like a pet patiently hanging around. Rare, bounded acts with real
    /// sleeps between (no display-link or continuous rendering); cancellation
    /// follows focus/quiet, Still, system Reduce Motion and NSHostingView
    /// removal. Never schedules a health cue from decoration.
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

            switch Int.random(in: 0..<5) {
            case 0: await blinkAct()
            case 1: await glanceAct()
            case 2: await tiltAct()
            case 3: await rollAct()
            default: await hopAct()
            }
        }
        blinking = false
        idleGazeOffset = 0
        tilt = 0
    }

    /// While an invitation waits on screen, rotate a small begging
    /// repertoire every ~20-28 s — a playful roll, pressing against the
    /// glass, or teary sniffles (the host may chime, rate-limited). The
    /// kind gesture still plays on arrival via cueAnimation().
    @MainActor
    private func runCuePerformance() async {
        guard attending, motionAllowed else { return }
        do {
            try await Task.sleep(
                nanoseconds: UInt64.random(in: 11...15) * 1_000_000_000)
        } catch { return }
        while !Task.isCancelled, attending {
            switch Int.random(in: 0..<3) {
            case 0:
                await rollAct()
            case 1:
                // Press against the glass.
                withAnimation(.easeInOut(duration: 0.3)) { squishing = true }
                do { try await Task.sleep(nanoseconds: 900_000_000) }
                catch { squishing = false; return }
                withAnimation(.easeInOut(duration: 0.3)) { squishing = false }
            default:
                withAnimation(.easeInOut(duration: 0.25)) { teary = true }
                onTearyAct?()
                do { try await Task.sleep(nanoseconds: 2_400_000_000) }
                catch { teary = false; return }
                withAnimation(.easeInOut(duration: 0.3)) { teary = false }
            }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64.random(in: 13...19) * 1_000_000_000)
            } catch { break }
        }
        tilt = 0
        squishing = false
        teary = false
    }

    // MARK: shared acts

    private func blinkAct() async {
        withAnimation(.easeInOut(duration: 0.07)) { blinking = true }
        do { try await Task.sleep(nanoseconds: 150_000_000) }
        catch { return }
        withAnimation(.easeInOut(duration: 0.07)) { blinking = false }
    }

    private func glanceAct() async {
        let glance: CGFloat = (Bool.random() ? 1.6 : -1.6) * scale
        withAnimation(.easeInOut(duration: 0.2)) { idleGazeOffset = glance }
        do { try await Task.sleep(nanoseconds: 850_000_000) }
        catch { return }
        withAnimation(.easeInOut(duration: 0.2)) { idleGazeOffset = 0 }
    }

    /// A curious head tilt.
    private func tiltAct() async {
        let side: CGFloat = Bool.random() ? 1 : -1
        withAnimation(.easeInOut(duration: 0.28)) { tilt = 9 * side }
        do { try await Task.sleep(nanoseconds: 420_000_000) }
        catch { tilt = 0; return }
        withAnimation(.easeInOut(duration: 0.24)) { tilt = 0 }
    }

    /// A playful roll: tilt onto one side with a little hop, then upright.
    private func rollAct() async {
        let side: CGFloat = Bool.random() ? 1 : -1
        withAnimation(.easeInOut(duration: 0.22)) {
            tilt = 16 * side
            hop = true
        }
        do { try await Task.sleep(nanoseconds: 280_000_000) }
        catch { tilt = 0; hop = false; return }
        withAnimation(.easeInOut(duration: 0.26)) {
            tilt = 0
            hop = false
        }
    }

    private func hopAct() async {
        withAnimation(.easeInOut(duration: 0.24).repeatCount(2, autoreverses: true)) {
            hop = true
        }
        do { try await Task.sleep(nanoseconds: 520_000_000) }
        catch { return }
        hop = false
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
        .scaleEffect(x: squishing ? 1.08 : 1, y: squishing ? 0.88 : 1, anchor: .bottom)
        .rotationEffect(.degrees(tilt), anchor: .bottom)
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
            if teary {
                // Begging droplets welling under each eye.
                Ellipse().fill(MubiArt.eyes.opacity(0.85))
                    .frame(width: 2.4 * scale, height: 3.6 * scale)
                    .offset(x: (MubiArt.eyeLeft.x - 60) * scale + idleGazeOffset,
                            y: (MubiArt.eyeLeft.y - 70 + 7.5) * scale)
                Ellipse().fill(MubiArt.eyes.opacity(0.85))
                    .frame(width: 2.4 * scale, height: 3.6 * scale)
                    .offset(x: (MubiArt.eyeRight.x - 60) * scale + idleGazeOffset,
                            y: (MubiArt.eyeRight.y - 70 + 7.5) * scale)
            }
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
        if !message.isEmpty {
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

/// Hosting view that can opt into AppKit's background-drag behaviour only
/// while the explicit placement mode is active. Outside it the panel stays
/// fully pointer-through (issue #54).
private final class CompanionHostingView: NSHostingView<AnyView> {
    var allowsWindowDrag = false
    override var mouseDownCanMoveWindow: Bool { allowsWindowDrag }
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

    // Presentation is one shipped design now (issue #140): the M-size
    // character with subtle motion. The only config input left is the
    // drag-placed home position.
    private let bodySize: CGFloat = 78
    private let motion = "subtle"
    private var quiet = false
    // Issue #104 + owner decision 2026-11-10: a directly placed home
    // position (per-mille of the usable work area; -1 = the default
    // bottom-right corner), written whenever the user drags Mubi — no
    // placement mode, the pointer-through panel flips pettable/draggable
    // under the cursor at any time.
    private var freeX: Int64 = -1
    private var freeY: Int64 = -1
    private var placementSaveTask: Task<Void, Never>?
    /// Polls the pointer to flip the panel between click-through and
    /// pettable/draggable whenever the cursor rests on it — free drag, any
    /// time; petting while a cue waits.
    private var proximityTask: Task<Void, Never>?
    /// Persist the normalized position after a user drag (debounced).
    var onPlacementChanged: ((Int64, Int64) -> Void)?
    /// Petting = Done (self-reported acknowledgement of the open cue).
    var onPet: (() -> Void)?
    /// The bubble's Later tag = snooze the open cue.
    var onLater: (() -> Void)?
    /// The teary begging act played; the host may chime (rate-limited).
    var onTearyAct: (() -> Void)?

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

    func applyConfig(freeX: Int64, freeY: Int64) {
        cancelVisit()
        self.freeX = freeX
        self.freeY = freeY
        if let panel, panel.isVisible {
            present(quiet ? .focus : .idle, message: "")
        }
    }

    /// One click from the menu bar clears the drag-placed home and parks
    /// Mubi at the default corner. Dragging is the everyday way to move;
    /// this recovery action exists so a misplaced pet is never stuck.
    /// Moving never edits cue completion/snooze.
    func resetHome() {
        // An explicit Reset during a cue's travel wins: cancel the
        // in-flight visit so it cannot carry Mubi back to the old home.
        cancelVisit()
        freeX = -1
        freeY = -1
        onPlacementChanged?(freeX, freeY)
        // Moving the pet must not dismiss a health invitation or turn
        // it into an idle pose. Keep the active artwork and cue readable.
        if panel?.isVisible == true { relayout() }
    }

    /// A genuine due cue makes one friendly, non-activating visit to the
    /// visible work area's center and STAYS there until answered (issue
    /// #140): the invitation persists, so there is no return timer. The
    /// pointer near the character flips the panel pettable; tap = Done, the
    /// bubble's Later tag = snooze, tray actions work as always. Nothing
    /// time-based or click-outside-based ends the visit — showIdle/showAck
    /// (driven by the settled ledger) bring Mubi home.
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
        returnHomeThen { self.present(self.quiet ? .focus : .idle, message: "") }
    }

    /// Travel back to the home dock (or jump, when motion is off), then run
    /// the finisher at the dock.
    private func returnHomeThen(_ finish: @escaping () -> Void) {
        guard let panel else { finish(); return }
        let home = homeOrigin()
        let from = panel.frame.origin
        guard from != home else { finish(); return }
        let canTravel = motion != "still"
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard canTravel else {
            panel.setFrameOrigin(home)
            finish()
            return
        }
        let current = generation
        visitTask = Task { [weak self] in
            guard let self else { return }
            if await self.travel(panel: panel, from: from, to: home,
                                 steps: 12, current: current) {
                finish()
            }
        }
    }

    /// Acknowledgment flourish after a pet or tray Done (self-reported):
    /// the happy glint plays where Mubi stands, then it heads home.
    func showAck() {
        guard !quiet else { return }
        cancelVisit()
        present(.ack, message: "")
        let current = generation
        visitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, self.generation == current else { return }
            await self.returnHomeThen {
                self.present(self.quiet ? .focus : .idle, message: "")
            }
        }
    }

    func setQuiet(_ enabled: Bool) {
        cancelVisit()
        quiet = enabled
        returnHomeThen { self.present(self.quiet ? .focus : .idle, message: "") }
    }

    func hide() {
        cancelVisit()
        generation += 1
        panel?.orderOut(nil)
    }

    private func cancelVisit() {
        visitTask?.cancel()
        visitTask = nil
        stopProximityMonitor()
    }

    // MARK: pettable + draggable window

    /// Flip the panel between full pointer-through and pettable/draggable
    /// based on pointer proximity — the surface stays pointer-through
    /// everywhere except while the cursor rests on Mubi itself (issue #54).
    /// Free drag, any time; petting while a cue waits.
    private func startProximityMonitor(_ current: Int) {
        proximityTask?.cancel()
        proximityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let panel = self.panel,
                      self.generation == current else { return }
                let hittable = NSPointInRect(NSEvent.mouseLocation, panel.frame)
                panel.ignoresMouseEvents = !hittable
                panel.isMovableByWindowBackground = hittable
                (panel.contentView as? CompanionHostingView)?.allowsWindowDrag
                    = hittable
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
        }
    }

    private func stopProximityMonitor() {
        proximityTask?.cancel()
        proximityTask = nil
        if let panel {
            panel.ignoresMouseEvents = true
            panel.isMovableByWindowBackground = false
            (panel.contentView as? CompanionHostingView)?.allowsWindowDrag = false
        }
    }

    /// Frame-bounded animation instead of a persistent 30/60 FPS timer.
    /// The panel remains non-activating throughout; while an invitation is
    /// up, the pointer-proximity monitor flips it pettable over Mubi itself.
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

        // Persistent invitation (issue #140): no return timer. Wait here
        // until the ledger settles (showIdle/showAck) and bring Mubi home.
        // Petting/dragging is armed by the proximity monitor in present().
        guard !Task.isCancelled, generation == current, !quiet else { return }
    }

    /// The home-dock frame origin for the current placement (per-mille free
    /// position, else the default bottom-right corner).
    private func homeOrigin() -> NSPoint {
        guard let contentView = panel?.contentView,
              let screen = panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        else {
            return panel?.frame.origin ?? NSPoint.zero
        }
        let size = contentView.fittingSize
        let safe = screen.visibleFrame
        let clearance: CGFloat = 16
        if freeX >= 0 && freeY >= 0 {
            let travelW = max(0, safe.width - size.width - 2 * clearance)
            let travelH = max(0, safe.height - size.height - 2 * clearance)
            return NSPoint(
                x: safe.minX + clearance + travelW * CGFloat(freeX) / 1000,
                y: safe.maxY - size.height - clearance
                    - travelH * CGFloat(freeY) / 1000)
        }
        return NSPoint(x: safe.maxX - size.width - clearance,
                       y: safe.minY + clearance)
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
        let character = MubiView(state: state, message: message,
                                 bodySize: bodySize, motion: motion,
                                 onPet: { [weak self] in self?.onPet?() },
                                 onLater: { [weak self] in self?.onLater?() },
                                 onTearyAct: { [weak self] in self?.onTearyAct?() })
        let host = CompanionHostingView(rootView: AnyView(character))
        host.allowsWindowDrag = false
        panel.contentView = host
        relayout()
        // NSPanel never becomes key or main; outside the pointer-proximity
        // flip the whole window ignores mouse events (#54 fallback).
        panel.orderFrontRegardless()
        startProximityMonitor(generation)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above every app window, including fullscreen Spaces: a reminder
        // that can be covered is not a reminder (issue #140).
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.delegate = self
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
        if freeX >= 0 && freeY >= 0 {
            // Normalized placement keeps the character fully on-screen after
            // display/DPI changes: the travel range excludes its own size.
            let travelW = max(0, safe.width - size.width - 2 * clearance)
            let travelH = max(0, safe.height - size.height - 2 * clearance)
            // Stored coordinates are fractions from the TOP-LEFT of the
            // usable work area so a synced profile means the same place on
            // Windows/Linux; AppKit's origin is bottom-left.
            x = safe.minX + clearance
                + travelW * CGFloat(freeX) / 1000
            y = safe.maxY - size.height - clearance
                - travelH * CGFloat(freeY) / 1000
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }
        // Default corner: bottom-right.
        x = safe.maxX - size.width - clearance
        y = safe.minY + clearance
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Convert the dragged origin back into per-mille of the usable travel
    /// range. Clamping is inherent: the drag cannot leave the screen.
    private func savePlacement() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let safe = screen.visibleFrame
        let size = panel.frame.size
        let clearance: CGFloat = 16
        let travelW = max(1, safe.width - size.width - 2 * clearance)
        let travelH = max(1, safe.height - size.height - 2 * clearance)
        let fractionX = (panel.frame.minX - safe.minX - clearance) / travelW
        let fractionY = (safe.maxY - size.height - clearance
                         - panel.frame.minY) / travelH
        let nx = Int64((min(1, max(0, fractionX)) * 1000).rounded())
        let ny = Int64((min(1, max(0, fractionY)) * 1000).rounded())
        guard nx != freeX || ny != freeY else { return }
        freeX = nx
        freeY = ny
        onPlacementChanged?(nx, ny)
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        guard let panel, panel.isVisible else { return }
        // A hotplug/work-area change invalidates the visit's old coordinates.
        // Re-dock immediately; the next due cue recalculates the new bounds.
        cancelVisit()
        present(quiet ? .focus : .idle, message: "")
    }
}


extension CompanionController: NSWindowDelegate {
    /// Debounced persistence while the user drags Mubi by its background.
    /// Programmatic moves (the cue walk, relayout, reset) happen with no
    /// mouse buttons held — they must never be saved as a new home.
    func windowDidMove(_ notification: Notification) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        placementSaveTask?.cancel()
        placementSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.savePlacement()
        }
    }
}
