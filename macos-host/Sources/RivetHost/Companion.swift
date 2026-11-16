import SwiftUI
import AppKit

// Mubi（沐比）— the MoveBit companion, rendered from the canonical design
// system (issue #56; assets/mubi/tokens.json) and the 2026-11-15 desktop
// contract (design/DESIGN.md): one pet at its workspace-edge position, one
// invitation attached to it, a menu button and the pettable surface. The
// character DELIVERS the backend's health cues (charter #51); it is not a
// pet product.
//
// Interaction contract (2026-11-15 design/DESIGN.md): every pet interaction
// is companionship ONLY — petting never completes a reminder. Completion
// submits through the invitation's buttons (做到了 / 只做了一部分 per-kind),
// the tray response items, or the micro-break window's 做好了. Dragging uses
// an 8 px two-dimensional threshold with pet+invitation moving as one and
// the position clamped to the workspace. Captions appear only around recent
// interaction (~2.2 s), then the character returns to quiet waiting.
//
// Safety contract (issue #54): the panel is non-activating and pointer-
// through except while the cursor rests on it. The panel never crosses the
// document center; the drag-placed home position is clamped on display
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
    static let mouthSmall = "M 57.5 77 C 59 78.4, 61 78.4, 62.5 77"
    static let mouthSmile = "M 55 76 C 58 82, 62 82, 65 76"
    static let gazeCrescent = "M 92 38 C 96.5 40.5, 99 45, 98 50"
    static let ackGlint = "M 84 56 L 86 60.5 L 90.5 62 L 86 63.5 L 84 68 L 82 63.5 L 77.5 62 L 82 60.5 Z"
    // Water cup + holding hand: absolute canvas paths from the prototype
    // petArt (design/prototype/shared.js) — bottom-right of the body.
    static let cupBody = "M 76 89 h 20 l -2 22 H 78 Z"
    static let cupWater = "M 80 100 h 13 l -1 9 H 81 Z"
    static let cupHandle = "M 96 93 h 4 q 6 7 -5 10"
    static let cupHand = "M 77 99 q -9 -4 -12 2"
    // Rest props (prototype petArt): leaf at the head, move arrows at the
    // flanks, headphones over the face, gold completion sparkles.
    static let leafProp = "M 82 27 C 92 12, 104 18, 104 18 C 101 32, 85 40, 85 40 M 85 30 L 97 22"
    static let moveArrowLeft = "M 16 72 L 10 66 L 16 60"
    static let moveArrowRight = "M 105 60 L 111 66 L 105 72"
    static let headphonesBand = "M 31 64 L 31 57 C 59 31, 89 31, 89 57 L 89 64"
    static let headphonePadLeft = "M 28 56 h 8 v 17 a 4 4 0 0 1 -4 4 h 0 a 4 4 0 0 1 -4 -4 Z"
    static let headphonePadRight = "M 84 56 h 8 v 17 a 4 4 0 0 1 -4 4 h 0 a 4 4 0 0 1 -4 -4 Z"

    static let eyeLeft = CGPoint(x: 46.5, y: 65)
    static let eyeRight = CGPoint(x: 73.5, y: 65)

    // Color tokens (assets/mubi/tokens.json) + the prototype's cue palette
    // (design/prototype/shared.css `--pet-*`).
    static let bodyLight = Color(hex: "#FBF5E9")
    static let bodyBase = Color(hex: "#F6EEDF")
    static let bodyDeep = Color(hex: "#E8D7BE")
    static let shadow = Color(hex: "#D8C8B5")
    static let ink = Color(hex: "#2D2A28")
    static let fin = Color(hex: "#F1E4CC")
    static let blush = Color(hex: "#E79E88")
    static let water = Color(hex: "#62B6FF")
    static let waterSoft = Color(hex: "#8FCBFF")
    static let move = Color(hex: "#FF8C6B")
    static let eyes = Color(hex: "#65C8B8")
    static let leaf = Color(hex: "#42866B")
    static let done = Color(hex: "#F2C96B")
    static let focusTint = Color(hex: "#8DA1B5")
    static let labelSurfaceLight = Color(hex: "#FFFDFB")
    static let labelTextLight = Color(hex: "#2D2A28")
    static let labelSurfaceDark = Color(hex: "#33302B")
    static let labelTextDark = Color(hex: "#F1EEE7")
    static let captionInkLight = Color(hex: "#6D5948")
    static let captionBgLight = Color(hex: "#F6F1E9")
    static let captionInkDark = Color(hex: "#E8D4BB")
    static let captionBgDark = Color(hex: "#3A3028")
}

