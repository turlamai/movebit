import SwiftUI
import AppKit

/// First-run state. The v1 reboot's "less is more" rule (#90): one screen,
/// the real character, one sentence, one Start button — no wizard, no cadence
/// questions, no license promotion, nothing to configure before using the app.
@MainActor
final class OnboardingState: ObservableObject {
    var finished = false

    /// The only first-run write is the "seen" marker: the shipped balanced
    /// rhythm and silent-by-default sound need no confirmation.
    func persist(model: MoveBitModel, welcomeShown: Bool) {
        model.saveConfig(model.config.with(welcome_shown: welcomeShown))
    }
}

/// One screen, under 30 seconds: meet Mubi, read one sentence, press Start.
struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    @ObservedObject var model: MoveBitModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            MubiView(state: .idle, message: "", bodySize: 104,
                     motion: "still", labelsAlways: false)
                .frame(height: 150)
                .accessibilityHidden(true)

            Text(L10n.t("ob.hello"))
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Palette.inkPrimary)
                .padding(.top, 10)

            Text(L10n.t("ob.line"))
                .font(.system(size: 14.5))
                .foregroundColor(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 12)

            Spacer(minLength: 14)

            Text(L10n.t("ob.privacy"))
                .font(.system(size: 11.5))
                .foregroundColor(Palette.inkMuted)

            Button {
                finish()
            } label: {
                Text(L10n.t("ob.start"))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 12)

            Text(L10n.t("ob.startHint"))
                .font(.system(size: 11))
                .foregroundColor(Palette.inkMuted)
                .padding(.top, 8)
        }
        .padding(28)
        .frame(width: 460, height: 520)
        .background(Palette.appBg)
    }

    private func finish() {
        state.finished = true
        state.persist(model: model, welcomeShown: true)
        AppDelegate.shared?.onboardingFinished()
        AppDelegate.shared?.closeOnboarding()
    }
}
