import SwiftUI

/// Modal sheet requiring users to acknowledge their obligation to comply with
/// applicable recording consent laws before using the transcription feature.
struct RecordingConsentView: View {
    @Binding var isPresented: Bool
    @Bindable var settings: AppSettings
    @State private var acknowledged = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Recording is the red domain in the token semantics.
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LoreTheme.Accent.red)
                .frame(height: 52)

            Spacer().frame(height: 20)

            Text("Recording Consent Notice")
                .font(LoreTheme.Typography.heading)
                .foregroundStyle(LoreTheme.TextColor.primary)
                .multilineTextAlignment(.center)

            Spacer().frame(height: 10)

            Text("""
            \(LoreTheme.wordmark) records and transcribes audio from your microphone \
            and system audio during meetings. Many jurisdictions require \
            all-party consent before recording a conversation.

            By using this app, you acknowledge that:
            """)
                .font(LoreTheme.Typography.body)
                .foregroundStyle(LoreTheme.TextColor.muted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer().frame(height: 12)

            VStack(alignment: .leading, spacing: 8) {
                LoreBulletRow(text: "You are solely responsible for obtaining any required consent from all participants before recording.")
                LoreBulletRow(text: "You will comply with all applicable local, state, and federal laws governing recording and wiretapping.")
                LoreBulletRow(text: "The developers of \(LoreTheme.wordmark) accept no liability for unauthorized or unlawful recording.")
            }
            .padding(.horizontal, 8)

            Spacer().frame(height: 16)

            Toggle(isOn: $acknowledged) {
                Text("I understand and accept these obligations")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LoreTheme.TextColor.primary)
            }
            .toggleStyle(.checkbox)

            Spacer()

            LoreOnboardingFooter(
                leadingTitle: "Cancel",
                leadingAction: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                },
                primaryTitle: "I Agree",
                primaryEnabled: acknowledged,
                primaryProminent: false
            ) {
                settings.hasAcknowledgedRecordingConsent = true
                withAnimation(.easeOut(duration: 0.2)) {
                    isPresented = false
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LoreTheme.Surface.window)
        .background(.ultraThinMaterial)
    }
}