/// The presentation expressions (2026-11-15 contract table). `held` and
/// `landed` belong to direct manipulation; `happy` / `wink` / `peek` are the
/// patting responses; everything else maps a health or resting state.
enum MubiExpression: Equatable {
    case waiting
    case hello
    case water
    case move
    case eyes
    case done
    case later
    case focus
    case sleep
    case happy
    case wink
    case peek
    case held
    case landed

    var captionKey: String {
        switch self {
        case .waiting: return "pet.caption.waiting"
        case .hello: return "pet.caption.hello"
        case .water: return "pet.caption.water"
        case .move: return "pet.caption.move"
        case .eyes: return "pet.caption.eyes"
        case .done: return "pet.caption.done"
        case .later: return "pet.caption.later"
        case .focus: return "pet.caption.focus"
        case .sleep: return "pet.caption.sleep"
        case .happy: return "pet.caption.happy"
        case .wink: return "pet.caption.wink"
        case .peek: return "pet.caption.peek"
        case .held: return "pet.caption.held"
        case .landed: return "pet.caption.landed"
        }
    }

    var isSmiling: Bool {
        switch self {
        case .done, .happy, .hello, .move, .landed: return true
        default: return false
        }
    }

    var isResting: Bool {
        switch self {
        case .focus, .sleep, .eyes, .later: return true
        default: return false
        }
    }
}

/// The invitation attached to the pet: one merged cue, one heading, one
/// response surface. Kinds are the backend kind symbols ("sit"/"water"/
/// "micro") — the heading and the per-kind checkboxes derive from them.
struct CompanionInvitation: Equatable {
    var kinds: [String]
}

extension ReminderKind {
    /// Semantic kind -> invitation word key (invite.title.* / kind.*).
    var invitationWord: String {
        switch self {
        case .sit: return "move"
        case .water: return "water"
        case .micro: return "eyes"
        }
    }
}

/// Compose the invitation heading: 起来走走，喝口水？-style, one phrase per
/// present kind (invite.title.* covers every combination).
func invitationTitle(for kinds: [String]) -> String {
    let words = ["move", "water", "eyes"].filter { kinds.contains($0) }
    switch words.joined(separator: "-") {
    case "move": return L10n.t("invite.title.move")
    case "water": return L10n.t("invite.title.water")
    case "eyes": return L10n.t("invite.title.eyes")
    case "move-water": return L10n.t("invite.title.moveWater")
    case "move-eyes": return L10n.t("invite.title.moveEyes")
    case "water-eyes": return L10n.t("invite.title.waterEyes")
    default: return L10n.t("invite.title.all")
    }
}

/// The invitation kind word for the per-kind checkboxes (起身 / 喝水 / 护眼).
func kindWord(_ kind: String) -> String {
    switch kind {
    case "water": return L10n.t("kind.water")
    case "micro": return L10n.t("kind.micro")
    default: return L10n.t("kind.sit")
    }
}

// MARK: - presentation model

/// Everything the SwiftUI surface renders; the controller mutates it in
/// place so the panel content never rebuilds mid-drag.
@MainActor
final class CompanionPresentation: ObservableObject {
    @Published var expression: MubiExpression = .waiting
    /// The caption bubble shows only around recent interaction (~2.2 s) or
    /// for an explicit hello (onboarding hand-off), then quiet waiting.
    @Published var chat = false
    @Published var invitation: CompanionInvitation?
    /// The invitation's per-kind checklist opens from the invitation itself
    /// or remotely via the tray's 逐项确认.
    @Published var partialExpanded = false
    @Published var dragTilt: CGFloat = 0
    /// Body height in logical units (the shipped M size, 78).
    let bodySize: CGFloat = 78
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

/// The character, its occasional caption and its props — one accessibility
/// element labelled by the a11y pat contract.
struct MubiCharacterView: View {
    @ObservedObject var presentation: CompanionPresentation
    var onPat: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hop = false
    @State private var blinking = false
    @State private var landedSquish = false
    @State private var nod = false

    private var dark: Bool { scheme == .dark }
    private var scale: CGFloat { presentation.bodySize / MubiArt.bodyHeight }
    private var artSize: CGSize {
        CGSize(width: MubiArt.canvas.width * scale,
               height: MubiArt.canvas.height * scale)
    }
    private var expression: MubiExpression { presentation.expression }

    var body: some View {
        VStack(spacing: 4) {
            if presentation.chat {
                caption
            }
            petButton
        }
        .onChange(of: expression) { newValue in playExpressionAnimation(newValue) }
        .onAppear { playExpressionAnimation(expression) }
    }

    /// The pet surface: Tab-focusable, Enter/Space = pat, arrows move the
    /// pet (the controller clamps and persists). Clicking never completes.
    private var petButton: some View {
        Button {
            onPat?()
        } label: {
            character
        }
        .buttonStyle(.plain)
        .focusable()
        .onMoveCommand { direction in
            let mapped: MoveCommandDirection
            switch direction {
            case .left: mapped = .left
            case .right: mapped = .right
            case .up: mapped = .up
            case .down: mapped = .down
            @unknown default: return
            }
            NotificationCenter.default.post(
                name: .companionMoveCommand, object: mapped)
        }
        .accessibilityLabel(L10n.t("pet.patA11y"))
        .help(L10n.t("pet.patA11y"))
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
            // Body with volume gradient. Dark never inverts the character
            // (2026-11-15 contract); only the rim light softens (#56 §2).
            MubiShape(d: MubiArt.body)
                .fill(LinearGradient(
                    stops: [
                        .init(color: MubiArt.bodyLight, location: 0),
                        .init(color: MubiArt.bodyBase, location: 0.45),
                        .init(color: MubiArt.bodyDeep, location: 1),
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
        .scaleEffect(x: landedSquish ? 1.06 : 1,
                     y: landedSquish ? 0.94 : 1, anchor: .bottom)
        .offset(y: nod ? 1.5 : 0)
        .rotationEffect(.degrees(presentation.dragTilt), anchor: .bottom)
    }

    @ViewBuilder private var face: some View {
        // Face group shifts a touch for the peek response.
        Group {
            switch expression {
            case .eyes, .focus, .sleep, .later:
                restingEyes
            case .happy, .done, .hello, .move, .landed, .water:
                smilingEyes
            case .wink:
                MubiShape(d: MubiArt.eyeClosedLeft)
                    .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                openEye(at: MubiArt.eyeRight)
            case .held:
                // Wide round eyes while carried.
                openEye(at: MubiArt.eyeLeft, rx: 4, ry: 5)
                openEye(at: MubiArt.eyeRight, rx: 4, ry: 5)
                Ellipse().fill(MubiArt.ink)
                    .frame(width: 3 * scale, height: 4 * scale)
                    .offset(x: 1 * scale, y: (78 - 70) * scale)
            case .peek:
                openEye(at: MubiArt.eyeLeft)
                openEye(at: MubiArt.eyeRight)
            default:
                openEye(at: MubiArt.eyeLeft)
                openEye(at: MubiArt.eyeRight)
                // Small resting mouth.
                MubiShape(d: MubiArt.mouthSmall)
                    .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            blushMarks
            if expression.isSmiling {
                MubiShape(d: MubiArt.mouthSmile)
                    .stroke(MubiArt.ink,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .offset(x: expression == .peek ? 3 * scale : 0,
                y: expression == .peek ? -1 * scale : 0)
    }

    private func openEye(at center: CGPoint, rx: CGFloat = 3, ry: CGFloat = 4) -> some View {
        Ellipse().fill(MubiArt.ink)
            .frame(width: rx * 2 * scale, height: ry * 2 * scale)
            .offset(x: (center.x - 60) * scale, y: (center.y - 70) * scale)
    }

    private var restingEyes: some View {
        Group {
            MubiShape(d: MubiArt.eyeClosedLeft)
                .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            MubiShape(d: MubiArt.eyeClosedRight)
                .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }

    /// Upward closed-happy arcs (`q -8` style from the prototype petArt).
    private var smilingEyes: some View {
        Group {
            Path { path in
                path.move(to: CGPoint(x: 42, y: 66))
                path.addQuadCurve(to: CGPoint(x: 52, y: 66),
                                  control: CGPoint(x: 47, y: 58))
            }
            .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: artSize.width, height: artSize.height)
            Path { path in
                path.move(to: CGPoint(x: 69, y: 66))
                path.addQuadCurve(to: CGPoint(x: 79, y: 66),
                                  control: CGPoint(x: 74, y: 58))
            }
            .stroke(MubiArt.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: artSize.width, height: artSize.height)
        }
    }

    private var blushMarks: some View {
        Group {
            Ellipse().fill(MubiArt.blush)
                .opacity(expression.isSmiling || expression == .wink ? 0.6 : 0.28)
                .frame(width: 14 * scale, height: 7 * scale)
                .offset(x: (36 - 60) * scale, y: (77 - 70) * scale)
            Ellipse().fill(MubiArt.blush)
                .opacity(expression.isSmiling || expression == .wink ? 0.6 : 0.28)
                .frame(width: 14 * scale, height: 7 * scale)
                .offset(x: (85 - 60) * scale, y: (77 - 70) * scale)
        }
    }

    @ViewBuilder private var props: some View {
        switch expression {
        case .water:
            Group {
                MubiShape(d: MubiArt.cupBody)
                    .fill(MubiArt.waterSoft)
                    .overlay(MubiShape(d: MubiArt.cupBody)
                        .stroke(MubiArt.water,
                                style: StrokeStyle(lineWidth: 2)))
                MubiShape(d: MubiArt.cupWater)
                    .fill(MubiArt.water.opacity(0.6))
                MubiShape(d: MubiArt.cupHandle)
                    .stroke(MubiArt.water,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                MubiShape(d: MubiArt.cupHand)
                    .stroke(MubiArt.shadow,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            .frame(width: artSize.width, height: artSize.height)
        case .move:
            MubiShape(d: MubiArt.moveArrowLeft)
                .stroke(MubiArt.move,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: artSize.width, height: artSize.height)
            MubiShape(d: MubiArt.moveArrowRight)
                .stroke(MubiArt.move,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: artSize.width, height: artSize.height)
        case .eyes:
            MubiShape(d: MubiArt.leafProp)
                .stroke(MubiArt.leaf,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: artSize.width, height: artSize.height)
        case .focus:
            MubiShape(d: MubiArt.headphonesBand)
                .stroke(MubiArt.focusTint,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: artSize.width, height: artSize.height)
            MubiShape(d: MubiArt.headphonePadLeft)
                .fill(MubiArt.focusTint)
                .frame(width: artSize.width, height: artSize.height)
            MubiShape(d: MubiArt.headphonePadRight)
                .fill(MubiArt.focusTint)
                .frame(width: artSize.width, height: artSize.height)
        case .done:
            MubiShape(d: MubiArt.ackGlint)
                .fill(MubiArt.done)
                .frame(width: artSize.width, height: artSize.height)
        default:
            EmptyView()
        }
    }

    /// The caption bubble: shown while `chat`, with the little tail.
    @ViewBuilder private var caption: some View {
        Text(L10n.t(expression.captionKey))
            .font(.system(size: 13, weight: .medium))
            .multilineTextAlignment(.center)
            .foregroundColor(dark ? MubiArt.captionInkDark : MubiArt.captionInkLight)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(dark ? MubiArt.captionBgDark : MubiArt.captionBgLight))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(dark ? MubiArt.captionBgDark : MubiArt.captionBgLight)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
                    .offset(y: 4)
            }
            .padding(.bottom, 6)
    }

    /// 360 ms single-shot feedback per the contract; never a loop. Reduce
    /// Motion keeps the static expression (no hop/squish).
    private func playExpressionAnimation(_ value: MubiExpression) {
        hop = false
        landedSquish = false
        nod = false
        let motionAllowed = !systemReduceMotion
        guard motionAllowed else { return }
        switch value {
        case .done:
            withAnimation(.easeOut(duration: 0.36)) { hop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                withAnimation(.easeInOut(duration: 0.2)) { hop = false }
            }
        case .landed:
            withAnimation(.easeOut(duration: 0.18)) { landedSquish = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeInOut(duration: 0.2)) { landedSquish = false }
            }
        case .later:
            withAnimation(.easeInOut(duration: 0.36)) { nod = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                withAnimation(.easeInOut(duration: 0.2)) { nod = false }
            }
        default:
            break
        }
    }
}

// MARK: - invitation card

/// The invitation attached to the pet: 做到了 / 只做了一部分 / 稍后 / 隐藏这次.
/// The pet's surface itself is excluded from completion on purpose.
struct CompanionInvitationCard: View {
    @ObservedObject var presentation: CompanionPresentation
    var onDoneAll: (() -> Void)?
    var onLater: (() -> Void)?
    var onHideThis: (() -> Void)?
    var onConfirmPartial: (([String]) -> Void)?
    @Environment(\.colorScheme) private var scheme
    @State private var selected: Set<String> = []
    private var partialExpanded: Bool { presentation.partialExpanded }

    private var dark: Bool { scheme == .dark }
    private var surface = Color(hex: "#F8F7F3")
    private var surfaceDark = Color(hex: "#282622")
    private var edge = Color.white.opacity(0.10)
    private var ink = Color(hex: "#26241F")
    private var inkDark = Color(hex: "#F1EBDF")
    private var muted = Color(hex: "#655F55")
    private var mutedDark = Color(hex: "#C0B5A4")
    private var accent = Color(hex: "#A7472C")
    private var accentDark = Color(hex: "#EFAA85")

    private var invitation: CompanionInvitation? { presentation.invitation }
    private var fg: Color { dark ? inkDark : ink }
    private var mutedColor: Color { dark ? mutedDark : muted }
    private var accentColor: Color { dark ? accentDark : accent }

    var body: some View {
        if let invitation {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(invitationTitle(for: invitation.kinds))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        onHideThis?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(mutedColor)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("invite.hideClose"))
                    .help(L10n.t("invite.hideClose"))
                }
                HStack(spacing: 8) {
                    Button {
                        onDoneAll?()
                    } label: {
                        Text(L10n.t("tray.cueDone"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(dark ? Color(hex: "#241C16") : surface)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(accentColor))
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("tray.cueDone"))
                    Button {
                        onLater?()
                    } label: {
                        Text(L10n.t("invite.later"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(fg)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                    .buttonStyle(.plain)
                }
                if partialExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(invitation.kinds, id: \.self) { kind in
                            Toggle(isOn: Binding(
                                get: { selected.contains(kind) },
                                set: { value in
                                    if value { selected.insert(kind) }
                                    else { selected.remove(kind) }
                                })) {
                                Text(L10n.t("invite.itemDone", kindWord(kind)))
                                    .font(.system(size: 13))
                                    .foregroundColor(fg)
                            }
                            .toggleStyle(.checkbox)
                        }
                        Button {
                            onConfirmPartial?(invitation.kinds.filter { selected.contains($0) })
                        } label: {
                            Text(L10n.t("invite.partialConfirm"))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(fg)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                        .buttonStyle(.plain)
                        .disabled(selected.isEmpty)
                        Text(L10n.t("invite.partialNote"))
                            .font(.system(size: 11.5))
                            .foregroundColor(mutedColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                } else {
                    Button {
                        selected = Set(invitation.kinds)
                        presentation.partialExpanded = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.t("invite.partial"))
                                .font(.system(size: 12.5, weight: .medium))
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(mutedColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(width: 248, alignment: .leading)
            .onChange(of: presentation.invitation == nil) { gone in
                if gone { presentation.partialExpanded = false }
            }
            .background(RoundedRectangle(cornerRadius: 14)
                .fill(dark ? surfaceDark : surface))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(edge, lineWidth: 1))
            .shadow(color: Color.black.opacity(dark ? 0.32 : 0.10),
                    radius: 12, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(invitationTitle(for: invitation.kinds))
        }
    }
}

/// The pet's ••• button (36x28 capsule per the prototype). Reports its
/// window-relative frame; the controller converts it to screen coordinates.
struct CompanionMenuButton: View {
    var onOpen: (NSRect) -> Void
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        GeometryReader { geo in
            Button {
                onOpen(geo.frame(in: .global))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(dark ? Color(hex: "#C0B5A4")
                                          : Color(hex: "#655F55"))
                    .frame(width: 36, height: 28)
                    .background(
                        Capsule()
                            .fill(dark ? Color(hex: "#282622").opacity(0.65)
                                       : Color(hex: "#F8F7F3").opacity(0.65)))
                    .overlay(Capsule()
                        .strokeBorder(dark ? Color.white.opacity(0.12)
                                           : Color.black.opacity(0.10),
                                      lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable()
            .accessibilityLabel(L10n.t("pet.menuOpen"))
            .help(L10n.t("pet.menuOpen"))
        }
        .frame(width: 36, height: 30)
    }
}

/// Hosting view that can opt into AppKit's background-drag behaviour only
/// while an explicit drag is armed. Otherwise the panel stays pointer-
/// through outside the proximity flip (issue #54).
private final class CompanionHostingView: NSHostingView<AnyView> {
    var allowsWindowDrag = false
    override var mouseDownCanMoveWindow: Bool { allowsWindowDrag }
}

extension Notification.Name {
    /// Arrow-key move command posted by the focused pet button.
    static let companionMoveCommand =
        Notification.Name("companionMoveCommand")
}

/// Borderless panel that can take key focus for keyboard petting/moving
/// without activating the app.
private final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - controller

@MainActor
final class CompanionController: NSObject {
    private var panel: CompanionPanel?
    private var presentation = CompanionPresentation()
    private var host: CompanionHostingView?
    private var moodResetTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    // One short approach per real due cue is GONE with the 2026-11-15
    // contract: the invitation waits attached to the pet. No roaming timer.
    private let bodySize: CGFloat = 78
    private var suspended = false
    // Issue #104 + owner decision 2026-11-10: a directly placed home
    // position (per-mille of the usable work area; -1 = the default
    // bottom-right corner), written whenever the user drags Mubi.
    private var freeX: Int64 = -1
    private var freeY: Int64 = -1
    private var placementSaveTask: Task<Void, Never>?
    /// Polls the pointer to flip the panel between click-through and
    /// interactive whenever the cursor rests on it — pet, buttons, drag.
    private var proximityTask: Task<Void, Never>?
    /// Persist the normalized position after a user drag (debounced).
    var onPlacementChanged: ((Int64, Int64) -> Void)?
    /// Petting = companionship only (2026-11-15 contract). Never completion.
    var onPat: (() -> Void)?
    var onDoneAll: (() -> Void)?
    var onLater: (() -> Void)?
    var onHideThis: (() -> Void)?
    var onConfirmPartial: (([String]) -> Void)?
    /// The pet's ••• button with its screen rect — the host pops the same
    /// menu as the tray at that anchor.
    var onMenuButton: ((NSRect) -> Void)?
    /// Move-command rect → the host clamps/persists; returns the applied dx/dy.
    var onMoveCommand: ((NSRect, NSScreen?) -> Void)?

    private var eventMonitors: [Any] = []
    private var globalDragMonitor: Any?
    private var keyMonitor: Any?
    // Drag state (8 px 2D threshold, pointer-capture semantics).
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint?
    private var dragging = false
    private var lastDragEndAt = Date.distantPast
    private var patCount = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(moveCommandArrived(_:)),
            name: .companionMoveCommand, object: nil)
    }

    // The controller lives for the process lifetime (owned by the app
    // delegate), so event monitors never need explicit removal. deinit only
    // drops the notification observation — Swift 6 forbids touching the
    // non-Sendable monitor state from a nonisolated deinit.
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: presentation

    func applyConfig(freeX: Int64, freeY: Int64) {
        self.freeX = freeX
        self.freeY = freeY
        if let panel, panel.isVisible { relayout() }
    }

    /// One click from the menu clears the drag-placed home and parks Mubi at
    /// the default corner. Moving never edits cue completion/snooze.
    func resetHome() {
        freeX = -1
        freeY = -1
        onPlacementChanged?(freeX, freeY)
        if panel?.isVisible == true { relayout() }
    }

    /// The invitation waits attached to the pet (no visit, no travel). The
    /// expression derives from the invitation's kinds unless a short mood
    /// (held/done/...) is playing.
    func update(invitation: CompanionInvitation?, suspended: Bool) {
        self.suspended = suspended
        presentation.invitation = (suspended || invitation?.kinds.isEmpty != false)
            ? nil : invitation
        settleBaseExpression()
        ensurePresented()
    }

    func setSuspended(_ enabled: Bool) {
        suspended = enabled
        if enabled { presentation.invitation = nil }
        settleBaseExpression()
        ensurePresented()
    }

    /// Tray 逐项确认: reveal the invitation with its checklist expanded.
    func revealPartial() {
        if presentation.invitation != nil, !suspended {
            presentation.partialExpanded = true
        }
    }

    /// Idle waiting (no pending cues): quiet, no caption.
    func showIdle() {
        presentation.invitation = nil
        settleBaseExpression()
        ensurePresented()
    }

    /// A short mood around interaction: caption + expression for ~2.2 s,
    /// then back to the base state. Patting rotates happy → wink → peek.
    func react(_ expression: MubiExpression, speak: Bool = true) {
        presentation.expression = expression
        presentation.chat = speak
        moodResetTask?.cancel()
        moodResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.presentation.chat = false
            self.settleBaseExpression()
        }
    }

    /// Pat responses rotate (prototype: happy → wink → peek).
    func reactPat() {
        patCount += 1
        react([.happy, .wink, .peek][(patCount - 1) % 3])
    }

    /// Completion flourish: single light hop + sparkles at the pet.
    func showAck() {
        react(.done)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // MARK: expression derivation

    private func settleBaseExpression() {
        // A short mood owns the surface until its task resets it.
        if moodResetTask != nil, !(moodResetTask?.isCancelled ?? true),
           presentation.expression == .held || presentation.expression == .landed {
            return
        }
        if dragging { return }
        if presentation.chat && presentation.expression != .waiting {
            // Keep the recent-interaction mood visible for its 2.2 s.
            return
        }
        presentation.chat = false
        presentation.expression = baseExpression
    }

    private var baseExpression: MubiExpression {
        if suspended { return .sleep }
        if let kinds = presentation.invitation?.kinds {
            if kinds.contains("water") { return .water }
            if kinds.contains("move") { return .move }
            if kinds.contains("micro") { return .eyes }
        }
        return .waiting
    }

    // MARK: surface management

    private func ensurePresented() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if host == nil {
            let character = MubiCharacterView(presentation: presentation,
                                              onPat: { [weak self] in self?.handlePat() })
            let invitation = CompanionInvitationCard(
                presentation: presentation,
                onDoneAll: { [weak self] in self?.onDoneAll?() },
                onLater: { [weak self] in self?.onLater?() },
                onHideThis: { [weak self] in self?.onHideThis?() },
                onConfirmPartial: { [weak self] kinds in
                    self?.onConfirmPartial?(kinds) })
            let root = VStack(spacing: 8) {
                invitation
                character
                menuButton
            }
            .padding(.init(top: 0, leading: 0, bottom: 4, trailing: 0))
            let anyView = AnyView(
                root.environment(\.layoutDirection, .leftToRight))
            let newHost = CompanionHostingView(rootView: anyView)
            panel.contentView = newHost
            host = newHost
        }
        if let host {
            // Re-measure on every presentation change: the invitation's
            // appearance toggles the panel height (it grows upward from the
            // pet; AppKit keeps the origin = the pet's bottom edge).
            // NOTE: no .preferredContentSize sizing option — with it the
            // hosting view reports a zero fittingSize and the panel
            // collapses to 0x0 (verified 2026-11-17).
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            panel.setContentSize(size)
            relayout()
        }
        // NSPanel never activates the app; outside the pointer-proximity
        // flip the whole window ignores mouse events (#54 fallback).
        panel.orderFrontRegardless()
        startProximityMonitor()
    }

    private var menuButton: some View {
        CompanionMenuButton { [weak self] windowRect in
            guard let self, let panel = self.panel else { return }
            self.onMenuButton?(panel.convertToScreen(windowRect))
        }
    }

    private func handlePat() {
        // A drag that just ended must not fire a pat (prototype justDragged).
        guard Date().timeIntervalSince(lastDragEndAt) > 0.25 else { return }
        onPat?()
        reactPat()
    }

    private func makePanel() -> CompanionPanel {
        let panel = CompanionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 180),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above every app window, including fullscreen Spaces: a reminder
        // that can be covered is not a reminder (#140).
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        installEventMonitors()
        return panel
    }

    private func relayout() {
        guard let panel, let contentView = panel.contentView,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let size = contentView.fittingSize
        panel.setContentSize(size)
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
            x = safe.minX + clearance + travelW * CGFloat(freeX) / 1000
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

    private func clampIntoWorkArea() {
        guard let panel,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let safe = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(safe.minX, frame.origin.x),
                             safe.maxX - frame.width)
        frame.origin.y = min(max(safe.minY, frame.origin.y),
                             safe.maxY - frame.height)
        panel.setFrameOrigin(frame.origin)
    }

    // MARK: pettable + draggable window

    /// Flip the panel between full pointer-through and interactive based on
    /// pointer proximity — the surface stays pointer-through everywhere
    /// except while the cursor rests on it (issue #54).
    private func startProximityMonitor() {
        proximityTask?.cancel()
        proximityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let panel = self.panel else { return }
                let hittable = NSPointInRect(NSEvent.mouseLocation, panel.frame)
                if panel.ignoresMouseEvents != !hittable {
                    panel.ignoresMouseEvents = !hittable
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return }
            }
        }
    }

    // MARK: drag (8 px 2D threshold + capture semantics)

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }
        eventMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
            handler: { [weak self] event in self?.handleLocalDragEvent(event) ?? event }))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else {
                return event
            }
            // Escape never completes anything; it only releases a drag.
            if event.keyCode == 53, self.dragging {
                self.endDrag(commit: false)
                return nil
            }
            return event
        }
    }

    /// Pointer-capture semantics: while a drag runs, the cursor may leave
    /// the panel — a GLOBAL monitor keeps tracking there (a local monitor
    /// only sees events routed to this app's windows). Each event reaches
    /// exactly one of the two monitors, so handlers can share state.
    private func installGlobalDragMonitors() {
        guard globalDragMonitor == nil else { return }
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in self?.handleExternalDragEvent(event) }
        }
    }

    private func removeGlobalDragMonitors() {
        if let monitor = globalDragMonitor {
            NSEvent.removeMonitor(monitor)
            globalDragMonitor = nil
        }
    }

    private func handleLocalDragEvent(_ event: NSEvent) -> NSEvent? {
        guard let panel, panel.isVisible, event.window === panel else {
            return event
        }
        switch event.type {
        case .leftMouseDown:
            dragStart = NSEvent.mouseLocation
            dragOrigin = panel.frame.origin
            dragging = false
            return event
        case .leftMouseDragged:
            guard let start = dragStart, let origin = dragOrigin else {
                return event
            }
            if !dragging {
                let dx = NSEvent.mouseLocation.x - start.x
                let dy = NSEvent.mouseLocation.y - start.y
                // Two-dimensional 8 px threshold (prototype Math.hypot > 8).
                guard hypot(dx, dy) > 8 else { return event }
                dragging = true
                installGlobalDragMonitors()
                presentation.expression = .held
                presentation.chat = true
            }
            performDrag()
            return nil // captured: no click leaks to the buttons mid-drag
        case .leftMouseUp:
            if dragging {
                endDrag(commit: true)
                return nil
            }
            dragStart = nil
            dragOrigin = nil
            return event
        default:
            return event
        }
    }

    private func handleExternalDragEvent(_ event: NSEvent) {
        guard dragging else { return }
        if event.type == .leftMouseUp {
            endDrag(commit: true)
        } else {
            performDrag()
        }
    }

    private func performDrag() {
        guard let start = dragStart, let origin = dragOrigin else { return }
        let dx = NSEvent.mouseLocation.x - start.x
        let dy = NSEvent.mouseLocation.y - start.y
        movePanel(to: NSPoint(x: origin.x + dx, y: origin.y + dy), tilt: dx / 10)
    }

    private func movePanel(to origin: NSPoint, tilt: CGFloat) {
        guard let panel else { return }
        panel.setFrameOrigin(origin)
        presentation.dragTilt = max(-8, min(8, tilt))
    }

    private func endDrag(commit: Bool) {
        dragging = false
        removeGlobalDragMonitors()
        presentation.dragTilt = 0
        lastDragEndAt = Date()
        dragStart = nil
        dragOrigin = nil
        if commit {
            clampIntoWorkArea()
            savePlacement()
            react(.landed)
        } else {
            // Cancelled drags never submit a health response; restore pose.
            presentation.chat = false
            settleBaseExpression()
            if let panel { relayout() }
        }
    }

    /// Arrow keys on the focused pet: move by 8 pt within the work area.
    @objc private func moveCommandArrived(_ note: Notification) {
        guard let panel, panel.isVisible,
              let direction = note.object as? MoveCommandDirection else { return }
        var frame = panel.frame
        switch direction {
        case .left: frame.origin.x -= 8
        case .right: frame.origin.x += 8
        case .up: frame.origin.y += 8
        case .down: frame.origin.y -= 8
        }
        panel.setFrameOrigin(frame.origin)
        clampIntoWorkArea()
        savePlacement()
    }

    /// Convert the placed origin back into per-mille of the usable travel
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
        // A hotplug/work-area change invalidates the old coordinates.
        // Re-dock immediately; the drag-placed home reclamps.
        relayout()
    }
}

enum MoveCommandDirection {
    case left, right, up, down
}

extension CompanionController: NSWindowDelegate {
    /// Debounced persistence while the user drags Mubi. Programmatic moves
    /// (relayout, reset) happen with no mouse buttons held — they must never
    /// be saved as a new home.
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
